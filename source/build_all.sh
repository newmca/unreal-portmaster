#!/usr/bin/env bash
# build_all.sh - rebuild every binary this port compiles and lay the results
# over gamedata/. The single entry point for a release build; see BUILD.md.
#
#   source/build_all.sh [--no-assemble] [--strict]
#
#   --no-assemble  stop after staging the overlay and leave gamedata/ alone
#                  (for a build without the Unreal Gold install)
#   --strict       fail if a binary differs from its recorded sha256
#
# Environment, defaults in brackets:
#   UNREALGOLD_CACHE          [~/.cache/unrealgold-port] inputs, build trees, outputs
#   UNREALGOLD_BUILD_IMAGE    [localhost/unrealgold-build:jammy]
#   UNREALGOLD_REBUILD_IMAGE  [0] 1 runs "podman build --no-cache" even if the
#                             image exists (the packages may then be newer)
#   USER_GAME                 [<repository>/UnrealGold] the modded Unreal Gold install
#   DEST                      [unreal/gamedata]
#   PRUNE                     [0] passed on to tools/assemble_gamedata.sh
#   JOBS                      [nproc] parallel compile jobs
#
# Steps:
#   1. image     use the build image; build it from ./Containerfile if missing
#   2. inputs    fetch the pinned inputs that are missing from the cache and
#                check the 227k_15 trees against their release tarballs
#   3. build     sdl3shim, SDLDrv, NOpenGLESDrv (arm64 and amd64),
#                each through its own build.sh
#   4. stage     $UNREALGOLD_CACHE/build/overlay, laid out like gamedata/:
#                SystemARM64/{libSDL3.so.0,SDLDrv.so,NOpenGLESDrv.so}
#                from the arm64 builds, and System/NOpenGLESDrv.int
#   5. assemble  tools/assemble_gamedata.sh with OVERLAY=<the overlay>
#   6. report    sha256 of every shipped binary, compared with the recorded
#                hashes and with the file each one was copied from
# Steps 2 to 6 run inside the build container, so the host needs only podman.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname "$HERE")
PORT=$ROOT/unreal
REPO=$(dirname "$ROOT")
CACHE=${UNREALGOLD_CACHE:-$HOME/.cache/unrealgold-port}
IMAGE=${UNREALGOLD_BUILD_IMAGE:-localhost/unrealgold-build:jammy}
USER_GAME=${USER_GAME:-$REPO/UnrealGold}
DEST=${DEST:-$PORT/gamedata}
OVERLAY_DIR=$CACHE/build/overlay

log() { printf 'build_all: %s\n' "$*"; }
die() { printf 'build_all: error: %s\n' "$*" >&2; exit 1; }
sha256() { sha256sum "$1" | cut -d' ' -f1; }

ASSEMBLE=1 STRICT=0
for arg; do
	case $arg in
		--no-assemble) ASSEMBLE=0 ;;
		--strict)      STRICT=1 ;;
		-h|--help)     sed -n '2,/^set -euo/{/^#/s/^# \{0,1\}//p}' "$0"; exit 0 ;;
		*)             die "unknown option '$arg' (see --help)" ;;
	esac
done

# ---------------------------------------------------------------------------
# Pinned inputs. BUILD.md lists the same pins with their sources.
# ---------------------------------------------------------------------------
RELEASE_URL=https://github.com/OldUnreal/Unreal-testing/releases/download/v227k_15
GAME_TAR=OldUnreal-UnrealPatch227k-Linux.tar.bz2
GAME_SHA=b04eba6d5c885c98bd9da8279840b15cd8fa06ed2b750235e7ad7aa26ef3f7a1
SDK_TAR=OldUnreal-UnrealPatch227k-SDK-Linux.tar.bz2
SDK_SHA=8ec77372a666d999ae688b9d1a852632433a66b0dabc6805b098bf019e82be4f
CMAKE_NAME="cmake-3.31.6-linux-x86_64"
CMAKE_URL=https://github.com/Kitware/CMake/releases/download/v3.31.6/$CMAKE_NAME.tar.gz
CMAKE_SHA=5a1133ff103c71eb5120e2cc3de922733e7d8a26a98ae716397e8676adb367bf
# directory under downloads/, repository, commit. The build scripts check the
# content they use (tree hashes, or git archive of the commit). bmdhacks' SDL
# is fetched by sdl3shim/build.sh itself.
GIT_INPUTS=(
	"sdl3-release-3.4.8     https://github.com/libsdl-org/SDL.git        d9d5536704d585616d4db3c8ba3c4ff6fc2757e1"
	"Andiweli_UT99-Android  https://github.com/Andiweli/UT99-Android.git 85b1a9ada6ae28c422570d4603e57e4e4cef6eb1"
)

# Outputs under $CACHE/build and the sha256 they had when SOURCE.md was
# written. The builds are deterministic, so the same inputs, patches and
# image give the same bytes. After a deliberate change to a patch, update
# these, SOURCE.md and the component's BUILD.md together.
RECORDED=(
	"sdl3shim/arm64/libSDL3.so.0     c31b0bd73f12b71c4c839042d4f2e21fa5e844def05e845dc3b45dbfce5392c5"
	"sdldrv/arm64/SDLDrv.so          70010af4c380a2b1ad2ed3fe6619ab3fb9d92871431f0bbc9c077188f5c2bb51"
	"nopengles/arm64/NOpenGLESDrv.so 2f71b8cb6fbccdeeb9952782cb18f92d7848209606e261ba3d94fd3664ade0e6"
	"sdl3shim/amd64/libSDL3.so.0     1197aa2b8677a9f3a62fbf3801d00db627dad878ce971804310524e7c2e0034d"
	"sdldrv/amd64/SDLDrv.so          d128eda2b2c95b45fd74d8c24a6e7c79273d7ec4538eb4d67a1e4e34a4698a68"
	"nopengles/amd64/NOpenGLESDrv.so 8fdb8910246ed054745f39b96249dbb8681bee11d6b4c2cd9d569107d9ab58e2"
)

# What the overlay holds: path in gamedata, then its source.
OVERLAY_FILES=(
	"SystemARM64/libSDL3.so.0    $CACHE/build/sdl3shim/arm64/libSDL3.so.0"
	"SystemARM64/SDLDrv.so       $CACHE/build/sdldrv/arm64/SDLDrv.so"
	"SystemARM64/NOpenGLESDrv.so $CACHE/build/nopengles/arm64/NOpenGLESDrv.so"
	"System/NOpenGLESDrv.int     $HERE/NOpenGLESDrv/NOpenGLESDrv.int"
)

# The directories of the 227k_15 tree that assemble_gamedata.sh reads.
PATCH_DIRS_USED=(System SystemARM64 SystemLocalized Maps Music Sounds Textures Meshes)

# ===========================================================================
# Host: the build image, then this script again inside it.
# ===========================================================================
if [[ ${UNREALGOLD_BUILD_ALL_STAGE:-} != container ]]; then
	command -v podman > /dev/null || die "podman is required"
	((ASSEMBLE == 0)) || [[ -d $USER_GAME/System ]] ||
		die "USER_GAME=$USER_GAME is not an Unreal Gold install; set USER_GAME or pass --no-assemble"
	mkdir -p "$CACHE"

	# 1. The build image. An existing image is used as it is (its packages
	#    are what the recorded hashes were built with); a Containerfile
	#    label tells whether it came from this Containerfile. A missing image
	#    is built with podman's layer cache; UNREALGOLD_REBUILD_IMAGE=1
	#    bypasses the cache, so apt installs today's package versions.
	cf_sha=$(sha256 "$HERE/Containerfile")
	build_args=()
	[[ ${UNREALGOLD_REBUILD_IMAGE:-0} == 1 ]] && build_args=(--no-cache)
	if ((${#build_args[@]})) || ! podman image exists "$IMAGE"; then
		log "1/6 image: podman build ${build_args[*]} $IMAGE from $HERE/Containerfile"
		podman build "${build_args[@]}" --label "org.unrealgold.containerfile-sha256=$cf_sha" \
			-t "$IMAGE" -f "$HERE/Containerfile" "$HERE"
	fi
	label=$(podman image inspect --format '{{index .Labels "org.unrealgold.containerfile-sha256"}}' "$IMAGE")
	image_id=$(podman image inspect --format '{{.Id}}' "$IMAGE")
	log "1/6 image: $IMAGE ${image_id:0:12}"
	case $label in
		"$cf_sha") ;;
		"")        log "    the image has no Containerfile label (built by hand); using it as it is" ;;
		*)         log "    warning: the image was built from another Containerfile ($label);"
		           log "    UNREALGOLD_REBUILD_IMAGE=1 rebuilds it from $HERE/Containerfile" ;;
	esac

	mounts=(-v "$CACHE:$CACHE" -v "$ROOT:$ROOT")
	if ((ASSEMBLE)); then
		mounts+=(-v "$USER_GAME:$USER_GAME:ro")
		case $DEST/ in
			"$ROOT"/*|"$CACHE"/*) ;;
			*) mkdir -p "$DEST" && mounts+=(-v "$DEST:$DEST") ;;
		esac
	fi
	podman run --rm --security-opt label=disable --userns=keep-id "${mounts[@]}" -w "$HERE" \
		-e UNREALGOLD_BUILD_ALL_STAGE=container -e UNREALGOLD_CACHE="$CACHE" \
		-e USER_GAME="$USER_GAME" -e DEST="$DEST" -e PRUNE="${PRUNE:-0}" -e JOBS="${JOBS:-}" \
		-e PYTHONDONTWRITEBYTECODE=1 \
		"$IMAGE" bash "$HERE/build_all.sh" "$@"

	exit 0
fi

# ===========================================================================
# Inside the build container.
# ===========================================================================
[[ -d $CACHE ]] || die "UNREALGOLD_CACHE=$CACHE does not exist"
export UNREALGOLD_CACHE=$CACHE
downloads=$CACHE/downloads
SECONDS=0
step() { log "$1 ($((SECONDS / 60))m$((SECONDS % 60))s)"; }

download() # URL FILE SHA256
{
	local url=$1 file=$2 want=$3 got
	log "    download $url"
	mkdir -p "$(dirname "$file")"
	python3 -c 'import shutil, sys, urllib.request
with urllib.request.urlopen(sys.argv[1], timeout=120) as r, open(sys.argv[2], "wb") as f:
    shutil.copyfileobj(r, f, 1 << 20)' "$url" "$file.part"
	got=$(sha256 "$file.part")
	[[ $got == "$want" ]] || die "$url has sha256 $got, expected $want"
	mv -f "$file.part" "$file"
}

release_tree() # TARBALL SHA256 DIR: DIR holds exactly TARBALL's files, unchanged
{
	local tarball=$1 want=$2 dir=$3 extra
	[[ -f $tarball && $(sha256 "$tarball") == "$want" ]] ||
		download "$RELEASE_URL/${tarball##*/}" "$tarball" "$want"
	if [[ ! -d $dir ]]; then
		log "    extract ${tarball##*/} into $dir"
		rm -rf "$dir.part"
		mkdir -p "$dir.part"
		tar -xf "$tarball" -C "$dir.part"
		mv "$dir.part" "$dir"
	fi
	# Content, size, mode and mtime of every file in the tarball.
	tar -df "$tarball" -C "$dir" >&2 || die "$dir differs from ${tarball##*/} (see above)"
	# Files the tarball does not have, for example left by a test run.
	extra=$(LC_ALL=C comm -13 \
		<(tar -tf "$tarball" | sed 's#^\./##' | LC_ALL=C sort) \
		<(cd "$dir" && find . -type f | sed 's#^\./##' | LC_ALL=C sort))
	REPLY=$extra
}

git_input() # DIR URL COMMIT: shallow checkout of COMMIT unless DIR exists
{
	local dir=$downloads/$1 url=$2 commit=$3
	if [[ ! -e $dir ]]; then
		log "    fetch $url $commit"
		rm -rf "$dir.part"
		git init -q "$dir.part"
		git -C "$dir.part" remote add origin "$url"
		git -C "$dir.part" fetch -q --depth 1 origin "$commit"
		git -C "$dir.part" -c advice.detachedHead=false checkout -q --detach "$commit"
		mv "$dir.part" "$dir"
	fi
	git -C "$dir" cat-file -e "$commit^{commit}" 2> /dev/null ||
		die "$dir does not contain commit $commit of $url"
}

# 2. Inputs.
step "2/6 inputs: $downloads"
release_tree "$downloads/227k_15/$SDK_TAR" "$SDK_SHA" "$downloads/227k_15/sdk-linux"
[[ -z $REPLY ]] || die "files in sdk-linux that are not in $SDK_TAR: $REPLY"
release_tree "$downloads/227k_15/$GAME_TAR" "$GAME_SHA" "$downloads/227k_15/linux"
if [[ -n $REPLY ]]; then
	used=$(grep -E "^($(IFS='|'; echo "${PATCH_DIRS_USED[*]}"))/" <<< "$REPLY" || true)
	[[ -z $used ]] || die "files in 227k_15/linux that are not in $GAME_TAR: $used"
	log "    not from the tarball, in directories nothing here reads: $(tr "\n" " " <<< "$REPLY")"
fi
for entry in "${GIT_INPUTS[@]}"; do
	# shellcheck disable=SC2086
	git_input $entry
done
cmake=$CACHE/tools/$CMAKE_NAME/bin/cmake
if [[ ! -x $cmake ]]; then
	download "$CMAKE_URL" "$CACHE/tools/$CMAKE_NAME.tar.gz" "$CMAKE_SHA"
	tar -xf "$CACHE/tools/$CMAKE_NAME.tar.gz" -C "$CACHE/tools"
fi
[[ $("$cmake" --version | head -n 1) == "cmake version 3.31.6" ]] || die "$cmake is not CMake 3.31.6"

# 3. Components. Each build.sh recreates its build tree, checks its pinned
#    inputs, builds arm64 and amd64 and checks the result (SONAME, NEEDED,
#    RUNPATH, exports). Inside this container they run directly.
for component in sdl3shim SDLDrv NOpenGLESDrv; do
	step "3/6 build: $component"
	sh "$HERE/$component/build.sh"
done

differ=0
for entry in "${RECORDED[@]}"; do
	read -r rel want <<< "$entry"
	got=$(sha256 "$CACHE/build/$rel")
	if [[ $got == "$want" ]]; then
		log "    $rel: reproduces the recorded sha256"
	else
		log "    $rel: DIFFERS: $got, recorded $want"
		differ=$((differ + 1))
	fi
done

# 4. Overlay. Recreated every run; cp -a keeps the mtimes, which
#    assemble_gamedata.sh compares to skip files that did not change.
step "4/6 stage: $OVERLAY_DIR"
rm -rf "$OVERLAY_DIR"
declare -A OVERLAY_SRC=()
for entry in "${OVERLAY_FILES[@]}"; do
	read -r rel src <<< "$entry"
	OVERLAY_SRC[$rel]=$src
	mkdir -p "$OVERLAY_DIR/$(dirname "$rel")"
	cp -a --reflink=auto "$src" "$OVERLAY_DIR/$rel"
	case $rel in
		*.so|*.so.*)
			hdr=$(readelf -h "$OVERLAY_DIR/$rel")
			grep -q 'Machine: *AArch64' <<< "$hdr" || die "$src is not an arm64 ELF"
			readelf -d "$OVERLAY_DIR/$rel" | grep -q "Library soname: \[${rel##*/}\]" ||
				die "$src does not have SONAME ${rel##*/}" ;;
	esac
done

if ((!ASSEMBLE)); then
	step "5/6 assemble: skipped (--no-assemble)"
	(cd "$OVERLAY_DIR" && find . -type f -printf '%P\0' | LC_ALL=C sort -z | xargs -0 sha256sum)
	((STRICT == 0 || differ == 0)) || die "$differ build output(s) differ from the recorded sha256"
	exit 0
fi

# 5. gamedata/. The script is idempotent and ends with the texture pack import check.
step "5/6 assemble: $DEST"
assemble() { # [DRY_RUN=1] assemble
	USER_GAME=$USER_GAME PATCH_DIR=$downloads/227k_15/linux DEST=$DEST OVERLAY=$OVERLAY_DIR \
		PRUNE=${PRUNE:-0} DRY_RUN=${DRY_RUN:-0} bash "$HERE/tools/assemble_gamedata.sh"
}
assemble

# 6. Report. Every file in SystemARM64 and the .int must be byte-identical to
#    the file the plan copies it from (for the overlay: the build output), and
#    SystemARM64 must hold no symlink.
step "6/6 report: $DEST/SystemARM64"
declare -A FROM=()
while IFS= read -r line; do
	FROM[${line%% <- *}]=${line#* <- }
done < <(DRY_RUN=1 assemble | grep -E '^(SystemARM64/[^/]+|System/NOpenGLESDrv\.int) <- ')
links=$(find "$DEST/SystemARM64" -type l)
[[ -z $links ]] || die "symlinks in $DEST/SystemARM64: $links"
bad=0
for rel in "${!FROM[@]}"; do
	[[ -f $DEST/$rel ]] || { printf '  %s is missing\n' "$rel"; bad=1; }
done
while IFS= read -r -d '' rel; do
	src=${FROM[$rel]:-}
	if [[ -z $src ]]; then
		printf '  %-64s  %-22s NOT IN THE PLAN\n' "$(sha256 "$DEST/$rel")" "$rel"; bad=1; continue
	fi
	if [[ $src == "$OVERLAY_DIR"/* ]]; then
		src=${OVERLAY_SRC[$rel]}	# the build output itself, not its overlay copy
	fi
	cmp -s "$DEST/$rel" "$src" || { printf '  %s differs from %s\n' "$rel" "$src"; bad=1; continue; }
	case $src in
		"$CACHE"/build/*) origin="this port: ${src#"$CACHE"/}" ;;
		"$HERE"/*) origin="this port: source/${src#"$HERE"/}" ;;
		"$downloads"/227k_15/linux/*) origin="227k_15 ${src#"$downloads"/227k_15/linux/}" ;;
		"$USER_GAME"/*) origin="Unreal Gold install ${src#"$USER_GAME"/}" ;;
		*) origin=$src ;;
	esac
	printf '  %s  %-34s %s\n' "$(sha256 "$DEST/$rel")" "$rel" "$origin"
done < <(cd "$DEST" && find SystemARM64 System/NOpenGLESDrv.int -type f -print0 | LC_ALL=C sort -z)
((bad == 0)) || die "gamedata does not match the plan (see above)"
log "SystemARM64 and System/NOpenGLESDrv.int are byte-identical to their sources"
if ((differ)); then
	log "warning: $differ build output(s) differ from the recorded sha256 (see step 3)"
	((STRICT == 0)) || exit 1
fi
step "done"
