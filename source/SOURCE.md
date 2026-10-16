# Source and binary provenance

Every binary in `../unreal/gamedata/` is either an unchanged file of the OldUnreal
227k_15 release or one of three modules built for this port. The package
ships the three modules; `../unreal/install/install.bash` installs the 227k_15 files on
the first start (see "Installed on the first start"). The build is described
in [BUILD.md](BUILD.md); `build_all.sh` rebuilds the three modules from
the pinned inputs below and lays them over `../unreal/gamedata/`. The hashes in this
file are those of the files in `../unreal/gamedata/` as assembled on 2026-10-05.

## Engine

- OldUnreal Unreal patch 227k_15, Linux (i386, amd64 and ARM64 in one archive): `OldUnreal-UnrealPatch227k-Linux.tar.bz2`
  - Release: https://github.com/OldUnreal/Unreal-testing/releases/tag/v227k_15
  - SHA-256: `b04eba6d5c885c98bd9da8279840b15cd8fa06ed2b750235e7ad7aa26ef3f7a1`
  - The port uses its `SystemARM64` engine and its `System`, `Maps`,
    `Music`, `Sounds`, `Textures` and `SystemLocalized` files unchanged,
    except the two `SystemARM64` modules replaced under "Built for this
    port" and the renderers it leaves out (`OpenGLDrv` and `XOpenGLDrv`).
    exFAT has no symbolic links, so the archive's `libSDL3_ttf.so.0` link is
    installed as a real copy of `libSDL3_ttf-3.0.so.0`, and its
    `libSDL3.so.0` link (to `libSDL3-3.0.so.0`) is replaced by the SDL3 shim.
- OldUnreal Unreal 227k_15 public SDK: `OldUnreal-UnrealPatch227k-SDK-Linux.tar.bz2`
  - Release: https://github.com/OldUnreal/Unreal-testing/releases/tag/v227k_15
  - SHA-256: `8ec77372a666d999ae688b9d1a852632433a66b0dabc6805b098bf019e82be4f`
  - Provides the Core, Engine and Render headers and the SDLDrv source of the
    rebuilt modules. Not shipped.

### `../unreal/gamedata/SystemARM64`

Every file in the directory once the port is installed, all real files.
"Shipped" files are in the package; "installed" files come from the 227k_15
archive (the path in it is given where it differs).

| File | SHA-256 | Origin |
|---|---|---|
| `libSDL3.so.0` | `c31b0bd73f12b71c4c839042d4f2e21fa5e844def05e845dc3b45dbfce5392c5` | shipped; built for this port (SDL3 shim) |
| `SDLDrv.so` | `70010af4c380a2b1ad2ed3fe6619ab3fb9d92871431f0bbc9c077188f5c2bb51` | shipped; built for this port |
| `NOpenGLESDrv.so` | `2f71b8cb6fbccdeeb9952782cb18f92d7848209606e261ba3d94fd3664ade0e6` | shipped; built for this port |
| `B227_MapFix.ini` | `6c47068fcba15d771145076b05f68e969ee5b092ca24a89c1e66fbc401dd8bce` | shipped; porter's install, mod settings |
| `Botpack.ini` | `325f0d9b905d49daeb7cc67163bbaf5236a4833c1549cc072937f7440e59d25f` | shipped; porter's install, mod settings |
| `OldSkool.ini` | `98b5a1f785f51d00474fb497f59be9284724085fe43dc8041dfbd281109b2422` | shipped; porter's install, mod settings |
| `ONP.ini` | `8b09a5f680e59ab3916940aa55db422a66dad95ab9a32fb5589df487a3076f3c` | shipped; porter's install, mod settings |
| `Xidia.ini` | `d0d4437f828e1edb4413eccdee760d07f5264e49936a3ff9cad7a5d6dba0e622` | shipped; porter's install, mod settings |
| `unreal-bin-arm64` | `7d46c4c5e770d7ad5c1c402adca8b537f9a827327814159fd5bd44eeba5c1d20` | installed; 227k_15 |
| `ucc-bin-arm64` | `80cbe4ae40ddcc777d1ed3668d09e17106d8cec6e65eb3ade5b55d61572c4d7f` | installed; 227k_15 |
| `Core.so` | `f6b6275a877dfa6d3dad9a3ef6d10f5bafb3a218ac9510cf8d118b76a20aa7d2` | installed; 227k_15 |
| `Engine.so` | `d582e4c70a89bce4f63ff4870ac95d77769a625edd294ad4d4e78f8bcff01858` | installed; 227k_15 |
| `Render.so` | `26fb3c18b3a8163976936377206901acff592bc2b6871bb55d161fd9689c4bbf` | installed; 227k_15 |
| `ALAudio.so` | `5dedf11ceab201160a7ccdbdf48b306460262ba8e825a38d60ae14e7e311bda1` | installed; 227k_15 |
| `Editor.so` | `b58bdf0835c4b2d5b12061af0343aaf57b93ab3aecc2990fa448fc33f54da2dd` | installed; 227k_15 |
| `Emitter.so` | `b8ef5832dfb2b73db268e3e3c14bd04563fcca6277028aace6c516c0f7d0e502` | installed; 227k_15 |
| `Fire.so` | `834f1d254bdf7ba6df23fb7659a4c60a7fcad8184ce41137ecc77eec3ad73aaf` | installed; 227k_15 |
| `IpDrv.so` | `64798f5f0effebcf9fe046fa65ce6ad8671ef5f951a24c00f9531dbf9575e392` | installed; 227k_15 |
| `PathLogic.so` | `4c276d8c042558e02a85ee66590c68ab904a7d0bc696aa5dff3fbc58f5ed1032` | installed; 227k_15 |
| `PhysXPhysics.so` | `7d5927ef71871cf0ee821e299c919856de9727724a4d007e2fd6e2aa888ec418` | installed; 227k_15 (PhysX 4.1 linked in) |
| `UEnginePPC.so` | `fb0d786e5eae7b63e7ef46f915706abd92cf4cb64ecd971dc270ae4b897190e0` | installed; 227k_15 |
| `UPak.so` | `fb0147c9fcf333cb06490a0b5b509a65b07fe7ebc22c88a1e889928cba5108b3` | installed; 227k_15 |
| `USQLite.so` | `933c7443986a719e118386126e842d895faba7f9996fd7b53293a57d860bdff6` | installed; 227k_15 |
| `UWebAdmin.so` | `13119869b593ff03be5863722524abd3892b8e26e11b72d83c18e6554d1c9e61` | installed; 227k_15 |
| `libSDL3_ttf.so.0` | `f05b49997b17ea599d64cf172e39194e393353949c0db7147aca4b1b2435c025` | installed; 227k_15 `libSDL3_ttf-3.0.so.0` |
| `libopenal.so.1` | `ed7db24741eb6ab7437b2c80c05a88cb011e2f5866b4a5e4883175bee03ece55` | installed; 227k_15 (OpenAL Soft 1.24.3) |
| `libsndfile.so.1` | `61e6bcf060630e12acd8ac5c55437177ba12c8d0df8ffff4432385aa7e5cea16` | installed; 227k_15 |
| `libxmp.so.4` | `eb01faba48124390953ad0759cee40f0f63aedff63005629c9facfe3845f3239` | installed; 227k_15 |
| `libmpg123.so` | `fc103e69cfc778a091df23115c81e985051aee5e665721f8270d124da20c6b16` | installed; 227k_15 |
| `libmp3lame.so.0` | `724a756b65cda03256b888286e6159373e3073020be718964f6d258fd46aa09f` | installed; 227k_15 |
| `DefaultLinux.ini` | `9ac3df4834f13bad10d4fe3ff8788458401d09ed369dccafeb8890ee83484ae7` | installed; 227k_15 `System/DefaultLinux.ini` |
| `DefUser.ini` | `8fd9f76c99e2ea1315b6d7dab3dbaa7a1f96a811ad30762dfe1f9102c70c879a` | installed; 227k_15 `System/DefUser.ini` |

On the device the launcher's `bind_files` creates two empty files,
`UnrealLinux.ini` and `User.ini`, in this directory and bind-mounts
`conf/UnrealLinux.ini` and `conf/User.ini` over them.

## Built for this port

Each module is built by `<component>/build.sh` in the build container
(`Containerfile`: Ubuntu 22.04, GCC 12.3.0) and linked against the
official 227k_15 `Core.so`, `Engine.so` and `libSDL3-3.0.so.0`. The builds
are deterministic and reproduced the hashes above. Patch hashes are those of
the files the binaries were built from.

- `SystemARM64/libSDL3.so.0`: bmdhacks' SDL3 with an SDL2 backend (an SDL3
  that forwards video, audio and input to the device's own SDL2).
  - Source: https://github.com/bmdhacks/SDL/tree/sdl2-backend, commit `6057d79baf8321bf190479a699655f06cc2a962f`
  - Patches, in order (`sdl3shim/`):
    - `sdl3-sdl2-backend-fixes.patch`, SHA-256 `3323ea17907b53efd5c2c766ce509d32c84acb1c00c7ad90a1da8303dc7e5d08`:
      from https://github.com/PortsMaster/PortMaster-New, commit
      `3fcdb796b828bfac8d62a40b24842b3215c60ab4`,
      `ports/railroadrampage/railroadrampage/patches/sdl3-sdl2-backend-fixes.patch`, unchanged
    - `sdl3-sdl2-backend-unrealgold-gl.patch`, SHA-256 `489ba70d913aaf09196fc5825d1588fc68d0827166900cd5c425924cae720518`: this port
    - `sdl3-sdl2-backend-unrealgold-winsize.patch`, SHA-256 `24c09f8a373d10da0606f061dc13ba5819fecb4552e6ed6b5089fa7aa7f9054d`: this port
  - Replaces the 227k_15 `libSDL3.so.0` link to `libSDL3-3.0.so.0` (SDL 3.4.8, SHA-256 `f3482811493bf279b3eb398505e637f77794b0252cc5935cdca98720bbc13c1c`).
  - Build: `sdl3shim/BUILD.md`
- `SystemARM64/SDLDrv.so`: the 227k_15 SDK's `SDLDrv` with
  `SDLDrv/SDLDrv-handheld.patch` (SHA-256 `6b468c69e2964ff88518214db44248ec8e26f875aa2bc5383e8bcc606a5b4acc`)
  and `SDLDrv/SDLDrv-keyrepeat.patch` (SHA-256 `73ec25a14730a7fedf5f566ad4f5543f12337380f05b0a3cd9d4312e26683715`).
  - Replaces the 227k_15 `SDLDrv.so` (SHA-256 `5ea480d98dcf05d1bf5da8265e2bbcc8cf18e6a33f4cb4c56bb8ca94087efb97`).
  - Build: `SDLDrv/BUILD.md`
- `SystemARM64/NOpenGLESDrv.so` and `System/NOpenGLESDrv.int`: the OpenGL ES 2
  renderer ported to the 227 render-device interface.
  - Origin: fgsfds' GLES2 renderer, https://github.com/fgsfdsfgs/UE1, first commit `19fd7d23faad9ebbe140a5c2179d220ffa0b0740`
  - Via Maxim Kaxd's https://github.com/maximqaxd/ut99dc and Andiweli's
    https://github.com/Andiweli/UT99-Android, commit `85b1a9ada6ae28c422570d4603e57e4e4cef6eb1`
    (`third_party/ut99dc/Source/NOpenGLESDrv` and `app/src/main/cpp/android_{glad,glm}_compat`)
  - Patch: `NOpenGLESDrv/NOpenGLESDrv227.patch` (SHA-256 `ffa4735d6239382c17c2e02cd1c0c1355805d44ebd229eb1416c147fd794a13b`).
    It includes the changes of the PortMaster Unreal Tournament port's
    `ports/ut99/source/NOpenGLESDrv469.patch`.
  - `System/NOpenGLESDrv.int` (SHA-256 `f54e259d0ca9268f446a9017fb92533eb43d6d9308aef45410f68d93f65b7623`): `NOpenGLESDrv/NOpenGLESDrv.int`, written for this port.
  - Build: `NOpenGLESDrv/BUILD.md`
- `common/BCDecode.h` (SHA-256 `a20173ac1dbbdfafd78d1fd2ad90dca6be5f2c0b4006fc834bef1505e64ad05e`):
  the BC1/BC2/BC3 decoder compiled into the renderer, written for this port.
  Docs: `common/BUILD.md`.

Other build inputs, not shipped:

- SDL 3.4.8 headers (the SDL that 227k_15 is built against): https://github.com/libsdl-org/SDL, tag `release-3.4.8`, commit `d9d5536704d585616d4db3c8ba3c4ff6fc2757e1`
- CMake 3.31.6: https://github.com/Kitware/CMake/releases/download/v3.31.6/cmake-3.31.6-linux-x86_64.tar.gz, SHA-256 `5a1133ff103c71eb5120e2cc3de922733e7d8a26a98ae716397e8676adb367bf`
- The Ubuntu 22.04 packages of the build image; `BUILD.md` lists their versions.

## Other files

- `../unreal/gconv/`: copied unchanged from the PortMaster Unreal Tournament port.
  - `ISO8859-1.so` (SHA-256 `c26da623ddd21293fcbf4214bfd5a16068b68c484c800bba7be83e67d7b600b5`) and
    `UTF-16.so` (SHA-256 `1fcff185eb995382a54422db185b907374e79519351e988ef1c45764feb2338d`):
    TrimUI/CrossMix compatibility modules, https://github.com/cizia64/CrossMix-OS/issues/566
    - Attachment SHA-256: `cf948299eec5ccc8a1f498f4dcfe0916ce77389746a61fb55fd9f2c66235a4f4`
  - `CP1252.so` (SHA-256 `057173703d27245d512ba038efb4a429f2ad2ecce3888475227485227921b866`):
    Ubuntu glibc 2.33 ARM64 package `libc6_2.33-0ubuntu5_arm64.deb`.
    - Package SHA-256: `05fbb121343e1161b1abe85367f09cea93b046e83a7f6ac15edb061ec8fbfee3`
    - Source: https://old-releases.ubuntu.com/ubuntu/pool/main/g/glibc/libc6_2.33-0ubuntu5_arm64.deb
  - `gconv-modules` (SHA-256 `219891a28177967a8606dd3275df1f6dab9734e4e7ccb973fc23a9837396bbf1`)
- `../unreal/unreal.ini`: the gptokeyb2 button mapping, the Unreal Tournament port's `ut99.gptk` with Select sending Enter instead of F1 (both are in gptokeyb2's INI format; gptokeyb2 does not go by the extension).
- `../unreal/config/UnrealLinux.ini`, `../unreal/config/User.ini`: derived from the porter's own
  227 configuration (mods, preferences) and adapted for the handheld.
- gptokeyb2 and the PortMaster runtime come from the user's PortMaster installation and are not bundled.

## Installed on the first start

The package does not include the files of Unreal Gold itself or of the
227k_15 patch. `../unreal/install/stock.tsv` lists them (archive, path in the archive,
size, SHA-256, path in `../unreal/gamedata/`), and `../unreal/install/install.bash` takes them
from the two downloads of OldUnreal's Linux installer
(https://github.com/OldUnreal/FullGameInstallers, `Linux/install-unreal.sh`):

- `UNREAL_GOLD.ISO`, 676734976 bytes, SHA-256 `7e360d0cc9e5533f38859819fd3cbfea7c475ecd428f9f433b5f8e1d5742cbca`,
  from https://files.oldunreal.net/UNREAL_GOLD.ISO (mirrors `files2`, `files3`
  and https://archive.org/download/totallyunreal/UNREAL_GOLD.ISO): 294 files
- `OldUnreal-UnrealPatch227k-Linux.tar.bz2` (see Engine): 1766 files

A file of the port's `../unreal/gamedata/` is in the list when its content equals a
file of either archive; `tools/make_stock_manifest.py` writes the list
(`BUILD.md`, "Self-installing package"). The install unpacks the
archives with PortMaster's `7zzs`.

## Licenses

See `../unreal/licenses/`: the OldUnreal 227 distribution and SDK licenses (including
OpenAL Soft, libxmp, libsndfile and mpg123), LAME, SDL3 and the SDL2-backend
fork, glibc (gconv modules), and the
NOpenGLESDrv provenance notice. The upstream UT99-Android/ut99dc and
fgsfdsfgs/UE1 trees do not contain a standalone open-source license covering
the GLES2 renderer; redistribution approval should be confirmed with the
upstream authors and the PortMaster reviewers before an official release.
