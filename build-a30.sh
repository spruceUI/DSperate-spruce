#!/bin/bash
set -euo pipefail

DSPERATE_REPO="${DSPERATE_REPO:-https://github.com/beebono/DSperate.git}"
DSPERATE_VERSION="${DSPERATE_VERSION:-main}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
SKIP_TESTS="${SKIP_TESTS:-0}"
CROSS=arm-a30-linux-gnueabihf
TCDIR=/opt/a30
export DSP_SYSROOT="${TCDIR}/${CROSS}/sysroot"
export PATH="${TCDIR}/bin:$PATH"

# Allwinner A33: quad Cortex-A7, NEON/VFPv4. Left at -mcpu only; the buildroot
# toolchain already targets this device's float ABI and fpu, and overriding
# those from here is how you get a binary the sysroot's own libs disagree with.
ARCH_FLAGS="${ARCH_FLAGS:--mcpu=cortex-a7}"

# The A30 sysroot's glibc. Far below the aarch64 target's 2.31.
GLIBC_MAX="${GLIBC_MAX:-2.23}"

# ============================================================
# Toolchain
# ============================================================
export DSP_CC="${TCDIR}/bin/${CROSS}-gcc"
export DSP_CXX="${TCDIR}/bin/${CROSS}-g++"
export DSP_AR="$(command -v ${CROSS}-gcc-ar || echo ${TCDIR}/bin/${CROSS}-gcc-ar)"
export DSP_RANLIB="$(command -v ${CROSS}-gcc-ranlib || echo ${TCDIR}/bin/${CROSS}-gcc-ranlib)"
export DSP_NM="$(command -v ${CROSS}-gcc-nm || echo ${TCDIR}/bin/${CROSS}-gcc-nm)"
export DSP_STRIP="${TCDIR}/bin/${CROSS}-strip"
READELF="${TCDIR}/bin/${CROSS}-readelf"

for t in "$DSP_CC" "$DSP_CXX" "$DSP_AR" "$DSP_RANLIB" "$DSP_STRIP" "$READELF"; do
    [ -x "$t" ] || { echo "ERROR: $t not found or not executable"; exit 1; }
done
[ -d "$DSP_SYSROOT" ] || { echo "ERROR: sysroot $DSP_SYSROOT missing"; exit 1; }

export CCACHE_DIR="${CCACHE_DIR:-/ccache}"
mkdir -p "$CCACHE_DIR"
ccache --max-size=2G
ccache --zero-stats

# SDL2 2.28.5 already lives in the sysroot, so unlike the aarch64 target there
# is nothing to build first - just point pkg-config inside the sysroot.
export PKG_CONFIG_SYSROOT_DIR="$DSP_SYSROOT"
export PKG_CONFIG_LIBDIR="$DSP_SYSROOT/usr/lib/pkgconfig:$DSP_SYSROOT/usr/share/pkgconfig"
export PKG_CONFIG_PATH="$PKG_CONFIG_LIBDIR"

echo "=== Toolchain ==="
"$DSP_CXX" --version | head -1
echo "sysroot SDL2: $(pkg-config --modversion sdl2 2>/dev/null || echo '<pkg-config found no sdl2>')"

# ============================================================
# Source
# ============================================================
echo "=== Cloning DSperate (${DSPERATE_VERSION}) ==="
rm -rf /build/DSperate
git clone "$DSPERATE_REPO" /build/DSperate
cd /build/DSperate
git checkout "$DSPERATE_VERSION"
DSPERATE_SHA="$(git rev-parse HEAD)"
DSPERATE_DATE="$(git log -1 --format=%cI)"

for patch in /patches/*.patch; do
    [ -f "$patch" ] || continue
    git apply "$patch" && echo "Applied: $(basename "$patch")"
done
for patch in /patches/*.py; do
    [ -f "$patch" ] || continue
    python3 "$patch" && echo "Applied: $(basename "$patch")"
done

# ============================================================
# Configure and build
# ============================================================
COMMON_FLAGS="-O3 ${ARCH_FLAGS} -pthread"
LINK_FLAGS="-pthread -Wl,--no-as-needed -lpthread -Wl,--as-needed"
LINK_FLAGS="${LINK_FLAGS} -static-libstdc++ -static-libgcc"
# GCC's arm backend does not stream per-function target options into LTO IR the
# way the aarch64 one does, so with -flto the link step recompiles against
# whatever the LINK command names. Omit these here and the tuning is silently
# lost - or worse, a -mcpu-implied feature macro sets up builtins the relink
# then rejects.
LINK_FLAGS="${LINK_FLAGS} ${ARCH_FLAGS}"

echo "=== Configuring ==="
cmake -S . -B build -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE=/toolchain-a30.cmake \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS="$COMMON_FLAGS" \
    -DCMAKE_CXX_FLAGS="$COMMON_FLAGS" \
    -DCMAKE_EXE_LINKER_FLAGS="$LINK_FLAGS" \
    -DDSPERATE_HEADLESS=ON \
    -DDSPERATE_SDL=ON \
    -DDSPERATE_TESTS=ON

! grep -q 'COMPILER_AR:FILEPATH=.*NOTFOUND' build/CMakeCache.txt || { echo "ERROR: no LTO archiver"; exit 1; }
[ -d build/src/frontend/sdl ] || { echo "ERROR: SDL2 not found in sysroot, no SDL frontend"; exit 1; }

# The inverse of the aarch64 target's check, and just as deliberate. DSperate's
# recompiler emits AArch64 and its NEON kernels use A64-only intrinsics, so a
# 32-bit build is interpreter + portable renderer. If either of these ever turns
# ON here it means somebody added an ARM32 backend, and this script is lying
# about what it produced.
# compile_commands.json, not CMakeCache.txt: option() leaves the cache entry at
# its ON default even after CMakeLists.txt turns these off with a plain set(),
# so a cache grep answers the wrong question in both directions.
! grep -q -- '-DDSPERATE_JIT=1'  build/compile_commands.json || echo "NOTE: JIT is compiled in on a 32-bit build - an ARM32 backend exists now?"
! grep -q -- '-DDSPERATE_NEON=1' build/compile_commands.json || echo "NOTE: NEON kernels are compiled in on a 32-bit build"

echo "=== Building ==="
cmake --build build -j"$(nproc)"

if [ "$SKIP_TESTS" = "1" ]; then
    echo "=== Tests skipped (SKIP_TESTS=1) ==="
else
    echo "=== Testing under qemu-arm ==="
    ( cd build && ctest --output-on-failure )
fi

# ============================================================
# Verify the ABI floor
# ============================================================
check_floor() {
    local bin="$1" worst
    worst=$($READELF -V "$bin" 2>/dev/null | grep -oE 'GLIBC_2\.[0-9]+' | sort -uV | tail -1)
    echo "  $(basename "$bin"): max ${worst:-none}"
    [ -n "$worst" ] || return 0
    if [ "$(printf '%s\n' "GLIBC_$GLIBC_MAX" "$worst" | sort -V | tail -1)" != "GLIBC_$GLIBC_MAX" ]; then
        echo "ERROR: $(basename "$bin") needs $worst, above the GLIBC_$GLIBC_MAX floor"
        return 1
    fi
    if $READELF -V "$bin" 2>/dev/null | grep -qE 'GLIBCXX_|CXXABI_'; then
        echo "ERROR: $(basename "$bin") references libstdc++ versioned symbols"
        return 1
    fi
}
echo "=== glibc floor ==="
check_floor build/src/frontend/headless/dsperate-headless
check_floor build/src/frontend/sdl/dsperate

echo "=== Shared library dependencies ==="
for b in build/src/frontend/headless/dsperate-headless build/src/frontend/sdl/dsperate; do
    echo "  $(basename "$b"): $($READELF -d "$b" | grep NEEDED | sed 's/.*\[\(.*\)\]/\1/' | tr '\n' ' ')"
done

# ============================================================
# Package
# ============================================================
echo "=== Collecting output ==="
rm -rf "${OUTPUT_DIR:?}"/*
mkdir -p "$OUTPUT_DIR/configs"
# Upstream 1.0.0 swapped these two names round: the SDL frontend is now called
# "dsperate" and the headless one "dsperate-headless". "dsperate" in this
# tarball used to be the CLI binary and is now the one a device runs.
cp build/src/frontend/sdl/dsperate                "$OUTPUT_DIR/dsperate"
cp build/src/frontend/headless/dsperate-headless  "$OUTPUT_DIR/dsperate-headless"
"$DSP_STRIP" -s "$OUTPUT_DIR/dsperate" "$OUTPUT_DIR/dsperate-headless"
cp configs/*.ini "$OUTPUT_DIR/configs/"
cp LICENSE README.md "$OUTPUT_DIR/"

cat > "$OUTPUT_DIR/BUILD_INFO" <<EOF
upstream:   ${DSPERATE_REPO}
ref:        ${DSPERATE_VERSION}
commit:     ${DSPERATE_SHA}
committed:  ${DSPERATE_DATE}
built:      $(date -u +%Y-%m-%dT%H:%M:%SZ)
toolchain:  $("$DSP_CXX" --version | head -1) (A30 buildroot, glibc 2.23 sysroot)
glibc floor: ${GLIBC_MAX}
arch:       armhf, ${ARCH_FLAGS}
jit:        OFF  (DSperate's recompiler emits AArch64 only)
neon:       OFF  (kernels use A64-only intrinsics)
NOTE: interpreter + portable C++ renderer. Expect it to be slow.
EOF

echo "=== ccache stats ==="
ccache --show-stats | head -8
echo "=== Build complete ==="
find "$OUTPUT_DIR" -type f -printf '%10s  %P\n' | sort -k2
