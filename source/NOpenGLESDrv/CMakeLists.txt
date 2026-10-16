cmake_minimum_required(VERSION 3.16)
project(NOpenGLESDrv227 C CXX)

# Standalone build of NOpenGLESDrv.so for OldUnreal 227k_15 (Unreal Gold).
# build.sh drives it; see BUILD.md for the inputs.

set(CMAKE_CXX_STANDARD 14) # As the 227 SDK's CMakeLists.txt.
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(UT99DC_ROOT "" CACHE PATH "Patched UT99-Android third_party/ut99dc directory")
set(UT99DC_COMPAT_ROOT "" CACHE PATH "UT99-Android app/src/main/cpp directory (glad/glm compat)")
set(UNREAL227_SDK "" CACHE PATH "Extracted OldUnreal 227k_15 SDK-Linux directory")
set(UNREAL227_SYSTEM "" CACHE PATH "227k_15 SystemARM64 or System64 directory")
set(SDL3_INCLUDE_DIR "" CACHE PATH "SDL 3.4.8 include directory")
set(BCDECODE_DIR "${CMAKE_CURRENT_LIST_DIR}/../common" CACHE PATH "Directory of BCDecode.h")
set(NOPENGLES_ARCH "" CACHE STRING "arm64 or amd64")
set(NOPENGLES_OUTPUT_DIR "${CMAKE_BINARY_DIR}/out" CACHE PATH "Renderer output directory")

foreach(required_path UT99DC_ROOT UT99DC_COMPAT_ROOT UNREAL227_SDK UNREAL227_SYSTEM SDL3_INCLUDE_DIR BCDECODE_DIR)
  if(NOT IS_DIRECTORY "${${required_path}}")
    message(FATAL_ERROR "${required_path} must name an existing directory")
  endif()
endforeach()
if(NOT NOPENGLES_ARCH MATCHES "^(arm64|amd64)$")
  message(FATAL_ERROR "NOPENGLES_ARCH must be arm64 or amd64")
endif()

# GLES2 import library of the build environment (glvnd). Its SONAME,
# libGLESv2.so.2, is the libmali symlink on muOS.
find_library(GLES2_LIBRARY NAMES GLESv2 REQUIRED)

add_library(NOpenGLESDrv SHARED
  "${UT99DC_ROOT}/Source/NOpenGLESDrv/NOpenGLESDrv.cpp"
  "${UT99DC_COMPAT_ROOT}/android_glad_compat/glad.c"
)

target_include_directories(NOpenGLESDrv PRIVATE
  "${UT99DC_ROOT}/Source/NOpenGLESDrv"
  "${UT99DC_COMPAT_ROOT}/android_glad_compat"
  "${UT99DC_COMPAT_ROOT}/android_glm_compat"
  "${UNREAL227_SDK}/Core/Inc"
  "${UNREAL227_SDK}/Engine/Inc"
  "${UNREAL227_SDK}/Render/Inc"
  "${SDL3_INCLUDE_DIR}"
  "${BCDECODE_DIR}"
)

# The 227 SDK's Linux defines (CMakeLists.txt 305-369, 486-508).
target_compile_definitions(NOpenGLESDrv PRIVATE
  _RELEASE NDEBUG RELEASE
  UTGLR_UNREAL_227_BUILD
  UTGLR_USES_ALPHABLEND=1
  OLDUNREAL_TEXTURE_COMPRESSION=0
  __UNIX__=1 UNICODE=1 _UNICODE=1 _REENTRANT=1 HAVE_PRAGMA_PACK=1
  SDL3BUILD
  GPackage=LocalPackageNameNOpenGLESDrv
  NOPENGLESDRV_EXPORTS
  NOPENGLES_227=1
)

target_compile_options(NOpenGLESDrv PRIVATE
  -pipe
  -fsigned-char
  "-ffile-prefix-map=${UT99DC_ROOT}=ut99dc"
  "-ffile-prefix-map=${UT99DC_COMPAT_ROOT}=compat"
)

if(NOPENGLES_ARCH STREQUAL "arm64")
  target_compile_definitions(NOpenGLESDrv PRIVATE
    ENGINE_ARCHITECTURE="arm64"
    USES_SSE_INTRINSICS=0
    __LINUX_ARM__=1
    SDL_DISABLE_MM3DNOW_H=1 SDL_DISABLE_IMMINTRIN_H=1 SDL_DISABLE_MMINTRIN_H=1
    SDL_DISABLE_XMMINTRIN_H=1 SDL_DISABLE_EMMINTRIN_H=1 SDL_DISABLE_PMMINTRIN_H=1
  )
  # Cortex-A53 (Allwinner H700). The official modules tune for the A72.
  target_compile_options(NOpenGLESDrv PRIVATE -march=armv8-a -mtune=cortex-a53)
else()
  target_compile_definitions(NOpenGLESDrv PRIVATE
    ENGINE_ARCHITECTURE="amd64"
    USES_SSE_INTRINSICS=1
    __LINUX_X86__=1
  )
  target_compile_options(NOpenGLESDrv PRIVATE -msse -msse2)
  # As the official amd64 modules: static libstdc++/libgcc, gold, Version.script.
  target_link_options(NOpenGLESDrv PRIVATE
    -static-libgcc -static-libstdc++ -fuse-ld=gold
    "-Wl,--version-script=${UNREAL227_SDK}/Version.script"
  )
endif()

# -z defs: every symbol must resolve against the libraries below.
# --as-needed: NEEDED only what is used (Render.so is not).
target_link_options(NOpenGLESDrv PRIVATE
  -Wl,-z,defs
  -Wl,--as-needed
  -Wl,--strip-all
  -Wl,--enable-new-dtags
)

target_link_libraries(NOpenGLESDrv PRIVATE
  "${UNREAL227_SYSTEM}/Engine.so"
  "${UNREAL227_SYSTEM}/Core.so"
  "${UNREAL227_SYSTEM}/libSDL3-3.0.so.0"
  "${GLES2_LIBRARY}"
)

set_target_properties(NOpenGLESDrv PROPERTIES
  PREFIX ""
  OUTPUT_NAME "NOpenGLESDrv"
  NO_SONAME OFF
  LIBRARY_OUTPUT_DIRECTORY "${NOPENGLES_OUTPUT_DIR}"
  BUILD_WITH_INSTALL_RPATH TRUE
  SKIP_BUILD_RPATH TRUE
  INSTALL_RPATH "\$ORIGIN"
)
