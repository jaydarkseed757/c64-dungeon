#!/usr/bin/env python3
"""Capture the C64 Ultimate's screen as a PNG.

    python3 tools/ult_screenshot.py out.png [--mode auto|stream|memory] [--host IP]

stream: one frame of the VIC video stream (needs the Ultimate's wired Ethernet;
        over WiFi the firmware answers "No Operational Network Interface").
memory: text-mode reconstruction from memory read over REST (machine:readmem of
        screen RAM, colour RAM, $D018/$D020/$D021) drawn with the C64 character
        ROM from the local VICE installation. Exact for standard text mode only
        (no sprites, bitmap, multicolour or raster effects).
auto:   stream, falling back to memory.

Starts the video stream with PUT /v1/streams/video:start?ip=<me>:<port>, receives
UDP packets until one complete frame (between two end-of-frame packets) has
arrived, stops the stream (PUT /v1/streams/video:stop) and writes a PNG.
Packet format from the Ultimate documentation ("Data Streams"): 12-byte header
(seq, frame, line | $8000 on the last packet, 384, 4 lines, 4 bpp, encoding 0),
then 4 x 384 pixels of 4-bit VIC colour, low nibble first. Standard library only.
"""
import argparse
import os
import socket
import struct
import sys
import urllib.error
import urllib.request
import zlib
from pathlib import Path

# VIC-II colours (the commonly used "Pepto" PAL palette)
PALETTE = [(0, 0, 0), (255, 255, 255), (104, 55, 43), (112, 164, 178), (111, 61, 134),
           (88, 141, 67), (53, 40, 121), (184, 199, 111), (111, 79, 37), (67, 57, 0),
           (154, 103, 89), (68, 68, 68), (108, 108, 108), (154, 210, 132), (108, 94, 181),
           (149, 149, 149)]


def my_ip(host):
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.connect((host, 80))
        return s.getsockname()[0]


def put(host, path):
    req = urllib.request.Request(f"http://{host}/v1/{path}", data=b"", method="PUT")
    with urllib.request.urlopen(req, timeout=10) as r:
        return r.read()


def capture(host, me, port, timeout=10):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 22)
    sock.bind(("0.0.0.0", port))
    sock.settimeout(timeout)
    put(host, f"streams/video:start?ip={me}:{port}")
    try:
        lines, started, frame = {}, False, None
        while True:
            data, _ = sock.recvfrom(2048)
            if len(data) < 12:
                continue
            seq, frm, line, width, lpp, bpp, enc = struct.unpack_from("<HHHHBBH", data, 0)
            last = bool(line & 0x8000)
            line &= 0x7FFF
            if not started:
                started = last              # begin after an end-of-frame packet
                continue
            if frame is None:
                frame = frm
            if frm != frame:
                lines, frame = {}, frm      # a frame changed mid-way: start over
            px = data[12:12 + width * lpp // 2]
            for k in range(lpp):
                row = []
                for b in px[k * width // 2:(k + 1) * width // 2]:
                    row += [b & 15, b >> 4]
                lines[line + k] = row
            if last:
                return width, lines
    finally:
        put(host, "streams/video:stop")
        sock.close()


CHARGEN = Path("/opt/homebrew/share/vice/C64/chargen-901225-01.bin")


def readmem(host, addr, n):
    with urllib.request.urlopen(f"http://{host}/v1/machine:readmem?address={addr:04X}&length={n}",
                                timeout=10) as r:
        return r.read()


def capture_memory(host, read=None):
    """Render standard text mode (VIC bank 0 assumed) as the stream would show it: 384x272.
    `read(addr, n)` defaults to REST readmem on `host` (tests pass a VICE reader)."""
    if read is None:
        def read(addr, n):
            return readmem(host, addr, n)
    rom = None
    for cand in [CHARGEN, *Path("/opt/homebrew/Cellar/vice").glob("*/share/vice/C64/chargen-901225-01.bin")]:
        if cand.exists():
            rom = cand.read_bytes()
            break
    if rom is None:
        sys.exit("C64 character ROM not found (install VICE)")
    d018, = read(0xD018, 1)
    border, bg = (c & 15 for c in read(0xD020, 2))
    screen_addr = (d018 >> 4) * 1024
    char_sel = (d018 >> 1) & 7                 # $1000 (upper) / $1800 (lower) map to the ROM in bank 0
    font = rom[0x800:0x1000] if char_sel == 3 else rom[0:0x800]
    scr = read(screen_addr, 1000)
    col = [c & 15 for c in read(0xD800, 1000)]
    width, height, x0, y0 = 384, 272, 32, 35
    lines = {y: [border] * width for y in range(height)}
    for row in range(25):
        for cy in range(8):
            y = y0 + row * 8 + cy
            line = lines[y]
            for c in range(40):
                bits = font[scr[row * 40 + c] * 8 + cy]
                fg = col[row * 40 + c]
                for b in range(8):
                    line[x0 + c * 8 + b] = fg if bits & (0x80 >> b) else bg
    return width, lines


def write_png(path, width, lines, scale=1):
    height = max(lines) + 1
    raw = bytearray()
    for y in range(height):
        row = bytearray()
        for c in lines.get(y, [0] * width):
            row += bytes(PALETTE[c]) * scale
        for _ in range(scale):
            raw.append(0)
            raw += row
    width, height = width * scale, height * scale

    def chunk(tag, body):
        return struct.pack(">I", len(body)) + tag + body + struct.pack(">I", zlib.crc32(tag + body) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)) \
        + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)
    return height


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("out")
    ap.add_argument("--host", default=os.environ.get("ULT_HOST", "192.168.10.148"))
    ap.add_argument("--me", help="this machine's LAN address (default: auto)")
    ap.add_argument("--port", type=int, default=11000)
    ap.add_argument("--mode", choices=["auto", "stream", "memory"], default="auto")
    ap.add_argument("--scale", type=int, default=1, help="integer upscale (nearest neighbour)")
    args = ap.parse_args()
    how = None
    if args.mode in ("auto", "stream"):
        me = args.me or my_ip(args.host)
        try:
            width, lines = capture(args.host, me, args.port)
            how = f"video stream to {me}:{args.port}"
        except (socket.timeout, urllib.error.HTTPError) as e:
            if args.mode == "stream":
                sys.exit(f"video stream failed: {e}")
            print(f"video stream unavailable ({e}); using the memory reconstruction", file=sys.stderr)
    if how is None:
        width, lines = capture_memory(args.host)
        how = "text-mode reconstruction from memory"
    h = write_png(args.out, width, lines, args.scale)
    print(f"{args.out}: {width}x{h} from {args.host} ({how})")


if __name__ == "__main__":
    main()
