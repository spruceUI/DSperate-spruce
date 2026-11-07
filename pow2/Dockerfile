FROM ubuntu:20.04

ENV DEBIAN_FRONTEND=noninteractive
ARG SDL2_VERSION=2.26.1

# focal arm64 multiarch: glibc 2.31, the spruce aarch64 floor.
RUN dpkg --add-architecture arm64 && \
    sed -i 's/^deb http/deb [arch=amd64] http/g' /etc/apt/sources.list && \
    echo "deb [arch=arm64] http://ports.ubuntu.com/ubuntu-ports focal main restricted universe multiverse" >> /etc/apt/sources.list && \
    echo "deb [arch=arm64] http://ports.ubuntu.com/ubuntu-ports focal-updates main restricted universe multiverse" >> /etc/apt/sources.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
    build-essential wget gnupg software-properties-common ca-certificates \
    && wget -O - https://apt.kitware.com/keys/kitware-archive-latest.asc 2>/dev/null | apt-key add - && \
    apt-add-repository 'deb https://apt.kitware.com/ubuntu/ focal main' && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
    cmake ninja-build git python3 rsync pkg-config file \
    binutils-aarch64-linux-gnu gcc-10-aarch64-linux-gnu g++-10-aarch64-linux-gnu \
    zlib1g-dev:arm64 libpng-dev:arm64 libgles2-mesa-dev:arm64 libegl1-mesa-dev:arm64 \
    && rm -rf /var/lib/apt/lists/*

# build-bundle.sh and parallel-rsp's toolchain file call the unsuffixed cross tools.
RUN for t in gcc g++ cpp gcc-ar gcc-nm gcc-ranlib; do \
        ln -sf /usr/bin/aarch64-linux-gnu-$t-10 /usr/bin/aarch64-linux-gnu-$t; \
    done

# Linked against, not shipped: the device supplies libSDL2. 2.26.1 is the oldest SDL2 spruce ships.
RUN cd /tmp && \
    wget -q "https://github.com/libsdl-org/SDL/releases/download/release-${SDL2_VERSION}/SDL2-${SDL2_VERSION}.tar.gz" && \
    tar xf "SDL2-${SDL2_VERSION}.tar.gz" && cd "SDL2-${SDL2_VERSION}" && \
    ./configure --host=aarch64-linux-gnu --prefix=/usr/aarch64-linux-gnu \
        --enable-shared --disable-static --disable-video-x11 --disable-video-wayland \
        --disable-video-rpi --disable-oss --disable-esd --disable-arts --disable-pulseaudio --disable-jack \
        CC=aarch64-linux-gnu-gcc CXX=aarch64-linux-gnu-g++ && \
    make -j"$(nproc)" && make install && \
    cd /tmp && rm -rf SDL2-*

COPY build.sh /build.sh
RUN chmod +x /build.sh

WORKDIR /build
ENTRYPOINT ["/build.sh"]
