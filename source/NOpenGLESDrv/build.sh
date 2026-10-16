#!/bin/sh
# Build NOpenGLESDrv.so for the Unreal Gold port: the UT99-Android GLES2
# renderer with NOpenGLESDrv227.patch, compiled with GCC 12 against the
# official OldUnreal 227k_15 Core.so, Engine.so and libSDL3.so.0. See BUILD.md.
#
#   ./build.sh [arm64] [amd64]          (default: both)
#
# Runs inside localhost/unrealgold-build:jammy. Started on the host, it
# re-runs itself in that container. Results:
#   $UNREALGOLD_CACHE/build/nopengles/arm64/NOpenGLESDrv.so   (device, SystemARM64)
#   $UNREALGOLD_CACHE/build/nopengles/amd64/NOpenGLESDrv.so   (amd64 host build, not shipped)
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
sources=$(CDPATH= cd -- "$here/.." && pwd)   # also holds common/BCDecode.h
image=localhost/unrealgold-build:jammy

if [ ! -e /run/.containerenv ] && [ ! -e /.dockerenv ]; then
	cache=${UNREALGOLD_CACHE:-$HOME/.cache/unrealgold-port}
	exec podman run --rm --security-opt label=disable --userns=keep-id \
		-v "$cache:$cache" -v "$sources:$sources" -w "$here" \
		-e UNREALGOLD_CACHE="$cache" \
		"$image" sh "$here/build.sh" "$@"
fi

: "${UNREALGOLD_CACHE:?set UNREALGOLD_CACHE to the port cache directory}"
downloads=$UNREALGOLD_CACHE/downloads
sdk=$downloads/227k_15/sdk-linux             # OldUnreal-UnrealPatch227k-SDK-Linux.tar.bz2
game=$downloads/227k_15/linux                # OldUnreal-UnrealPatch227k-Linux.tar.bz2
sdl3=$downloads/sdl3-release-3.4.8/include   # libsdl-org/SDL tag release-3.4.8
repo=$downloads/Andiweli_UT99-Android        # github.com/Andiweli/UT99-Android
commit=85b1a9ada6ae28c422570d4603e57e4e4cef6eb1
bcdecode=$sources/common                     # BCDecode.h of this port
cmake=$UNREALGOLD_CACHE/tools/cmake-3.31.6-linux-x86_64/bin/cmake
root=$UNREALGOLD_CACHE/build/nopengles

arches=${*:-arm64 amd64}
for arch in $arches; do
	case $arch in
		arm64|amd64) ;;
		*) echo "build.sh: unknown architecture '$arch' (arm64, amd64)" >&2; exit 2 ;;
	esac
done

# Pinned inputs. Directory trees are compared by the sha256 of their sorted
# per-file sha256 list; BUILD.md lists the archives they come from.
fail() { echo "build.sh: $*" >&2; exit 1; }
check_tree() {
	dir=$1 want=$2
	shift 2
	got=$(cd "$dir" && find "$@" -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)
	[ "$got" = "$want" ] || fail "$dir ($*) is not the pinned input"
}
check_file() {
	got=$(sha256sum "$1" | cut -d' ' -f1)
	[ "$got" = "$2" ] || fail "$1 is not the pinned input"
}
check_tree "$sdk" a8aa0a74efa6bbe401effb66a37ef1d456aaa16e84905c1fd8d3f9ac346bde1a \
	Core/Inc Engine/Inc Render/Inc Version.script
check_tree "$sdl3" 89219ef54e3392755c6184b8df5ec3a2f7553f9df59d1935fd1efd632cfbf606 SDL3
check_file "$game/SystemARM64/Core.so"          f6b6275a877dfa6d3dad9a3ef6d10f5bafb3a218ac9510cf8d118b76a20aa7d2
check_file "$game/SystemARM64/Engine.so"        d582e4c70a89bce4f63ff4870ac95d77769a625edd294ad4d4e78f8bcff01858
check_file "$game/SystemARM64/libSDL3-3.0.so.0" f3482811493bf279b3eb398505e637f77794b0252cc5935cdca98720bbc13c1c
check_file "$game/System64/Core.so"             ed25a38c385a3b47f579ac1ca525966f7d632ffcbd41a132a27286a71eb60ff9
check_file "$game/System64/Engine.so"           8c5a49314c086a4848fe181699fb2e0629930d9ad7047e4498699b0c3c49d62e
check_file "$game/System64/libSDL3-3.0.so.0"    afeb8af768babf2ed696962200dcc4c9c76b2294cba53d6a65a055e3a672a08e
[ -x "$cmake" ] || fail "CMake 3.31.6 not found at $cmake"

# Renderer sources at the pinned commit (git checks the object hashes),
# cloned on first use.
if [ ! -d "$repo/.git" ]; then
	git clone --quiet https://github.com/Andiweli/UT99-Android.git "$repo"
fi
git -C "$repo" cat-file -e "$commit^{commit}" 2>/dev/null || git -C "$repo" fetch --quiet origin "$commit"

# Patched copy, recreated every run.
src=$root/src
rm -rf "$src"
mkdir -p "$src"
git -C "$repo" archive "$commit" third_party/ut99dc/Source/NOpenGLESDrv \
	app/src/main/cpp/android_glad_compat app/src/main/cpp/android_glm_compat | tar -x -C "$src"
(cd "$src" && git apply --whitespace=nowarn "$here/NOpenGLESDrv227.patch")

for arch in $arches; do
	case $arch in
		arm64)
			sys=$game/SystemARM64
			toolchain="-DCMAKE_TOOLCHAIN_FILE=$here/aarch64-linux-gnu.cmake"
			readelf=aarch64-linux-gnu-readelf objdump=aarch64-linux-gnu-objdump ;;
		amd64)
			sys=$game/System64
			toolchain="-DCMAKE_C_COMPILER=gcc-12 -DCMAKE_CXX_COMPILER=g++-12"
			readelf=readelf objdump=objdump ;;
	esac
	obj=$root/obj-$arch
	rm -rf "$obj"
	mkdir -p "$root/$arch"
	# shellcheck disable=SC2086
	"$cmake" -S "$here" -B "$obj" -G Ninja -DCMAKE_BUILD_TYPE=Release $toolchain \
		-DUT99DC_ROOT="$src/third_party/ut99dc" \
		-DUT99DC_COMPAT_ROOT="$src/app/src/main/cpp" \
		-DUNREAL227_SDK="$sdk" -DUNREAL227_SYSTEM="$sys" \
		-DSDL3_INCLUDE_DIR="$sdl3" -DBCDECODE_DIR="$bcdecode" \
		-DNOPENGLES_ARCH="$arch" -DNOPENGLES_OUTPUT_DIR="$root/$arch" >/dev/null
	"$cmake" --build "$obj"

	so=$root/$arch/NOpenGLESDrv.so
	# -z defs at link time already proved every symbol resolves against
	# Engine.so, Core.so, libSDL3.so.0, libGLESv2.so.2 and the C/C++ runtime.
	needed=$("$readelf" -d "$so" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | tr '\n' ' ')
	case "$needed" in
		"Engine.so Core.so libSDL3.so.0 libGLESv2.so.2 "*) ;;
		*) fail "$arch: unexpected NEEDED: $needed" ;;
	esac
	"$readelf" -d "$so" | grep -q 'Library soname: \[NOpenGLESDrv.so\]' || fail "$arch: wrong SONAME"
	"$readelf" -d "$so" | grep -q 'Library runpath: \[\$ORIGIN\]' || fail "$arch: wrong RUNPATH"
	# IMPLEMENT_PACKAGE exports, which the engine looks up when it binds the module.
	"$objdump" -T "$so" | grep -q ' GLoadedNOpenGLESDrv$' || fail "$arch: GLoadedNOpenGLESDrv not exported"
	glibc=$("$objdump" -T "$so" | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1)
	glibcxx=$("$objdump" -T "$so" | grep -o 'GLIBCXX_[0-9.]*' | sort -uV | tail -1 || true)

	(cd "$root/$arch" && sha256sum NOpenGLESDrv.so > NOpenGLESDrv.so.sha256)
	echo "nopengles: $so $(cut -d' ' -f1 "$so.sha256") NEEDED: $needed max $glibc ${glibcxx:-(static libstdc++)}"
done
