#!/usr/bin/env python3
"""ue1pkg.py - import checks for the Unreal (227) packages of a game tree.

The engine links a package to its dependencies by name: every import names a
top-level package, an outer path (groups), an object name and the object's
class. A dependency that is missing, or a replacement package that lacks one
of the imported objects, makes the importing map or mod fail to load. These
checks read only the package header and the name, import and export tables.

Commands:
  missing ROOT
      Every top-level package that a package under ROOT imports but that the
      engine cannot find through the Paths= list of the port's UnrealLinux.ini
      (System/*.u, Maps/*.unr, Maps/UPak/*.unr, Textures/*.utx, Sounds/*.uax,
      Music/*.umx, Meshes/*.usm, plus the <language> subfolder the engine also
      searches, see --language). Prints one "MISSING name<TAB>importers" line
      per package and always exits 0.

  objects [-q] ROOT NAME...
      For each package NAME, check that every object any other package under
      ROOT imports from it exists in the file the engine loads for NAME, with
      the same class, class package and outer path, and is public. Exits 1 if
      anything is missing.

  dropin CANDIDATE NAME ROOT
      Same check, but against the file CANDIDATE instead of the one in ROOT:
      can CANDIDATE replace package NAME for every importer under ROOT?
      Exits 1 if not, and prints what is missing.

Only files that start with the package tag are read; Textures/AddOns and any
other folder off the search path are ignored, both as importers and as
targets. Name matching is case-insensitive, like the engine's FName and like
exFAT. The outer (group) path must match exactly.

Format reference: UT v432 public headers (UnLinker.h, UnArc.h FCompactIndex)
and the 227 public source (Core/Inc/UnLinker.h).
"""
import argparse
import collections
import os
import struct
import sys

PKG_TAG = 0x9E2A83C1
RF_PUBLIC = 0x00000004
# 227 (Core/Inc/UnObjBas.h RF_HasArchtype): the export table entry then has an
# INT ArchetypeIndex after ObjectFlags (seen in 227k_15 System/UnrealShare.u).
RF_HAS_ARCHETYPE = 0x00000100

# Paths= of config/UnrealLinux.ini, in order. The first file found wins.
SEARCH_PATHS = [("System", ".u"), ("Maps", ".unr"), ("Maps/UPak", ".unr"),
                ("Textures", ".utx"), ("Sounds", ".uax"), ("Music", ".umx"),
                ("Meshes", ".usm")]


class PackageError(Exception):
    pass


class Package:
    """Header, name, import and export tables of one package file."""

    def __init__(self, path):
        self.path = path
        self.name = os.path.splitext(os.path.basename(path))[0]
        with open(path, "rb") as f:
            self._f = f
            self._read()
        del self._f, self._buf

    # The tables are usually at the end of the file; read them in place.
    def _seek(self, off):
        self._f.seek(off)
        self._buf = self._f.read(1 << 20)
        self._buf_off = off  # file offset of self._buf[0]
        self._pos = 0

    def _need(self, n):
        if self._pos + n > len(self._buf):
            more = self._f.read(max(n, 1 << 20))
            self._buf = self._buf[self._pos:] + more
            self._buf_off += self._pos
            self._pos = 0
            if n > len(self._buf):
                raise PackageError("%s: truncated table" % self.path)

    def _bytes(self, n):
        self._need(n)
        b = self._buf[self._pos:self._pos + n]
        self._pos += n
        return b

    def _u8(self):
        return self._bytes(1)[0]

    def _i32(self):
        return struct.unpack("<i", self._bytes(4))[0]

    def _compact(self):
        """FCompactIndex. Like the engine, the 5th byte is used unmasked and the
        result wraps in 32 bits (some tools write e.g. -12 in 5 bytes)."""
        b0 = self._u8()
        val = b0 & 0x3F
        if b0 & 0x40:
            shift = 6
            for i in range(4):
                b = self._u8()
                if i == 3:
                    val |= b << shift
                    break
                val |= (b & 0x7F) << shift
                shift += 7
                if not b & 0x80:
                    break
        val &= 0xFFFFFFFF
        if b0 & 0x80:
            val = -val & 0xFFFFFFFF
        return val - (1 << 32) if val & 0x80000000 else val

    def _read(self):
        header = self._f.read(36)
        if len(header) < 36:
            raise PackageError("%s: too short" % self.path)
        (tag, self.ver, _lic, _flags, ncount, noff, ecount, eoff, icount,
         ioff) = struct.unpack("<IHHIIIIIII", header)
        if tag != PKG_TAG:
            raise PackageError("%s: not a package" % self.path)

        self._seek(noff)
        names = []
        for _ in range(ncount):
            if self.ver >= 64:
                n = self._compact()
                if n < 0:  # 227 writes non-Latin-1 names as UTF-16LE
                    s = self._bytes(-n * 2).decode("utf-16-le")
                else:
                    s = self._bytes(n).decode("latin-1")
            else:
                raw = bytearray()
                while True:
                    c = self._u8()
                    if not c:
                        break
                    raw.append(c)
                s = raw.decode("latin-1")
            names.append(s.rstrip("\0"))
            self._bytes(4)  # name flags
        self.names = names
        self.name_table_span = (noff, self._buf_off + self._pos)

        self._seek(ioff)
        self.imports = []  # (class package, class name, outer ref, name)
        for _ in range(icount):
            cpkg, cname = self._compact(), self._compact()
            outer = self._i32()
            oname = self._compact()
            self.imports.append((names[cpkg], names[cname], outer, names[oname]))

        self._seek(eoff)
        self.exports = []  # (class ref, outer ref, name, flags)
        for _ in range(ecount):
            cls = self._compact()
            self._compact()  # super
            outer = self._i32()
            oname = self._compact()
            flags = struct.unpack("<I", self._bytes(4))[0]
            if flags & RF_HAS_ARCHETYPE:
                self._i32()  # 227: FObjectExport::ArchetypeIndex
            if self._compact() > 0:  # serial size, then offset
                self._compact()
            self.exports.append((cls, outer, names[oname], flags))
        for cls, outer, _, _ in self.exports:
            if not (-icount <= cls <= ecount and -icount <= outer <= ecount):
                raise PackageError("%s: export table reference out of range" % self.path)

    def path_of(self, ref):
        """Full dotted path of an import (<0) or export (>0) reference.
        Export paths do not include the package's own name."""
        parts = []
        for _ in range(64):
            if ref == 0:
                break
            if ref < 0:
                _, _, ref2, nm = self.imports[-ref - 1]
            else:
                _, ref2, nm, _ = self.exports[ref - 1]
            parts.append(nm)
            ref = ref2
        return ".".join(reversed(parts))

    def export_class(self, i):
        """(class package, class name) of export i, as GetExportClassPackage
        and GetExportClassName compute them."""
        cls = self.exports[i][0]
        if cls < 0:
            _, _, outer, cname = self.imports[-cls - 1]
            return (self.imports[-outer - 1][3] if outer < 0 else "Core"), cname
        if cls > 0:
            return self.name, self.exports[cls - 1][2]
        return "Core", "Class"

    def export_table(self):
        """{lower(path): [(lower(class package), lower(class name), public)]}"""
        table = collections.defaultdict(list)
        for i, exp in enumerate(self.exports):
            cpkg, cname = self.export_class(i)
            table[self.path_of(i + 1).lower()].append(
                (cpkg.lower(), cname.lower(), bool(exp[3] & RF_PUBLIC)))
        return table

    def object_imports(self):
        """Imports below package level: (top package, path, class package, class name)."""
        out = []
        for i, (cpkg, cname, outer, _) in enumerate(self.imports):
            if outer == 0:
                continue  # a top-level package
            path = self.path_of(-(i + 1))
            top, _, rest = path.partition(".")
            out.append((top, rest, cpkg, cname))
        return out

    def package_imports(self):
        return {nm for (_, cname, outer, nm) in self.imports if outer == 0 and cname == "Package"}


def is_package(path):
    try:
        with open(path, "rb") as f:
            return struct.unpack("<I", f.read(4))[0] == PKG_TAG
    except (OSError, struct.error):
        return False


class Tree:
    """The package files of a game tree the engine can find, by lower-case name."""

    def __init__(self, root, language="int"):
        self.root = root
        self.files = {}     # lower-case name -> the file the engine loads
        self.searched = []  # every file a search path matches, shadowed ones too
        dirs = list(SEARCH_PATHS)
        # The engine also looks in <path>/<language>/ (e.g. Sounds/int/Interm1.uax).
        dirs += [("%s/%s" % (d, language), e) for d, e in SEARCH_PATHS]
        for d, ext in dirs:
            full = os.path.join(root, d)
            if not os.path.isdir(full):
                continue
            for f in sorted(os.listdir(full)):
                stem, e = os.path.splitext(f)
                p = os.path.join(full, f)
                if e.lower() == ext and os.path.isfile(p):
                    self.files.setdefault(stem.lower(), p)
                    self.searched.append(p)

    def all_packages(self):
        """Every package file in the searched folders (also the shadowed ones,
        to stay on the safe side), sorted."""
        return sorted(p for p in self.searched if is_package(p))

    def load_all(self, errors):
        for p in self.all_packages():
            try:
                yield Package(p)
            except (PackageError, IndexError, struct.error) as e:
                errors.append("%s: %s" % (os.path.relpath(p, self.root), e))


def check_objects(tree, targets, candidates=None, out=sys.stdout, quiet=False):
    """Check every import from the packages in targets (lower-case names).
    candidates maps a lower-case name to a replacement file. quiet leaves out
    the packages that are fine. Returns the number of missing objects."""
    candidates = candidates or {}
    wanted = collections.defaultdict(lambda: collections.defaultdict(set))
    errors = []
    for pkg in tree.load_all(errors):
        own = pkg.name.lower()
        for top, path, cpkg, cname in pkg.object_imports():
            t = top.lower()
            if t in targets and t != own:
                key = (path.lower(), cpkg.lower(), cname.lower())
                wanted[t][key].add(os.path.relpath(pkg.path, tree.root))
    for e in errors:
        print("PARSE-ERROR\t%s" % e, file=out)
    bad = 0
    for t in sorted(targets):
        src = candidates.get(t) or tree.files.get(t)
        if not src:
            print("NO-FILE\t%s" % t, file=out)
            bad += 1
            continue
        if not wanted[t] and t not in candidates:
            continue  # nothing imports from it
        try:
            table = Package(src).export_table()
        except (PackageError, IndexError, struct.error) as e:
            print("UNREADABLE\t%s\t%s" % (src, e), file=out)
            bad += 1
            continue
        users = set().union(*wanted[t].values()) if wanted[t] else set()
        missing = []
        for (path, cpkg, cname), importers in sorted(wanted[t].items()):
            found = table.get(path, [])
            if any(c == (cpkg, cname, True) for c in found):
                continue
            if any(c[:2] == (cpkg, cname) for c in found):
                why = "not public"
            elif found:
                why = "class is %s" % ", ".join("%s.%s" % c[:2] for c in found)
            else:
                why = "no such object"
            missing.append((path, cpkg, cname, why, importers))
        if quiet and not missing:
            continue
        print("%s\t%s\t%d objects imported by %d packages, %d missing"
              % ("OK" if not missing else "INCOMPATIBLE", src if t in candidates
                 else os.path.relpath(src, tree.root), len(wanted[t]), len(users),
                 len(missing)), file=out)
        for path, cpkg, cname, why, importers in missing:
            print("    %s.%s (%s.%s): %s  <- %s"
                  % (t, path, cpkg, cname, why, ", ".join(sorted(importers))), file=out)
        bad += len(missing)
    return bad + len(errors)


def cmd_missing(a):
    tree = Tree(a.root, a.language)
    missing = collections.defaultdict(set)
    errors = []
    n = 0
    for pkg in tree.load_all(errors):
        n += 1
        for imp in pkg.package_imports():
            if imp.lower() not in tree.files and imp.lower() != pkg.name.lower():
                missing[imp.lower()].add(os.path.relpath(pkg.path, tree.root))
    print("scanned %d package files, %d parse errors" % (n, len(errors)))
    for e in errors:
        print("PARSE-ERROR\t%s" % e)
    for imp in sorted(missing):
        print("MISSING\t%s\t%s" % (imp, ", ".join(sorted(missing[imp]))))
    return 0


def cmd_objects(a):
    tree = Tree(a.root, a.language)
    bad = check_objects(tree, {n.lower() for n in a.names}, quiet=a.quiet)
    if a.quiet and not bad:
        print("objects: every object imported from the %d package(s) exists" % len(a.names))
    return 1 if bad else 0


def cmd_dropin(a):
    tree = Tree(a.root, a.language)
    name = a.name.lower()
    return 1 if check_objects(tree, {name}, {name: a.candidate}) else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--language", default="int", help="engine Language= (default int)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("missing")
    p.add_argument("root")
    p.set_defaults(func=cmd_missing)
    p = sub.add_parser("objects")
    p.add_argument("-q", "--quiet", action="store_true", help="print only problems")
    p.add_argument("root")
    p.add_argument("names", nargs="+")
    p.set_defaults(func=cmd_objects)
    p = sub.add_parser("dropin")
    p.add_argument("candidate")
    p.add_argument("name")
    p.add_argument("root")
    p.set_defaults(func=cmd_dropin)
    a = ap.parse_args()
    sys.exit(a.func(a))


if __name__ == "__main__":
    main()
