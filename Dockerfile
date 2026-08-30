FROM ubuntu:20.04

ENV DEBIAN_FRONTEND=noninteractive

# arm64 multiarch, so we link against focal's aarch64 libraries: glibc 2.31,
# the floor shared by every spruce aarch64 device. Upstream CI builds on
# ubuntu-24.04-arm, which floors at glibc 2.39 and will not load on any of them.
RUN dpkg --add-architecture arm64 && \
    sed -i 's/^deb http/deb [arch=amd64] http/g' /etc/apt/sources.list && \
    echo "deb [arch=arm64] http://ports.ubuntu.com/ubuntu-ports focal main restricted universe multiverse" >> /etc/apt/sources.list && \
    echo "deb [arch=arm64] http://ports.ubuntu.com/ubuntu-ports focal-updates main restricted universe multiverse" >> /etc/apt/sources.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
    build-essential \
    wget \
    apt-transport-https \
    gnupg \
    software-properties-common \
    ca-certificates \
    && wget -O - https://apt.kitware.com/keys/kitware-archive-latest.asc 2>/dev/null | apt-key add - && \
    apt-add-repository 'deb https://apt.kitware.com/ubuntu/ focal main' && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
    cmake \
    ninja-build \
    git \
    python3 \
    ccache \
    pkg-config \
    file \
    binutils-aarch64-linux-gnu \
    gcc-aarch64-linux-gnu \
    g++-aarch64-linux-gnu \
    gcc-10-aarch64-linux-gnu \
    g++-10-aarch64-linux-gnu \
    qemu-user-static \
    # DSperate links only SDL2; ALSA and Wayland are dlopen'd at runtime
    libsdl2-dev:arm64 \
    && rm -rf /var/lib/apt/lists/*

COPY toolchain-aarch64.cmake /toolchain-aarch64.cmake
COPY build.sh /build.sh
RUN chmod +x /build.sh
COPY patches/ /patches/

WORKDIR /build
ENTRYPOINT ["/build.sh"]
