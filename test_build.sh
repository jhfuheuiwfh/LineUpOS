#!/bin/bash
# LineUpOS Build Test Script
# Verifies build environment and runs quick checks

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${ROOT_DIR}/build"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[TEST]${NC} $*"; }
ok() { echo -e "${GREEN}[PASS]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err() { echo -e "${RED}[FAIL]${NC} $*" >&2; }

check_command() {
    if command -v "$1" >/dev/null 2>&1; then
        ok "$1 found: $($1 --version 2>&1 | head -1)"
        return 0
    else
        err "$1 not found"
        return 1
    fi
}

check_docker() {
    if docker info >/dev/null 2>&1; then
        ok "Docker daemon running"
        return 0
    else
        err "Docker not running"
        return 1
    fi
}

check_kvm() {
    if [[ -e /dev/kvm ]]; then
        ok "KVM available"
        return 0
    else
        warn "KVM not available (will use TCG)"
        return 1
    fi
}

test_kernel_config() {
    log "Testing kernel config..."
    local CONFIG="${ROOT_DIR}/config/kernel/lineupos-x86_64"
    
    if [[ ! -f "$CONFIG" ]]; then
        err "Kernel config not found"
        return 1
    fi
    
    # Check critical configs
    local critical=(
        "CONFIG_CMA=y"
        "CONFIG_CMA_SIZE_MBYTES=732"
        "CONFIG_PREEMPT_RT=y"
        "CONFIG_DRM_AMDGPU=y"
        "CONFIG_DRM_AMDGPU_SI=y"
        "CONFIG_DRM_AMDGPU_CIK=y"
        "CONFIG_IOMMU_SUPPORT=y"
        "CONFIG_AMD_IOMMU=y"
        "CONFIG_INTEL_IOMMU=y"
        "CONFIG_DMABUF_HEAPS=y"
        "CONFIG_DMABUF_HEAPS_CMA=y"
        "CONFIG_RUST=y"
        "CONFIG_LINEUPOS_AI_MEM_RESERVATION=y"
    )
    
    local failed=0
    for cfg in "${critical[@]}"; do
        if grep -q "^${cfg}$" "$CONFIG"; then
            ok "Kernel config: $cfg"
        else
            err "Kernel config missing: $cfg"
            ((failed++))
        fi
    done
    
    return $failed
}

test_rust_syntax() {
    log "Testing Rust syntax..."
    
    if ! command -v rustc >/dev/null 2>&1; then
        warn "rustc not found, skipping"
        return 0
    fi
    
    local rust_dir="${ROOT_DIR}/boot/kernel/rust"
    if [[ -f "${rust_dir}/Cargo.toml" ]]; then
        cd "$rust_dir"
        if cargo check --workspace 2>&1 | grep -q "error"; then
            err "Rust syntax check failed"
            return 1
        else
            ok "Rust syntax OK"
        fi
    fi
}

test_csharp_syntax() {
    log "Testing C# syntax..."
    
    if ! command -v dotnet >/dev/null 2>&1; then
        warn "dotnet not found, skipping"
        return 0
    fi
    
    local shell_dir="${ROOT_DIR}/userspace/shell"
    if [[ -f "${shell_dir}/LineUpShell.csproj" ]]; then
        cd "$shell_dir"
        if dotnet build --no-restore 2>&1 | grep -q "error"; then
            err "C# build failed"
            return 1
        else
            ok "C# syntax OK"
        fi
    fi
}

test_cpp_syntax() {
    log "Testing C++ syntax..."
    
    if ! command -v cmake >/dev/null 2>&1; then
        warn "cmake not found, skipping"
        return 0
    fi
    
    local lineml_dir="${ROOT_DIR}/userspace/lineml"
    if [[ -f "${lineml_dir}/CMakeLists.txt" ]]; then
        mkdir -p "${BUILD_DIR}/test_lineml"
        cd "${BUILD_DIR}/test_lineml"
        if cmake "$lineml_dir" -DCMAKE_BUILD_TYPE=Release 2>&1 | grep -q "error"; then
            err "CMake configure failed"
            return 1
        else
            ok "CMake configure OK"
        fi
    fi
}

test_node_syntax() {
    log "Testing Node.js/TypeScript syntax..."
    
    if ! command -v node >/dev/null 2>&1; then
        warn "node not found, skipping"
        return 0
    fi
    
    local powerup_dir="${ROOT_DIR}/userspace/powerup"
    if [[ -f "${powerup_dir}/package.json" ]]; then
        cd "$powerup_dir"
        if [[ ! -d "node_modules" ]]; then
            warn "node_modules not found, run 'npm install' first"
            return 0
        fi
        if npx tsc --noEmit 2>&1 | grep -q "error"; then
            err "TypeScript check failed"
            return 1
        else
            ok "TypeScript syntax OK"
        fi
    fi
}

test_docker_build() {
    log "Testing Docker build..."
    
    if ! check_docker; then
        return 1
    fi
    
    local dockerfile="${ROOT_DIR}/toolchain/Dockerfile.builder"
    if [[ ! -f "$dockerfile" ]]; then
        err "Dockerfile not found"
        return 1
    fi
    
    # Quick syntax check
    if docker build --dry-run -f "$dockerfile" "$ROOT_DIR" 2>&1 | grep -q "error"; then
        err "Dockerfile syntax error"
        return 1
    else
        ok "Dockerfile syntax OK"
    fi
}

test_iso_structure() {
    log "Testing ISO structure..."
    
    local limine_cfg="${ROOT_DIR}/build/iso_root/boot/limine/limine.conf"
    if [[ -f "$limine_cfg" ]]; then
        if grep -q "protocol: linux" "$limine_cfg" && \
           grep -q "kernel_path: boot/vmlinuz-lineupos" "$limine_cfg" && \
           grep -q "module_path: boot/initramfs-lineupos.xz" "$limine_cfg"; then
            ok "Limine config structure OK"
        else
            err "Limine config incomplete"
            return 1
        fi
    else
        warn "ISO not built yet"
    fi
}

main() {
    log "=== LineUpOS Build Environment Test ==="
    echo
    
    local total=0
    local passed=0
    local failed=0
    
    # Environment checks
    for cmd in docker qemu-system-x86_64 clang rustc cargo dotnet cmake node npm xorriso; do
        ((total++))
        if check_command "$cmd"; then
            ((passed++))
        else
            ((failed++))
        fi
    done
    
    check_kvm
    
    echo
    log "=== Component Tests ==="
    
    # Kernel config
    ((total++))
    if test_kernel_config; then
        ((passed++))
    else
        ((failed++))
    fi
    
    # Syntax checks
    ((total++))
    if test_rust_syntax; then
        ((passed++))
    else
        ((failed++))
    fi
    
    ((total++))
    if test_csharp_syntax; then
        ((passed++))
    else
        ((failed++))
    fi
    
    ((total++))
    if test_cpp_syntax; then
        ((passed++))
    else
        ((failed++))
    fi
    
    ((total++))
    if test_node_syntax; then
        ((passed++))
    else
        ((failed++))
    fi
    
    ((total++))
    if test_docker_build; then
        ((passed++))
    else
        ((failed++))
    fi
    
    # ISO test (only if built)
    test_iso_structure
    
    echo
    log "=== Summary ==="
    echo "Total checks: $total"
    echo -e "${GREEN}Passed: $passed${NC}"
    echo -e "${RED}Failed: $failed${NC}"
    
    if [[ $failed -eq 0 ]]; then
        ok "All checks passed! Ready to build."
        return 0
    else
        err "Some checks failed. Fix before building."
        return 1
    fi
}

main "$@"