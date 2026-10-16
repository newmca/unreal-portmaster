# SDLDrv for the Unreal Gold port (single-surface handheld)

`SDLDrv.so` is the OldUnreal 227k_15 SDL3 viewport/input driver from the
227k_15 SDK with `SDLDrv-handheld.patch` and `SDLDrv-keyrepeat.patch`,
rebuilt with GCC 12. It replaces `SystemARM64/SDLDrv.so`. Other modules stay
ABI-compatible: the class layout does not change (see "ABI" below).

## What SDLDrv-handheld.patch changes

One fix is always on. The handheld behaviour is enabled only when the
environment variable `UNREALGOLD_HANDHELD` is set to anything except `""` or
`"0"`. The launcher sets `UNREALGOLD_HANDHELD=1`. `USDLClient::Init` reads the
variable once into the global `GSDLDrvHandheld`, and logs
`SDLDrv: Handheld mode (UNREALGOLD_HANDHELD=1): ...` when it is set.

| | Where | Change | Why |
|---|---|---|---|
| A | `UpdateInput` | Ignore `SDL_EVENT_WINDOW_*` events whose `windowID` is not the viewport's window (always on). | Stock SDLDrv applied size changes of the launcher's splash window (719x200) and of XOpenGLDrv's hidden 2x2 probe window to the viewport. |
| A | `SetMouseCapture` | Log `SDLDrv: SetMouseCapture - Capture N` when the stock path changes the capture state (always on). | Shows the stock capture behaviour in the log. It only logs and changes nothing. |
| B | constructor, `SetMouseCapture`, end of `ResizeViewport` | Handheld: `bWindowsMouseAvailable` stays 0, and the mouse stays grabbed in relative mode. `SetMouseCapture` returns without any SDL call unless the grab was lost. `ResizeViewport` skips the relative-mode off/on "mode switching quirk". | muOS draws no OS cursor on fbdev. UWindow draws its own cursor only while `bWindowsMouseAvailable` is 0, and moves it by `IK_MouseX`/`IK_MouseY` deltas. In fullscreen, `UGameEngine::Tick` calls `SetMouseCapture(0,0)` on every tick while a menu is open. |
| B | `Repaint` → `CentreHandheldMenuMouse` | Handheld: when `bShowWindowsMouse` goes on (a menu or the UWindow console opens), set `WindowConsole.MouseX/MouseY` to the screen centre, divided by `Root.GUIScale`. This happens before the frame is drawn. | 227 keeps the cursor in UnrealScript. It starts at 0,0 and otherwise keeps the position the last menu left it at. The UT99 port centred it the same way. |
| C | `ResizeViewport` | Handheld: create the window with `SDL_WINDOW_FULLSCREEN`. Skip `ResizeWindow` (`SDL_SetWindowSize`/`SDL_SetWindowPosition`), `SDL_SetWindowFullscreenMode`, `SDL_RaiseWindow`, and `SDL_SetWindowFullscreen` when the window is already fullscreen. | The window is one fbdev surface with a fixed 720x480 mode. With these calls skipped, it is no longer created at 100x100 and then resized, centred and mode-switched. |
| C | `EndFullscreen`, `SetScreenMode`, `SETRES`, `TEMPSETRES`, `OpenWindow` | Handheld: `EndFullscreen` is a logged no-op. This covers Alt+Enter, `TOGGLEFULLSCREEN`, `ENDFULLSCREEN` and a failed `SETRES`. `SetScreenMode Windowed/Borderless` is a logged no-op and saves nothing. `SETRES`/`TEMPSETRES` and the startup render device always request fullscreen. | There is no windowed mode. `StartupFullscreen=False` in an ini cannot produce a window either. |
| D | `Exec` | Handheld: `RELAUNCH` is caught before `UViewport::Exec` passes it to Core. It is logged, and the player gets `Restart the game to apply this change.` | Core's `appRelaunch` forks and execs a second game process onto the single fbdev surface. UMenu sends `RELAUNCH` after video, audio, console, language or raw-input changes. The setting is already saved by then. `PlayerPawn.ConsoleCommand` reaches `USDLViewport::Exec` first, through vtable slot 0xf0 of `Player->Exec`, as `APlayerPawn::execConsoleCommand` in the amd64 Engine.so shows. |
| E | (none) | Text input is not added. `SDL_StartTextInput` stays compiled out. | Enabling it would type every digit twice: once from `KEY_DOWN`, once from `TEXT_INPUT`. |

The patch header repeats this summary. Each hunk also carries a comment in the code.

## What SDLDrv-keyrepeat.patch changes

A bug fix, always on, in every mode. It applies after the handheld patch, or
on its own to the pristine SDK.

SDLDrv emulates key repeat for typed characters itself, because SDL text
input is off (row E above). Stock `UpdateInput` set a 0.5 s delay on
`KEY_DOWN` and, at the end of the same call, subtracted `DeltaSeconds`, the
time since the previous `UpdateInput`, which passed before the key went down.
So when the frame before a key press took longer than 0.5 s (a level load, a
save, a decode hitch), a tapped key was typed twice. On the handheld that
doubles a digit typed into a mod keypad or a UWindow edit box. The patch:

- **Uses a real-time timer.** `KEY_DOWN` records `appSeconds`. The first
  repeat comes 0.5 s after the `UpdateInput` that saw the key go down, then
  one every 0.1 s. The timer starts when the game sees the key, not at the SDL
  event's timestamp, so a key pressed during a hitch still gets its full 0.5 s.
- **Requires the key to be held.** A repeat is sent only while
  `SDL_GetKeyboardState` reports the key as held, and only by the viewport
  that saw it go down. Stock SDLDrv repeated a key forever when its `KEY_UP`
  never reached that viewport (another viewport drained the shared SDL queue,
  or `UseHIDKeyboard` skipped the event).
- **Does not catch up.** One `UpdateInput` sends at most one repeat; after a
  long frame the 0.1 s cadence restarts.

The scancode, key-down time and owning viewport are file statics in
`SDLViewport.cpp`, not class members, so the class layout stays the official
one. SDL has one keyboard and one event queue, so only one key auto-repeats
at a time.

## Rebuild

```sh
./build.sh            # arm64 and amd64; or ./build.sh arm64
```

The script re-runs itself in `localhost/unrealgold-build:jammy`, the image
built from [../Containerfile](../Containerfile). That image is
Ubuntu 22.04 with `g++-12` and `aarch64-linux-gnu-g++-12` 12.3.0, binutils 2.38
and gold 1.16. The script then:

1. checks the pinned inputs (below);
2. copies the pristine `SDLDrv/` to `~/.cache/unrealgold-port/build/sdldrv/src`
   and applies `SDLDrv-handheld.patch`, then `SDLDrv-keyrepeat.patch`, with
   `patch -p1 -F0`;
3. compiles the five `Src/*.cpp` files with the official CMake settings (Release `-O3`, `gnu++14`,
   `-fsigned-char`, `-fPIC`, the 227 defines, `GPackage=LocalPackageNameSDLDrv`;
   on arm64 also `-march=armv8-a -mtune=cortex-a53`);
4. links against the official 227k_15 `Engine.so`, `Core.so` and
   `libSDL3.so.0` with `-z defs`. Like the official module, amd64 links
   libstdc++/libgcc statically, uses gold and `Version.script`, and is
   stripped; arm64 uses the system libstdc++.

The build is reproducible: `SOURCE_DATE_EPOCH` pins `__DATE__`/`__TIME__`
in the window title to the SDK upload time, and `__FILE__` is mapped to
`/workspace`, the same as the official binary. Two runs give identical files:

| File | SHA-256 |
|---|---|
| `~/.cache/unrealgold-port/build/sdldrv/arm64/SDLDrv.so` (device) | `70010af4c380a2b1ad2ed3fe6619ab3fb9d92871431f0bbc9c077188f5c2bb51` |
| `~/.cache/unrealgold-port/build/sdldrv/amd64/SDLDrv.so` (amd64 host build, not shipped) | `d128eda2b2c95b45fd74d8c24a6e7c79273d7ec4538eb4d67a1e4e34a4698a68` |

`build.sh` refuses to finish unless the result has all of the following:

- SONAME `SDLDrv.so` and RUNPATH `$ORIGIN`, as the official module has;
- `Engine.so Core.so libSDL3.so.0` as the first NEEDED entries, and no `libSDL3_ttf.so.0`;
- every `USDL*` symbol the official module exports.

### Pinned inputs

Directory trees are identified by the SHA-256 of their sorted per-file SHA-256 list, as `build.sh` computes it.

| Input | Source | SHA-256 |
|---|---|---|
| 227k_15 SDK | https://github.com/OldUnreal/Unreal-testing/releases/download/v227k_15/OldUnreal-UnrealPatch227k-SDK-Linux.tar.bz2 | `8ec77372a666d999ae688b9d1a852632433a66b0dabc6805b098bf019e82be4f` |
| SDK tree used (`Core/Inc Engine/Inc Render/Inc SDLDrv Version.script`) | extracted to `~/.cache/unrealgold-port/downloads/227k_15/sdk-linux` | tree `7a123e4f4d3e9b6098172aa25ea149be1e62580409e1220445040cb653c32733` |
| 227k_15 Linux game (link libraries, reference module) | https://github.com/OldUnreal/Unreal-testing/releases/download/v227k_15/OldUnreal-UnrealPatch227k-Linux.tar.bz2, extracted to `~/.cache/unrealgold-port/downloads/227k_15/linux` | `b04eba6d5c885c98bd9da8279840b15cd8fa06ed2b750235e7ad7aa26ef3f7a1`; `build.sh` also pins `Core.so`, `Engine.so`, `libSDL3-3.0.so.0` and `SDLDrv.so` of `SystemARM64/` and `System64/` |
| SDL 3 headers | libsdl-org/SDL tag `release-3.4.8` (`d9d5536704d585616d4db3c8ba3c4ff6fc2757e1`), `include/SDL3` | tree `89219ef54e3392755c6184b8df5ec3a2f7553f9df59d1935fd1efd632cfbf606` |

The SDK version (vcpkg port in `ExternalNew/vcpkg/ports/sdl3`) is pinned to SDL 3.4.8, and the shipped
`libSDL3` reports 3.4.8. The official `libSDL3.so.0` is used only to link.
At run time the port ships the SDL3-over-SDL2 shim as `libSDL3.so.0`, which
exports every SDL function this module imports.

## ABI

- No field is added to or moved in `USDLClient` or `USDLViewport`. The
  handheld state is a global (`GSDLDrvHandheld`) plus a function-local static.
  The key-repeat state is three file statics in `SDLViewport.cpp`. The sizes
  stay `sizeof(USDLClient) == 384` and `sizeof(USDLViewport) == 504`, the
  values the official binaries pass to their `UClass` constructors
  (`0x180`/`0x1f8`). `USDLViewport::GetWindow`/`IsFullscreen` load
  `+368`/`+376`, the same offsets as the official arm64 code.
- Exports: every official `USDL*` symbol is present. GCC additionally emits the
  complete-object destructors `USDLClient::~USDLClient()` and
  `USDLViewport::~USDLViewport()` (D1) as aliases. Other symbols the official
  module does not export:
  - `GSDLDrvHandheld`;
  - GCC's weak copies of inline templates (`TArray<...>::~TArray`, `FindField<...>`);
  - the empty inline `UEngine::Draw`/`MouseDelta` (Engine.so exports the
    same weak definitions).
- Imports: the SDL import set is the official one plus `SDL_GetWindowID`
  (handheld patch) and `SDL_GetKeyboardState` (key-repeat patch). The official
  `libSDL3` and the port's shim export both. The Core/Engine imports resolve
  against the official 227k_15 libraries; `-z defs` enforces this at link time.
- Runtime needs, arm64: GLIBC_2.17, CXXABI_1.3.8 and GCC_3.0. muOS has glibc
  2.38 and libstdc++ 6.0.32. NEEDED also lists `ld-linux-aarch64.so.1`, because
  Ubuntu's GCC enables `-fstack-protector-strong` and on aarch64
  `__stack_chk_guard` lives in the dynamic loader.
- The official module also NEEDs `libSDL3_ttf.so.0`, although its TTF code is
  `UNREAL_TOURNAMENT_OLDUNREAL`-only. This build does not link it, so the port
  does not have to ship SDL3_ttf for SDLDrv.

## Known stock behaviour left unchanged

- SDLDrv opens the first joystick even with `UseJoystick=False`, but only
  reads it when `UseJoystick=True`.
