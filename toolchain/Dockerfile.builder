# LineUpOS Builder Container
# Base: Alpine Linux edge (musl, latest packages)
# Tudo para build reprodutível: kernel, rust, c#, c++, node, vulkan

FROM alpine:edge AS base

# Repositórios
RUN echo "https://dl-cdn.alpinelinux.org/alpine/edge/main" > /etc/apk/repositories && \
    echo "https://dl-cdn.alpinelinux.org/alpine/edge/community" >> /etc/apk/repositories && \
    echo "https://dl-cdn.alpinelinux.org/alpine/edge/testing" >> /etc/apk/repositories

# Packages base
RUN apk update && apk add --no-cache \
    # Build tools
    build-base \
    clang \
    lld \
    llvm \
    cmake \
    meson \
    ninja \
    pkgconf \
    # Kernel
    linux-headers \
    linux-firmware \
    # Rust
    rust \
    cargo \
    rustup \
    # C# / .NET
    dotnet9-sdk \
    # Node.js (para powerup.js)
    nodejs \
    npm \
    # Vulkan / GPU
    vulkan-loader \
    vulkan-headers \
    vulkan-tools \
    shaderc \
    glslang \
    spirv-tools \
    spirv-headers \
    # Python (LineML bindings)
    python3 \
    py3-pip \
    py3-pybind11 \
    # Compression / ISO
    cpio \
    xz \
    zstd \
    xorriso \
    mtools \
    dosfstools \
    e2fsprogs \
    # QEMU (test)
    qemu-system-x86_64 \
    qemu-img \
    # Utils
    git \
    curl \
    wget \
    tar \
    gzip \
    bzip2 \
    unzip \
    python3-dev \
    linux-api-headers \
    elfutils-dev \
    zlib-dev \
    openssl-dev \
    libcap-dev \
    attr-dev \
    acl-dev \
    libarchive-tools \
    squashfs-tools \
    erofs-utils

# Rust toolchain específico
RUN rustup default stable && \
    rustup target add x86_64-unknown-linux-gnu && \
    rustup component add rust-src llvm-tools-preview

# .NET Native AOT dependencies
RUN dotnet workload install wasm-tools || true

# Python packages para LineML
RUN pip3 install --no-cache-dir --break-system-packages \
    numpy \
    torch \
    torchvision \
    torchaudio \
    safetensors \
    onnx \
    onnxruntime \
    pybind11 \
    meson-python \
    ninja

# Limine bootloader (build from source)
WORKDIR /opt
RUN git clone --depth 1 https://github.com/limine-bootloader/limine.git && \
    cd limine && \
    make -j$(nproc) && \
    make install

# Clang/LLVM para kernel build
ENV CC=clang
ENV LD=ld.lld
ENV AR=llvm-ar
ENV NM=llvm-nm
ENV OBJCOPY=llvm-objcopy
ENV OBJDUMP=llvm-objdump
ENV READELF=llvm-readelf
ENV STRIP=llvm-strip
ENV HOSTCC=clang
ENV HOSTCXX=clang++

# Kernel build optimizations
ENV KCFLAGS="-march=x86-64-v3 -mtune=generic -O2 -pipe -flto=thin"
ENV KLDFLAGS="-fuse-ld=lld -Wl,--as-needed -Wl,-z,now -Wl,-z,relro"

# Working directory
WORKDIR /src

# Entry point
ENTRYPOINT ["/bin/sh"]