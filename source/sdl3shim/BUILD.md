# Rebuilding libSDL3.so.0 (SDL3-over-SDL2 shim)

OldUnreal 227k_15 links only against SDL3. muOS 2601.1 on the RG34XX-SP ships
only SDL2 2.28.5 (JohnnyonFlame's `mali-fbdev` fork). The port therefore ships
bmdhacks' `sdl2-backend` branch of SDL3 as `SystemARM64/libSDL3.so.0`. It is a
real SDL3 whose video, audio and joystick drivers `dlopen` the device's own
`libSDL2-2.0.so.0` at run time and forward to it. This directory has the
patches and the script that build it.

## Inputs

| Input | Pin |
|---|---|
| Shim source | `https://github.com/bmdhacks/SDL.git` commit `6057d79baf8321bf190479a699655f06cc2a962f` (branch `sdl2-backend`, 2026-05-18, SDL 3.5.0-dev). PortMaster's railroadrampage and taisei ports and zalo/melee pin the same commit. Fetched by `build.sh` with `git fetch --depth 1`; the commit hash pins the content. |
| `sdl3-sdl2-backend-fixes.patch` | Verbatim from `PortsMaster/PortMaster-New` commit `3fcdb796b828bfac8d62a40b24842b3215c60ab4`, path `ports/railroadrampage/railroadrampage/patches/sdl3-sdl2-backend-fixes.patch`. Added in `0e8b597b776fcc1f3f0e4107cbcc9e9f1f4e2954` ("Add new Port: Railroad Rampage"). git blob `b07c2f489ca178f7712f3edabd1502f6d88b60c9`, SHA-256 `3323ea17907b53efd5c2c766ce509d32c84acb1c00c7ad90a1da8303dc7e5d08`. |
| `sdl3-sdl2-backend-unrealgold-gl.patch` | This port. SHA-256 `489ba70d913aaf09196fc5825d1588fc68d0827166900cd5c425924cae720518`. |
| `sdl3-sdl2-backend-unrealgold-winsize.patch` | This port. SHA-256 `24c09f8a373d10da0606f061dc13ba5819fecb4552e6ed6b5089fa7aa7f9054d`. |
| Build environment | Image `localhost/unrealgold-build:jammy`, built from `../Containerfile`: Ubuntu 22.04, GCC 12.3.0 (`gcc-12`, `aarch64-linux-gnu-gcc-12`), Ninja 1.10.1, git 2.34.1. |
| CMake | 3.31.6, `cmake-3.31.6-linux-x86_64.tar.gz` from the Kitware GitHub release, SHA-256 `5a1133ff103c71eb5120e2cc3de922733e7d8a26a98ae716397e8676adb367bf`, unpacked to `$UNREALGOLD_CACHE/tools/`. Override the path with `CMAKE=...`. |

## Patches

They are applied in this order. Each file explains its hunks at the top.

1. **`sdl3-sdl2-backend-fixes.patch` (PortMaster):**
   - SDL2 mouse motion is forwarded as `xrel/yrel` only while SDL2's relative
     mode is on, and as `x/y` otherwise. Upstream sent SDL2's absolute
     position as a relative delta, so aiming was garbage.
   - libSDL2 is no longer `dlclose`d at video shutdown. This crashed when the
     SDL2 audio thread was still running.
2. **`sdl3-sdl2-backend-unrealgold-gl.patch`:**
   - The shim now copies the GL attributes to SDL2 again just before SDL2
     creates the window, where SDL2 picks the EGL config, and before it
     creates the context. Upstream copied them only at the first
     `SDL_GL_LoadLibrary`, so OpenGLDrv's depth size, which it sets after
     loading the library, was ignored (16-bit depth instead of 24).
   - It also forwards the multisample, share-context and sRGB attributes.
   - A non-ES request older than 2.0 now asks SDL2 for ES 2.0. OpenGLDrv's
     first detection probe uses profile 0 and version 0.0, which upstream
     turned into an ES 1.x request. On Mesa that request fails outright, and
     OpenGLDrv then calls `glGetIntegerv` without checking for failure.
   - Destroying a window no longer deletes the last GL context created on it.
     227 destroys its context first and its window second, so upstream
     deleted the context twice. With SDL2 on GLX that double delete kills the
     process with `GLXBadContext`.
3. **`sdl3-sdl2-backend-unrealgold-winsize.patch`:** after creating a window
   and after `SDL_SetWindowSize`, the shim reports to SDL3 the size SDL2
   actually gave the window, not the size that was requested. Without the
   blitter, mali-fbdev makes every window 720x480. SDLDrv works out its mouse
   scale from `SDL_GetWindowSize`, which therefore has to match
   `SDL_GetWindowSizeInPixels` and the EGL surface. The shim does not fake
   the fullscreen flag. SDL3 already reports the 720x480 desktop mode when
   227 enters fullscreen.

## Build

```sh
./build.sh            # both architectures; or: ./build.sh arm64 | amd64
```

Run on the host, `build.sh` re-runs itself in the build container. It mounts
`$UNREALGOLD_CACHE`, which defaults to `~/.cache/unrealgold-port`, at the
same path. To run it inside the container yourself:

```sh
podman run --rm --security-opt label=disable --userns=keep-id \
  -v "$UNREALGOLD_CACHE:$UNREALGOLD_CACHE" -v "$PWD:$PWD" -w "$PWD" \
  -e UNREALGOLD_CACHE="$UNREALGOLD_CACHE" localhost/unrealgold-build:jammy sh ./build.sh
```

The script does the following:

1. Fetches the pinned commit into `build/sdl3shim/src`, unless it is already
   there.
2. Exports a clean copy to `build/sdl3shim/patched` and applies the three
   patches with `git apply`, so any drift fails the build.
3. Configures the shim the Melee way: `-DSDL_SDL2_BACKEND=ON
   -DSDL_UNIX_CONSOLE_BUILD=ON`, with X11, Wayland, KMSDRM, offscreen,
   dummy video, every audio backend, Vulkan, SDL_GPU and HIDAPI off. It uses
   `-DSDL_OPENGL=OFF -DSDL_OPENGLES=ON` and turns pkg-config off, so no
   optional desktop integration is pulled in. The amd64 build is the same
   library; its SDL2 underneath uses X11.
4. Builds and strips both architectures. arm64 is built with
   `-march=armv8-a -mtune=cortex-a53`.

The outputs are written to `$UNREALGOLD_CACHE/build/sdl3shim/`:

| File | SHA-256 |
|---|---|
| `arm64/libSDL3.so.0` | `c31b0bd73f12b71c4c839042d4f2e21fa5e844def05e845dc3b45dbfce5392c5` |
| `amd64/libSDL3.so.0` | `1197aa2b8677a9f3a62fbf3801d00db627dad878ce971804310524e7c2e0034d` |
| `LICENSE.txt` | SDL's zlib licence; ship it in `licenses/`. |

The build is reproducible bit for bit with the image above; repeated runs and
a fresh fetch into a different cache root gave the same hashes.

Both libraries have these properties:
- SONAME `libSDL3.so.0`.
- `NEEDED` lists only libc, libm and ld.so. libSDL2 is loaded with `dlopen`.
- `DF_1_INTERPOSE` is set.
- The highest symbol version required is `GLIBC_2.34`. 227k_15 itself needs
  2.34; muOS has 2.38.
- They export 1288 `SDL3_0.0.0` symbols. That covers all 166 SDL symbols
  imported by 227k_15's `SystemARM64`/`System64` ELFs and every export of
  the official 227k_15 `libSDL3-3.0.so.0`.

## Install and run

**Installing**
- Copy `arm64/libSDL3.so.0` into `SystemARM64/` as a **real file**. It
  replaces both the official `libSDL3.so.0` symlink and
  `libSDL3-3.0.so.0`, because exFAT has no symlinks.
- The engine binaries' `RUNPATH $ORIGIN` finds it there.

**Launcher environment**
- `SDL_VIDEO_DRIVER=sdl2`: this is SDL3's variable. Never export
  `SDL_VIDEODRIVER`, which the inner SDL2 also reads.
- `SDL3SHIM_ENABLE_MOUSE=1`: without it, `SDL_SetWindowRelativeMouseMode`
  fails. SDLDrv then logs `Assertion failed` and mouselook stops at the
  screen edges.
- Leave `SDL_MOUSE_RELATIVE_SPEED_SCALE` unset. SDL2 and SDL3 both apply it,
  so the scale would be applied twice.
- Start the game with `-log` so SDLLaunch skips its splash window.
  mali-fbdev supports only one window.
- `SDL3SHIM_SDL2_VIDEODRIVER` (optional) is copied into SDL2's
  `SDL_VIDEODRIVER`. `SDL3SHIM_SDL2_LIB` (optional) names the SDL2 library;
  the default is `libSDL2-2.0.so.0`.

**Limits that remain**
- `SDL_GL_LoadLibrary` ignores its path. A second call with a path fails with
  "OpenGL library already loaded", which OpenGLDrv tolerates.
- `SDL_GetWindowSurface` does not work, so SoftDrv and the splash screen do
  not work either.
- With the blitter disabled, mali-fbdev stores the swap interval but never
  applies it.
