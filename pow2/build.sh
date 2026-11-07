#!/bin/bash
set -euo pipefail

POW2_REPO="${POW2_REPO:-https://github.com/beebono/mupen64plus-pow2.git}"
POW2_VERSION="${POW2_VERSION:-devel}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
GLIBC_MAX="${GLIBC_MAX:-2.31}"
X=aarch64-linux-gnu-

echo "=== Toolchain ==="
${X}gcc --version | head -1
cmake --version | head -1

echo "=== Cloning mupen64plus-pow2 (${POW2_VERSION}) ==="
git clone "$POW2_REPO" /build/pow2
cd /build/pow2
git checkout "$POW2_VERSION"
git submodule update --init --recursive
POW2_SHA="$(git rev-parse HEAD)"
echo "Building ${POW2_SHA}"

echo "=== Building ==="
SDL2_LIBDIR=/usr/aarch64-linux-gnu/lib bundle/build-bundle.sh aarch64 /build/out

bin=/build/out/mupen64plus-pow2
echo "=== ABI check ==="
file "$bin"
file "$bin" | grep -q aarch64 || { echo "FAIL: not aarch64"; exit 1; }
worst=$(${X}objdump -T "$bin" | grep -oE 'GLIBC_2\.[0-9]+' | sort -uV | tail -1 || true)
echo "Newest glibc symbol: ${worst:-none} (maximum GLIBC_$GLIBC_MAX)"
if [ -n "$worst" ] && [ "$(printf '%s\n' "GLIBC_$GLIBC_MAX" "$worst" | sort -V | tail -1)" != "GLIBC_$GLIBC_MAX" ]; then
    echo "FAIL: needs $worst"
    exit 1
fi
if ${X}objdump -T "$bin" | grep -qE 'GLIBCXX_|CXXABI_'; then
    echo "FAIL: dynamic libstdc++ symbols"
    exit 1
fi

echo "=== Packaging ==="
mkdir -p "$OUTPUT_DIR/data"
cp "$bin" "$OUTPUT_DIR/"
cp ext/mupen64plus-core-dento/data/mupen64plus.ini ext/mupen64plus-core-dento/data/mupencheat.txt "$OUTPUT_DIR/data/"
cp -r LICENSES NOTICE README.md "$OUTPUT_DIR/"
cat > "$OUTPUT_DIR/BUILD_INFO" <<INFO
repo: $POW2_REPO
ref: $POW2_VERSION
commit: $POW2_SHA
toolchain: $(${X}gcc --version | head -1)
glibc max: ${worst:-none}
INFO
echo "NEEDED: $(${X}readelf -d "$bin" | awk '/NEEDED/{print $5}' | tr -d '[]' | tr '\n' ' ')"
