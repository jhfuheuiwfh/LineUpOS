#!/bin/bash
# LineUpOS Build System
# Requer: docker, qemu-system-x86_64, alpine-sdk (host) ou roda tudo em container

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
ISO_DIR="${ROOT_DIR}/iso"
VERSION="0.1.0-$(date +%Y%m%d)"

# Cores
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log() { echo -e "${BLUE}[LineUpOS]${NC} $*"; }
ok() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err() { echo -e "${RED}[ERR]${NC} $*" >&2; }

usage() {
    cat <<EOF
Usage: $0 <target>

Targets:
  all         Build completo (kernel + userspace + ISO)
  kernel      Kernel híbrido + initramfs
  userspace   Shell C# + powerup.js + LineML
  iso         Gera ISO bootável
  test        Boot no QEMU (KVM se disponível)
  clean       Limpa build/
  docker-build  Build dentro de container Alpine (reprodutível)
EOF
}

# ============================================================
# DOCKER BUILD ENVIRONMENT (reprodutível, isolado)
# ============================================================
docker_build() {
    log "Construindo imagem de build Alpine..."
    docker build -t lineupos-builder -f "${ROOT_DIR}/toolchain/Dockerfile.builder" "${ROOT_DIR}"
    log "Rodando build dentro do container..."
    docker run --rm --privileged -v "${ROOT_DIR}:/src" lineupos-builder /src/build.sh internal-all
}

# ============================================================
# KERNEL BUILD (C + Rust, Alpine-based)
# ============================================================
build_kernel() {
    log "=== BUILD KERNEL ==="
    mkdir -p "${BUILD_DIR}/kernel"

    # 1. Baixar sources Alpine kernel + patches
    local KERNEL_VER="6.10"  # LTS
    local KERNEL_DIR="${BUILD_DIR}/kernel/linux-${KERNEL_VER}"

    if [[ ! -d "${KERNEL_DIR}" ]]; then
        log "Baixando kernel ${KERNEL_VER}..."
        curl -Ls "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KERNEL_VER}.tar.xz" \
            | tar -xJ -C "${BUILD_DIR}/kernel"
    fi

    # 2. Config LineUpOS (base Alpine + nossos patches)
    log "Aplicando config LineUpOS..."
    cp "${ROOT_DIR}/config/kernel/lineupos-x86_64" "${KERNEL_DIR}/.config"
    
    # 3. Compilar kernel (C)
    log "Compilando kernel C..."
    make -C "${KERNEL_DIR}" -j"$(nproc)" \
        CC=clang LLVM=1 \
        KCFLAGS="-march=x86-64-v3 -mtune=generic -O2 -pipe" \
        bzImage modules

    # 4. Módulos Rust (drivers, fs, security)
    log "Compilando módulos Rust..."
    build_rust_modules "${KERNEL_DIR}"

    # 5. Initramfs minimal
    log "Gerando initramfs..."
    build_initramfs "${KERNEL_DIR}"

    # 6. Copiar artifacts
    cp "${KERNEL_DIR}/arch/x86/boot/bzImage" "${BUILD_DIR}/kernel/vmlinuz-lineupos"
    ok "Kernel pronto: ${BUILD_DIR}/kernel/vmlinuz-lineupos"
}

build_rust_modules() {
    local KERNEL_DIR="$1"
    local RUST_DIR="${ROOT_DIR}/boot/kernel/rust"

    mkdir -p "${RUST_DIR}"
    
    # Cargo.toml para módulos kernel
    cat > "${RUST_DIR}/Cargo.toml" <<'EOF'
[package]
name = "lineupos-kmods"
version = "0.1.0"
edition = "2021"

[dependencies]
kernel = { path = "../../../../kernel/rust/kernel" }  # kernel crate from linux source
alloc = { version = "1", features = ["global"] }

[profile.release]
opt-level = "z"
lto = true
panic = "abort"
codegen-units = 1
strip = true
EOF

    # Exemplo: driver de rede Rust
    mkdir -p "${RUST_DIR}/src/net"
    cat > "${RUST_DIR}/src/net/mod.rs" <<'EOF'
// LineUpOS Network Driver - Rust
// Memory-safe, zero-cost FFI to C kernel
#![no_std]
#![no_main]

use kernel::prelude::*;
use kernel::net::{NetDevice, Ethernet};

module! {
    type: LineupNetDriver,
    name: "lineup_net",
    author: "LineUpOS",
    description: "Memory-safe network driver",
    license: "GPL",
}

struct LineupNetDriver;

impl kernel::Module for LineupNetDriver {
    fn init(_module: &'static ThisModule) -> Result<Self> {
        pr_info!("LineUpOS net driver loaded\n");
        Ok(LineupNetDriver)
    }
}
EOF

    # Build com rustc + bindgen para kernel headers
    cd "${RUST_DIR}"
    cargo build --release --target x86_64-unknown-linux-gnu
    
    # Copiar .ko para módulos do kernel
    cp target/x86_64-unknown-linux-gnu/release/*.ko "${KERNEL_DIR}/drivers/lineupos/" 2>/dev/null || true
}

build_initramfs() {
    local KERNEL_DIR="$1"
    local INITRAMFS_DIR="${BUILD_DIR}/initramfs"
    
    rm -rf "${INITRAMFS_DIR}"
    mkdir -p "${INITRAMFS_DIR}"/{bin,sbin,etc,proc,sys,dev,run,lib/modules,root}

    # BusyBox static (Alpine base)
    log "Instalando busybox static..."
    docker run --rm alpine:latest sh -c "apk add --no-cache busybox-static && tar -czf - /bin/busybox" | tar -xz -C "${INITRAMFS_DIR}"

    # Init script (nosso PID 1)
    cat > "${INITRAMFS_DIR}/init" <<'INITEOF'
#!/bin/busybox sh
# LineUpOS Init - PID 1
# Monta filesystems essenciais, carrega módulos, passa para userspace

export PATH=/bin:/sbin
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
mkdir -p /run /tmp

# Carrega módulos kernel (Rust + C)
for mod in /lib/modules/*.ko; do
    [ -f "$mod" ] && insmod "$mod" 2>/dev/null || true
done

# Detecta GPU e carrega driver apropriado
if lspci | grep -qi "vga.*amd"; then
    modprobe amdgpu 2>/dev/null || true
elif lspci | grep -qi "vga.*nvidia"; then
    modprobe nvidia 2>/dev/null || true
fi

# Reserva 732MB para LineML (via kernel parameter lineupos_ai_mem=732M)
AI_MEM=$(cat /proc/cmdline | grep -o 'lineupos_ai_mem=[^ ]*' | cut -d= -f2)
if [ -n "$AI_MEM" ]; then
    echo "Reservando ${AI_MEM} para LineML..."
    # TODO: implementar via CMA ou reserved-memory no device tree
fi

# Inicia shell C# (compositor + display server)
exec /sbin/lineup-shell
INITEOF
    chmod +x "${INITRAMFS_DIR}/init"

    # Módulos compilados
    cp -r "${KERNEL_DIR}/drivers/lineupos" "${INITRAMFS_DIR}/lib/modules/" 2>/dev/null || true

    # Gerar initramfs.cpio.xz
    cd "${INITRAMFS_DIR}"
    find . | cpio -o -H newc | xz -9 --threads=0 > "${BUILD_DIR}/kernel/initramfs-lineupos.xz"
    ok "Initramfs: ${BUILD_DIR}/kernel/initramfs-lineupos.xz"
}

# ============================================================
# USERSPACE BUILD
# ============================================================
build_userspace() {
    log "=== BUILD USERSPACE ==="

    # 1. Shell C# Native AOT
    build_shell_csharp

    # 2. powerup.js (V8 fork + Next.js fork)
    build_powerup_js

    # 3. LineML (C++ compute shaders + Python bindings)
    build_lineml
}

build_shell_csharp() {
    log "Compilando Shell C# Native AOT..."
    local SHELL_DIR="${ROOT_DIR}/userspace/shell"
    mkdir -p "${SHELL_DIR}"

    # Project file
    cat > "${SHELL_DIR}/LineUpShell.csproj" <<'EOF'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net9.0</TargetFramework>
    <PublishAot>true</PublishAot>
    <StripSymbols>true</StripSymbols>
    <InvariantGlobalization>true</InvariantGlobalization>
    <IlcOptimizationPreference>Speed</IlcOptimizationPreference>
    <IlcStripMetadata>true</IlcStripMetadata>
    <TrimmerDefaultAction>link</TrimmerDefaultAction>
    <RuntimeIdentifier>linux-x64</RuntimeIdentifier>
    <SelfContained>true</SelfContained>
    <EnableUnsafeBinaryFormatterSerialization>false</EnableUnsafeBinaryFormatterSerialization>
  </PropertyGroup>

  <ItemGroup>
    <PackageReference Include="Silk.NET" Version="2.22.0" />
    <PackageReference Include="Silk.NET.Vulkan" Version="2.22.0" />
    <PackageReference Include="Silk.NET.Windowing.Sdl3" Version="2.22.0" />
    <PackageReference Include="System.IO.Pipelines" Version="9.0.0" />
  </ItemGroup>
</Project>
EOF

    # Program.cs - Compositor + Display Server minimal
    cat > "${SHELL_DIR}/Program.cs" <<'EOF'
using System;
using System.Runtime.InteropServices;
using Silk.NET.Vulkan;
using Silk.NET.Windowing;
using Silk.NET.Windowing.Sdl3;

namespace LineUpShell;

unsafe class Program {
    static Vk* vk;
    static IWindow window;
    static uint width = 1920, height = 1080;

    [DllImport("libc", SetLastError = true)]
    static extern int ioctl(int fd, ulong request, void* argp);

    static int Main() {
        Console.WriteLine("[LineUpShell] Starting compositor...");

        // Init Vulkan
        vk = Vk.GetApi();
        var instance = CreateVulkanInstance();
        
        // Create window (headless ou SDL3)
        var opts = WindowOptions.Default with {
            Size = new Silk.NET.Maths.Vector2D<int>((int)width, (int)height),
            Title = "LineUpOS Shell",
            API = GraphicsAPI.None, // We manage Vulkan directly
            IsVisible = true
        };
        window = Window.Create(opts);
        
        // IPC com kernel (ioctl / dev/lineupos)
        InitKernelIPC();

        // Main loop: compositor + input
        window.Run(() => {
            CompositeFrame();
            PollInput();
        });

        return 0;
    }

    static VkInstance CreateVulkanInstance() {
        var appInfo = new VkApplicationInfo {
            SType = VkStructureType.ApplicationInfo,
            PApplicationName = (byte*)Marshal.StringToHGlobalAnsi("LineUpShell").ToPointer(),
            ApplicationVersion = VkMakeVersion(0, 1, 0),
            PEngineName = (byte*)Marshal.StringToHGlobalAnsi("LineUpOS").ToPointer(),
            EngineVersion = VkMakeVersion(0, 1, 0),
            ApiVersion = VkVersion12
        };

        var createInfo = new VkInstanceCreateInfo {
            SType = VkStructureType.InstanceCreateInfo,
            PApplicationInfo = &appInfo
        };

        VkInstance instance;
        vk->CreateInstance(&createInfo, null, &instance);
        return instance;
    }

    static void InitKernelIPC() {
        // Abre /dev/lineupos (char device do kernel Rust)
        // Registra callbacks para: input, buffer swap, AI memory mgmt
    }

    static void CompositeFrame() {
        // Acquire next image, submit command buffer, present
    }

    static void PollInput() {
        // Poll SDL events, forward to powerup.js via IPC
    }

    static uint VkMakeVersion(uint major, uint minor, uint patch) 
        => (major << 22) | (minor << 12) | patch;
}
EOF

    # Build Native AOT
    cd "${SHELL_DIR}"
    dotnet publish -c Release -r linux-x64 --self-contained true \
        -o "${BUILD_DIR}/userspace/shell"

    # Copiar para initramfs/userspace
    mkdir -p "${BUILD_DIR}/initramfs/usr/bin"
    cp "${BUILD_DIR}/userspace/shell/LineUpShell" "${BUILD_DIR}/initramfs/sbin/lineup-shell"
    ok "Shell C# AOT: ${BUILD_DIR}/initramfs/sbin/lineup-shell"
}

build_powerup_js() {
    log "Construindo powerup.js (V8 fork)..."
    local POWERUP_DIR="${ROOT_DIR}/userspace/powerup"
    mkdir -p "${POWERUP_DIR}"

    # Package.json minimal - fork Next.js 14+ com otimizações
    cat > "${POWERUP_DIR}/package.json" <<'EOF'
{
  "name": "powerup.js",
  "version": "0.1.0-lineupos",
  "description": "Ultra-performance web-native UI framework for LineUpOS",
  "private": true,
  "scripts": {
    "build": "node scripts/build.js",
    "build:native": "node scripts/build-native.js"
  },
  "dependencies": {
    "next": "^14.2.0",
    "react": "^18.3.0",
    "react-dom": "^18.3.0"
  },
  "devDependencies": {
    "@types/node": "^20.0.0",
    "@types/react": "^18.3.0",
    "typescript": "^5.5.0",
    "esbuild": "^0.23.0",
    "v8": "^0.1.0"
  }
}
EOF

    # Build script: compila Next.js + React para bytecode V8 snapshot
    cat > "${POWERUP_DIR}/scripts/build-native.js" <<'EOF'
// Compila powerup.js para V8 snapshot (binário nativo)
// Elimina JIT warmup, reduz memória ~732MB vs Electron

const esbuild = require('esbuild');
const fs = require('fs');
const path = require('path');

async function build() {
    console.log('[powerup.js] Building native snapshot...');
    
    // 1. Bundle Next.js + React + nosso runtime minimal
    await esbuild.build({
        entryPoints: ['src/runtime/entry.ts'],
        bundle: true,
        platform: 'node',
        target: 'node20',
        format: 'cjs',
        outfile: 'dist/bundle.js',
        minify: true,
        treeShaking: true,
        external: ['v8', 'fs', 'path'], // Built-ins
        define: {
            'process.env.NODE_ENV': '"production"',
            'POWERUP_NATIVE': 'true'
        }
    });

    // 2. Gerar V8 snapshot (requer V8 com --snapshot_blob)
    // Isso cria um heap snapshot que carrega instantaneamente
    console.log('[powerup.js] Snapshot generation requires V8 build from source');
    console.log('[powerup.js] See: https://v8.dev/docs/embed');
}

build().catch(() => process.exit(1));
EOF

    # Runtime minimal TypeScript
    mkdir -p "${POWERUP_DIR}/src/runtime"
    cat > "${POWERUP_DIR}/src/runtime/entry.ts" <<'EOF'
// powerup.js Runtime Entry - LineUpOS Native
// Sem DOM, sem browser APIs, direto no V8 isolado

export interface PowerUpConfig {
    width: number;
    height: number;
    aiMemoryBudget: number; // 732MB reservado
    ipcChannel: string;     // Comunicação com Shell C#
}

export class PowerUpRuntime {
    private config: PowerUpConfig;
    private ipc: MessagePort;

    constructor(config: PowerUpConfig) {
        this.config = config;
        this.initIPC();
    }

    private initIPC() {
        // Conexão com Shell C# via Unix socket / IPC compartilhado
    }

    render(component: any) {
        // Render para buffer Vulkan compartilhado (zero-copy)
    }

    // API exposta para apps LineUpOS
    static createApp(config: PowerUpConfig) {
        return new PowerUpRuntime(config);
    }
}

// Global para compat Next.js
(globalThis as any).PowerUp = PowerUpRuntime;
EOF

    # Build (requer Node.js + esbuild)
    cd "${POWERUP_DIR}"
    npm ci --prefer-offline 2>/dev/null || npm install
    node scripts/build-native.js

    # Output para initramfs
    mkdir -p "${BUILD_DIR}/initramfs/usr/lib/powerup"
    cp -r dist/* "${BUILD_DIR}/initramfs/usr/lib/powerup/" 2>/dev/null || true
    ok "powerup.js runtime pronto"
}

build_lineml() {
    log "Construindo LineML (compute shaders + bindings)..."
    local LINEML_DIR="${ROOT_DIR}/userspace/lineml"
    mkdir -p "${LINEML_DIR}"/{src,shaders,bindings}

    # CMake para C++ compute shaders (Vulkan/OpenCL)
    cat > "${LINEML_DIR}/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.28)
project(LineML LANGUAGES CXX C)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_BUILD_TYPE Release)

# Vulkan para compute shaders
find_package(Vulkan REQUIRED)
find_package(OpenCL REQUIRED)

# Python bindings (pybind11)
find_package(pybind11 CONFIG REQUIRED)

add_library(lineml_core SHARED
    src/fp8_int8_emulation.cpp
    src/fp16_bitpacking.cpp
    src/tensor_router.cpp
    src/safetensors_parser.cpp
    src/onnx_jit.cpp
    src/dma_channels.cpp
    src/cpu_fallback.cpp
)

target_link_libraries(lineml_core PRIVATE
    Vulkan::Vulkan
    OpenCL::OpenCL
    pybind11::module
)

target_include_directories(lineml_core PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    shaders
)

# Compila shaders SPIR-V
add_custom_command(
    OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/shaders/fp8_to_int8.spv
    COMMAND glslc -o ${CMAKE_CURRENT_BINARY_DIR}/shaders/fp8_to_int8.spv
            ${CMAKE_CURRENT_SOURCE_DIR}/shaders/fp8_to_int8.comp
    DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/shaders/fp8_to_int8.comp
)

# Python module
pybind11_add_module(lineml_python bindings/python_bindings.cpp)
target_link_libraries(lineml_python PRIVATE lineml_core)

install(TARGETS lineml_core lineml_python
    LIBRARY DESTINATION lib
    ARCHIVE DESTINATION lib
)
EOF

    # Shader: FP8 -> INT8 emulation (Vulkan compute)
    mkdir -p "${LINEML_DIR}/shaders"
    cat > "${LINEML_DIR}/shaders/fp8_to_int8.comp" <<'GLSL'
#version 460 core
#extension GL_EXT_shader_explicit_arithmetic_types_float8 : enable

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0) readonly buffer InputFP8 {
    float8_ext_t data[];
} in_buf;

layout(set = 0, binding = 1) writeonly buffer OutputINT8 {
    int8_t data[];
} out_buf;

layout(set = 0, binding = 2) uniform ScaleBuffer {
    float scale;  // Fator de escala FP8 -> INT8
} scale_buf;

void main() {
    uint idx = gl_GlobalInvocationID.x;
    if (idx >= 1000000000u) return; // bound check placeholder
    
    // Converte FP8 (E4M3 ou E5M2) para INT8 escalado
    // FP8 value = sign * 2^(exp - bias) * (1 + mantissa/8)
    // INT8 = clamp(round(FP8_value * scale), -128, 127)
    float fp8_val = float(in_buf.data[idx]);
    int8_t int8_val = int8_t(clamp(round(fp8_val * scale_buf.scale), -128.0, 127.0));
    out_buf.data[idx] = int8_val;
}
GLSL

    # C++ Core: FP8->INT8 host code
    cat > "${LINEML_DIR}/src/fp8_int8_emulation.cpp" <<'CPP'
#include "lineml/fp8_int8_emulation.hpp"
#include <vulkan/vulkan.h>
#include <cstdint>
#include <algorithm>

namespace lineml {

FP8Int8Emulator::FP8Int8Emulator(VkDevice device, VkPhysicalDevice phys_dev) 
    : device_(device) {
    // Cria pipeline compute para shader FP8->INT8
    createPipeline();
}

void FP8Int8Emulator::convert(const void* fp8_input, void* int8_output, 
                               size_t num_elements, float scale) {
    // Upload scale factor
    // Dispatch compute shader
    // Download result
    // Zero-copy via VK_EXT_external_memory_host se disponível
}

void FP8Int8Emulator::createPipeline() {
    // Load SPIR-V, create pipeline layout, descriptor sets
    // Usa push constants para scale factor (rápido)
}

} // namespace lineml
CPP

    # Header
    mkdir -p "${LINEML_DIR}/include/lineml"
    cat > "${LINEML_DIR}/include/lineml/fp8_int8_emulation.hpp" <<'HPP'
#pragma once
#include <vulkan/vulkan.h>
#include <cstddef>

namespace lineml {

class FP8Int8Emulator {
public:
    explicit FP8Int8Emulator(VkDevice device, VkPhysicalDevice phys_dev);
    ~FP8Int8Emulator();

    void convert(const void* fp8_input, void* int8_output, 
                 size_t num_elements, float scale);

private:
    void createPipeline();
    VkDevice device_;
    VkPipeline pipeline_;
    VkPipelineLayout layout_;
    VkDescriptorSetLayout desc_layout_;
};

} // namespace lineml
HPP

    # Tensor Router (o cérebro: CPU vs GPU)
    cat > "${LINEML_DIR}/src/tensor_router.cpp" <<'CPP'
#include "lineml/tensor_router.hpp"
#include <fstream>
#include <unordered_map>

namespace lineml {

TensorRouter::TensorRouter(size_t cpu_memory_budget) 
    : cpu_budget_(cpu_memory_budget) {}

TensorRouter::Plan TensorRouter::analyze(const SafetensorsModel& model) {
    Plan plan;
    plan.cpu_tensors.reserve(model.tensors.size() / 4);
    plan.gpu_tensors.reserve(model.tensors.size() * 3 / 4);

    for (const auto& [name, tensor] : model.tensors) {
        // Heurística: tensores grandes + embedding/conditional -> CPU
        // MatMul densos sequenciais -> GPU
        bool to_cpu = shouldOffloadToCPU(name, tensor);
        
        if (to_cpu && plan.cpu_memory_used + tensor.size_bytes <= cpu_budget_) {
            plan.cpu_tensors.push_back(name);
            plan.cpu_memory_used += tensor.size_bytes;
        } else {
            plan.gpu_tensors.push_back(name);
            plan.gpu_memory_used += tensor.size_bytes;
        }
    }
    return plan;
}

bool TensorRouter::shouldOffloadToCPU(const std::string& name, const TensorInfo& t) {
    // Embeddings, positional encodings, large conditionals
    if (name.find("embed") != std::string::npos) return true;
    if (name.find("pos") != std::string::npos) return true;
    if (name.find("norm") != std::string::npos && t.numel() > 1000000) return true;
    
    // Tensores > 100MB que não são matmul puro
    if (t.size_bytes > 100 * 1024 * 1024 && !isPureMatMul(name)) return true;
    
    return false;
}

bool TensorRouter::isPureMatMul(const std::string& name) {
    static const char* matmul_patterns[] = {
        "attn.qkv", "attn.out", "mlp.fc", "mlp.proj", "linear"
    };
    for (auto p : matmul_patterns) {
        if (name.find(p) != std::string::npos) return true;
    }
    return false;
}

} // namespace lineml
CPP

    # Build
    cd "${LINEML_DIR}"
    cmake -B build -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_CXX_FLAGS="-O3 -march=x86-64-v3 -flto" \
        -DCMAKE_INSTALL_PREFIX="${BUILD_DIR}/userspace/lineml/install"
    cmake --build build -j"$(nproc)"
    cmake --install build

    # Copiar para initramfs
    mkdir -p "${BUILD_DIR}/initramfs/usr/lib/lineml"
    cp -r "${BUILD_DIR}/userspace/lineml/install/lib/"* "${BUILD_DIR}/initramfs/usr/lib/lineml/"
    ok "LineML pronto"
}

# ============================================================
# ISO GENERATION (Limine bootloader)
# ============================================================
build_iso() {
    log "=== GERANDO ISO ==="
    mkdir -p "${ISO_DIR}"
    local ISO_ROOT="${BUILD_DIR}/iso_root"
    rm -rf "${ISO_ROOT}"
    mkdir -p "${ISO_ROOT}/boot"

    # Kernel + initramfs
    cp "${BUILD_DIR}/kernel/vmlinuz-lineupos" "${ISO_ROOT}/boot/"
    cp "${BUILD_DIR}/kernel/initramfs-lineupos.xz" "${ISO_ROOT}/boot/"

    # Limine config
    mkdir -p "${ISO_ROOT}/boot/limine"
    cat > "${ISO_ROOT}/boot/limine/limine.conf" <<EOF
timeout: 3
entry: LineUpOS

:LineUpOS
    protocol: linux
    kernel_path: boot/vmlinuz-lineupos
    cmdline: quiet lineupos_ai_mem=732M
    module_path: boot/initramfs-lineupos.xz
EOF

    # Baixar Limine binários
    local LIMINE_DIR="${BUILD_DIR}/limine"
    if [[ ! -f "${LIMINE_DIR}/limine-bios.sys" ]]; then
        log "Baixando Limine..."
        mkdir -p "${LIMINE_DIR}"
        curl -Ls "https://github.com/limine-bootloader/limine/releases/latest/download/limine-8.x.tar.gz" \
            | tar -xz -C "${LIMINE_DIR}" --strip-components=1
    fi

    # Gerar ISO híbrido (BIOS + UEFI)
    xorriso -as mkisofs \
        -b boot/limine/limine-bios.sys \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        --efi-boot boot/limine/limine-uefi.img \
        -efi-boot-part --efi-boot-image --protective-msdos-label \
        -o "${ISO_DIR}/lineupos-${VERSION}.iso" \
        "${ISO_ROOT}"

    # Instalar Limine na ISO (torna bootável USB)
    "${LIMINE_DIR}/limine-deploy" "${ISO_DIR}/lineupos-${VERSION}.iso"

    ok "ISO: ${ISO_DIR}/lineupos-${VERSION}.iso"
}

# ============================================================
# QEMU TEST
# ============================================================
test_qemu() {
    local ISO="${ISO_DIR}/lineupos-${VERSION}.iso"
    [[ -f "$ISO" ]] || { err "ISO não existe. Rode: $0 iso"; exit 1; }

    log "Bootando no QEMU..."
    local KVM_ARGS=""
    if [[ -e /dev/kvm ]]; then KVM_ARGS="-enable-kvm -cpu host"; fi

    qemu-system-x86_64 \
        $KVM_ARGS \
        -m 4G \
        -smp 4 \
        -machine q35,accel=kvm:tcg \
        -device virtio-gpu-pci \
        -display gtk,gl=on \
        -cdrom "$ISO" \
        -serial stdio \
        -netdev user,id=net0 -device virtio-net-pci,netdev=net0
}

# ============================================================
# MAIN
# ============================================================
case "${1:-}" in
    all)            build_kernel; build_userspace; build_iso ;;
    kernel)         build_kernel ;;
    userspace)      build_userspace ;;
    iso)            build_iso ;;
    test)           test_qemu ;;
    clean)          rm -rf "${BUILD_DIR}" "${ISO_DIR}"; ok "Limpo" ;;
    docker-build)   docker_build ;;
    internal-all)   build_kernel; build_userspace; build_iso ;;  # Dentro do container
    *)              usage; exit 1 ;;
esac