#!/usr/bin/env python3
"""select_campaigns.py - ship only the chosen single-player campaigns.

The modded install holds well over a hundred campaigns. Given the files of a
game tree, the New Game menu names of the campaigns to keep (campaigns.txt)
and the file list of the unmodded Unreal Gold install (stock_227k15.txt),
this works out which mod files the kept campaigns need. Everything else that
is not stock can be left out.

A file is kept when it is
  * stock (listed in the stock file list), in SystemARM64/ (the engine), or
    in Save/;
  * a package the closure below reaches;
  * a non-package file (X.int, X.ini, localized X.det, ...) whose name, minus
    the extension, is that of a kept package;
  * an .int file that holds the menu entry of a kept campaign.

The closure starts from every stock package, from the packages and maps the
port's inis name (--config), and, for each kept campaign, from the start map,
the screenshot and the packages that the menu entry's URL options name
(?Game=, ?Mutator=, ?Class=, ?Skin=, ...). It then follows, recursively,
  * the import table of each reached package (what the engine loads with it);
  * maps that a reached mod map names in a string that is nothing but a map
    URL ("Map", "Map#Tag?peer", "open Map", "Map.unr"): Teleporter URLs and
    the like, which is how a campaign chains its levels;
  * packages named as "Package.Object" in a string of a reached mod package
    (DynamicLoadObject targets, URL options such as ?Game=Pkg.Class).
Strings are not read from stock packages, nor from the name table (names are
identifiers, not URLs). Maps that a script package (.u) names are only
reported (SCRIPT-MAP-REF), not followed: mutators such as B227_MapFix name
every map they fix. A level that a kept campaign reaches only from
UnrealScript goes into campaigns.txt as "map NAME", and an optional package
that no map needs (a player model, say) as "package NAME".

Kept .int files are filtered: Object= lines for campaigns that are not kept,
and lines whose Name= or MetaClass= package is left out, are removed. The
filtered copy is written to --filtered-dir with the same relative path, line
endings and encoding untouched.

Inputs:
  --root DIR      the game tree to analyse (every file under DIR), or
  --plan FILE     NUL-separated "relpath NUL sourcepath NUL" records, as
                  assemble_gamedata.sh writes them
Outputs:
  --decisions FILE  one "keep|drop|filter <TAB> relpath <TAB> detail" line per
                    file of the tree (filter: detail is the filtered copy)
  --report FILE     what each kept campaign needs, sizes, and everything worth
                    a second look (default: stdout)
  --maps FILE       one "campaign <TAB> map <TAB> menu URL options" line per
                    map of each kept campaign (input for load tests)

Exit status 1 when a campaign or "map" line of campaigns.txt matches nothing.
"""
import argparse
import collections
import filecmp
import os
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ue1pkg  # noqa: E402

PACKAGE_EXTS = {ext for _, ext in ue1pkg.SEARCH_PATHS}
MAP_DIRS = {d.lower() for d, ext in ue1pkg.SEARCH_PATHS if ext == ".unr"}
SINGLEPLAYER = "unrealshare.singleplayer"

# A string that is nothing but a map URL: "Map", "Map.unr", "Map#Tag?peer",
# the old "Map/Portal" form (Steele Dawn, Unreal PSX), or a console command of
# a trigger or script actor such as "open Map?..." or "ChangeLevel Map.unr"
# (Operation Na Pali and Deja Vu chain levels that way).
MAP_URL_RE = re.compile(r"(?:(?:open|start|travel|servertravel|switchlevel|changelevel)\s+)?"
                        r"([^#?/]+?)(?:\.unr)?(?:[#?/].*)?", re.I | re.S)
# "Package.Object" anywhere in a string, and ?Game=Package without an object.
PKG_REF_RE = re.compile(r"(?<![\w\-])([A-Za-z0-9_\-]+)\.[A-Za-z_][\w\-]*")
GAME_OPT_RE = re.compile(r"[?&]game=([A-Za-z0-9_\-]+)", re.I)
# Null-terminated printable ASCII: FString bodies and bytecode string constants.
STRING_RE = re.compile(rb"[\x20-\x7e]{2,1024}(?=\x00)")
# Property tags (Engine FPropertyTag): the type is the low nibble of the info
# byte; 7 is a fixed-size string[N] (Unreal 1), 13 a dynamic string. Value
# sizes 1, 2, 4, 12 and 16 are size codes 0-4 in bits 4-6; otherwise code 5
# or 6 says a one- or two-byte size follows.
STRING_TYPES = {7, 13}
INFO_SIZE_CODE = {1: 0, 2: 1, 4: 2, 12: 3, 16: 4}
# String properties that are text shown to the player, never a map URL (the
# Title of RTNPUER-Cryox is "Cryox", which is also a beta map's file name).
TEXT_PROPERTIES = {"title", "author", "levelentertext", "idealplayercount"}


# Keys of [URL] that name maps the engine loads by itself.
URL_MAP_KEYS = {"localmap", "altlocalmap", "entrymap", "map"}
# Sections whose class references the engine resolves whatever is played.
ENGINE_SECTIONS = {"engine.engine", "engine.gameengine", "umenu.umenumutatorcw",
                   "defaultplayer"}
# Engine inis next to the binary (DefaultLinux.ini/DefUser.ini seed the
# player's UnrealLinux.ini/User.ini).
ENGINE_INIS = {"defaultlinux.ini", "defuser.ini"}


def sections_of(path, sections):
    """Append the (key, value, path) items of an ini to sections, keyed by the
    lower-case section name."""
    sec = ""
    with open(path, encoding="latin-1") as f:
        for line in f:
            line = line.strip()
            if line.startswith("[") and line.endswith("]"):
                sec = line[1:-1].strip().lower()
                sections.setdefault(sec, [])
            elif line and line[0] not in ";#" and "=" in line:
                key, value = (x.strip() for x in line.split("=", 1))
                sections.setdefault(sec, []).append((key, value, path))


def decode_text(raw):
    if raw[:2] in (b"\xff\xfe", b"\xfe\xff"):
        return raw.decode("utf-16")
    try:
        return raw.decode("utf-8-sig")
    except UnicodeDecodeError:
        return raw.decode("latin-1")


def int_field(line, key):
    """Value of Key=... in an .int Object=(...) line, or None."""
    m = re.search(r"\b%s\s*=\s*(\"[^\"]*\"|[^,)]*)" % key, line, re.I)
    if not m:
        return None
    return m.group(1).strip().strip('"')


class Tree:
    """The files of a game tree (from disk or from a plan) and the package
    the engine loads for each name, following the Paths= order."""

    def __init__(self, plan, language="int"):
        self.src = plan  # relpath -> source file
        self.files = {}  # lower-case package name -> relpath
        by_dir = collections.defaultdict(list)
        for rel in plan:
            by_dir[os.path.dirname(rel).lower()].append(rel)
        dirs = list(ue1pkg.SEARCH_PATHS)
        dirs += [("%s/%s" % (d, language), e) for d, e in ue1pkg.SEARCH_PATHS]
        for d, ext in dirs:
            for rel in sorted(by_dir.get(d.lower(), [])):
                stem, e = os.path.splitext(os.path.basename(rel))
                if e.lower() == ext:
                    self.files.setdefault(stem.lower(), rel)
        self.packages = set(self.files.values())

    def is_map(self, rel):
        return os.path.dirname(rel).lower() in MAP_DIRS

    def map_file(self, name):
        rel = self.files.get(name.lower())
        return rel if rel and self.is_map(rel) else None

    def size(self, rel):
        return os.path.getsize(self.src[rel])


class Scanner:
    """Imports and string references of package files, cached."""

    def __init__(self, tree, stock):
        self.tree, self.stock = tree, stock
        self.cache = {}
        self.errors = []

    def scan(self, rel):
        if rel not in self.cache:
            self.cache[rel] = self._scan(rel)
        return self.cache[rel]

    def _scan(self, rel):
        """(imported package names, maps named by URL strings, packages named
        by "Package.Object" strings, lower-case names of the name table)."""
        src = self.tree.src[rel]
        try:
            pkg = ue1pkg.Package(src)
        except (ue1pkg.PackageError, IndexError, struct.error, UnicodeDecodeError) as e:
            self.errors.append("%s: %s" % (rel, e))
            return set(), [], [], set()
        imports = {n.lower() for n in pkg.package_imports()}
        names = [n.lower() for n in pkg.names]
        if rel.lower() in self.stock:
            return imports, [], [], set(names)
        own = pkg.name.lower()
        is_map = self.tree.is_map(rel)
        maps, pkgs = set(), set()
        with open(src, "rb") as f:
            data = f.read()
        a, b = pkg.name_table_span
        for seg in (data[:a], data[b:]):
            for m in STRING_RE.finditer(seg):
                for c, prop in self._strings(seg, m, names, is_map):
                    u = MAP_URL_RE.fullmatch(c.strip())
                    if u and prop not in TEXT_PROPERTIES and self.tree.map_file(u.group(1).strip()):
                        maps.add(self.tree.map_file(u.group(1).strip()))
                    if len(c.split()) > 3:  # prose, such as credits naming MyLevel.MyZoneInfo
                        continue
                    for p in PKG_REF_RE.findall(c) + GAME_OPT_RE.findall(c):
                        r = self.tree.files.get(p.lower())
                        if r and p.lower() != own and not self.tree.is_map(r):
                            pkgs.add(r)
        return imports, sorted(maps), sorted(pkgs), set(names)

    @classmethod
    def _strings(cls, seg, m, names, is_map):
        """(string, property name) for each string that a printable run ends
        with: the value of a string property, whose tag bytes before it are
        checked (property name "" for an UnrealScript string constant).
        Printable bytes that are not such a string, for example "oU" in BSP
        data, are skipped. The tag bytes may themselves be printable, so the
        value can start a few characters into the run."""
        s = m.group().decode("ascii")
        out = []
        for k in range(0, min(8, len(s) - 1)):
            pos, n = m.start() + k, len(s) - k
            # EX_StringConst (0x1F) + text + zero, in script code. A map holds
            # little code and much binary data, so there the string must be
            # longer than a stray byte pair.
            if k == 0 and pos >= 1 and seg[pos - 1] == 0x1F and (not is_map or n >= 4):
                out.append((s, ""))
                continue
            prop = cls._property_of(seg, pos, n, names)
            if prop is not None:
                out.append((s[k:], prop))
        return out

    @staticmethod
    def _property_of(seg, pos, n, names):
        """Name of the string property whose value is the n characters at pos
        (followed by a zero), or None when the bytes before them are not the
        property's tag: name index, info byte (type, size code, array flag),
        size, array index, then the value. The value is an FString (compact
        index of the length, zero included) or, in old packages and for
        fixed-size string[N] properties, just the zero-terminated text."""
        prefixes = [(pos, n + 1)]  # zero-terminated text only
        length = n + 1
        if length < 64 and pos >= 1 and seg[pos - 1] == length:
            prefixes.append((pos - 1, length + 1))
        elif 64 <= length < 8192 and pos >= 2 and seg[pos - 2] == 0x40 | (length & 0x3F) \
                and seg[pos - 1] == length >> 6:
            prefixes.append((pos - 2, length + 2))
        for q, size in prefixes:
            for array in (False, True):
                p = q
                if array:
                    if p < 1 or seg[p - 1] >= 0x80:
                        continue
                    p -= 1  # one-byte array index
                if size in INFO_SIZE_CODE:
                    info_pos, code = p - 1, INFO_SIZE_CODE[size]
                elif size < 0x100:
                    if p < 1 or seg[p - 1] != size:
                        continue
                    info_pos, code = p - 2, 5
                elif size < 0x10000:
                    if p < 2 or seg[p - 2] | seg[p - 1] << 8 != size:
                        continue
                    info_pos, code = p - 3, 6
                else:
                    continue
                if info_pos < 1:
                    continue
                info = seg[info_pos]
                if info & 0x0F not in STRING_TYPES or (info >> 4) & 7 != code \
                        or bool(info & 0x80) != array:
                    continue
                b = seg[info_pos - 1]  # the name index, compact, 1 or 2 bytes
                if b < 0x40 and b < len(names):
                    return names[b]
                if info_pos >= 2 and b < 0x80:
                    b0 = seg[info_pos - 2]
                    idx = (b0 & 0x3F) | b << 6
                    if b0 & 0x40 and not b0 & 0x80 and idx < len(names):
                        return names[idx]
        return None


class Closure:
    """Files reached from a set of seeds, with the first reason for each."""

    def __init__(self, tree, scanner):
        self.tree, self.scanner = tree, scanner
        self.why = {}               # relpath -> reason
        self.script_map_refs = collections.defaultdict(set)  # .u -> maps
        self.unresolved = collections.defaultdict(set)       # name -> importers

    def add(self, rel, reason):
        work = [(rel, reason)]
        while work:
            rel, reason = work.pop()
            if rel in self.why:
                continue
            self.why[rel] = reason
            if rel not in self.tree.packages:
                continue
            imports, maps, pkgs, _ = self.scanner.scan(rel)
            for name in sorted(imports):
                r = self.tree.files.get(name)
                if r:
                    work.append((r, "imported by " + rel))
                elif name != os.path.splitext(os.path.basename(rel))[0].lower():
                    self.unresolved[name].add(rel)
            for r in pkgs:
                work.append((r, "named in a string of " + rel))
            for r in maps:
                if self.tree.is_map(rel):
                    work.append((r, "map URL in " + rel))
                else:
                    self.script_map_refs[rel].add(r)


def url_packages(tree, text):
    """Packages that a menu URL, an option list or an ini value names. Maps
    are left out: "Map=X.unr" in an ini is a remembered menu choice."""
    out = set()
    for p in PKG_REF_RE.findall(text) + GAME_OPT_RE.findall(text):
        r = tree.files.get(p.lower())
        if r and not tree.is_map(r):
            out.add(r)
    return out


def read_selection(path):
    """Campaign menu names, and the names of the "map X" and "package X"
    lines."""
    campaigns, maps, packages = [], [], []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\r\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            if line.startswith("map "):
                maps.append(line[4:].strip())
            elif line.startswith("package "):
                packages.append(line[8:].strip())
            else:
                campaigns.append(line)
    return campaigns, maps, packages


def read_stock(path):
    with open(path, encoding="utf-8") as f:
        return {ln.strip() for ln in f if ln.strip() and not ln.startswith("#")}


def stock_duplicates(plan, stock):
    """Mod packages that are byte-identical to a stock package of the same
    file name in another search folder (the install has copies of the Return
    to Na Pali maps in Maps/ next to the stock ones in Maps/UPak/). Without
    the copy the engine loads the stock file, which has the same bytes.
    Returns {copy: stock file}."""
    search = {d.lower() for d, _ in ue1pkg.SEARCH_PATHS}
    stock_by_name = collections.defaultdict(list)
    for rel in plan:
        if rel.lower() in stock and os.path.dirname(rel).lower() in search:
            stock_by_name[os.path.basename(rel).lower()].append(rel)
    out = {}
    for rel in sorted(plan):
        if rel.lower() in stock or os.path.dirname(rel).lower() not in search:
            continue
        for st in stock_by_name.get(os.path.basename(rel).lower(), []):
            if filecmp.cmp(plan[rel], plan[st], shallow=False):
                out[rel] = st
                break
    return out


def load_plan(a):
    plan = {}
    if a.root:
        for dirpath, _, names in os.walk(a.root):
            for n in names:
                p = os.path.join(dirpath, n)
                plan[os.path.relpath(p, a.root)] = p
    else:
        with open(a.plan, "rb") as f:
            parts = f.read().split(b"\0")
        if parts and parts[-1] == b"":
            parts.pop()
        if len(parts) % 2:
            sys.exit("select_campaigns: odd number of fields in %s" % a.plan)
        for i in range(0, len(parts), 2):
            plan[os.fsdecode(parts[i])] = os.fsdecode(parts[i + 1])
    return plan


def int_entries(tree, language):
    """(relpath, line index, line, Name, MetaClass, Description) of every
    Object= line of the .int files the engine reads: System/*.int and
    SystemLocalized/<language>/*.int."""
    dirs = {"system", "systemlocalized/" + language.lower()}
    out = []
    for rel in sorted(tree.src):
        if os.path.dirname(rel).lower() not in dirs or not rel.lower().endswith(".int"):
            continue
        with open(tree.src[rel], "rb") as f:
            raw = f.read()
        text_lines = decode_text(raw).split("\n")
        for i, line in enumerate(text_lines):
            if not re.match(r"\s*Object\s*=\s*\(", line, re.I):
                continue
            out.append((rel, i, line, int_field(line, "Name"),
                        int_field(line, "MetaClass"), int_field(line, "Description")))
    return out


def campaign_name(desc):
    return desc.rsplit(";", 1)[1] if desc and ";" in desc else None


def human(n):
    return "%.1f MiB" % (n / 1048576.0)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--root")
    src.add_argument("--plan")
    ap.add_argument("--campaigns", required=True)
    ap.add_argument("--stock", required=True)
    ap.add_argument("--config", action="append", default=[])
    ap.add_argument("--language", default="int")
    ap.add_argument("--decisions")
    ap.add_argument("--filtered-dir")
    ap.add_argument("--report")
    ap.add_argument("--maps")
    a = ap.parse_args()

    plan = load_plan(a)
    stock = read_stock(a.stock)
    duplicates = stock_duplicates(plan, stock)
    tree = Tree({r: p for r, p in plan.items() if r not in duplicates}, a.language)
    scanner = Scanner(tree, stock)
    selected, extra_maps, extra_packages = read_selection(a.campaigns)
    out = open(a.report, "w", encoding="utf-8") if a.report else sys.stdout
    fatal = []

    engine_modules = {os.path.splitext(os.path.basename(r))[0].lower() for r in plan
                      if os.path.dirname(r).lower() == "systemarm64" and r.endswith(".so")}

    def always_kept(rel):
        top, base_name = rel.split("/", 1)[0].lower(), os.path.basename(rel).lower()
        if rel.lower() in stock or top == "save":
            return True
        if top == "systemarm64":  # the engine; its .ini files are mod configs
            return not base_name.endswith(".ini") or base_name in ENGINE_INIS
        return False

    # --- Seeds -----------------------------------------------------------
    base = Closure(tree, scanner)
    for rel in sorted(plan):
        if always_kept(rel):
            base.add(rel, "stock")
    sections = collections.OrderedDict()  # lower-case section -> [(key, value, ini)]
    for ini in a.config:
        sections_of(ini, sections)
    for sec, items in sections.items():
        for key, value, ini in items:
            where = "[%s] %s in %s" % (sec, key, os.path.basename(ini))
            if sec == "url" and key.lower() in URL_MAP_KEYS:
                u = MAP_URL_RE.fullmatch(value)
                if u and tree.map_file(u.group(1).strip()):
                    base.add(tree.map_file(u.group(1).strip()), where)
            elif sec in ENGINE_SECTIONS:
                for r in url_packages(tree, value):
                    base.add(r, where)
                if key.lower() == "serverpackages" and tree.files.get(value.lower()):
                    base.add(tree.files[value.lower()], where)

    entries = int_entries(tree, a.language)
    sp = [e for e in entries if (e[4] or "").lower() == SINGLEPLAYER and campaign_name(e[5])]
    per_campaign = collections.OrderedDict()
    urls = {}  # campaign -> menu URL
    kept_entries = set()  # (rel, line index)
    for name in selected:
        hits = [e for e in sp if campaign_name(e[5]) == name]
        if not hits:
            fatal.append("campaign %r is not in any .int file" % name)
            continue
        c = Closure(tree, scanner)
        for rel, i, line, _, _, desc in hits:
            kept_entries.add((rel, i))
            fields = desc.split(";")
            url = fields[0]
            start = MAP_URL_RE.fullmatch(url.strip())
            mrel = start and tree.map_file(start.group(1).strip())
            if not mrel:
                fatal.append("campaign %r: start map of %r not found" % (name, url))
            else:
                c.add(mrel, "start map")
            for r in url_packages(tree, url) | (url_packages(tree, fields[1]) if len(fields) == 3 else set()):
                c.add(r, "named in the menu entry (%s)" % rel)
            c.add(rel, "holds the menu entry")
        per_campaign[name] = c
        urls[name] = hits[0][5].split(";")[0]
    extra = Closure(tree, scanner)
    for name in extra_maps:
        r = tree.map_file(name)
        if not r:
            fatal.append("map %r not found" % name)
        else:
            extra.add(r, "map line in campaigns.txt")
    for name in extra_packages:
        r = tree.files.get(name.lower())
        if not r or tree.is_map(r):
            fatal.append("package %r not found" % name)
        else:
            extra.add(r, "package line in campaigns.txt")
    groups = [("(stock and config)", base)] + list(per_campaign.items()) + [("(extra lines)", extra)]

    # The ini sections of a class that is shipped ([Package.Class]) are read
    # when the class loads, and may name further classes.
    done = set()
    while True:
        reached = {os.path.splitext(os.path.basename(r))[0].lower()
                   for _, c in groups for r in c.why if r in tree.packages}
        todo = [sec for sec in sections if sec not in done and "." in sec
                and sec.split(".", 1)[0] in reached]
        if not todo:
            break
        for sec in todo:
            done.add(sec)
            for key, value, ini in sections[sec]:
                for r in url_packages(tree, value):
                    base.add(r, "[%s] %s in %s" % (sec, key, os.path.basename(ini)))

    keep = {}
    for label, c in groups:
        for rel, why in c.why.items():
            keep.setdefault(rel, "%s: %s" % (label, why))

    # --- Non-package mod files follow the package of the same name ---------
    pkg_by_stem = collections.defaultdict(list)
    for rel in tree.packages:
        pkg_by_stem[os.path.splitext(os.path.basename(rel))[0].lower()].append(rel)
    orphans = []
    decisions = {}
    for rel in sorted(plan):
        if rel in duplicates:
            decisions[rel] = ("drop", "byte-identical to stock " + duplicates[rel])
            continue
        if rel in keep:
            decisions[rel] = ("keep", keep[rel])
            continue
        if rel in tree.packages:
            decisions[rel] = ("drop", "no kept campaign needs it")
            continue
        stem = os.path.splitext(os.path.basename(rel))[0].lower()
        owners = pkg_by_stem.get(stem)
        if owners:
            k = [o for o in owners if o in keep]
            decisions[rel] = ("keep", "belongs to " + k[0]) if k else (
                "drop", "belongs to " + owners[0] + ", which is left out")
        elif stem in engine_modules:
            decisions[rel] = ("keep", "belongs to SystemARM64/%s.so" % stem)
        else:
            orphans.append(rel)
            decisions[rel] = ("drop", "mod file of no package and no kept campaign")

    # A mod .ini named after no package is the config(Name) file of a class:
    # keep it when a shipped package has that name in its name table. An .int
    # named after no package is kept when it registers objects of a shipped
    # package (it is then filtered below).
    kept_rels = [r for r in tree.packages if decisions[r][0] == "keep"]
    for rel in orphans:
        stem = os.path.splitext(os.path.basename(rel))[0].lower()
        if rel.lower().endswith(".ini"):
            users = [r for r in kept_rels if r.lower() not in stock and stem in scanner.scan(r)[3]]
            if users:
                decisions[rel] = ("keep", "config file named in " + ", ".join(sorted(users)))
    for rel, i, line, name, meta, desc in entries:
        if decisions[rel][0] == "drop" and rel in orphans:
            p = (name or "").split(".", 1)[0].lower()
            r = tree.files.get(p)
            if r and decisions[r][0] == "keep":
                decisions[rel] = ("keep", "registers objects of " + r)

    kept_pkg_names = {os.path.splitext(os.path.basename(r))[0].lower()
                      for r in tree.packages if decisions[r][0] == "keep"}
    all_pkg_names = set(tree.files)

    # --- .int filtering -----------------------------------------------------
    by_file = collections.defaultdict(list)
    for e in entries:
        by_file[e[0]].append(e)
    filtered_lines = {}
    int_notes = []
    for rel, ents in sorted(by_file.items()):
        if decisions[rel][0] != "keep":
            continue
        drop_idx = {}
        for _, i, line, name, meta, desc in ents:
            if (meta or "").lower() == SINGLEPLAYER and campaign_name(desc):
                if (rel, i) not in kept_entries:
                    drop_idx[i] = "campaign not shipped: " + campaign_name(desc)
                continue
            # Name= is an object path except for key binding entries.
            fields = [meta] + ([name] if (meta or "").lower() != "engine.input" else [])
            for field in fields:
                if not field or "." not in field:
                    continue
                p = field.split(".", 1)[0].lower()
                if p in all_pkg_names and p not in kept_pkg_names:
                    drop_idx[i] = "package %s is left out" % p
        if drop_idx:
            filtered_lines[rel] = drop_idx
    if a.filtered_dir:
        for rel, drop_idx in filtered_lines.items():
            with open(plan[rel], "rb") as f:
                raw = f.read()
            if raw[:2] in (b"\xff\xfe", b"\xfe\xff"):
                fatal.append("%s is UTF-16; filtering it is not implemented" % rel)
                continue
            lines = raw.split(b"\n")
            new = b"\n".join(ln for i, ln in enumerate(lines) if i not in drop_idx)
            dest = os.path.join(a.filtered_dir, rel)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            old = None
            if os.path.exists(dest):
                with open(dest, "rb") as f:
                    old = f.read()
            if old != new:  # leave the mtime alone when nothing changed
                with open(dest, "wb") as f:
                    f.write(new)
            decisions[rel] = ("filter", dest)

    # --- Report -------------------------------------------------------------
    def mod(rel):
        return not always_kept(rel)

    p = lambda *s: print(*s, file=out)  # noqa: E731
    owner_count = collections.Counter()
    for label, c in per_campaign.items():
        for rel in c.why:
            if mod(rel) and rel not in base.why:
                owner_count[rel] += 1
    p("== Kept campaigns")
    for label, c in per_campaign.items():
        maps = sorted(r for r in c.why if tree.is_map(r))
        own = [r for r in c.why if mod(r) and r not in base.why]
        excl = [r for r in own if owner_count[r] == 1]
        p("\n%s\n  %d maps (%d mod), %d mod files %s, %s only used by this campaign"
          % (label, len(maps), sum(1 for r in maps if mod(r)), len(own),
             human(sum(tree.size(r) for r in own)), human(sum(tree.size(r) for r in excl))))
        for r in maps:
            p("    map  %s   <- %s" % (r, c.why[r]))
        for r in sorted(own):
            if not tree.is_map(r):
                p("    pkg  %s   <- %s" % (r, c.why[r]))
    p("\n== Packages the config and stock files pull in (mod files only)")
    for r in sorted(base.why):
        if mod(r):
            p("    %s   <- %s" % (r, base.why[r]))
    p("\n== Totals")
    tot = collections.defaultdict(lambda: [0, 0, 0, 0])
    for rel, (d, _) in decisions.items():
        if not mod(rel):
            continue
        t = tot[rel.split("/", 1)[0]]
        i = 0 if d != "drop" else 2
        t[i] += 1
        t[i + 1] += os.path.getsize(plan[rel])
    for top in sorted(tot):
        k, ks, dr, ds = tot[top]
        p("  %-16s keep %5d files %10s   drop %5d files %10s" % (top, k, human(ks), dr, human(ds)))
    p("  %-16s keep %5d files %10s   drop %5d files %10s" % (
        "all mod files", sum(t[0] for t in tot.values()), human(sum(t[1] for t in tot.values())),
        sum(t[2] for t in tot.values()), human(sum(t[3] for t in tot.values()))))
    p("\n== SCRIPT-MAP-REF: maps named by kept script packages that are not shipped")
    for g_label, c in groups:
        for src_rel, maps in sorted(c.script_map_refs.items()):
            missing = sorted(m for m in maps if decisions.get(m, ("drop",))[0] == "drop")
            if missing:
                p("  %s (%s): %s" % (src_rel, g_label, ", ".join(missing)))
    p("\n== Imports that resolve to no file (also unresolved in the full tree)")
    for g_label, c in groups:
        for name, importers in sorted(c.unresolved.items()):
            p("  %s  <- %s" % (name, ", ".join(sorted(importers))))
    p("\n== Mod files that belong to no package (dropped unless they hold a kept menu entry)")
    for rel in orphans:
        p("  %-6s %s" % (decisions[rel][0], rel))
    p("\n== .int lines removed")
    for rel, drop_idx in sorted(filtered_lines.items()):
        p("  %s: %d lines" % (rel, len(drop_idx)))
        reasons = collections.Counter(v.split(":")[0] if v.startswith("campaign") else v
                                      for v in drop_idx.values())
        for why, n in sorted(reasons.items()):
            p("      %3d  %s" % (n, why))
    p("\n== Parse errors")
    for e in scanner.errors:
        p("  " + e)
    for e in fatal:
        p("ERROR: " + e)

    if a.maps:  # campaign, map, the menu URL's options: for load tests
        with open(a.maps, "w", encoding="utf-8") as f:
            for name, c in per_campaign.items():
                opts = urls[name][len(urls[name].split("?", 1)[0]):]
                for rel in sorted(r for r in c.why if tree.is_map(r)):
                    f.write("%s\t%s\t%s\n" % (name, rel, opts))
            for label, c in (("(extra lines)", extra), ("(stock and config)", base)):
                for rel in sorted(r for r in c.why if tree.is_map(r) and not always_kept(r)):
                    f.write("%s\t%s\t\n" % (label, rel))
    if a.decisions:
        with open(a.decisions, "w", encoding="utf-8") as f:
            for rel in sorted(decisions):
                d, why = decisions[rel]
                f.write("%s\t%s\t%s\n" % (d, rel, why))
    if fatal:
        for e in fatal:
            print("select_campaigns: error: " + e, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
