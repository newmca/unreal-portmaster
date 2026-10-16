#!/bin/sh
# Build SDLDrv.so for the Unreal Gold port: SDLDrv from the OldUnreal 227k_15
# SDK with SDLDrv-handheld.patch and SDLDrv-keyrepeat.patch, compiled with
# GCC 12 against the official 227k_15 Core.so, Engine.so and libSDL3.so.0.
# See BUILD.md.
#
#   ./build.sh [arm64] [amd64]          (default: both)
#
# Runs inside localhost/unrealgold-build:jammy. Started on the host, it
# re-runs itself in that container. Results (drop-in replacements for the
# official System*/SDLDrv.so):
#   $UNREALGOLD_CACHE/build/sdldrv/arm64/SDLDrv.so   (device)
#   $UNREALGOLD_CACHE/build/sdldrv/amd64/SDLDrv.so   (amd64 host build, not shipped)
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
image=localhost/unrealgold-build:jammy

if [ ! -e /run/.containerenv ] && [ ! -e /.dockerenv ]; then
	cache=${UNREALGOLD_CACHE:-$HOME/.cache/unrealgold-port}
	exec podman run --rm --security-opt label=disable --userns=keep-id \
		-v "$cache:$cache" -v "$here:$here" -w "$here" \
		-e UNREALGOLD_CACHE="$cache" \
		"$image" sh "$here/build.sh" "$@"
fi

: "${UNREALGOLD_CACHE:?set UNREALGOLD_CACHE to the port cache directory}"
downloads=$UNREALGOLD_CACHE/downloads
sdk=$downloads/227k_15/sdk-linux            # OldUnreal-UnrealPatch227k-SDK-Linux.tar.bz2
game=$downloads/227k_15/linux               # OldUnreal-UnrealPatch227k-Linux.tar.bz2
sdl3=$downloads/sdl3-release-3.4.8/include  # libsdl-org/SDL tag release-3.4.8
root=$UNREALGOLD_CACHE/build/sdldrv

arches=${*:-arm64 amd64}
for arch in $arches; do
	case $arch in
		arm64|amd64) ;;
		*) echo "build.sh: unknown architecture '$arch' (arm64, amd64)" >&2; exit 2 ;;
	esac
done

# Pinned inputs. Directory trees are compared by the sha256 of their sorted
# per-file sha256 list; BUILD.md lists the archives they are extracted from.
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
check_tree "$sdk" 7a123e4f4d3e9b6098172aa25ea149be1e62580409e1220445040cb653c32733 \
	Core/Inc Engine/Inc Render/Inc SDLDrv Version.script
check_tree "$sdl3" 89219ef54e3392755c6184b8df5ec3a2f7553f9df59d1935fd1efd632cfbf606 SDL3
check_file "$game/SystemARM64/Core.so"          f6b6275a877dfa6d3dad9a3ef6d10f5bafb3a218ac9510cf8d118b76a20aa7d2
check_file "$game/SystemARM64/Engine.so"        d582e4c70a89bce4f63ff4870ac95d77769a625edd294ad4d4e78f8bcff01858
check_file "$game/SystemARM64/libSDL3-3.0.so.0" f3482811493bf279b3eb398505e637f77794b0252cc5935cdca98720bbc13c1c
check_file "$game/SystemARM64/SDLDrv.so"        5ea480d98dcf05d1bf5da8265e2bbcc8cf18e6a33f4cb4c56bb8ca94087efb97
check_file "$game/System64/Core.so"             ed25a38c385a3b47f579ac1ca525966f7d632ffcbd41a132a27286a71eb60ff9
check_file "$game/System64/Engine.so"           8c5a49314c086a4848fe181699fb2e0629930d9ad7047e4498699b0c3c49d62e
check_file "$game/System64/libSDL3-3.0.so.0"    afeb8af768babf2ed696962200dcc4c9c76b2294cba53d6a65a055e3a672a08e
check_file "$game/System64/SDLDrv.so"           7b816013f95576b2ef0f71801216b557f7e50e6811701e24418f253e394e7fd9

# Patched copy of the pristine SDK sources, recreated every run. The patches
# apply in this order; each explains itself in its header.
src=$root/src
rm -rf "$src"
mkdir -p "$src"
cp -a "$sdk/SDLDrv" "$src/"
for p in SDLDrv-handheld.patch SDLDrv-keyrepeat.patch; do
	patch -d "$src" -p1 -F0 --no-backup-if-mismatch -s < "$here/$p"
done

# Compiler setup of the official CMake build (CMakeLists.txt 305-390, 434-437:
# Release, C++14, -fsigned-char, -fPIC; amd64 links libstdc++/libgcc
# statically with Version.script and is stripped). GPackage gets the
# per-module name CMake gives it (oldunreal_set_package_properties).
# Reproducible output: SetTitleBar embeds __DATE__/__TIME__ (pinned to the
# 227k_15 SDK upload time, 2026-08-15 12:06:39 UTC) and check() embeds
# __FILE__ (mapped to /workspace, the path the official build used).
export SOURCE_DATE_EPOCH=1786795599
set -- -std=gnu++14 -O3 -fPIC -pipe -fsigned-char -ffile-prefix-map="$src"=/workspace \
	-D_RELEASE -DNDEBUG -DRELEASE -DUTGLR_UNREAL_227_BUILD -DUTGLR_USES_ALPHABLEND=1 \
	-DOLDUNREAL_TEXTURE_COMPRESSION=0 -D__UNIX__=1 -DUNICODE=1 -D_UNICODE=1 -D_REENTRANT=1 \
	-DHAVE_PRAGMA_PACK=1 -DSDL3BUILD -DGPackage=LocalPackageNameSDLDrv \
	-I"$sdk/Core/Inc" -I"$sdk/Engine/Inc" -I"$sdk/Render/Inc" -I"$src/SDLDrv/Inc" -I"$sdl3"

units="SDLViewport SDLClient SDLDrv RawMouseHelper RawKeyboardHelper"

for arch in $arches; do
	case $arch in
		arm64)
			cxx=aarch64-linux-gnu-g++-12 nm=aarch64-linux-gnu-nm readelf=aarch64-linux-gnu-readelf
			sys=$game/SystemARM64
			archflags="-march=armv8-a -mtune=cortex-a53 -DUSES_SSE_INTRINSICS=0 -D__LINUX_ARM__=1
				-DSDL_DISABLE_MM3DNOW_H=1 -DSDL_DISABLE_IMMINTRIN_H=1 -DSDL_DISABLE_MMINTRIN_H=1
				-DSDL_DISABLE_XMMINTRIN_H=1 -DSDL_DISABLE_EMMINTRIN_H=1 -DSDL_DISABLE_PMMINTRIN_H=1"
			engarch='"arm64"'
			linkflags= ;;
		amd64)
			cxx=g++-12 nm=nm readelf=readelf
			sys=$game/System64
			archflags="-msse -msse2 -DUSES_SSE_INTRINSICS=1 -D__LINUX_X86__=1"
			engarch='"amd64"'
			linkflags="-static-libgcc -static-libstdc++ -fuse-ld=gold
				-Wl,--version-script=$sdk/Version.script -Wl,--strip-all" ;;
	esac

	obj=$root/obj-$arch
	rm -rf "$obj"
	mkdir -p "$obj" "$root/$arch"
	for unit in $units; do
		# shellcheck disable=SC2086
		"$cxx" "$@" $archflags -DENGINE_ARCHITECTURE="$engarch" \
			-c "$src/SDLDrv/Src/$unit.cpp" -o "$obj/$unit.o"
	done

	# Same dynamic section as the official module: SONAME SDLDrv.so, RUNPATH
	# $ORIGIN, NEEDED Engine.so Core.so libSDL3.so.0. libSDL3_ttf.so.0 is
	# not linked: no TTF function is used outside UNREAL_TOURNAMENT_OLDUNREAL.
	# -z defs: every symbol must resolve against the libraries named here.
	# shellcheck disable=SC2086
	"$cxx" -shared -o "$root/$arch/SDLDrv.so" "$obj"/*.o \
		"$sys/Engine.so" "$sys/Core.so" "$sys/libSDL3-3.0.so.0" \
		-Wl,-soname,SDLDrv.so -Wl,-rpath,'$ORIGIN' -Wl,--enable-new-dtags -Wl,-z,defs \
		$linkflags

	# Exported USDL* symbols must be the official module's. GCC also emits the
	# complete-object destructors (D1) as aliases of the base-object ones (D2),
	# which clang, used for the official module, folds away; nothing else may
	# be extra.
	so=$root/$arch/SDLDrv.so
	"$nm" -D --defined-only "$sys/SDLDrv.so" | awk '{print $3}' | grep USDL | LC_ALL=C sort > "$obj/exports.official"
	"$nm" -D --defined-only "$so" | awk '{print $3}' | grep USDL | LC_ALL=C sort > "$obj/exports.built"
	missing=$(LC_ALL=C comm -23 "$obj/exports.official" "$obj/exports.built")
	extra=$(LC_ALL=C comm -13 "$obj/exports.official" "$obj/exports.built" | grep -v 'D1Ev$' || true)
	[ -z "$missing$extra" ] || fail "$arch: USDL* exports differ from the official SDLDrv.so: $missing $extra"
	needed=$("$readelf" -d "$so" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | tr '\n' ' ')
	case "$needed" in
		"Engine.so Core.so libSDL3.so.0 "*) ;;
		*) fail "$arch: unexpected NEEDED: $needed" ;;
	esac
	case "$needed" in
		*SDL3_ttf*) fail "$arch: links libSDL3_ttf" ;;
	esac
	"$readelf" -d "$so" | grep -q 'Library soname: \[SDLDrv.so\]' || fail "$arch: wrong SONAME"
	"$readelf" -d "$so" | grep -q 'Library runpath: \[\$ORIGIN\]' || fail "$arch: wrong RUNPATH"

	(cd "$root/$arch" && sha256sum SDLDrv.so > SDLDrv.so.sha256)
	echo "sdldrv: $so $(cut -d' ' -f1 "$so.sha256") NEEDED: $needed"
done
