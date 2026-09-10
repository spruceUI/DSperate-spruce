#!/bin/bash
set -euo pipefail

OUTPUT_DIR="${OUTPUT_DIR:-/output}"
ZLIB_VERSION="${ZLIB_VERSION:-1.3.1}"
OPENSSL_VERSION="${OPENSSL_VERSION:-1.1.1w}"
CURL_VERSION="${CURL_VERSION:-8.22.0}"
CA_BUNDLE="${CA_BUNDLE:-/mnt/SDCARD/spruce/etc/ca-certificates.crt}"
GLIBC_MAX="${GLIBC_MAX:-2.23}"

CROSS=arm-a30-linux-gnueabihf
TCDIR=/opt/a30
SYSROOT="${TCDIR}/${CROSS}/sysroot"
export PATH="${TCDIR}/bin:$PATH"
READELF="${TCDIR}/bin/${CROSS}-readelf"
STRIP="${TCDIR}/bin/${CROSS}-strip"
DEPS=/build/deps
JOBS="$(nproc)"

export CC="${CROSS}-gcc"
export CFLAGS="-mcpu=cortex-a7 -O2"
export LDFLAGS="-Wl,-rpath-link,${DEPS}/lib"
export PKG_CONFIG_PATH="${DEPS}/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="${DEPS}/lib/pkgconfig"

mkdir -p /build/src "$DEPS"
cd /build/src

echo "=== zlib ${ZLIB_VERSION} ==="
wget -q "https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/zlib-${ZLIB_VERSION}.tar.gz"
tar xzf "zlib-${ZLIB_VERSION}.tar.gz"
( cd "zlib-${ZLIB_VERSION}" && ./configure --prefix="$DEPS" && make -j"$JOBS" && make install )

echo "=== OpenSSL ${OPENSSL_VERSION} ==="
wget -q "https://github.com/openssl/openssl/releases/download/OpenSSL_${OPENSSL_VERSION//./_}/openssl-${OPENSSL_VERSION}.tar.gz"
tar xzf "openssl-${OPENSSL_VERSION}.tar.gz"
( cd "openssl-${OPENSSL_VERSION}" \
  && CC=gcc ./Configure linux-armv4 shared no-tests --prefix="$DEPS" --openssldir=/etc/ssl \
       --cross-compile-prefix="${CROSS}-" \
  && make -j"$JOBS" && make install_sw )

echo "=== curl ${CURL_VERSION} ==="
wget -q "https://github.com/curl/curl/releases/download/curl-${CURL_VERSION//./_}/curl-${CURL_VERSION}.tar.xz"
tar xJf "curl-${CURL_VERSION}.tar.xz"
( cd "curl-${CURL_VERSION}" \
  && ./configure --host="$CROSS" --prefix="$DEPS" \
       --with-openssl="$DEPS" --with-zlib="$DEPS" \
       --with-ca-bundle="$CA_BUNDLE" --with-ca-fallback \
       --enable-shared --disable-static \
       --disable-ldap --disable-ldaps --disable-rtsp --disable-manual --disable-docs \
       --without-libpsl --without-libidn2 --without-nghttp2 --without-brotli \
       --without-zstd --without-librtmp --without-libssh2 \
  && make -j"$JOBS" && make install )

echo "=== Collecting output ==="
rm -rf "${OUTPUT_DIR:?}"/*
mkdir -p "$OUTPUT_DIR"
for so in libcurl.so.4 libssl.so.1.1 libcrypto.so.1.1 libz.so.1; do
    cp -L "$DEPS/lib/$so" "$OUTPUT_DIR/$so"
    "$STRIP" -s "$OUTPUT_DIR/$so"
done

echo "=== Verify ==="
for so in "$OUTPUT_DIR"/*.so*; do
    file "$so" | grep -q 'ARM, EABI5' || { echo "ERROR: $(basename "$so") is not armhf"; exit 1; }
    worst=$($READELF -V "$so" | grep -oE 'GLIBC_2\.[0-9]+' | sort -uV | tail -1)
    if [ "$(printf '%s\n' "GLIBC_$GLIBC_MAX" "$worst" | sort -V | tail -1)" != "GLIBC_$GLIBC_MAX" ]; then
        echo "ERROR: $(basename "$so") needs $worst, above the GLIBC_$GLIBC_MAX floor"; exit 1
    fi
    echo "  $(basename "$so"): $worst, NEEDED $($READELF -d "$so" | grep NEEDED | sed 's/.*\[\(.*\)\]/\1/' | tr '\n' ' ')"
done
$READELF -d "$OUTPUT_DIR/libcurl.so.4" | grep -q 'libssl.so.1.1' || { echo "ERROR: libcurl is not linked against OpenSSL 1.1"; exit 1; }

echo "=== curl --version under qemu-arm ==="
qemu-arm-static -L "$SYSROOT" -E LD_LIBRARY_PATH="$DEPS/lib" "$DEPS/bin/curl" --version | tee "$OUTPUT_DIR/curl-version.txt"
