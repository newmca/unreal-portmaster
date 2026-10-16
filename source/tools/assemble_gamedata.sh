#!/usr/bin/env bash
# assemble_gamedata.sh - build ports/unrealgold/gamedata/ from a modded Unreal
# Gold install (OldUnreal 227k_13 plus mods) with the official OldUnreal
# 227k_15 Linux patch laid over it.
#
# Every file is a btrfs reflink clone (cp -a --reflink=always), so no bytes are
# duplicated and both sources are only read. DEST must be on the same btrfs
# filesystem as the sources.
#
# No HD content: the HD skin packs and the mutators that need them are left
# out, and the HD re-releases of 49 texture packs are replaced by the original
# packs the install keeps in Textures/AddOns/ (see HD_ORIGINALS).
#
# The script is idempotent. A file whose size and mtime already match its
# source is skipped. A file in DEST that the plan no longer contains is listed,
# and deleted only when PRUNE=1. At the end, ue1pkg.py checks that the
# swapped texture packs satisfy every import.
#
# Usage:
#   [USER_GAME=dir] [PATCH_DIR=dir] [DEST=dir] [OVERLAY=dir:dir...]
#   [CAMPAIGNS=file] [STOCK_ENGINE=0|1] [PRUNE=0|1] [DRY_RUN=0|1]
#   assemble_gamedata.sh
#
#   USER_GAME   the modded install: Maps/ Music/ Sounds/ System/ System64/ ...
#   PATCH_DIR   OldUnreal-UnrealPatch227k-Linux.tar.bz2 (v227k_15,
#               sha256 b04eba6d5c885c98bd9da8279840b15cd8fa06ed2b750235e7ad7aa26ef3f7a1),
#               extracted. The tarball has no top-level directory.
#   DEST        output directory; defaults to ../../gamedata next to this script.
#   OVERLAY     colon-separated directories laid over everything else, each
#               mirroring the gamedata layout (for example a build output with
#               SystemARM64/OpenGLDrv.so). Rebuilt modules belong here, so a
#               rerun does not put the official 227k_15 files back. Defaults
#               to the overlay build_all.sh stages in
#               ${UNREALGOLD_CACHE:-~/.cache/unrealgold-port}/build/overlay.
#   CAMPAIGNS   the single-player campaigns to ship, by New Game menu name
#               (default: campaigns.txt next to this script). Mod files that
#               none of them needs are left out, see select_campaigns.py. Its
#               report and the filtered .int files go to
#               ${UNREALGOLD_CACHE:-~/.cache/unrealgold-port}/build/campaigns.
#               CAMPAIGNS= (empty) ships every campaign of the install.
#   STOCK_ENGINE=1  allow an empty OVERLAY, i.e. ship the official 227k_15
#               SDLDrv/OpenGLDrv and real libSDL3, which cannot open a window
#               on muOS. Only useful for comparisons on a desktop.
#   PRUNE=1     delete files in DEST that are not in the plan (never Save/).
#   DRY_RUN=1   print the plan (one "DEST_REL <- SOURCE" line per file) and
#               what is left out, then stop without touching DEST.
set -euo pipefail
shopt -s nullglob
export LC_ALL=C	# byte-wise sort order and ASCII case folding

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
USER_GAME=${USER_GAME:-/home/boss/Code/ut99-muos-portmaster/UnrealGold}
PATCH_DIR=${PATCH_DIR:-/home/boss/.cache/unrealgold-port/downloads/227k_15/linux}
DEST=${DEST:-$(cd "$HERE/../../unreal" && pwd)/gamedata}
CACHE=${UNREALGOLD_CACHE:-$HOME/.cache/unrealgold-port}
OVERLAY=${OVERLAY-$CACHE/build/overlay}
CAMPAIGNS=${CAMPAIGNS-$HERE/campaigns.txt}
CONFIG_DIR=$(cd "$HERE/../../unreal/config" && pwd)
STOCK_ENGINE=${STOCK_ENGINE:-0}
PRUNE=${PRUNE:-0}
DRY_RUN=${DRY_RUN:-0}

die() { printf 'assemble_gamedata: error: %s\n' "$*" >&2; exit 1; }
log() { printf 'assemble_gamedata: %s\n' "$*"; }

for d in "$USER_GAME/System" "$USER_GAME/System64" "$PATCH_DIR/System" "$PATCH_DIR/SystemARM64"; do
	[[ -d $d ]] || die "missing directory $d"
done
[[ -d $(dirname "$DEST") ]] || die "parent of DEST does not exist: $DEST"
[[ -n $OVERLAY || $STOCK_ENGINE == 1 ]] ||
	die "OVERLAY is empty: the port's rebuilt modules would be replaced by the official ones (run build_all.sh, or set STOCK_ENGINE=1 on purpose)"

# ---------------------------------------------------------------------------
# The plan: one entry per output file, keyed by the lower-cased output path.
# exFAT is case-insensitive, so two paths that differ only in case are the same
# file on the SD card. A second "new" entry for a key is a hard error. An
# "overlay" entry replaces the earlier one and takes over its spelling.
# ---------------------------------------------------------------------------
declare -A PLAN_SRC=() PLAN_DST=()
declare -a DROPPED=() OVERLAID=()
declare -i CAMPAIGN_DROPPED=0

plan_add() # plan_add DEST_REL SRC_PATH new|overlay
{
	local rel=$1 src=$2 mode=$3 key=${1,,}
	if [[ -n ${PLAN_SRC[$key]+set} ]]; then
		[[ $mode == overlay ]] || die "'${PLAN_DST[$key]}' and '$rel' differ only in case (exFAT cannot hold both)"
		OVERLAID+=("$rel")
	fi
	PLAN_SRC[$key]=$src
	PLAN_DST[$key]=$rel
}

drop() { DROPPED+=("$1|$2"); }

is_elf() # is_elf FILE: true for ELF executables and shared objects
{
	local magic=
	IFS= read -r -N 4 magic < "$1" || true
	[[ $magic == $'\x7fELF' ]]
}

# Files of the modded install that are byte-identical copies of a package
# under a name the engine never loads. They are dropped only while they stay
# identical; otherwise the script stops so someone can look at them.
declare -A DUPLICATE_OF=(
	[Maps/Bluf224c.rra]=Maps/Bluff.unr
	[Sounds/MatrixSnd.extro]=Sounds/MatrixSnd.uax
)

# user_drop_reason REL: set REASON to why a file of the modded install is left
# out, or to "" to keep it.
user_drop_reason()
{
	local rel=$1 base=${1##*/}
	REASON=
	case $base in
		.*)                         REASON="hidden file"; return ;;
		*.bak|*.BAK)                REASON="backup copy"; return ;;
		Thumbs.db|desktop.ini)      REASON="Windows desktop junk"; return ;;
		*.log|*.tmp|*~)             REASON="log or temporary file"; return ;;
	esac
	case $rel in
		# HD skin packs: 1.4 GB of BC1 up to 4096x4096, used only by the
		# HDSkinsMutCustom mutator, far beyond a 2 GB handheld.
		Textures/HDSkins2.utx|Textures/HDSkinsCustom.utx|Textures/HDSkinsUT99.utx|\
		System/HDSkinsMutCustom.u|System/HDSkinsMut.int|System/HDSkinsConfig.ini)
			REASON="HD skin pack"; return ;;
		# HD armour mutator. HDRandomArmor.u imports HDSkinsUT99.HDJarmor2, so
		# without HDSkinsUT99.utx it cannot load ("Can't find file for package
		# HDSkinsUT99"). HDArmor.utx (three 2048x2048 BC1 armour skins) is
		# imported by HDRandomArmor.u and nothing else.
		System/HDRandomArmor.u|System/HDRandomArmor.int|Textures/HDArmor.utx)
			REASON="HD armour mutator, needs the HD skin pack"; return ;;
		# Seven 256x256 BC3 textures. No package, map, .int or .ini in the
		# tree refers to the package.
		Textures/HDtextures.utx)
			REASON="HD leftover, nothing refers to it"; return ;;
		# BotPack.u/.int (2012) and Botpack.u/.int (Botpack227, 2023) differ
		# only in case. exFAT can hold one of them; Botpack227 is the 227 one.
		System/BotPack.u|System/BotPack.int)
			REASON="2012 BotPack, case-collides with Botpack227 (2023)"; return ;;
		# The old Windows Unreal.ini (Galaxy/SoftDrv, backslash Paths) and the
		# desktop icon. The Linux engine reads UnrealLinux.ini from conf/.
		# The stock installer leftovers (Default.ini, Manifest.ini,
		# OpenGlDrv.ini, ConfigLogo.bmp) stay: the OldUnreal Linux install
		# keeps them too.
		System/Unreal.ini|System/Unreal.ico)
			REASON="Windows-only leftover, not part of the OldUnreal Linux install"; return ;;
	esac
	if [[ -n ${DUPLICATE_OF[$rel]+set} ]]; then
		cmp -s "$USER_GAME/$rel" "$USER_GAME/${DUPLICATE_OF[$rel]}" ||
			die "$rel is no longer identical to ${DUPLICATE_OF[$rel]}"
		REASON="byte-identical copy of ${DUPLICATE_OF[$rel]}"; return
	fi
	# System/ of the modded install holds the i386 engine (*.so, *-bin-x86).
	# The ARM64 engine comes from the patch below.
	if [[ $rel == System/* ]] && is_elf "$USER_GAME/$rel"; then
		REASON="i386 binary"
	fi
}

# Files of the modded install that are shipped under another name.
declare -A RENAME=(
	# Double extension: the engine looks for XenomeFD.int, so the olroot
	# MapPack entry XenomeFD.FirstDay was never listed.
	[System/XenomeFD.int.int]=System/XenomeFD.int
	# Upper-case extension: the engine finds WOT.int only through its slower
	# case-insensitive search (and not at all on a case-sensitive card).
	[System/WOT.INT]=System/WOT.int
)
declare -a RENAMED=()
for rel in "${!RENAME[@]}"; do
	[[ ! -e $USER_GAME/${RENAME[$rel]} ]] ||
		die "both $rel and ${RENAME[$rel]} exist in $USER_GAME; compare them and update RENAME"
done

# 1. The modded install. Help/, Manuals/, WebServer/, Compress/, Save/ (PC
#    saves), System64/ (amd64 engine and the PC's live config) and the
#    227k_13 SystemARM64/ are not copied. Neither is Textures/AddOns/: it is
#    not on the Linux Paths= list, HD_ORIGINALS below takes the originals it
#    holds, and the rest of it is byte-identical copies of Textures/ files
#    and three other versions that are not used (see HD_ORIGINALS).
USER_DIRS=(System SystemLocalized Maps Music Sounds Textures Meshes)
links=$(cd "$USER_GAME" && find "${USER_DIRS[@]}" -type l -print -quit)
[[ -z $links ]] || die "unexpected symlink in the modded install: $links"
addons=("$USER_GAME"/Textures/AddOns/*)
drop "Textures/AddOns/ (${#addons[@]} files)" "not on the Linux Paths; HD_ORIGINALS takes the originals from it"
while IFS= read -r -d '' rel; do
	user_drop_reason "$rel"
	if [[ -n $REASON ]]; then
		drop "$rel" "$REASON"
	elif [[ -n ${RENAME[$rel]+set} ]]; then
		plan_add "${RENAME[$rel]}" "$USER_GAME/$rel" new
		RENAMED+=("$rel -> ${RENAME[$rel]}")
	else
		plan_add "$rel" "$USER_GAME/$rel" new
	fi
done < <(cd "$USER_GAME" && find "${USER_DIRS[@]}" -path Textures/AddOns -prune -o -type f -print0 | sort -z)

# HD texture packs. Textures/ of the modded install holds BC1 re-releases of
# these UT texture and skin packs (up to 2048x2048, SGTech1 and ShaneChurch
# up to 4096x4096; 1686 MiB). The original packs (P8, at most 512x512;
# 122 MiB) are in Textures/AddOns/. Every export apart from palettes has the
# same name, group and class in both. `ue1pkg.py dropin` found every object
# that any package of gamedata imports from these packs in the original, and
# the check after the copy below repeats that for the finished tree.
# Not swapped, although AddOns/ has another version:
#   Unreal95Tex    The Textures/ copy is not HD but a P8 version with 10 more
#                  textures, 9 of them used by DE02_Attila, DE03_KarpathianK
#                  and DE24_Underworld; the AddOns copy lacks those.
#   LadderFonts,   The 227k_15 patch below ships both, so its stock files
#   UGreenWindowFonts
#                  win. The AddOns copies are older; the UGreenWindowFonts one
#                  is a 17 MB HD font pack.
HD_ORIGINALS=(
	ArenaTex BossSkins city commandoskins Coret_FX Crypt2 Crypt_FX CTF
	DacomaFem DacomaSkins DDayFX Egypt EgyptPan eol Factory FCommandoSkins
	FractalFX GothFem GothSkins Indus1 Indus2 Indus3 Indus4 Indus5 Indus6
	Lian-X Metalmys noxxpack of1 Old_FX RainFX SGirlSkins SGTech1 ShaneChurch
	Slums Soldierskins tcowmeshskins tnalimeshskins TrenchesFX tskmskins UT
	UTbase1 UTcrypt UTtech1 UTtech2 UTtech3 XbpFX Xtortion xutfx
)
for name in "${HD_ORIGINALS[@]}"; do
	[[ -f $USER_GAME/Textures/$name.utx && -f $USER_GAME/Textures/AddOns/$name.utx ]] ||
		die "HD_ORIGINALS: Textures/$name.utx or Textures/AddOns/$name.utx is missing"
	# The patch is laid over this; a pack it ships must stay the patch's.
	[[ ! -e $PATCH_DIR/Textures/$name.utx ]] ||
		die "HD_ORIGINALS: the 227k_15 patch ships Textures/$name.utx; remove $name from the list"
	plan_add "Textures/$name.utx" "$USER_GAME/Textures/AddOns/$name.utx" overlay
done

# Mod packages installed by accident next to the amd64 binary. The PC searched
# ../System64/*.u before ../System/*.u, so these are the copies the game
# loaded; they replace the older ones in System/ (Serpentineplus.u differs).
for f in Serpentinepm.u Serpentineplus.u Serpentineplus.int; do
	plan_add "System/$f" "$USER_GAME/System64/$f" overlay
done

# 2. The 227k_15 patch over it: UnrealScript packages and inis in System/,
#    SystemLocalized/ and the new maps, music, sounds and textures. The
#    patch ships no file of any mod, so nothing of a mod is replaced.
#    Skipped: the i386 binaries, the SDL symlinks, and the localization
#    repository's .git/.gitattributes stubs.
PATCH_DIRS=()
for d in System SystemLocalized Maps Music Sounds Textures Meshes; do
	[[ -d $PATCH_DIR/$d ]] && PATCH_DIRS+=("$d")
done
while IFS= read -r -d '' rel; do
	base=${rel##*/}
	case $base in
		UnrealLinux.ini|User.ini|*.log)
			die "$PATCH_DIR/$rel was generated by a test run; use a clean extraction" ;;
	esac
	if [[ $rel == SystemLocalized/.git* ]]; then
		drop "patch:$rel" "localization repository stub"
	elif [[ $rel == System/* ]] && is_elf "$PATCH_DIR/$rel"; then
		drop "patch:$rel" "i386 binary"
	else
		plan_add "$rel" "$PATCH_DIR/$rel" overlay
	fi
done < <(cd "$PATCH_DIR" && find "${PATCH_DIRS[@]}" -type f -print0 | sort -z)

# 3. SystemARM64: the 227k_15 ARM64 engine as real files. The tarball's
#    libSDL3.so.0 and libSDL3_ttf.so.0 are symlinks to the versioned files;
#    exFAT has no symlinks, so the versioned file is copied under the
#    symlink's name (the SONAME the binaries ask for) and not under its own.
declare -A ARM64_ALIAS=()
for link in "$PATCH_DIR"/SystemARM64/*; do
	[[ -L $link ]] || continue
	target=$(readlink "$link")
	[[ $target != */* && -f $PATCH_DIR/SystemARM64/$target ]] ||
		die "unexpected symlink $link -> $target"
	ARM64_ALIAS[$target]=${link##*/}
done
for f in "$PATCH_DIR"/SystemARM64/*; do
	[[ -L $f ]] && continue
	name=${f##*/}
	if [[ -n ${ARM64_ALIAS[$name]+set} ]]; then
		drop "patch:SystemARM64/$name" "shipped as SystemARM64/${ARM64_ALIAS[$name]}"
		name=${ARM64_ALIAS[$name]}
		if command -v readelf > /dev/null; then
			soname=$(readelf -d "$f" | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p')
			[[ $soname == "$name" ]] || die "$f has SONAME '$soname', expected '$name'"
		fi
	fi
	plan_add "SystemARM64/$name" "$f" new
done

# The engine copies DefaultLinux.ini/DefUser.ini to UnrealLinux.ini/User.ini
# when those are missing, and ResetConfig reads them. The patch has no inis in
# SystemARM64/. System/DefaultLinux.ini is the one that names
# OpenGLDrv.OpenGLRenderDevice and SDLDrv.SDLClient; System64's still names
# SDL2Drv.SDL2Client.
for f in DefaultLinux.ini DefUser.ini; do
	plan_add "SystemARM64/$f" "$PATCH_DIR/System/$f" new
done

# Mod inis that lived next to the amd64 binary. The engine opens config(X)
# as X.ini in its working directory, so these are the live mod settings.
# System64 also has oldskool.ini (300 B, older) next to OldSkool.ini
# (1073 B); exFAT holds only one, and OldSkool.ini is the name config(OldSkool)
# opens. UnrealLinux.ini and User.ini are not copied: the launcher bind-mounts
# them from conf/.
for f in RLCoopE.ini RLCoopEHub.ini RLCoopClient.ini OldSkool.ini UMSSpaceMenu.ini; do
	plan_add "SystemARM64/$f" "$USER_GAME/System64/$f" new
done
drop "System64/oldskool.ini" "case-collides with System64/OldSkool.ini (kept)"

# 4. Optional overlays (see OVERLAY above), in the order given.
IFS=: read -r -a overlay_dirs <<< "$OVERLAY"
for odir in "${overlay_dirs[@]}"; do
	[[ -d $odir ]] || die "OVERLAY directory $odir does not exist (build_all.sh stages it)"
	links=$(find "$odir" -type l -print -quit)
	[[ -z $links ]] || die "symlink in OVERLAY directory: $links"
	while IFS= read -r -d '' rel; do
		plan_add "$rel" "$odir/$rel" overlay
	done < <(cd "$odir" && find . -type f -printf '%P\0' | sort -z)
done

# 5. Campaign selection. select_campaigns.py reads the plan and decides, per
#    file, whether a kept campaign (or the stock game, the engine or the
#    port's inis) needs it. Files it drops leave the plan; .int files that
#    list dropped campaigns or packages are replaced by filtered copies.
CAMPAIGN_WORK=$CACHE/build/campaigns
if [[ -n $CAMPAIGNS ]]; then
	[[ -f $CAMPAIGNS ]] || die "CAMPAIGNS file $CAMPAIGNS does not exist"
	mkdir -p "$CAMPAIGN_WORK"
	for key in "${!PLAN_SRC[@]}"; do
		printf '%s\0%s\0' "${PLAN_DST[$key]}" "${PLAN_SRC[$key]}"
	done > "$CAMPAIGN_WORK/plan"
	python3 "$HERE/select_campaigns.py" --plan "$CAMPAIGN_WORK/plan" \
		--campaigns "$CAMPAIGNS" --stock "$HERE/stock_227k15.txt" \
		--config "$CONFIG_DIR/UnrealLinux.ini" --config "$CONFIG_DIR/User.ini" \
		--decisions "$CAMPAIGN_WORK/decisions.tsv" \
		--filtered-dir "$CAMPAIGN_WORK/filtered" \
		--report "$CAMPAIGN_WORK/report.txt" ||
		die "select_campaigns.py failed (see $CAMPAIGN_WORK/report.txt)"
	while IFS=$'\t' read -r decision rel detail; do
		key=${rel,,}
		[[ ${PLAN_DST[$key]:-} == "$rel" ]] || die "select_campaigns.py decided on '$rel', which is not in the plan"
		case $decision in
			keep) ;;
			drop)
				unset 'PLAN_SRC[$key]' 'PLAN_DST[$key]'
				CAMPAIGN_DROPPED+=1 ;;
			filter)
				PLAN_SRC[$key]=$detail
				OVERLAID+=("$rel") ;;
			*) die "select_campaigns.py: unknown decision '$decision' for $rel" ;;
		esac
	done < "$CAMPAIGN_WORK/decisions.tsv"
fi

# 6. Mod config files. The engine opens config(X) as X.ini in its working
#    directory only, which is SystemARM64/ on the device (the launcher cds
#    there): a probe line in System/B227_MapFix.ini was ignored, the same
#    line in the working directory took effect. The mods put their inis in
#    System/, the Windows working directory, so the ones not stock move to
#    SystemARM64/ (B227_MapFix.ini with the collection's map fixes and game
#    types, Botpack.ini, ONP.ini, Xidia.ini). A copy that SystemARM64/
#    already has from the PC's System64/ (OldSkool.ini) is the live one; the
#    older System/ copy stays where it is, unread.
declare -A STOCK_FILE=()
while IFS= read -r line; do
	[[ -z $line || $line == \#* ]] || STOCK_FILE[$line]=1
done < "$HERE/stock_227k15.txt"
declare -a MOVED_INI=()
for key in "${!PLAN_DST[@]}"; do
	rel=${PLAN_DST[$key]}
	[[ $rel == System/*.ini && -z ${STOCK_FILE[$key]+set} ]] || continue
	new=SystemARM64/${rel#System/}
	[[ -z ${PLAN_SRC[${new,,}]+set} ]] || continue
	PLAN_SRC[${new,,}]=${PLAN_SRC[$key]}
	PLAN_DST[${new,,}]=$new
	unset 'PLAN_SRC[$key]' 'PLAN_DST[$key]'
	MOVED_INI+=("$rel -> $new")
done

report_plan()
{
	log "plan: ${#PLAN_SRC[@]} files (${#OVERLAID[@]} replaced by System64, HD_ORIGINALS, the 227k_15 patch, OVERLAY or a filtered .int), ${#DROPPED[@]} left out"
	local entry
	for entry in "${RENAMED[@]}"; do
		log "  renamed: $entry"
	done
	for entry in "${MOVED_INI[@]}"; do
		log "  moved to the working directory: $entry"
	done
	for entry in "${DROPPED[@]}"; do
		log "  left out: ${entry%%|*}  (${entry#*|})"
	done
	if [[ -n $CAMPAIGNS ]]; then
		log "  left out: $CAMPAIGN_DROPPED mod files that no campaign in $CAMPAIGNS needs (see $CAMPAIGN_WORK/report.txt)"
	fi
}

if [[ $DRY_RUN == 1 ]]; then
	for key in "${!PLAN_SRC[@]}"; do
		printf '%s <- %s\n' "${PLAN_DST[$key]}" "${PLAN_SRC[$key]}"
	done | sort
	report_plan
	exit 0
fi

# ---------------------------------------------------------------------------
# Apply the plan.
# ---------------------------------------------------------------------------
mkdir -p "$DEST"

# Current state of DEST, so unchanged files are not cloned again.
declare -A HAVE=()
while IFS=$'\t' read -r -d '' rel state; do
	HAVE[$rel]=$state
done < <(find "$DEST" -type f -printf '%P\t%s %T@\0')

copied=0 kept=0
declare -A MADE_DIR=()
for key in "${!PLAN_SRC[@]}"; do
	rel=${PLAN_DST[$key]} src=${PLAN_SRC[$key]}
	want=$(stat -L -c '%s %.9Y' -- "$src")
	have=${HAVE[$rel]:-}
	# find prints %T@ with 10 fractional digits, stat %.9Y with 9.
	if [[ -n $have && ${have:0:${#want}} == "$want" && ! -L $DEST/$rel ]]; then
		kept=$((kept + 1))
		continue
	fi
	dir=$(dirname "$DEST/$rel")
	if [[ -z ${MADE_DIR[$dir]+set} ]]; then
		mkdir -p "$dir"
		MADE_DIR[$dir]=1
	fi
	# -f: some sources are read-only (0444) and so are their earlier clones.
	cp -af --reflink=always -- "$src" "$DEST/$rel"
	copied=$((copied + 1))
done

# Save/ starts empty; the README keeps the directory in zip archives.
mkdir -p "$DEST/Save"
readme="Default save game folder of Unreal Gold (SavePath=../Save). This file only keeps the folder in zip archives."
if [[ ! -f $DEST/Save/README.txt || $(< "$DEST/Save/README.txt") != "$readme" ]]; then
	printf '%s\n' "$readme" > "$DEST/Save/README.txt"
fi

# Anything else in DEST is left over from an older plan or was written by a
# game run. Save/ is never touched: it may hold someone's save games.
declare -a STALE=()
while IFS= read -r -d '' rel; do
	key=${rel,,}
	[[ $rel == Save/* ]] && continue
	[[ ${PLAN_DST[$key]:-} == "$rel" ]] || STALE+=("$rel")
done < <(find "$DEST" -type f -printf '%P\0')

report_plan
log "copied $copied, already up to date $kept"

if ((${#STALE[@]})); then
	for rel in "${STALE[@]}"; do
		if [[ $PRUNE == 1 ]]; then
			rm -f -- "$DEST/$rel"
			log "  pruned: $rel"
		else
			log "  not in the plan: $rel"
		fi
	done
	[[ $PRUNE == 1 ]] || die "${#STALE[@]} file(s) in $DEST are not in the plan; rerun with PRUNE=1 to delete them"
	find "$DEST" -mindepth 1 -type d -empty ! -path "$DEST/Save" -delete
fi

# The swapped texture packs must hold every object any package of the finished
# tree imports from them (name, group, class). Exit status 1 otherwise.
# Packs that the campaign selection left out are not checked.
shipped=()
for name in "${HD_ORIGINALS[@]}"; do
	[[ -n ${PLAN_SRC[textures/${name,,}.utx]+set} ]] && shipped+=("$name")
done
log "checking the imports from the ${#shipped[@]} shipped original texture packs"
python3 "$HERE/ue1pkg.py" objects -q "$DEST" "${shipped[@]}" ||
	die "an original texture pack lacks an imported object (see above)"
