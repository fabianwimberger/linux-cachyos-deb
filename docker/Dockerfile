FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive

# "distro" uses the clang in the Ubuntu archive, which is what /usr/bin/clang
# points at on every target machine — DKMS calls that binary, so a newer
# toolchain here makes every out-of-tree module fail to build. A number
# installs that release from apt.llvm.org instead.
ARG LLVM_VERSION=distro

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl gnupg \
 && if [ "$LLVM_VERSION" = distro ]; then \
      apt-get install -y --no-install-recommends clang lld llvm; \
    else \
      install -d /etc/apt/keyrings \
      && curl -fsSL https://apt.llvm.org/llvm-snapshot.gpg.key -o /etc/apt/keyrings/llvm.asc \
      && . /etc/os-release \
      && echo "deb [signed-by=/etc/apt/keyrings/llvm.asc] http://apt.llvm.org/$VERSION_CODENAME/ llvm-toolchain-$VERSION_CODENAME-$LLVM_VERSION main" \
           > /etc/apt/sources.list.d/llvm.list \
      && apt-get update \
      && apt-get install -y --no-install-recommends \
           "clang-$LLVM_VERSION" "lld-$LLVM_VERSION" "llvm-$LLVM_VERSION" \
      && for t in clang clang++ ld.lld llvm-ar llvm-nm llvm-objcopy llvm-objdump llvm-readelf llvm-strip; do \
           ln -sf "/usr/bin/$t-$LLVM_VERSION" "/usr/bin/$t"; \
         done; \
    fi \
 && apt-get install -y --no-install-recommends \
      bc bison flex build-essential \
      cpio dwarves kmod libdw-dev libelf-dev libssl-dev \
      dpkg-dev debhelper fakeroot apt-utils gcc-x86-64-linux-gnu \
      python3 rsync tar xz-utils zstd \
 && rm -rf /var/lib/apt/lists/*

# Keep hostnames and usernames out of the build stamp.
ENV KBUILD_BUILD_USER=linux-cachyos-deb \
    KBUILD_BUILD_HOST=builder

WORKDIR /work
