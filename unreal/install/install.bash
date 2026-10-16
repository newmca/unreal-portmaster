#!/bin/bash
# install.bash - put the stock Unreal Gold files into gamedata/.
#
# The package ships the mods and the port's own engine modules, but not the
# files of Unreal Gold itself. install/stock.tsv lists those files; this
# script takes them from the two downloads that OldUnreal's Linux installer
# uses:
#
#   - UNREAL_GOLD.ISO, the Unreal Gold CD image that OldUnreal hosts with
#     Epic's approval (646 MiB)
#   - OldUnreal-UnrealPatch227k-Linux.tar.bz2, the OldUnreal 227k_15 patch
#     (125 MiB)
#
# "Unreal.sh" runs it in PortMaster's patcher (utils/patcher.txt) on the
# first start. The patcher first asks the question of install/questions.lua
# and passes the answer as EPIC_TOS, then shows every line printed here. A
# failure ends with "Patching process failed!", which the patcher reports.
# The launcher starts the game only once gamedata/.installed exists, which
# this script writes last (it holds the id of install/stock.tsv).
#
# To install without Wi-Fi, copy UNREAL_GOLD.ISO and the patch archive into
# ports/unreal/ first; they are used if their checksums match. The script
# can also run by hand, on the device or on a PC:
#
#   EPIC_TOS=agree SEVENZIP=/path/to/7zz ports/unreal/install/install.bash
#
# Every step can be repeated: files already in gamedata/ with the right size
# are kept, an archive is fetched only while files from it are missing, and
# an interrupted download resumes.
set -uo pipefail

case $0 in
  */*) GAMEDIR=${0%/*}/.. ;;
  *) GAMEDIR=.. ;;
esac
GAMEDIR=$(cd "$GAMEDIR" && pwd) || exit 1
DATADIR=$GAMEDIR/gamedata
MANIFEST=$GAMEDIR/install/stock.tsv
MARKER=$DATADIR/.installed
DLDIR=$GAMEDIR/install/downloads
WORK=$GAMEDIR/install/work
LOG=$GAMEDIR/patchlog.txt

ISO_NAME=UNREAL_GOLD.ISO
ISO_SIZE=676734976
ISO_SHA256=7e360d0cc9e5533f38859819fd3cbfea7c475ecd428f9f433b5f8e1d5742cbca
ISO_URLS=(
  https://files.oldunreal.net/UNREAL_GOLD.ISO
  https://files2.oldunreal.net/UNREAL_GOLD.ISO
  https://files3.oldunreal.net/UNREAL_GOLD.ISO
  https://archive.org/download/totallyunreal/UNREAL_GOLD.ISO
)
PATCH_NAME=OldUnreal-UnrealPatch227k-Linux.tar.bz2
PATCH_SIZE=131414620
PATCH_SHA256=b04eba6d5c885c98bd9da8279840b15cd8fa06ed2b750235e7ad7aa26ef3f7a1
PATCH_URLS=(
  https://github.com/OldUnreal/Unreal-testing/releases/download/v227k_15/OldUnreal-UnrealPatch227k-Linux.tar.bz2
)

# Free space left over at the step that needs the most.
SPARE_KB=16384
# Seconds between progress lines.
TICK=5

# The patcher reads stdout only; keep a copy in patchlog.txt.
exec > >(tee "$LOG") 2>&1

fail() {
  echo "Error: $*"
  echo "PATCH_FAIL_MSG:Unreal Gold could not be installed. $* Details are in ports/unreal/patchlog.txt."
  echo "Patching process failed!"
  exit 1
}

# Sizes come from "ls -ln" (field 5): muOS has no stat command.
file_size() {
  local size
  size=$(ls -ln -- "$1" 2>/dev/null | awk 'NR == 1 { print $5 }')
  echo "${size:-0}"
}
mib() { echo $(($1 / 1048576)); }
free_kb() { df -Pk "$GAMEDIR" | awk 'NR == 2 { print $4 }'; }

# The manifest, one array element per file.
M_ARC=() M_SRC=() M_SIZE=() M_DEST=()
while IFS=$'\t' read -r arc src size _ dest; do
  M_ARC+=("$arc") M_SRC+=("$src") M_SIZE+=("$size") M_DEST+=("$dest")
done < <(grep -v '^#' "$MANIFEST" 2>/dev/null)

# scan: set HAVE[dest] to the size of each manifest file in gamedata/, with
# one ls for all of them (a process per file is slow on the device). The
# name is ls's last field; manifest paths have no blanks.
declare -A HAVE
scan() {
  local size name
  HAVE=()
  while read -r size name; do
    HAVE[$name]=$size
  done < <(cd "$DATADIR" && ls -lnd -- "${M_DEST[@]}" 2>/dev/null | awk '{ print $5, $NF }')
}
# missing I: true unless manifest file I is in gamedata/ with its size.
missing() { [ "${HAVE[${M_DEST[$1]}]:-}" != "${M_SIZE[$1]}" ]; }

# check FILE SIZE SHA256: true if FILE has that size and checksum.
check() {
  [ "$(file_size "$1")" = "$2" ] || return 1
  echo "Checking ${1##*/}..."
  [ "$(sha256sum "$1" | cut -d' ' -f1)" = "$3" ]
}

# every CMD...: run CMD, calling progress() every TICK seconds while it
# runs; return its status.
every() {
  local pid t=0
  "$@" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1
    t=$((t + 1))
    if [ $((t % TICK)) -eq 0 ] && kill -0 "$pid" 2>/dev/null; then
      progress
    fi
  done
  wait "$pid"
}

# download URL FILE: fetch URL into FILE, resuming a partial FILE.
download() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 20 --retry 3 --retry-delay 5 -C - -o "$2" "$1"
  else
    wget -q -T 20 -c -O "$2" "$1"
  fi
}

# user_copy NAME: print ports/unreal/NAME in any letter case, if there.
user_copy() {
  local f base
  for f in "$GAMEDIR"/*; do
    base=${f##*/}
    if [ -f "$f" ] && [ "${base,,}" = "${1,,}" ]; then
      echo "$f"
      return 0
    fi
  done
  return 1
}

# fetch NAME SIZE SHA256 URL...: set ARCHIVE to a checked copy of NAME: the
# user's copy in ports/unreal/, an earlier download, or a new download.
# FETCHED is set when the copy is ours to delete.
fetch() {
  local name=$1 size=$2 sum=$3 url own part
  shift 3
  if own=$(user_copy "$name"); then
    if check "$own" "$size" "$sum"; then
      echo "Using ports/unreal/${own##*/}."
      ARCHIVE=$own FETCHED=
      return 0
    fi
    echo "ports/unreal/${own##*/} is damaged or another version; downloading $name instead."
  fi

  mkdir -p "$DLDIR" || fail "Cannot write to ports/unreal/install."
  ARCHIVE=$DLDIR/$name FETCHED=1
  if [ -f "$ARCHIVE" ]; then
    check "$ARCHIVE" "$size" "$sum" && return 0
    rm -f "$ARCHIVE"
  fi
  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 ||
    fail "Neither curl nor wget is installed, so $name cannot be downloaded."

  part=$ARCHIVE.part
  for url; do
    [ "$(file_size "$part")" -le "$size" ] || rm -f "$part"
    if [ "$(file_size "$part")" -lt "$size" ]; then
      echo "Downloading $name ($(mib "$size") MiB) from ${url#https://}"
      progress() {
        local have
        have=$(file_size "$part")
        echo "  $name: $((have * 100 / size))% ($(mib "$have") of $(mib "$size") MiB)"
      }
      every download "$url" "$part" || echo "The download stopped (status $?)."
    fi
    if check "$part" "$size" "$sum"; then
      mv -f "$part" "$ARCHIVE"
      return 0
    fi
    # A complete file with the wrong checksum cannot be resumed.
    [ "$(file_size "$part")" -lt "$size" ] || rm -f "$part"
  done
  fail "$name could not be downloaded. Check the Wi-Fi connection and start Unreal again; the download resumes where it stopped."
}

# unpack KIND ARCHIVE DIR LIST: unpack the paths in LIST from ARCHIVE.
unpack() {
  case $1 in
    iso) "$SEVENZIP" x -y -bso0 -bsp0 -o"$3" "$2" @"$4" ;;
    # The tar is unpacked while the bzip2 stream is decompressed.
    patch) "$SEVENZIP" x -so "$2" | "$SEVENZIP" x -si -ttar -y -bso0 -bsp0 -o"$3" @"$4" ;;
  esac
}

# install_from KIND NAME SIZE SHA256 URL...: put the missing files that the
# manifest takes from archive KIND (iso or patch) into gamedata/.
install_from() {
  local kind=$1 name=$2 size=$3 sum=$4
  shift 4
  local list=$WORK/$kind.list stage=$WORK/$kind
  local i src bytes=0 count=0 need_kb
  local -A listed=() placed=() made=()

  rm -rf "$WORK"
  mkdir -p "$stage" || fail "Cannot write to ports/unreal/install."
  scan
  for i in "${!M_DEST[@]}"; do
    [ "${M_ARC[$i]}" = "$kind" ] && missing "$i" || continue
    src=${M_SRC[$i]}
    if [ -z "${listed[$src]:-}" ]; then
      listed[$src]=1
      echo "$src" >> "$list"
      bytes=$((bytes + M_SIZE[i]))
    fi
    count=$((count + 1))
  done
  if [ "$count" -eq 0 ]; then
    rm -rf "$WORK"
    return 0
  fi
  echo "$count files to install from $name."

  # Room for the rest of the download and for the unpacked files, which
  # then move into gamedata/ on the same card.
  need_kb=$((bytes / 1024 + SPARE_KB))
  if ! user_copy "$name" >/dev/null && [ ! -f "$DLDIR/$name" ]; then
    need_kb=$((need_kb + (size - $(file_size "$DLDIR/$name.part")) / 1024))
  fi
  [ "$(free_kb)" -ge "$need_kb" ] ||
    fail "There is not enough free space: installing needs $((need_kb / 1024)) MiB, the card has $(($(free_kb) / 1024)) MiB free."

  fetch "$name" "$size" "$sum" "$@"

  echo "Unpacking $(mib "$bytes") MiB from $name..."
  # Files, not bytes: du counts whole exFAT clusters.
  progress() { echo "  unpacked $(find "$stage" -type f | wc -l) of ${#listed[@]} files"; }
  every unpack "$kind" "$ARCHIVE" "$stage" "$list" || fail "Unpacking $name failed."

  # Move each file to its place in gamedata/. A file that several entries
  # share (a mod's copy of a stock map, say) is copied from the first one.
  # The sizes are checked once at the end.
  for i in "${!M_DEST[@]}"; do
    [ "${M_ARC[$i]}" = "$kind" ] && missing "$i" || continue
    src=${M_SRC[$i]}
    dest=$DATADIR/${M_DEST[$i]}
    if [ -z "${made[${dest%/*}]:-}" ]; then
      mkdir -p "${dest%/*}" || fail "Cannot create the folder of gamedata/${M_DEST[$i]}."
      made[${dest%/*}]=1
    fi
    if [ -f "$stage/$src" ]; then
      mv -f "$stage/$src" "$dest" || fail "Cannot write gamedata/${M_DEST[$i]}."
      placed[$src]=$dest
    elif [ -n "${placed[$src]:-}" ]; then
      cp -f "${placed[$src]}" "$dest" || fail "Cannot write gamedata/${M_DEST[$i]}."
    else
      fail "$src is missing from $name."
    fi
  done
  rm -rf "$WORK"
  # Only our own download is deleted; a copy the user provided stays.
  if [ -n "$FETCHED" ]; then
    rm -f "$ARCHIVE"
  fi
  echo "Installed $count files from $name."
}

echo "Installing the Unreal Gold game files."
[ "${#M_DEST[@]}" -gt 0 ] || fail "install/stock.tsv is missing or empty; reinstall the port."
[ "${EPIC_TOS:-}" = agree ] ||
  fail "You need to agree to the Epic Games Terms of Service first."
if [ -z "${SEVENZIP:-}" ]; then
  SEVENZIP=$(command -v 7zz || command -v 7z) || fail "7-Zip was not found. Update PortMaster, which provides it."
fi
[ -x "$SEVENZIP" ] || fail "7-Zip ($SEVENZIP) is missing. Update PortMaster, which provides it."
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is not installed."

rm -f "$MARKER"
install_from iso "$ISO_NAME" "$ISO_SIZE" "$ISO_SHA256" "${ISO_URLS[@]}"
install_from patch "$PATCH_NAME" "$PATCH_SIZE" "$PATCH_SHA256" "${PATCH_URLS[@]}"

scan
lost=0
for i in "${!M_DEST[@]}"; do
  if missing "$i"; then
    echo "Missing: gamedata/${M_DEST[$i]}"
    lost=$((lost + 1))
  fi
done
[ "$lost" -eq 0 ] || fail "$lost files are still missing."

rmdir "$DLDIR" 2>/dev/null
sed -n 's/^# id: //p' "$MANIFEST" > "$MARKER" || fail "Cannot write gamedata/.installed."
echo "Unreal Gold is installed."
