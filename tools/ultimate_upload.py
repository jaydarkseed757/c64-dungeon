#!/usr/bin/env python3
"""FTP this project's release files to the C64 Ultimate's USB drive.

Files land in <USB>/dist/dungeon-master/ (the folder name ../ultimate-dist uses
for this project: directory name without "c64-"). The USB root is auto-detected
(first top-level entry named usb*), or set with --usb.

  python3 tools/ultimate_upload.py             list, ask once, upload
  python3 tools/ultimate_upload.py --dry-run   list files only, no FTP
  python3 tools/ultimate_upload.py --yes       upload without asking

Environment: ULT_HOST (default 192.168.10.148), ULT_FTP_USER / ULT_FTP_PASSWORD
(default anonymous login). Standard library only. Every upload is size-checked.
Based on ../ultimate-dist/ultimate_dist.py.
"""
import argparse
import ftplib
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_HOST = "192.168.10.148"
TIMEOUT = 15
REMOTE_NAME = "dungeon-master"

# (local path relative to the project, name on the Ultimate)
MANIFEST = [
    ("terminal/build/dm64.prg", "DM64.PRG"),                  # the AI terminal
    ("game/build/dm64game.prg", "DM64GAME.PRG"),              # the dungeon game (Milestone 5, no AI yet)
    ("models/exported/baseline_bpe72_v3q.d64ai", "DM64AI.REU"),       # .REU: the menu offers "Load into REU"
    ("models/exported/baseline_bpe72_v3q.manifest.json", "MANIFEST.JSON"),
    ("release/README.txt", "README.TXT"),
]


def log(msg=""):
    print(msg, flush=True)


def ftp_connect(host):
    user = os.environ.get("ULT_FTP_USER") or "anonymous"
    log(f"FTP connect {host} as {user}")
    ftp = ftplib.FTP(host, timeout=TIMEOUT)
    ftp.login(user, os.environ.get("ULT_FTP_PASSWORD", ""))
    ftp.voidcmd("TYPE I")
    return ftp


def names_in(ftp, path):
    try:
        return {n.rstrip("/").rsplit("/", 1)[-1] for n in ftp.nlst(path)}
    except ftplib.error_perm:
        return set()


def detect_usb(ftp):
    usb = sorted(n for n in names_in(ftp, "/") if n.lower().startswith("usb"))
    if not usb:
        sys.exit("no USB drive found at the Ultimate's FTP root; pass --usb")
    if len(usb) > 1:
        log(f"several USB roots ({', '.join(usb)}); using /{usb[0]} (override with --usb)")
    return "/" + usb[0]


def ensure_dir(ftp, path):
    parent, name = path.rstrip("/").rsplit("/", 1)
    if name not in names_in(ftp, parent or "/"):
        log(f"MKD {path}")
        ftp.mkd(path)


def upload(ftp, local, remote):
    n = local.stat().st_size
    with open(local, "rb") as f:
        ftp.storbinary(f"STOR {remote}", f)
    try:
        got = ftp.size(remote)
    except ftplib.error_perm:
        got = None
    if got != n:
        raise ftplib.Error(f"size check failed: local {n}, remote {got}")
    return n


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default=os.environ.get("ULT_HOST", DEFAULT_HOST))
    ap.add_argument("--usb", help="USB root on the Ultimate, e.g. /USB1 (default: auto)")
    ap.add_argument("--dry-run", action="store_true", help="list files, no FTP")
    ap.add_argument("--check", action="store_true",
                    help="connect and list the target folder only (read-only)")
    ap.add_argument("--yes", "-y", action="store_true", help="don't ask before uploading")
    args = ap.parse_args()

    files, missing = [], []
    for rel, remote in MANIFEST:
        f = ROOT / rel
        (files if f.is_file() else missing).append((f, remote, rel))
    for f, remote, _ in files:
        log(f"  dist/{REMOTE_NAME}/{remote}  ({f.stat().st_size:,} bytes)  <- {f.relative_to(ROOT)}")
    for _, _, rel in missing:
        log(f"  MISSING: {rel}")
    if missing:
        sys.exit("missing release files (run `make convert`, `make terminal` and `make game` first)")
    if args.dry_run:
        log("\ndry run, nothing uploaded")
        return

    try:
        ftp = ftp_connect(args.host)
    except (OSError, ftplib.Error) as e:
        sys.exit(f"cannot connect to {args.host}: {e}\n"
                 "Is the Ultimate on, on the network, and is its FTP service enabled?")
    failed = False
    try:
        usb = args.usb.rstrip("/") if args.usb else detect_usb(ftp)
        target = f"{usb}/dist/{REMOTE_NAME}"
        if args.check:
            have = names_in(ftp, target)
            log(f"{args.host}:{target}/ " + (f"contains: {', '.join(sorted(have))}" if have
                                             else "does not exist yet (or is empty)"))
            return
        if not args.yes:
            ans = input(f"\nupload {len(files)} files to {args.host}:{target}/ (overwriting)? [y/N] ")
            if ans.strip().lower() != "y":
                sys.exit("cancelled")
        ensure_dir(ftp, f"{usb}/dist")
        ensure_dir(ftp, target)
        for f, remote, _ in files:
            try:
                n = upload(ftp, f, f"{target}/{remote}")
                log(f"{target}/{remote}: {n:,} bytes, verified")
            except (OSError, ftplib.Error) as e:
                log(f"FAILED {remote}: {e}")
                failed = True
    finally:
        try:
            ftp.quit()
        except (OSError, ftplib.Error):
            pass
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
