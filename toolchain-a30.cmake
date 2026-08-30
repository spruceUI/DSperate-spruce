# SPDX-License-Identifier: GPL-3.0-or-later
#
# Cross toolchain for the 32-bit spruce devices (A30 / Miyoo Mini class):
# armhf, Cortex-A7, glibc 2.23 from the A30 buildroot sysroot.

set(CMAKE_SYSTEM_NAME Linux)
# NOT aarch64, and that is the whole story for this target: DSperate keys
# DSPERATE_JIT and DSPERATE_NEON off this, and its recompiler emits AArch64 only
# (src/core/cpu/jit/emit.h). A 32-bit build is interpreter + portable C++
# renderer by construction. build-a30.sh asserts that rather than let it be a
# surprise.
set(CMAKE_SYSTEM_PROCESSOR arm)

set(CMAKE_C_COMPILER   "$ENV{DSP_CC}")
set(CMAKE_CXX_COMPILER "$ENV{DSP_CXX}")
set(CMAKE_AR     "$ENV{DSP_AR}"     CACHE FILEPATH "" FORCE)
set(CMAKE_RANLIB "$ENV{DSP_RANLIB}" CACHE FILEPATH "" FORCE)
set(CMAKE_NM     "$ENV{DSP_NM}"     CACHE FILEPATH "" FORCE)
set(CMAKE_STRIP  "$ENV{DSP_STRIP}"  CACHE FILEPATH "" FORCE)
foreach(lang C CXX)
  set(CMAKE_${lang}_COMPILER_AR     "$ENV{DSP_AR}"     CACHE FILEPATH "" FORCE)
  set(CMAKE_${lang}_COMPILER_RANLIB "$ENV{DSP_RANLIB}" CACHE FILEPATH "" FORCE)
endforeach()
set(CMAKE_C_COMPILER_LAUNCHER   ccache)
set(CMAKE_CXX_COMPILER_LAUNCHER ccache)

set(CMAKE_SYSROOT "$ENV{DSP_SYSROOT}")
set(CMAKE_FIND_ROOT_PATH "$ENV{DSP_SYSROOT}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)

find_program(QEMU_ARM qemu-arm-static)
if(QEMU_ARM)
  set(CMAKE_CROSSCOMPILING_EMULATOR "${QEMU_ARM};-L;$ENV{DSP_SYSROOT}")
endif()
