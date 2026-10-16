# NOpenGLESDrv for Unreal Gold (OldUnreal 227k_15)

This is the OpenGL ES 2 renderer from the UT99 port (`ports/ut99`), ported to
the 227k_15 engine, and the port's only renderer: the launcher selects it on
every start. The render device class is `NOpenGLESDrv.NOpenGLESRenderDevice`.

| File | Purpose |
|---|---|
| `NOpenGLESDrv227.patch` | Unified diff against UT99-Android `85b1a9a`, `third_party/ut99dc/Source/NOpenGLESDrv` |
| `CMakeLists.txt`, `aarch64-linux-gnu.cmake` | Standalone build project and the GCC 12 cross toolchain |
| `build.sh` | One-step reproducible build of both architectures inside the build container |
| `NOpenGLESDrv.int` | Class registration for the engine and the video menu (goes into `System/`) |

## Inputs (pinned)

| Input | Source | Pin |
|---|---|---|
| Renderer source | https://github.com/Andiweli/UT99-Android | commit `85b1a9ada6ae28c422570d4603e57e4e4cef6eb1`. Uses `third_party/ut99dc/Source/NOpenGLESDrv` and `app/src/main/cpp/android_{glad,glm}_compat`. |
| 227k_15 SDK | https://github.com/OldUnreal/Unreal-testing/releases/tag/v227k_15 `OldUnreal-UnrealPatch227k-SDK-Linux.tar.bz2` | sha256 `8ec77372a666d999ae688b9d1a852632433a66b0dabc6805b098bf019e82be4f`. `build.sh` checks the extracted `Core/Inc Engine/Inc Render/Inc Version.script` tree: `a8aa0a74efa6bbe401effb66a37ef1d456aaa16e84905c1fd8d3f9ac346bde1a`. |
| 227k_15 binaries | same release, `OldUnreal-UnrealPatch227k-Linux.tar.bz2` | sha256 `b04eba6d5c885c98bd9da8279840b15cd8fa06ed2b750235e7ad7aa26ef3f7a1`. Linked against: `SystemARM64/{Core.so f6b6275a…, Engine.so d582e4c7…, libSDL3-3.0.so.0 f3482811…}` and `System64/{Core.so ed25a38c…, Engine.so 8c5a4931…, libSDL3-3.0.so.0 afeb8af7…}`. `build.sh` holds the full hashes. |
| SDL 3.4.8 headers | https://github.com/libsdl-org/SDL tag `release-3.4.8` | commit `d9d5536704d585616d4db3c8ba3c4ff6fc2757e1`. `include/SDL3` tree: `89219ef54e3392755c6184b8df5ec3a2f7553f9df59d1935fd1efd632cfbf606`. |
| BC decoder | `../common/BCDecode.h` (this port) | The shipped binaries were built from sha256 `a20173ac1dbbdfafd78d1fd2ad90dca6be5f2c0b4006fc834bef1505e64ad05e`. |
| Toolchain | `localhost/unrealgold-build:jammy` (`../Containerfile`, Ubuntu 22.04) | GCC 12.3.0 (`g++-12`, `aarch64-linux-gnu-g++-12`), glvnd `libgles-dev` 1.4.0 for amd64 and arm64, CMake 3.31.6 (portable, under `tools/`). |

`build.sh` reads the inputs from `$UNREALGOLD_CACHE/downloads/` (default
`~/.cache/unrealgold-port`). It stops if any pinned input differs. If the
UT99-Android clone is missing, it clones it.

## Build

```sh
./build.sh            # arm64 and amd64; ./build.sh arm64 builds one
```

On the host, the script re-runs itself in the build container. It then:

1. Exports the renderer at the pinned commit.
2. Applies `NOpenGLESDrv227.patch` with `git apply`.
3. Configures CMake with the 227 SDK's Linux defines (`CMakeLists.txt`
   305-369 of the SDK) plus `NOPENGLES_227=1`.
4. Builds with GCC 12, using `-z defs` so that every symbol must resolve
   against the libraries it links.
5. Checks NEEDED, SONAME, RUNPATH and the `GLoadedNOpenGLESDrv` export.

On amd64 it links libstdc++ statically with the SDK's `Version.script`, as the
official amd64 modules do. On arm64 it links the system libstdc++, as the
official arm64 modules do, and tunes for the Cortex-A53.

| Output | sha256 | NEEDED | Highest symbol versions |
|---|---|---|---|
| `build/nopengles/arm64/NOpenGLESDrv.so` | `2f71b8cb6fbccdeeb9952782cb18f92d7848209606e261ba3d94fd3664ade0e6` | Engine.so Core.so libSDL3.so.0 libGLESv2.so.2 libstdc++ libm libgcc_s libc ld-linux | GLIBC_2.29 (`pow` on the CPU for the tone tables and for vertex colours above 1; muOS has 2.38), GLIBCXX_3.4.21, CXXABI_1.3.9 |
| `build/nopengles/amd64/NOpenGLESDrv.so` | `8fdb8910246ed054745f39b96249dbb8681bee11d6b4c2cd9d569107d9ab58e2` | Engine.so Core.so libSDL3.so.0 libGLESv2.so.2 libm libc ld-linux | GLIBC_2.35, from `_dl_find_object` in jammy's static libgcc unwinder. Not shipped. |

The build is deterministic: rebuilding gives the same hashes. Build paths are
mapped out with `-ffile-prefix-map`.

The renderer calls GLES 2 directly through `libGLESv2.so.2`. On muOS that file
is the `libmali.so` symlink. Only SDL3 goes through `libSDL3.so.0`, which is
the port's SDL3-over-SDL2 shim.

## Installing

- `NOpenGLESDrv.so` goes into `SystemARM64/`, next to Engine.so. Its RUNPATH
  is `$ORIGIN`.
- `NOpenGLESDrv.int` goes into `System/`; the engine finds it through
  `LangPaths=../System/*.<lang>` in the port's `../unreal/config/UnrealLinux.ini`.
  It is UTF-8 with a BOM, like 227k_15's `OpenGLDrv.int`. The engine does not
  need it to load the class; the video menu's device list and the Preferences entry ("OpenGL ES 2") do.
- To select the renderer, set `[Engine.Engine] GameRenderDevice` and
  `WindowedRenderDevice` to `NOpenGLESDrv.NOpenGLESRenderDevice`.
- Settings live in `[NOpenGLESDrv.NOpenGLESRenderDevice]`. A missing key
  takes the default:

| Key | Default | Meaning |
|---|---|---|
| `MaxDecompressedTextureSize` | 512 | BC1/2/3 textures are decoded starting from the largest mip of at most this size. 0 means the GL limit. |
| `Overbright` | True | Lightmaps at 2x, like the stock renderers. |
| `DetailTextures`, `MeshDetailTextures` | False | Extra texture passes, which cost too much fill rate on Mali-G31. |
| `UseBGRA` | False | BGRA uploads through `GL_EXT_texture_format_BGRA8888`. Off, light maps are swizzled on the CPU, as the UT99 port does. |
| `UseVAO` | False | Vertex buffer object for the batch. |
| `NoFiltering` | False | Nearest-neighbour filtering of non-lightmap textures. |
| `VolumetricLighting`, `ShinySurfaces`, `Coronas`, `HighDetailActors` | True | Inherited from URenderDevice. `HighDetailActors` also gates weapon muzzle flashes. |
| `WidescreenFOV` | False | Android only; has no effect here. |

Brightness is `[SDLDrv.SDLClient] Brightness` (the port's config sets 0.5),
mapped through the same tone curve as 227's OpenGLDrv (see "Tone curve"
below). Changes in the video
menu, with the `BRIGHTNESS` command (the port's F11) or with `set` apply on the
next frame.

## What the patch changes

The patch carries `NOpenGLESDrv469.patch` from the UT99 port: highp texture
coordinates, ES2 context attributes, the swap in `Unlock`, the conservative
defaults, `TEXT()`/`appFromAnsi` and the `std::string` shader builder. These
are 469-only and stay behind `NOPENGLES_469_COMPAT`: the menu-mouse hack, the
`PF_RenderHint` font hack, the SmokeBlack suppression and the modulated decal
mask. With 469e SDK headers, `NOPENGLES_469_COMPAT` still compiles.

### Engine interface (227, `NOPENGLES_227`)

- **Class.** The device derives from 227's `URenderDevice`, uses
  `DECLARE_CLASS(…, NOpenGLESDrv)` and `DLL_EXPORT_CLASS`, and includes the
  SDK's `Render.h`. It implements `ReadPixels(FColor*, UBOOL)`,
  `PreDrawGouraud`/`PostDrawGouraud`, `SetZTestMode`, `PrecacheTexture`, a
  virtual `SetSceneNode`, `Draw2DLine` and `Draw2DPoint`. The defaults are kept
  where they are right:
  - `DrawGouraudPolyList` splits into `DrawGouraudPolygon`.
  - `PushClipPlane`/`PopClipPlane` return 0, so clipping is done in software.
  - `PushRenderToTexture` returns FALSE.
  - `BeginMeshDraw`, `EndMeshDraw`, `DrawPass` and `ResetGamma` stay default.
- **Capability fields** (set in `Init`):

| Field | Value | Effect |
|---|---|---|
| `SupportsTC` | 1 | BC1/2/3 arrive compressed. |
| `SupportsNewBTC` | 0 | The engine decompresses BC4/5/7 and ETC1. |
| `DecompFormat` | `TEXF_RGBA8_` | The engine's default, P8, cannot hold those formats. |
| `SupportsHDLightmaps` | 0 | |
| `UseLightmapAtlas` | 0 | |
| `SupportsNoClipRender` | 0 | |
| `LegacyRenderingOnly` | 1 | Render.so draws mesh detail passes itself, together with `MeshDetailTextures`. |
| `SupportsAlphaBlend` | 1 | |
| `NeedsMaskedFonts` | 1 | |
| `SupportsDistanceFog` | 1 | |
| `MaxTextureSize` | `GL_MAX_TEXTURE_SIZE` | |
| `Description` | `GL_RENDERER` | |

  `NeedsMaskedFonts=1` makes `UCanvas::WrappedPrint` keep `PF_Masked` font
  draws (System64 Engine.so, 0x15fee4). Without it, the engine switches fonts to
  premultiplied `PF_Highlighted`, which needs palette alpha that the P8 upload
  does not keep.
- **Config defaults** are set in `StaticConstructor`. 227 copies class
  defaults into each new device and then runs the C++ constructor, so the
  upstream constructor overwrote the ini values. `DetailTextures` is
  `URenderDevice`'s own config property in 227, so the duplicate property was
  dropped.
- **GL context.** 227's SDLDrv only creates the window. `Init` does the rest,
  following XOpenGLDrv:
  1. Sets the ES 2.0, depth 24 and double-buffer attributes before the first
     `ResizeViewport`.
  2. Creates the context on the viewport window.
  3. Makes it current.
  4. Loads glad.

  `SetRes` resizes and makes the context current again. `Unlock` swaps, and
  `Exit` deletes the GL objects and the context.
- **PolyFlags (227 meanings).**
  - `PF_AlphaBlend` (0x20000) blends with `SRC_ALPHA, ONE_MINUS_SRC_ALPHA`.
    Opacity comes from the vertex light alpha (meshes) or `Light.W`
    (tiles), as in XOpenGLDrv.
  - `PF_Highlighted` is premultiplied. Neither flag writes depth.
  - `PF_Masked` is kept on translucent polygons, as XOpenGLDrv does.
- **Textures.** `UploadTexture` now dispatches on `Info.Format`:

| Format | Handling |
|---|---|
| P8 | Index 0 is transparent when drawn masked. Palette alpha is kept only for `PF_AlphaBlend` draws, which have their own cache tag; old packages carry garbage there, so other modes force it opaque. |
| BGRA8_LM, BGRA8 | Swizzled. |
| RGBA8_ | Uploaded as is. |
| BC1/BC2/BC3 | `BCDecode` decodes from the largest mip within `MaxDecompressedTextureSize`. A texture with no mip that small is halved on the CPU. BC1 keeps punch-through alpha. |
| Anything else | Logged once per format and drawn with a mid-grey 8x8 texture. |

  - Realtime textures are re-uploaded when `RenderTag` changes.
  - `UClampMode` and `VClampMode` select `CLAMP_TO_EDGE`.
  - Light and fog maps are recognised by format. Upstream used the missing
    palette, which would have clamped every BC texture.
  - GLES 2 has no `GL_TEXTURE_MAX_LEVEL`, and an incomplete chain samples as
    black. Mip chains that stop early, or lose a level, are therefore
    completed down to 1x1 with the box filter.
  - `Info.Modifier` (texture modifiers) transforms mesh UVs in locals, and
    normalised UVs for tiles.
- **Distance fog** (`ZoneInfo.bDistanceFog`). `PreDrawGouraud` sets a
  linear, exp or exp2 fog by eye depth, applied in the fragment shader
  (`SF_DistanceFog`). It uses OpenGLDrv's formulas and its neutral colours for
  modulated and translucent polygons. As in OpenGLDrv, `PreDrawGouraud` and
  `PostDrawGouraud` do nothing while the engine draws decals and projectors
  (`GUglyHackFlags & HACKFLAGS_DrawingDecal`), so blast marks are not fogged.
- **Viewport.**
  - The GL viewport is scaled from `SizeX×SizeY` to `PhysicalSizeX×Y`.
  - The far plane is `FRAME_MAX_Z_RANGE` (524288) instead of 32768.
  - `ReadPixels` reads the framebuffer, flips it vertically and returns BGR
    order, as XOpenGLDrv does. `bGammaCorrectOutput` needs no work, because
    the brightness is already applied in the shader.
- **Look.**
  - Lightmaps are overbright at 2.0 instead of 1.4, matching OpenGLDrv
    `OneXBlending=False` and XOpenGLDrv. Light map texels are clamped at
    127.5 first, as OpenGLDrv's shader does (`min(LightColor, 0.5)`), so
    bright dynamic lights saturate at the same level.
  - Brightness and gamma follow OpenGLDrv (next section).
  - Modulated polygons get no brightness scale, only the tone curve's power
    of their factor 2, because mid grey must stay their no-op. This replaces
    the 469 SmokeBlack and decal hacks.
- **Logging.** The `Unlock` log line every 60 frames and the Android FOV
  line are removed: the log is written to the SD card. A brightness change
  logs one line with the curve, for example
  `NOpenGLESDrv: Brightness 0.50: x^0.800, scale 1.0000 + 0.0000 t + 0.0000 t^2`.

### Tone curve (227)

227's OpenGLDrv (`ColorCorrectionMode=UseFramebuffer`,
`UseShaderGamma=False`) renders into an 8-bit framebuffer and then maps each
channel `x` of the finished frame with a `pow` per pixel
(227k_15 SDK: `OpenGL.cpp` `Lock`, `OpenGLBase.cpp` `SetColorCorrection`,
`OpenGL_ShaderWriter.h`):

```
B = clamp(2 * Brightness, 0.05, 2.99)    g = 1.05 - 0.25 * B
B <= 1:  (B * x)^g                        (Brightness 0.5: x^0.8)
B >  1:  min(x * (1 + (1 - m) * (B - 1)), 1)^g,  m = brightest channel of the pixel
```

The renderer reproduces the curve without a `pow` per fragment:

- **Power on the CPU.** `(a * b)^g = a^g * b^g`, so the power is applied to
  each factor of the colour product before it reaches the GPU: texels through
  a 256-entry table at upload (`ToneLUT`; P8 palettes, RGBA, BGRA and decoded
  BC1/2/3), light maps through their own table with the 127.5 clamp
  (`ToneLightLUT`), fog map alpha as `1 - (1 - 2a)^g` (`ToneFogAlphaLUT`),
  vertex and tile colours when they are batched (`ToneColor`, a 1025-entry
  table), the screen clear colour and the flash. The shader multiplies by the
  powers of its own constants: `(2 * overbright)^g` for light maps, `2^g` for
  fog maps and detail textures (uniform `uToneScale`).
- **Brightness.** For `B <= 1` the remaining factor is the constant `B^g`,
  which makes the result exact. For `B > 1` it is
  `H(t) = (1 + (1 - t^(1/g)) * (B - 1))^g` of the brightest powered channel
  `t`. Shaders compiled with `SF_ToneBoost`, which is only used while
  Brightness is above 0.5, evaluate a quadratic in `t` (two multiply-adds and
  two max). `UpdateTone` fits it by least squares over the 255 input levels,
  which keeps it within half a level up to Brightness 1.0.
- **Sums.** Blending and fog add colours, and the power of a sum is not the
  sum of the powers:
  - Fog maps and vertex fog: `FOG_ADD(c, f) = c + f - (2 - 2^g) * min(c, f)`.
    It is exact when either term is zero or both are equal, and at most 5% too
    bright in between.
  - Distance fog weighs the surface with `(1 - a)^g` and the fog colour with
    `a^g`, both computed with a cubic polynomial (`TONE_POW`), and adds them
    with `FOG_ADD`. This is exact for black fog.
  - Translucent (`ONE, ONE_MINUS_SRC_COLOR`) and premultiplied blending add
    the powered colours. This is exact over black and slightly brighter where
    several layers overlap.
  - Modulated blending (`DST_COLOR, SRC_COLOR`) is a product and stays exact.
  - 227 alpha blending (`PF_AlphaBlend`) mixes the powered colours with the
    unchanged alpha. This is exact for opaque texels and equal colours, and
    a little dark for partly transparent texels over black.
- **Changes at run time.** `Lock` compares `UClient::Brightness` with the
  value of the current curve every frame. On a change it rebuilds the tables
  and uniforms, and flushes the texture cache if the power changed, because
  cached textures hold the old power. The video menu slider, the
  `BRIGHTNESS` command and `set ini:Engine.Engine.ViewportManager Brightness`
  all take effect on the next frame. `ResetGamma` stays the engine default:
  no hardware gamma ramp is involved.
- **Cost.** Per fragment, nothing at Brightness 0.5 or below, and two
  multiply-adds plus two max above it. Distance-fogged surfaces add two cubic
  polynomials. On the CPU, one table lookup per texel at upload: the palette
  for P8 textures, every texel for the other formats.

### Latent upstream bugs fixed

| Bug | Fix | Builds |
|---|---|---|
| Batch overflow | `BeginPoly(NumPts)` flushes before a polygon would overrun the vertex buffer, the index buffer or the 16-bit index range, and skips degenerate polygons. This is the Mali "diagonal line" artefact; Unreal-Android v2.0.3 `PreparePoly`. The index buffer is now 3×MAX_VERTS. | All builds |
| `ComposeSize` | Updated after `appRealloc` (UE1 99319bb). | OldUnreal |
| VBO size | Allocated in bytes, not floats. | OldUnreal |
| `EndFlash` | The quad is drawn while the depth test is still off, and placed off the near plane. | All builds |
| Masked texels | The shader divides by alpha after the test (as XOpenGLDrv), so filtering no longer darkens cut-out edges. | All builds |
| `ReadPixels` | Vertical flip (UE1 a9e7d73). | 227 |
