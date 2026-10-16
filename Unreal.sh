#!/bin/bash

XDG_DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}

if [ -d "/opt/system/Tools/PortMaster/" ]; then
  controlfolder="/opt/system/Tools/PortMaster"
elif [ -d "/opt/tools/PortMaster/" ]; then
  controlfolder="/opt/tools/PortMaster"
elif [ -d "$XDG_DATA_HOME/PortMaster/" ]; then
  controlfolder="$XDG_DATA_HOME/PortMaster"
else
  controlfolder="/roms/ports/PortMaster"
fi

source "$controlfolder/control.txt"
[ -f "${controlfolder}/mod_${CFW_NAME}.txt" ] && source "${controlfolder}/mod_${CFW_NAME}.txt"
get_controls

GAMEDIR=/$directory/ports/unreal
DATADIR="$GAMEDIR/gamedata"
RUNDIR="$DATADIR/SystemARM64"
CONFDIR="$GAMEDIR/conf"

cd "$GAMEDIR"
> "$GAMEDIR/log.txt" && exec > >(tee "$GAMEDIR/log.txt") 2>&1

# The Unreal Gold files are downloaded from OldUnreal on the first start.
# install.bash writes gamedata/.installed when it is done.
if [ ! -f "$DATADIR/.installed" ]; then
  export SEVENZIP="$controlfolder/7zzs.${DEVICE_ARCH}"
  export PATCHER_FILE="$GAMEDIR/install/install.bash"
  export PATCHER_GAME="Unreal Gold"
  export PATCHER_TIME="5 to 15 minutes"
  export PATCHER_QUESTIONS="$GAMEDIR/install/questions.lua"
  if [ -f "$controlfolder/utils/patcher.txt" ] && [ -x "$SEVENZIP" ]; then
    $ESUDO chmod a+x "$PATCHER_FILE"
    source "$controlfolder/utils/patcher.txt"
  else
    pm_message "This port requires the latest PortMaster to run, please go to https://portmaster.games/ for more info."
    sleep 5
    exit 1
  fi
  [ -f "$DATADIR/.installed" ] || exit 1
fi

mkdir -p "$CONFDIR"
[ -f "$CONFDIR/UnrealLinux.ini" ] || cp "$GAMEDIR/config/UnrealLinux.ini" "$CONFDIR/UnrealLinux.ini"
[ -f "$CONFDIR/User.ini" ] || cp "$GAMEDIR/config/User.ini" "$CONFDIR/User.ini"

sed -i -E \
  -e "s/^(WindowedViewportX|FullscreenViewportX)=.*/\1=${DISPLAY_WIDTH}/" \
  -e "s/^(WindowedViewportY|FullscreenViewportY)=.*/\1=${DISPLAY_HEIGHT}/" \
  -e 's/^(WindowedColorBits|FullscreenColorBits)=.*/\1=32/' \
  -e 's/^(GameRenderDevice|WindowedRenderDevice)=.*/\1=NOpenGLESDrv.NOpenGLESRenderDevice/' \
  -e 's/^ViewportManager=.*/ViewportManager=SDLDrv.SDLClient/' \
  -e 's/^StartupFullscreen=.*/StartupFullscreen=True/' \
  -e 's/^UseJoystick=.*/UseJoystick=False/' \
  -e 's/^UseVAO=.*/UseVAO=False/' \
  -e 's/^UseBGRA=.*/UseBGRA=False/' \
  -e 's/^AutoGUIScale=.*/AutoGUIScale=False/' \
  -e 's/^(OutputRate|SampleRate)=.*/\1=48000Hz/' \
  "$CONFDIR/UnrealLinux.ini"

bind_files "$RUNDIR/UnrealLinux.ini" "$CONFDIR/UnrealLinux.ini"
bind_files "$RUNDIR/User.ini" "$CONFDIR/User.ini"

export LD_LIBRARY_PATH="$RUNDIR:$LD_LIBRARY_PATH"
# Supply the encodings 227 converts through iconv on every firmware.
export GCONV_PATH="$GAMEDIR/gconv"
export SDL_GAMECONTROLLERCONFIG="$sdl_controllerconfig"

# 227 is SDL3-only. SystemARM64/libSDL3.so.0 is the sdl3-sdl2-backend shim,
# which runs on the firmware's SDL2. SDL3 would read SDL_VIDEODRIVER too, so
# the firmware's choice goes to the shim's SDL2 instead.
if [ -n "$SDL_VIDEODRIVER" ] && [ "$SDL_VIDEODRIVER" != "sdl2" ]; then
  export SDL3SHIM_SDL2_VIDEODRIVER="$SDL_VIDEODRIVER"
fi
unset SDL_VIDEODRIVER
export SDL_VIDEO_DRIVER=sdl2
export SDL3SHIM_ENABLE_MOUSE=1
# Fullscreen-only viewport and software menu cursor in the port's SDLDrv.so.
export UNREALGOLD_HANDHELD=1

if [ "${CFW_NAME:-}" = "ROCKNIX" ]; then
  export SDL_HINT_APP_NAME="${SDL_HINT_APP_NAME:-Unreal Gold}"
  export SDL_OPENGL_ES_DRIVER="${SDL_OPENGL_ES_DRIVER:-1}"
  export SDL_TOUCH_MOUSE_EVENTS=0
  swaymsg input type:touch events disabled 2>/dev/null
fi

chmod +x "$RUNDIR/unreal-bin-arm64"
cd "$RUNDIR"

# The kernel truncates process names to 15 characters, and gptokeyb2 quits
# the game by that name. Its output (a line per right-stick sample) is dropped.
$GPTOKEYB2 "unreal-bin-arm6" -c "$GAMEDIR/unreal.ini" > /dev/null 2>&1 &
pm_platform_helper "$RUNDIR/unreal-bin-arm64" > /dev/null

# -log skips the launcher splash, a second window the fbdev display can't show.
./unreal-bin-arm64 -log

pm_finish
