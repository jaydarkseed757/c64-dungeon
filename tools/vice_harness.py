#!/usr/bin/env python3
"""Run a C64 program in VICE (x64sc) under automation.

Uses VICE's binary monitor protocol (API version 2) over TCP to:
  - preload memory and the REU image,
  - start a PRG and wait until the CPU reaches a stop address,
  - read memory back.

    with Vice(reu_image="model.d64ai") as vm:
        vm.load_prg("engine/build/test.prg")
        vm.run_until(stop_addr, timeout=120)
        data = vm.read(0xC000, 0xC0FF)

Timing: programs measure their own cycle counts with CIA timers, which VICE
emulates cycle-exactly at 1 MHz (PAL). Host wall time in warp mode means nothing.
"""
import os
import shutil
import socket
import struct
import subprocess
import tempfile
import time
from pathlib import Path

STX, API = 0x02, 0x02
CMD_MEM_GET, CMD_MEM_SET = 0x01, 0x02
CMD_CHECKPOINT_SET = 0x12
CMD_REGISTERS_GET = 0x31
CMD_REGISTERS_SET = 0x32
CMD_EXIT, CMD_QUIT = 0xAA, 0xBB
CMD_REGISTERS_AVAILABLE = 0x83
EV_STOPPED, EV_RESUMED, EV_CHECKPOINT = 0x62, 0x63, 0x11
X64SC = shutil.which("x64sc") or "/opt/homebrew/bin/x64sc"


class ViceError(RuntimeError):
    pass


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Vice:
    def __init__(self, reu_image=None, reu_kb=16384, extra_args=()):
        self.port = free_port()
        self.tmp = tempfile.mkdtemp(prefix="dm64vice")
        args = [X64SC, "-default", "-pal", "-warp", "-silent", "-sounddev", "dummy",
                "-binarymonitor", "-binarymonitoraddress", f"ip4://127.0.0.1:{self.port}",
                "+confirmonexit", "-reu", "-reusize", str(reu_kb)]
        if reu_image:
            # VICE wants an image of exactly the REU size; pad a copy.
            img = Path(self.tmp) / "reu.img"
            data = Path(reu_image).read_bytes()
            img.write_bytes(data + bytes(reu_kb * 1024 - len(data)))
            args += ["-reuimage", str(img)]
        args += list(extra_args)
        self.proc = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.sock = None
        self.req = 0
        deadline = time.time() + 20
        while time.time() < deadline:
            try:
                self.sock = socket.create_connection(("127.0.0.1", self.port), timeout=5)
                break
            except OSError:
                time.sleep(0.2)
        if self.sock is None:
            self.close()
            raise ViceError("could not connect to VICE binary monitor")
        self.sock.settimeout(None)
        self.buf = b""
        self._regs = self._register_ids()
        self.run_until(0xA474, timeout=30)   # BASIC "READY." after KERNAL cold start

    # ---- protocol ----
    def _send(self, cmd, body=b""):
        self.req += 1
        self.sock.sendall(struct.pack("<BBII B", STX, API, len(body), self.req, cmd) + body)
        return self.req

    def _recv_exact(self, n, timeout=None):
        self.sock.settimeout(timeout)
        while len(self.buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ViceError("VICE closed the connection")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def _recv(self, timeout=None):
        head = self._recv_exact(12, timeout)
        stx, api, length, rtype, err, rid = struct.unpack("<BBIBBI", head)
        if stx != STX:
            raise ViceError("protocol desync")
        return rtype, err, rid, self._recv_exact(length, timeout)

    def _call(self, cmd, body=b"", timeout=30):
        rid = self._send(cmd, body)
        while True:
            rtype, err, got, payload = self._recv(timeout)
            if got == rid:
                if err:
                    raise ViceError(f"command {cmd:#x} failed with error {err:#x}")
                return payload

    def _register_ids(self):
        payload = self._call(CMD_REGISTERS_AVAILABLE, bytes([0]))
        count = struct.unpack_from("<H", payload, 0)[0]
        ids, cursor = {}, 2
        for _ in range(count):
            size = payload[cursor]
            rid, bits, nlen = payload[cursor + 1], payload[cursor + 2], payload[cursor + 3]
            name = payload[cursor + 4:cursor + 4 + nlen].decode()
            ids[name] = rid
            cursor += size + 1
        return ids

    # ---- operations ----
    def read(self, start, end):
        """Read C64 RAM start..end inclusive (CPU view, no side effects)."""
        out = b""
        while start <= end:
            stop = min(end, start + 0xFFFF)
            body = struct.pack("<BHHBH", 0, start, stop, 0, 0)
            payload = self._call(CMD_MEM_GET, body)
            out += payload[2:2 + struct.unpack_from("<H", payload, 0)[0]]
            start = stop + 1
            if stop == 0xFFFF:
                break
        return out

    def write(self, start, data):
        body = struct.pack("<BHHBH", 0, start, start + len(data) - 1, 0, 0) + bytes(data)
        self._call(CMD_MEM_SET, body)

    def registers(self):
        """Stop the CPU (any command does) and return {name: value}."""
        payload = self._call(CMD_REGISTERS_GET, bytes([0]))
        count = struct.unpack_from("<H", payload, 0)[0]
        names = {v: k for k, v in self._regs.items()}
        out, cursor = {}, 2
        for _ in range(count):
            size, rid, value = payload[cursor], payload[cursor + 1], struct.unpack_from("<H", payload, cursor + 2)[0]
            out[names.get(rid, rid)] = value
            cursor += size + 1
        return out

    def set_pc(self, addr):
        body = struct.pack("<BH", 0, 1) + struct.pack("<BBH", 3, self._regs["PC"], addr)
        self._call(CMD_REGISTERS_SET, body)

    def load_prg(self, path, start=None):
        """Write a PRG into RAM (no KERNAL load) and set PC to `start` (default: SYS address
        of a standard BASIC stub, else the load address)."""
        data = Path(path).read_bytes()
        load = data[0] | data[1] << 8
        self.write(load, data[2:])
        if start is None:
            start = load
            if load == 0x0801:
                text = data[2:20]
                i = text.find(0x9E)
                if i >= 0:
                    digits = bytearray()
                    for c in text[i + 1:]:          # stop at the first non-digit
                        if c == 0x20 and not digits:
                            continue
                        if not 0x30 <= c <= 0x39:
                            break
                        digits.append(c)
                    start = int(digits.decode()) if digits else load
        self.set_pc(start)

    def run_until(self, addr, timeout=600):
        """Resume execution and block until the CPU executes `addr`."""
        body = struct.pack("<HHBBBB", addr, addr, 1, 1, 4, 0)
        self._call(CMD_CHECKPOINT_SET, body)
        self._call(CMD_EXIT)
        deadline = time.time() + timeout
        while True:
            remaining = deadline - time.time()
            if remaining <= 0:
                raise ViceError(f"timeout waiting for ${addr:04X}")
            try:
                rtype, _, _, payload = self._recv(timeout=remaining)
            except socket.timeout:
                raise ViceError(f"timeout waiting for ${addr:04X}") from None
            if rtype == EV_STOPPED:
                pc = struct.unpack_from("<H", payload, 0)[0]
                if pc == addr:
                    return
                self._call(CMD_EXIT)

    def close(self):
        try:
            if self.sock:
                self._send(CMD_QUIT)
                self.sock.close()
        except OSError:
            pass
        if self.proc:
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()


if __name__ == "__main__":
    import sys
    with Vice() as vm:
        vm.load_prg(sys.argv[1])
        stop = int(sys.argv[2], 16)
        vm.run_until(stop, timeout=60)
        print(vm.read(int(sys.argv[3], 16), int(sys.argv[4], 16)).hex())
