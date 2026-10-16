#!/usr/bin/env python3
"""make_stock_manifest.py - list the gamedata files that install/install.bash
fetches instead of the package shipping them.

A file of the assembled gamedata/ is a stock file if its content is a file of
the Unreal Gold ISO (the one OldUnreal's Linux installer downloads) or of the
OldUnreal 227k_15 Linux patch. The package leaves those files out, and the
installer extracts them from the two downloads on the device. Content, not
path, decides: a mod map that is a byte-identical copy of a stock map is
extracted from the ISO as well. Every other file ships with the package.

The two archives are read unpacked:

    7zz x -oISO_DIR UNREAL_GOLD.ISO
    mkdir PATCH_DIR && tar -xjf OldUnreal-UnrealPatch227k-Linux.tar.bz2 -C PATCH_DIR

Symbolic links in the patch are skipped; a file that equals a link's target
is extracted from the target, since exFAT has no links.

Usage:
    make_stock_manifest.py --gamedata DIR --iso-dir DIR --patch-dir DIR \
        --id ID --out FILE [--shipped FILE] [--exclude GLOB]...

--exclude leaves out the files of gamedata/ whose path matches GLOB (any
letter case): the package neither ships them nor installs them.

Output, one line per stock file of gamedata/, tab-separated:

    archive (iso or patch)  path in the archive  size  sha256  path in gamedata/

after "# " comment lines, of which "# id: ID" names this list: the launcher
reruns the installer when the id differs from the one the last successful
install recorded. --shipped writes the files of gamedata/ that are not stock,
one path per line.
"""
import argparse
import fnmatch
import hashlib
import os
import sys

ARCHIVES = ("iso", "patch")
# 7-Zip reads these as wildcards in a list file.
LISTFILE_UNSAFE = set("*?")


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def files(root):
    """Relative path -> absolute path of every regular file under root."""
    out = {}
    for d, dirs, names in os.walk(root):
        dirs.sort()
        for n in sorted(names):
            p = os.path.join(d, n)
            if not os.path.islink(p):
                out[os.path.relpath(p, root)] = p
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--gamedata", required=True)
    ap.add_argument("--iso-dir", required=True)
    ap.add_argument("--patch-dir", required=True)
    ap.add_argument("--id", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--shipped")
    ap.add_argument("--exclude", action="append", default=[])
    args = ap.parse_args()
    excluded = [g.lower() for g in args.exclude]

    # (size, sha256) -> [(archive, path)], each archive in sorted path order.
    sources = {}
    for archive, root in zip(ARCHIVES, (args.iso_dir, args.patch_dir)):
        for rel, p in files(root).items():
            key = (os.path.getsize(p), sha256(p))
            sources.setdefault(key, []).append((archive, rel))

    rows, shipped = [], []
    for rel, p in files(args.gamedata).items():
        if any(fnmatch.fnmatchcase(rel.lower(), g) for g in excluded):
            continue
        size = os.path.getsize(p)
        digest = sha256(p)
        candidates = sources.get((size, digest))
        if not candidates:
            shipped.append(rel)
            continue
        # The same path (ISO folders are upper case) first, then the patch,
        # whose files the OldUnreal installer lays over the ISO's.
        archive, src = min(candidates, key=lambda c: (c[1].lower() != rel.lower(), c[0] != "patch", c[1]))
        # install.bash reads sizes and names from "ls -ln", split at blanks.
        if LISTFILE_UNSAFE & set(src) or any(c.isspace() for c in src + rel):
            sys.exit("make_stock_manifest: unsupported character in %s or %s" % (src, rel))
        rows.append((archive, src, size, digest, rel))

    rows.sort(key=lambda r: (ARCHIVES.index(r[0]), r[1], r[4]))
    with open(args.out, "w", encoding="utf-8", newline="\n") as out:
        out.write("# Stock Unreal Gold files of gamedata/, fetched by install/install.bash.\n")
        out.write("# Written by source/tools/make_stock_manifest.py.\n")
        out.write("# id: %s\n" % args.id)
        out.write("# archive\tpath in archive\tsize\tsha256\tpath in gamedata/\n")
        for r in rows:
            out.write("%s\t%s\t%d\t%s\t%s\n" % r)
    if args.shipped:
        with open(args.shipped, "w", encoding="utf-8", newline="\n") as out:
            out.writelines(rel + "\n" for rel in sorted(shipped))

    for archive in ARCHIVES:
        mine = [r for r in rows if r[0] == archive]
        print("%-5s %4d files, %d bytes" % (archive, len(mine), sum(r[2] for r in mine)))
    print("ship  %4d files, %d bytes" % (len(shipped), sum(os.path.getsize(os.path.join(args.gamedata, s)) for s in shipped)))


if __name__ == "__main__":
    main()
