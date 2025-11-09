FROM node:22-trixie-slim AS base
SHELL ["/bin/bash", "-c"]

# Install dependencies
RUN apt update -qq && apt install -y --no-install-recommends --no-install-suggests \
      openssl \
      python3 \
      python3-pip \
      ca-certificates \
      gnupg \
      gosu \
      curl && \
    gosu nobody true && \
    rm -rf /var/lib/apt/lists/* && \
    rm -rf /var/cache/apt/* && \
    rm -vrf /usr/share/doc/* && \
    rm -vrf /usr/share/man/* && \
    rm -vrf /usr/local/share/doc/* && \
    rm -vrf /usr/local/share/man/*

# Node images hardcode the node uid to 1000 so that number is not available.
# The "peertube" user is created as a system account which selects a UID from
# the range of SYS_UID_MIN to SYS_UID_MAX (-1 to 1000] and consistently
# selects 999 given the current image build steps. The same is true for the
# system group range SYS_GID_MIN and SYS_GID_MAX. It is fine to manually assign
# them an ID outside of that range.
ENV DEFAULT_PEERTUBE_UID=999
ENV DEFAULT_PEERTUBE_GID=999

# Add peertube user
RUN groupadd -r -g ${PEERTUBE_GID:-${DEFAULT_PEERTUBE_GID}} peertube && \
    useradd -r -u ${PEERTUBE_UID:-${DEFAULT_PEERTUBE_UID}} -g peertube -m peertube && \
    mkdir /app && chown peertube:peertube /app

# Build ffmpeg for rockchip
FROM base AS ffmpeg
ARG WORKDIR='/tmp'
WORKDIR "${WORKDIR}"

# Install deps
RUN sed -i 's|main|main non-free non-free-firmware|' /etc/apt/sources.list.d/debian.sources && \
    apt update -qq && apt install -y --no-install-recommends --no-install-suggests\
      autoconf \
      automake \
      build-essential \
      cmake \
      git-core \
      libass-dev \
      libfreetype6-dev \
      libgnutls28-dev \
      libmp3lame-dev \
      libtool \
      meson \
      ninja-build \
      pkg-config \
      texinfo \
      wget \
      yasm \
      nasm \
      zlib1g-dev \
      libvpx-dev \
      libfdk-aac-dev \
      libdav1d-dev \
      libx264-dev \
      libx265-dev \
      libnuma-dev \
      libopus-dev \
      libaom-dev \
      libva-dev \
      libvdpau-dev \
      libvorbis-dev \
      libxcb1-dev \
      libxcb-shm0-dev \
      libxcb-xfixes0-dev \
      libdrm-dev && \
    rm -vrf /usr/share/doc/* && \
    rm -vrf /usr/share/man/* && \
    rm -vrf /usr/local/share/doc/* && \
    rm -vrf /usr/local/share/man/*

# Build MPP
RUN mkdir -p build && cd build && \
    git clone -b jellyfin-mpp --depth=1 https://github.com/nyanmisaka/mpp.git rkmpp && \
    pushd rkmpp && \
    mkdir rkmpp_build && \
    pushd rkmpp_build && \
    cmake \
      -DCMAKE_INSTALL_PREFIX=/usr/local \
      -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_SHARED_LIBS=ON \
      -DBUILD_TEST=OFF \
      .. && \
    make -j $(nproc) && \
    make install && \
# Build RGA
    cd ${WORKDIR}/build && \
    git clone -b jellyfin-rga --depth=1 https://github.com/nyanmisaka/rk-mirrors.git rkrga && \
    meson setup rkrga rkrga_build \
      --prefix=/usr/local \
      --libdir=lib \
      --buildtype=release \
      --default-library=shared \
      -Dcpp_args=-fpermissive \
      -Dlibdrm=false \
      -Dlibrga_demo=false && \
    meson configure rkrga_build && \
    ninja -C rkrga_build install && \
# Build ffmpeg
    git clone --depth=1 https://github.com/nyanmisaka/ffmpeg-rockchip.git ffmpeg && \
    cd ffmpeg && \
    echo '6.1.1' > VERSION && \
    ./configure \
      --prefix=/usr/local \
      --extra-libs="-lpthread -lm" \
      --extra-version=2+b1 \
      --disable-ffplay \
      --enable-gnutls \
      --enable-gpl \
      --enable-nonfree \
      --enable-libass \
      --enable-libfreetype \
      --enable-libfdk-aac \
      --enable-libvpx \
      --enable-libdav1d \
      --enable-libx264 \
      --enable-libx265 \
      --enable-libmp3lame \
      --enable-libaom \
      --enable-version3 \
      --enable-libdrm \
      --enable-rkmpp \
      --enable-rkrga && \
    make -j $(nproc) && \
    make install

FROM base AS build

ARG ALREADY_BUILT=0
ARG PEERTUBE_VERSION=develop
ARG WORKDIR='/app'

# Install PeerTube
WORKDIR ${WORKDIR}

COPY --from=ffmpeg /usr/local/ /usr/local/
RUN apt update -qq && apt install -y --no-install-recommends --no-install-suggests \
      git \
      build-essential

USER peertube

RUN git clone https://github.com/Chocobozzz/PeerTube.git /app && \
    git checkout ${PEERTUBE_VERSION} && \
    cp -rf ./support/docker/production ./ && \
    rm -rf .git .github .gitignore .gitpod.yml support

# Install manually client dependencies to apply our network timeout option
RUN for file in $(grep -r '=\${scaleFilterValue}'|cut -d: -f1 | sort -u);do \
      sed -i 's|=\${scaleFilterValue}|:\${scaleFilterValue}|' $file; \
    done && \
    for file in $(grep -r 'pix_fmt' packages | cut -d: -f1 | sort -u ); do \
      sed -i '/pix_fmt/d' $file ; \
    done && \
    if [ "${ALREADY_BUILT}" = 0 ]; then \
      npm run install-node-dependencies -- --network-timeout 1200000 && \
      npm run build; \
    else \
      echo "Do not build application inside Docker because of ALREADY_BUILT build argument"; \
    fi; \
    rm -rf ./node_modules ./client/node_modules ./client/.angular && \
    NOCLIENT=1 npm run install-node-dependencies -- --production --network-timeout 1200000 --network-concurrency 20 && \
    yarn cache clean

FROM base AS target

ARG WORKDIR='/app'
WORKDIR ${WORKDIR}

COPY --from=build /app /app
COPY --from=build /usr/local /usr/local

USER root

# Install dependencies for work ffmpeg
RUN sed -i 's|main|main non-free non-free-firmware|' /etc/apt/sources.list.d/debian.sources && \
    apt update && apt install -y --no-install-recommends --no-install-suggests \
      libva2 \
      libva-drm2 \
      libva-x11-2 \
      libfdk-aac2 \
      libaom3 \    
      libdav1d7 && \
    apt install -y \
      libass9 \    
      libmp3lame0 \
      libvpx9 \    
      libx264-164 \
      libx265-215 \
      libvdpau1 \
      libxcb-shape0 \
      libxcb-shm0 && \  
    rm -rf /var/lib/apt/lists/* && \
    rm -rf /var/cache/apt/* && \
    rm -vrf /usr/share/doc/* && \
    rm -vrf /usr/share/man/* && \
    rm -vrf /usr/local/share/doc/* && \
    rm -vrf /usr/local/share/man/* && \
    mkdir /data /config && \
    chown -R peertube:peertube /data /config && \
    cp ./production/entrypoint.sh /usr/local/bin/entrypoint.sh

ENV NODE_ENV=production
ENV NODE_CONFIG_DIR=/app/config:/app/production/config:/config
ENV PEERTUBE_LOCAL_CONFIG=/config

VOLUME /data
VOLUME /config

ENTRYPOINT [ "/usr/local/bin/entrypoint.sh" ]

# Expose API, RTMP and RTMPS ports
EXPOSE 9000 1935 1936

# Run the application
CMD [ "node", "dist/server" ]
