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

# A patch that no longer applies is fatal. It used to be written as
# `cmd && echo Applied:`, where set -e does not fire because the failure is on
# the left of &&, so a drifted patch produced a green build with the feature
# silently missing from the binary. Every patch here is required; none is
# optional, so there is nothing to be lenient about.
for patch in /patches/*.patch; do
    [ -f "$patch" ] || continue
    git apply "$patch" || { echo "ERROR: $(basename "$patch") did not apply"; exit 1; }
    echo "Applied: $(basename "$patch")"
done
for patch in /patches/*.py; do
    [ -f "$patch" ] || continue
    python3 "$patch" || { echo "ERROR: $(basename "$patch") did not apply"; exit 1; }
    echo "Applied: $(basename "$patch")"
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

# Upstream 1.6.0 grew a Wayland dmabuf scanout tier and builds it whenever the
# SDL2 it compiles against has wayland in it. The A30 sysroot's SDL2 has none,
# so upstream's own configure check would drop the tier here anyway - but say
# it outright rather than lean on a probe, same as the aarch64 target.
echo "=== Configuring ==="
cmake -S . -B build -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE=/toolchain-a30.cmake \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS="$COMMON_FLAGS" \
    -DCMAKE_CXX_FLAGS="$COMMON_FLAGS" \
    -DCMAKE_EXE_LINKER_FLAGS="$LINK_FLAGS" \
    -DDSPERATE_HEADLESS=ON \
    -DDSPERATE_SDL=ON \
    -DDSPERATE_WAYLAND=OFF \
    -DDSPERATE_TESTS=ON

! grep -q 'COMPILER_AR:FILEPATH=.*NOTFOUND' build/CMakeCache.txt || { echo "ERROR: no LTO archiver"; exit 1; }
[ -d build/src/frontend/sdl ] || { echo "ERROR: SDL2 not found in sysroot, no SDL frontend"; exit 1; }

# What this target actually got, read rather than assumed. It used to be
# assumed: the script hardcoded "jit: OFF / neon: OFF / expect it to be slow"
# in BUILD_INFO on the reasoning that the recompiler emits AArch64 and the NEON
# kernels use A64-only intrinsics. Upstream then wrote an ARM32 backend
# (src/core/cpu/jit/a32) and an ARMv7-expressible kernel subset, so the tarball
# shipped a build with a recompiler in it while its own BUILD_INFO called it an
# interpreter. Derive both, and let BUILD_INFO say whatever is true.
# compile_commands.json, not CMakeCache.txt: option() leaves the cache entry at
# its ON default even after CMakeLists.txt turns these off with a plain set(),
# so a cache grep answers the wrong question in both directions.
if grep -q -- '-DDSPERATE_JIT=1' build/compile_commands.json; then
    JIT_STATE="ON   (upstream's ARM32 backend)"
    _cpu="recompiler"
else
    JIT_STATE="OFF  (no ARM32 backend in this revision)"
    _cpu="interpreter"
fi
if grep -q -- '-DDSPERATE_NEON=1' build/compile_commands.json; then
    NEON_STATE="ON   (the ARMv7-expressible kernel subset)"
    _gpu="NEON-subset renderer"
else
    NEON_STATE="OFF  (kernels use A64-only intrinsics)"
    _gpu="portable C++ renderer"
fi
SPEED_NOTE="NOTE: ${_cpu} + ${_gpu}."
# An if, not `[ ... ] && assign`: that list's exit status is the test's, and
# set -e kills the script on the build where the test is false.
if [ "$_cpu" = "interpreter" ]; then
    SPEED_NOTE="${SPEED_NOTE} Expect it to be slow."
fi
echo "jit: ${JIT_STATE}"
echo "neon: ${NEON_STATE}"

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
jit:        ${JIT_STATE}
neon:       ${NEON_STATE}
${SPEED_NOTE}
EOF

echo "=== ccache stats ==="
ccache --show-stats | head -8
echo "=== Build complete ==="
find "$OUTPUT_DIR" -type f -printf '%10s  %P\n' | sort -k2
