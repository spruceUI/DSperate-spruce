# SPDX-License-Identifier: GPL-3.0-or-later
#
# Cross toolchain for the spruceOS universal aarch64 target: Ubuntu 20.04
# multiarch, glibc 2.31. We ship our own rather than use DSperate's
# cmake/aarch64-linux-gnu.cmake because that one hardcodes the unsuffixed
# compiler names and a /usr/aarch64-linux-gnu sysroot, and we want the
# ccache shims and multiarch library paths instead.

set(CMAKE_SYSTEM_NAME Linux)
# DSperate keys DSPERATE_JIT and DSPERATE_NEON off this, so it must read
# aarch64 or the cross build silently drops the recompiler and the NEON
# kernels and produces an interpreter-only binary that still runs.
set(CMAKE_SYSTEM_PROCESSOR aarch64)

# The real compilers, not a wrapper. ccache goes on as a launcher instead,
# because CMake derives the LTO archiver by looking for gcc-ar next to the
# compiler it was given: point CMAKE_CXX_COMPILER at a shim in
# /usr/local/bin and CMAKE_CXX_COMPILER_AR comes back NOTFOUND, and the
# static library link fails with "CMAKE_CXX_COMPILER_AR-NOTFOUND: not found".
set(CMAKE_C_COMPILER   "$ENV{DSP_CC}")
set(CMAKE_CXX_COMPILER "$ENV{DSP_CXX}")
set(CMAKE_C_COMPILER_LAUNCHER   ccache)
set(CMAKE_CXX_COMPILER_LAUNCHER ccache)

# DSperate builds its core as a static library with
# CMAKE_INTERPROCEDURAL_OPTIMIZATION on, so the archiver has to be the gcc
# wrapper of the matching version or the LTO plugin does not get loaded and
# the final link fails on "plugin needed to handle lto object". CMake would
# find these itself now that the compiler path is real; naming them is the
# guard against it quietly not doing so.
set(CMAKE_AR     "$ENV{DSP_AR}"     CACHE FILEPATH "" FORCE)
set(CMAKE_RANLIB "$ENV{DSP_RANLIB}" CACHE FILEPATH "" FORCE)
set(CMAKE_NM     "$ENV{DSP_NM}"     CACHE FILEPATH "" FORCE)
set(CMAKE_STRIP  "$ENV{DSP_STRIP}"  CACHE FILEPATH "" FORCE)
# These, not CMAKE_AR, are what the LTO path actually uses.
foreach(lang C CXX)
  set(CMAKE_${lang}_COMPILER_AR     "$ENV{DSP_AR}"     CACHE FILEPATH "" FORCE)
  set(CMAKE_${lang}_COMPILER_RANLIB "$ENV{DSP_RANLIB}" CACHE FILEPATH "" FORCE)
endforeach()

# Multiarch puts the arm64 libraries in /usr/lib/aarch64-linux-gnu but shares
# /usr/include with the host, so headers must be searched outside the root path.
set(CMAKE_LIBRARY_ARCHITECTURE aarch64-linux-gnu)
set(CMAKE_FIND_ROOT_PATH /usr/aarch64-linux-gnu /usr/lib/aarch64-linux-gnu)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE BOTH)

# Lets ctest run the cross-built unit tests, including the JIT and NEON ones.
find_program(QEMU_AARCH64 qemu-aarch64-static)
if(QEMU_AARCH64)
  set(CMAKE_CROSSCOMPILING_EMULATOR "${QEMU_AARCH64}")
endif()
