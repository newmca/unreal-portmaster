# Building the Unreal Gold port

The port runs the official OldUnreal 227k_15 ARM64 engine unchanged, except
for three binaries it builds itself. `build_all.sh` rebuilds all three from
pinned inputs, checks that they come out bit for bit as recorded, and lays
them over `../unreal/gamedata/`. The package then leaves out the stock files, which
the device downloads on the first start (see "Self-installing package").

| Shipped file | Component | Built from | Docs |
|---|---|---|---|
| `../unreal/gamedata/SystemARM64/libSDL3.so.0` | SDL3-over-SDL2 shim | bmdhacks' SDL `sdl2-backend` branch and three patches | [sdl3shim/BUILD.md](sdl3shim/BUILD.md) |
| `../unreal/gamedata/SystemARM64/SDLDrv.so` | Viewport and input driver | 227k_15 SDK `SDLDrv` and two patches | [SDLDrv/BUILD.md](SDLDrv/BUILD.md) |
| `../unreal/gamedata/SystemARM64/NOpenGLESDrv.so`, `../unreal/gamedata/System/NOpenGLESDrv.int` | Renderer (OpenGL ES 2) | UT99-Android's NOpenGLESDrv and one patch | [NOpenGLESDrv/BUILD.md](NOpenGLESDrv/BUILD.md) |

The renderer decodes BC1/BC2/BC3 textures with [common/BCDecode.h](common/BUILD.md).
[SOURCE.md](SOURCE.md) lists the sha256 and origin of every binary in the package.

## Prerequisites

- A Linux x86-64 host with **podman** (rootless works) and bash. Everything
  else runs in the build container.
- Network access the first time, to fetch the inputs below (about 250 MB,
  plus about 430 MB of Ubuntu package lists and packages if the build image
  has to be built; the image takes 2.9 GB).
- About 1.7 GB in the cache directory (`~/.cache/unrealgold-port` by
  default) for inputs, tools and build trees.
- For the assemble step only: the modded Unreal Gold install the game data
  comes from (`USER_GAME`, default `UnrealGold/` at the top of this
  repository), on the same reflink-capable filesystem (btrfs, XFS) as the
  cache and `../unreal/gamedata/`. `tools/assemble_gamedata.sh` copies with
  `cp --reflink=always`, so the game data (about 4 GiB) costs no extra space. Without
  the install, use `--no-assemble`.

## Build

```sh
source/build_all.sh   # from the port directory
```

Options: `--no-assemble`, `--strict`; settings
through `UNREALGOLD_CACHE`, `UNREALGOLD_BUILD_IMAGE`,
`UNREALGOLD_REBUILD_IMAGE`, `USER_GAME`, `DEST`, `PRUNE` and `JOBS`.
`build_all.sh --help` explains each. The steps:

1. **Image.** Uses `localhost/unrealgold-build:jammy`. If it does not exist,
   `podman build` creates it from [Containerfile](Containerfile) (podman
   reuses cached layers) and labels it with the Containerfile's sha256. An
   existing image is never rebuilt unless `UNREALGOLD_REBUILD_IMAGE=1`, which
   builds it with `--no-cache` and so installs the current Ubuntu packages.
   The script then runs itself in the container for steps 2 to 6.
2. **Inputs.** Downloads whatever is missing from the cache (table below)
   and checks every sha256 and commit. The two extracted 227k_15 trees are
   compared with their tarballs (`tar -d`). A file the tarball does not have
   stops the build if it is in a directory that `assemble_gamedata.sh` reads.
3. **Build.** Runs `sdl3shim/build.sh`, `SDLDrv/build.sh` and
   `NOpenGLESDrv/build.sh`. Each one recreates its
   build tree, checks its own pinned inputs, builds arm64 (device) and amd64
   (host build, not shipped), and checks SONAME, NEEDED, RUNPATH and exports.
   Every output is compared with its recorded sha256 (see Outputs).
4. **Stage.** Recreates `$UNREALGOLD_CACHE/build/overlay/`, laid out like
   `../unreal/gamedata/`: `SystemARM64/{libSDL3.so.0,SDLDrv.so,NOpenGLESDrv.so}`
   from the arm64 builds (real files, SONAME and machine checked) and
   `System/NOpenGLESDrv.int`. The engine finds the `.int` there, as it finds
   the `.int` files of the mods, through `LangPaths=../System/*.<lang>` in
   the port's `../unreal/config/UnrealLinux.ini` (the stock `DefaultLinux.ini` lacks
   that line).
5. **Assemble.** Runs `tools/assemble_gamedata.sh` with
   `OVERLAY=$UNREALGOLD_CACHE/build/overlay`. The script is idempotent: it
   copies only files whose size or mtime changed, lists files that are not
   in its plan (and deletes them only with `PRUNE=1`), checks the imports of
   the swapped texture packs, and ends with the texture pack import check. Only the
   campaigns listed in `tools/campaigns.txt` are shipped:
   `tools/select_campaigns.py` follows each one from its New Game entry
   through its maps (map URLs, `ChangeLevel` commands), the packages they
   import and the packages their scripts name, and leaves out every mod file
   that no kept campaign needs. Its report, with the maps and packages of
   each campaign and anything worth a second look, is
   `$UNREALGOLD_CACHE/build/campaigns/report.txt`. `CAMPAIGNS=` (empty)
   ships the whole collection.
6. **Report.** Prints the sha256 and origin of every file in
   `../unreal/gamedata/SystemARM64` and of `System/NOpenGLESDrv.int`, and checks that
   each is byte-identical to the file the plan copies it from and that
   `SystemARM64` holds no symlink.

A component can also be built on its own with its `build.sh`, which starts
the same container by itself.

## Build environment

[Containerfile](Containerfile): Ubuntu 22.04 (OldUnreal's own 227k baseline:
glibc 2.35, the GCC 12 libstdc++ ABI) with native and aarch64 cross GCC 12.
It is a copy of the file the image `localhost/unrealgold-build:jammy`
(ID `191f588710b3`) was built from on 2026-10-05. The packages come from the
Ubuntu archive at build time, so a rebuilt image can get newer versions. The
recorded hashes were produced with these:

| Package | Version |
|---|---|
| base image `docker.io/library/ubuntu:22.04` | image ID `e8df6c74f650`, digest `sha256:5ec03bb3441e8b0bf3b4f9cd4629a1ae763010dc3035bb8da3ae6cf026486401` (amd64 manifest `sha256:08ea48a03a3e78ebc7cd526e6a275053223aadd88bfc09cc49b06d5281525fde`) |
| `gcc-12`, `g++-12` | 12.3.0-1ubuntu1~22.04.3 |
| `gcc-12-aarch64-linux-gnu`, `g++-12-aarch64-linux-gnu` | 12.3.0-1ubuntu1~22.04.3cross1 |
| `binutils`, `binutils-aarch64-linux-gnu` | 2.38-4ubuntu2.12 |
| `libc6-dev` (amd64, arm64) | 2.35-0ubuntu3.15 |
| `libstdc++-12-dev:arm64` | 12.3.0-1ubuntu1~22.04.3 |
| `libgles-dev` (amd64, arm64) | 1.4.0-1 |
| `ninja-build` | 1.10.1-1 |
| `git` | 1:2.34.1-1ubuntu1.17 |
| `python3` | 3.10.6-1~22.04.1 |
| `qemu-user-static` | 1:6.2+dfsg-2ubuntu6.31 |

CMake 3.31.6 is not from Ubuntu; it is a pinned input below.

## Pinned inputs

`build_all.sh` fetches these into `$UNREALGOLD_CACHE` when they are missing.
The component scripts check the parts they use: extracted trees by the sha256
of their sorted per-file sha256 list, the engine libraries they link against
file by file, git inputs by commit.

| Input | Source | Pin | Cache path |
|---|---|---|---|
| OldUnreal 227k_15 Linux (engine, game files; link libraries) | https://github.com/OldUnreal/Unreal-testing/releases/download/v227k_15/OldUnreal-UnrealPatch227k-Linux.tar.bz2 | sha256 `b04eba6d5c885c98bd9da8279840b15cd8fa06ed2b750235e7ad7aa26ef3f7a1` | `downloads/227k_15/linux` |
| OldUnreal 227k_15 SDK (headers, SDLDrv source) | https://github.com/OldUnreal/Unreal-testing/releases/download/v227k_15/OldUnreal-UnrealPatch227k-SDK-Linux.tar.bz2 | sha256 `8ec77372a666d999ae688b9d1a852632433a66b0dabc6805b098bf019e82be4f` | `downloads/227k_15/sdk-linux` |
| SDL 3.4.8 headers (the SDL 227k_15 is built against) | https://github.com/libsdl-org/SDL, tag `release-3.4.8` | commit `d9d5536704d585616d4db3c8ba3c4ff6fc2757e1` | `downloads/sdl3-release-3.4.8` |
| bmdhacks' SDL3 with the SDL2 backend (shim) | https://github.com/bmdhacks/SDL, branch `sdl2-backend` | commit `6057d79baf8321bf190479a699655f06cc2a962f` (fetched by `sdl3shim/build.sh`) | `build/sdl3shim/src` |
| UT99-Android (NOpenGLESDrv source, `third_party/ut99dc/Source/NOpenGLESDrv`) | https://github.com/Andiweli/UT99-Android | commit `85b1a9ada6ae28c422570d4603e57e4e4cef6eb1` | `downloads/Andiweli_UT99-Android` |
| CMake 3.31.6 (shim and NOpenGLESDrv) | https://github.com/Kitware/CMake/releases/download/v3.31.6/cmake-3.31.6-linux-x86_64.tar.gz | sha256 `5a1133ff103c71eb5120e2cc3de922733e7d8a26a98ae716397e8676adb367bf` | `tools/cmake-3.31.6-linux-x86_64` |

In this repository:

| Input | Origin |
|---|---|
| `sdl3shim/sdl3-sdl2-backend-fixes.patch` | PortMaster-New commit `3fcdb796b828bfac8d62a40b24842b3215c60ab4`, `ports/railroadrampage/railroadrampage/patches/sdl3-sdl2-backend-fixes.patch`, unchanged (sha256 `3323ea17907b53efd5c2c766ce509d32c84acb1c00c7ad90a1da8303dc7e5d08`) |
| `sdl3shim/sdl3-sdl2-backend-unrealgold-{gl,winsize}.patch` | this port |
| `SDLDrv/SDLDrv-handheld.patch`, `SDLDrv/SDLDrv-keyrepeat.patch` | this port |
| `NOpenGLESDrv/NOpenGLESDrv227.patch` | this port; includes the PortMaster UT99 port's `NOpenGLESDrv469.patch` |
| `common/BCDecode.h` | this port |
| `tools/assemble_gamedata.sh`, `tools/ue1pkg.py`, `tools/select_campaigns.py`, `tools/make_stock_manifest.py` | this port (game data assembly) |

The game data itself is not a build input of the binaries. `../unreal/gamedata/` is the
user's modded Unreal Gold install with the 227k_15 files laid over it; see the
header of `tools/assemble_gamedata.sh`.

## Outputs

| File under `$UNREALGOLD_CACHE/build` | sha256 |
|---|---|
| `sdl3shim/arm64/libSDL3.so.0` | `c31b0bd73f12b71c4c839042d4f2e21fa5e844def05e845dc3b45dbfce5392c5` |
| `sdldrv/arm64/SDLDrv.so` | `70010af4c380a2b1ad2ed3fe6619ab3fb9d92871431f0bbc9c077188f5c2bb51` |
| `nopengles/arm64/NOpenGLESDrv.so` | `2f71b8cb6fbccdeeb9952782cb18f92d7848209606e261ba3d94fd3664ade0e6` |
| `sdl3shim/amd64/libSDL3.so.0` (amd64 host build, not shipped) | `1197aa2b8677a9f3a62fbf3801d00db627dad878ce971804310524e7c2e0034d` |
| `sdldrv/amd64/SDLDrv.so` (amd64 host build, not shipped) | `d128eda2b2c95b45fd74d8c24a6e7c79273d7ec4538eb4d67a1e4e34a4698a68` |
| `nopengles/amd64/NOpenGLESDrv.so` (amd64 host build, not shipped) | `8fdb8910246ed054745f39b96249dbb8681bee11d6b4c2cd9d569107d9ab58e2` |

A full run takes two to three and a half minutes on a 24-thread host once the
inputs are in the cache. The build is deterministic: full runs, including one
from an empty cache, reproduced every hash above.

When a patch or pin changes on purpose, update the hash in three places:
`RECORDED` in `build_all.sh`, `SOURCE.md`, and the component's `BUILD.md`.

## Self-installing package

The assembled `../unreal/gamedata/` holds the whole game. The package ships only the
files that are not stock: `../unreal/install/install.bash` installs the others on
the device from the two downloads of OldUnreal's Linux installer, the Unreal
Gold ISO and the 227k_15 Linux patch ([SOURCE.md](SOURCE.md), "Installed on the first
start"). `tools/make_stock_manifest.py` makes the split by content: a file is
stock when it equals a file of either archive. It writes `../unreal/install/stock.tsv`
and the list of files to ship:

```sh
W=~/.cache/unrealgold-port/selfinstall-work
mkdir -p "$W/patch"
7zz x -o"$W/iso" UNREAL_GOLD.ISO
tar -xjf OldUnreal-UnrealPatch227k-Linux.tar.bz2 -C "$W/patch"
source/tools/make_stock_manifest.py --gamedata unreal/gamedata \
    --iso-dir "$W/iso" --patch-dir "$W/patch" --id 227k_15-1 \
    --exclude '*/opengldrv.*' --exclude '*/xopengldrv.*' \
    --out unreal/install/stock.tsv --shipped "$W/shipped.txt"
```

The two `--exclude` patterns leave out the renderers the port does not use,
from both lists. The package's `unreal/gamedata/` then holds exactly the files in
`shipped.txt`. The installer writes the list's `--id` to
`unreal/gamedata/.installed` when it is done, and the launcher runs the
installer while that file is missing. Run again, the installer fetches only
the files that are missing.

`unreal/gamedata/System/NewSPMapPacks.int` in the package was edited by hand after
the assembly: the `*` in front of the Unreal Tournament campaigns became
`[UT] `, and a New Game entry for the Operation: Na Pali tutorial
(`NPTut?...?game=olextras.TVTutorial`) follows the Operation: Na Pali one.
`tools/campaigns.txt` keeps the names of the source `.int` files.
