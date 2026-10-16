#!/bin/sh
# Build libSDL3.so.0 for the Unreal Gold port: bmdhacks' SDL3-over-SDL2
# shim (an SDL3 whose video, audio and joystick drivers dlopen the device's
# own libSDL2-2.0.so.0) at a pinned commit, plus the patches next to this
# script. See BUILD.md.
#
#   ./build.sh [arm64] [amd64]          (default: both)
#
# Runs inside localhost/unrealgold-build:jammy. Started on the host, it
# re-runs itself in that container. Results, real files with SONAME
# libSDL3.so.0:
#   $UNREALGOLD_CACHE/build/sdl3shim/arm64/libSDL3.so.0   (device)
#   $UNREALGOLD_CACHE/build/sdl3shim/amd64/libSDL3.so.0   (amd64 host build, not shipped)
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
image=localhost/unrealgold-build:jammy

if [ ! -e /run/.containerenv ] && [ ! -e /.dockerenv ]; then
	cache=${UNREALGOLD_CACHE:-$HOME/.cache/unrealgold-port}
	exec podman run --rm --security-opt label=disable --userns=keep-id \
		-v "$cache:$cache" -v "$here:$here" -w "$here" \
		-e UNREALGOLD_CACHE="$cache" -e JOBS="${JOBS:-}" \
		"$image" sh "$here/build.sh" "$@"
fi

: "${UNREALGOLD_CACHE:?set UNREALGOLD_CACHE to the port cache directory}"
cmake=${CMAKE:-$UNREALGOLD_CACHE/tools/cmake-3.31.6-linux-x86_64/bin/cmake}
root=$UNREALGOLD_CACHE/build/sdl3shim
jobs=${JOBS:-$(nproc)}

# bmdhacks/SDL branch sdl2-backend, "SDL2 backend GPU: statically link
# SPIRV-Cross + libstdc++" (2026-05-18, SDL 3.5.0-dev). Same commit as the
# PortMaster ports that ship this shim (railroadrampage, taisei, melee).
repo=https://github.com/bmdhacks/SDL.git
rev=6057d79baf8321bf190479a699655f06cc2a962f

# Applied in this order; each one is described at its top.
patches="sdl3-sdl2-backend-fixes.patch
sdl3-sdl2-backend-unrealgold-gl.patch
sdl3-sdl2-backend-unrealgold-winsize.patch"

arches=${*:-arm64 amd64}
for arch in $arches; do
	case $arch in
		arm64|amd64) ;;
		*) echo "build.sh: unknown architecture '$arch' (arm64, amd64)" >&2; exit 2 ;;
	esac
done

# Pinned source, fetched once.
src=$root/src
if ! git -C "$src" cat-file -e "$rev^{commit}" 2>/dev/null; then
	if [ ! -d "$src/.git" ]; then
		git init -q "$src"
		git -C "$src" remote add origin "$repo"
	fi
	git -C "$src" fetch -q --depth 1 origin "$rev"
	git -C "$src" -c advice.detachedHead=false checkout -q --detach "$rev"
fi

# Patched copy of the pinned tree, rebuilt every run so it never drifts.
tree=$root/patched
rm -rf "$tree"
mkdir -p "$tree"
git -C "$src" archive "$rev" | tar -x -C "$tree"
git -C "$tree" init -q
for p in $patches; do
	git -C "$tree" apply "$here/$p"
done
cp "$tree/LICENSE.txt" "$root/LICENSE.txt"

# Melee-style minimal shim: only the sdl2 video/audio/joystick drivers,
# OpenGL ES through SDL2's EGL, no GPU API (would need SPIRV-Cross), no
# HIDAPI, no optional desktop integrations (pkg-config disabled). The amd64
# build is the same library; its SDL2 underneath uses X11.
set -- -G Ninja -DCMAKE_BUILD_TYPE=Release \
	-DPKG_CONFIG_EXECUTABLE=/bin/false \
	-DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_INSTALL=OFF \
	-DSDL_TESTS=OFF -DSDL_TEST_LIBRARY=OFF -DSDL_EXAMPLES=OFF \
	-DSDL_SDL2_BACKEND=ON -DSDL_UNIX_CONSOLE_BUILD=ON \
	-DSDL_X11=OFF -DSDL_WAYLAND=OFF -DSDL_KMSDRM=OFF -DSDL_OFFSCREEN=OFF -DSDL_DUMMYVIDEO=OFF \
	-DSDL_PIPEWIRE=OFF -DSDL_PULSEAUDIO=OFF -DSDL_ALSA=OFF -DSDL_SNDIO=OFF -DSDL_OSS=OFF -DSDL_JACK=OFF \
	-DSDL_DUMMYAUDIO=OFF -DSDL_DISKAUDIO=OFF \
	-DSDL_VULKAN=OFF -DSDL_OPENGL=OFF -DSDL_OPENGLES=ON \
	-DSDL_GPU=OFF -DSDL_RENDER_GPU=OFF -DSDL_HIDAPI=OFF \
	-DSDL_REVISION=SDL-3.5.0-bmdhacks-sdl2-backend-6057d79 -DSDL_VENDOR_INFO=unrealgold-port

for arch in $arches; do
	bdir=$root/build-$arch
	rm -rf "$bdir"
	case $arch in
		arm64)
			"$cmake" -S "$tree" -B "$bdir" "$@" \
				-DCMAKE_TOOLCHAIN_FILE="$here/aarch64-linux-gnu.cmake" \
				-DCMAKE_C_FLAGS="-march=armv8-a -mtune=cortex-a53"
			strip=aarch64-linux-gnu-strip readelf=aarch64-linux-gnu-readelf ;;
		amd64)
			"$cmake" -S "$tree" -B "$bdir" "$@" \
				-DCMAKE_C_COMPILER=gcc-12 -DCMAKE_CXX_COMPILER=g++-12
			strip=strip readelf=readelf ;;
	esac
	"$cmake" --build "$bdir" --parallel "$jobs"

	mkdir -p "$root/$arch"
	"$strip" --strip-unneeded -o "$root/$arch/libSDL3.so.0" "$(readlink -f "$bdir/libSDL3.so.0")"
	if ! "$readelf" -d "$root/$arch/libSDL3.so.0" | grep -q 'Library soname: \[libSDL3.so.0\]'; then
		echo "build.sh: $arch/libSDL3.so.0 has the wrong SONAME" >&2
		exit 1
	fi
	(cd "$root/$arch" && sha256sum libSDL3.so.0 > libSDL3.so.0.sha256)
	echo "sdl3shim: $root/$arch/libSDL3.so.0 $(cut -d' ' -f1 "$root/$arch/libSDL3.so.0.sha256")"
done
