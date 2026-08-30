#!/bin/bash
set -euo pipefail

DSPERATE_REPO="${DSPERATE_REPO:-https://github.com/beebono/DSperate.git}"
DSPERATE_VERSION="${DSPERATE_VERSION:-main}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
SKIP_TESTS="${SKIP_TESTS:-0}"
CROSS_GCC="${CROSS_GCC:-10}"
CROSS=aarch64-linux-gnu

# Every spruce aarch64 device is a Cortex-A53 (H700) or Cortex-A55 (RK3566,
# A133P, TrimUI). -mtune only changes instruction scheduling, never the
# instruction set, so the binary stays generic ARMv8-A and runs on both.
ARCH_FLAGS="${ARCH_FLAGS:--mtune=cortex-a55}"

# The glibc the oldest spruce aarch64 device ships. Anything above this and
# the binary will not load on device, which is the whole reason this repo
# exists rather than just using upstream's release.
GLIBC_MAX="${GLIBC_MAX:-2.31}"

# ============================================================
# Toolchain
# ============================================================
for t in gcc-${CROSS_GCC} g++-${CROSS_GCC} gcc-ar-${CROSS_GCC} gcc-ranlib-${CROSS_GCC} gcc-nm-${CROSS_GCC} strip readelf; do
    command -v "${CROSS}-${t}" >/dev/null || { echo "ERROR: ${CROSS}-${t} not found"; exit 1; }
done

export DSP_AR="$(command -v ${CROSS}-gcc-ar-${CROSS_GCC})"
export DSP_RANLIB="$(command -v ${CROSS}-gcc-ranlib-${CROSS_GCC})"
export DSP_NM="$(command -v ${CROSS}-gcc-nm-${CROSS_GCC})"
export DSP_STRIP="$(command -v ${CROSS}-strip)"
READELF="${CROSS}-readelf"

# ccache through named shims rather than the /usr/lib/ccache symlinks, so the
# version-suffixed cross compiler is unambiguous.
export CCACHE_DIR="${CCACHE_DIR:-/ccache}"
mkdir -p "$CCACHE_DIR"
for pair in "cc:gcc" "cxx:g++"; do
    shim="/usr/local/bin/dsp-${pair%%:*}"
    printf '#!/bin/sh\nexec ccache %s-%s-%s "$@"\n' "$CROSS" "${pair##*:}" "$CROSS_GCC" > "$shim"
    chmod +x "$shim"
done
export DSP_CC=/usr/local/bin/dsp-cc
export DSP_CXX=/usr/local/bin/dsp-cxx
ccache --max-size=2G
ccache --zero-stats

# pkg-config must see the arm64 multiarch .pc files, not the host's.
export PKG_CONFIG_PATH=/usr/lib/${CROSS}/pkgconfig
export PKG_CONFIG_LIBDIR=/usr/lib/${CROSS}/pkgconfig
export PKG_CONFIG_SYSROOT_DIR=

echo "=== Toolchain ==="
"$DSP_CXX" --version | head -1
cmake --version | head -1

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
echo "Building ${DSPERATE_SHA} (${DSPERATE_DATE})"

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
# -pthread: DSperate uses std::thread but never links Threads::Threads.
# Upstream CI never notices because glibc 2.34+ folded libpthread into libc;
# on our 2.31 target the symbols live in libpthread.so.0 and have to be asked
# for. --no-as-needed because CMake puts linker flags ahead of the objects
# that reference them, and as-needed would then drop the library.
COMMON_FLAGS="-O3 ${ARCH_FLAGS} -pthread"
LINK_FLAGS="-pthread -Wl,--no-as-needed -lpthread -Wl,--as-needed"
# The device's libstdc++ is older than this toolchain's on several targets,
# so carry ours. glibc stays dynamic — it is the floor we are matching.
LINK_FLAGS="${LINK_FLAGS} -static-libstdc++ -static-libgcc"
# The core is built with LTO, which recompiles at link time against whatever
# the link command names, so the arch flags have to be repeated here.
LINK_FLAGS="${LINK_FLAGS} ${ARCH_FLAGS}"
LINK_FLAGS="${LINK_FLAGS} -L/usr/lib/${CROSS} -Wl,-rpath-link,/usr/lib/${CROSS}"

echo "=== Configuring ==="
cmake -S . -B build -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE=/toolchain-aarch64.cmake \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS="$COMMON_FLAGS" \
    -DCMAKE_CXX_FLAGS="$COMMON_FLAGS" \
    -DCMAKE_EXE_LINKER_FLAGS="$LINK_FLAGS" \
    -DDSPERATE_JIT=ON \
    -DDSPERATE_NEON=ON \
    -DDSPERATE_CLI=ON \
    -DDSPERATE_SDL=ON \
    -DDSPERATE_TESTS=ON

# A configure that quietly fell back to the interpreter would still produce a
# working binary, just a slow one with nothing in any log to say why.
grep -q '^DSPERATE_JIT:BOOL=ON'  build/CMakeCache.txt || { echo "ERROR: JIT disabled by configure"; exit 1; }
grep -q '^DSPERATE_NEON:BOOL=ON' build/CMakeCache.txt || { echo "ERROR: NEON disabled by configure"; exit 1; }
[ -d build/src/frontend/sdl ] || { echo "ERROR: SDL2 not found, no SDL frontend"; exit 1; }

echo "=== Building ==="
cmake --build build -j"$(nproc)"

# ============================================================
# Test (cross-built binaries under qemu-user)
# ============================================================
if [ "$SKIP_TESTS" = "1" ]; then
    echo "=== Tests skipped (SKIP_TESTS=1) ==="
else
    echo "=== Testing under qemu-aarch64 ==="
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
        echo "ERROR: $(basename "$bin") references libstdc++ versioned symbols; -static-libstdc++ did not take"
        return 1
    fi
}

echo "=== glibc floor ==="
check_floor build/src/frontend/cli/dsperate
check_floor build/src/frontend/sdl/dsperate-sdl

echo "=== Shared library dependencies ==="
for b in build/src/frontend/cli/dsperate build/src/frontend/sdl/dsperate-sdl; do
    echo "  $(basename "$b"): $($READELF -d "$b" | grep NEEDED | sed 's/.*\[\(.*\)\]/\1/' | tr '\n' ' ')"
done

# ============================================================
# Package
# ============================================================
echo "=== Collecting output ==="
rm -rf "$OUTPUT_DIR"/*
mkdir -p "$OUTPUT_DIR/libs" "$OUTPUT_DIR/configs"

cp build/src/frontend/cli/dsperate     "$OUTPUT_DIR/"
cp build/src/frontend/sdl/dsperate-sdl "$OUTPUT_DIR/"
"$DSP_STRIP" -s "$OUTPUT_DIR/dsperate" "$OUTPUT_DIR/dsperate-sdl"

cp configs/*.ini "$OUTPUT_DIR/configs/"
cp LICENSE README.md "$OUTPUT_DIR/"

# Anything the device is known to provide stays out of the tarball — bundling
# a second copy only shadows a perfectly good system library.
SKIP_LIBS="linux-vdso|ld-linux|libc\.so|libm\.so|libdl\.so|libpthread\.so|librt\.so|libgcc_s|libstdc\+\+|libSDL2|libasound|libudev|libdrm|libwayland|libEGL|libGLES|libmali|libz\.so|libgomp|libvulkan"

collect_deps() {
    local binary="$1"
    $READELF -d "$binary" 2>/dev/null | grep NEEDED | sed 's/.*\[\(.*\)\]/\1/' | while read -r lib; do
        [ -f "$OUTPUT_DIR/libs/$lib" ] && continue
        echo "$lib" | grep -qE "$SKIP_LIBS" && continue
        local src
        src=$(find "/usr/lib/${CROSS}" "/lib/${CROSS}" -maxdepth 1 -name "$lib" 2>/dev/null | head -1)
        if [ -n "$src" ]; then
            cp -L "$src" "$OUTPUT_DIR/libs/$lib"
            echo "  Collected: $lib"
            collect_deps "$OUTPUT_DIR/libs/$lib"
        else
            echo "  WARNING: $lib not found"
        fi
    done
}
collect_deps "$OUTPUT_DIR/dsperate"
collect_deps "$OUTPUT_DIR/dsperate-sdl"
for so in "$OUTPUT_DIR"/libs/*.so*; do
    [ -f "$so" ] || continue
    "$DSP_STRIP" -s "$so" 2>/dev/null || true
done
rmdir "$OUTPUT_DIR/libs" 2>/dev/null || true

cat > "$OUTPUT_DIR/BUILD_INFO" <<EOF
upstream:   ${DSPERATE_REPO}
ref:        ${DSPERATE_VERSION}
commit:     ${DSPERATE_SHA}
committed:  ${DSPERATE_DATE}
built:      $(date -u +%Y-%m-%dT%H:%M:%SZ)
toolchain:  $("$DSP_CXX" --version | head -1) (Ubuntu 20.04 multiarch)
glibc floor: ${GLIBC_MAX}
flags:      ${COMMON_FLAGS}
EOF

echo "=== ccache stats ==="
ccache --show-stats

echo "=== Build complete ==="
find "$OUTPUT_DIR" -type f -printf '%10s  %P\n' | sort -k2
