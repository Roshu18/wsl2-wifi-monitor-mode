#!/usr/bin/env python3
import argparse
import glob
import os
import subprocess
import sys

MASK = 0xFFFFFFFF


def read_kallsyms(path):
    crcs = {}
    owners = {}
    try:
        fh = open(path, "r", errors="replace")
    except OSError:
        return crcs, owners
    with fh:
        for line in fh:
            parts = line.split()
            if len(parts) < 3:
                continue
            name = parts[2]
            if not name.startswith("__crc_"):
                continue
            try:
                crc = int(parts[0], 16) & MASK
            except ValueError:
                continue
            if crc == 0:
                continue
            sym = name[len("__crc_"):]
            crcs[sym] = crc
            if len(parts) >= 4 and parts[3].startswith("[") and parts[3].endswith("]"):
                owners[sym] = parts[3][1:-1]
            else:
                owners[sym] = "vmlinux"
    return crcs, owners


def read_shipped_modules(moddir, limit=4000):
    crcs = {}
    if not moddir or not os.path.isdir(moddir):
        return crcs
    patterns = ("*.ko", "*.ko.xz", "*.ko.gz", "*.ko.zst")
    files = []
    for pat in patterns:
        files.extend(glob.glob(os.path.join(moddir, "**", pat), recursive=True))
        if len(files) >= limit:
            break
    for ko in files[:limit]:
        try:
            res = subprocess.run(
                ["modprobe", "--dump-modversions", ko],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                timeout=30,
            )
        except (OSError, subprocess.SubprocessError):
            continue
        if res.returncode != 0:
            continue
        for line in res.stdout.decode("utf-8", "replace").splitlines():
            fields = line.split()
            if len(fields) != 2:
                continue
            try:
                crc = int(fields[0], 16) & MASK
            except ValueError:
                continue
            if crc == 0:
                continue
            crcs.setdefault(fields[1], crc)
    return crcs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kallsyms", default="/proc/kallsyms")
    ap.add_argument("--modules-dir", default="")
    ap.add_argument("--out", default="-")
    ap.add_argument("--min-symbols", type=int, default=1)
    args = ap.parse_args()

    kall, owners = read_kallsyms(args.kallsyms)
    shipped = read_shipped_modules(args.modules_dir) if args.modules_dir else {}

    conflicts = 0
    merged = dict(kall)
    for sym, crc in shipped.items():
        if sym in merged:
            if merged[sym] != crc:
                conflicts += 1
            continue
        merged[sym] = crc
        owners.setdefault(sym, "vmlinux")

    if len(merged) < args.min_symbols:
        print(
            "symbols=0 kallsyms=%d modules=%d conflicts=%d error=no CRCs available"
            % (len(kall), len(shipped), conflicts),
            file=sys.stderr,
        )
        return 1

    lines = []
    for sym in sorted(merged):
        lines.append("0x%08x\t%s\t\t%s\tEXPORT_SYMBOL_GPL" % (merged[sym], sym, owners.get(sym, "vmlinux")))
    body = "\n".join(lines) + "\n"

    if args.out == "-":
        sys.stdout.write(body)
    else:
        tmp = args.out + ".tmp"
        with open(tmp, "w") as fh:
            fh.write(body)
        os.replace(tmp, args.out)

    print(
        "symbols=%d kallsyms=%d modules=%d conflicts=%d" % (len(merged), len(kall), len(shipped), conflicts),
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
