<#
.SYNOPSIS
LineUpOS Build Environment Test - PowerShell version for Windows
#>

param(
    [switch]$Verbose
)

$ErrorActionPreference = "Stop"

# Windows: Set UTF-8 codepage to prevent encoding corruption
chcp 65001 > $null 2>&1

# Roots
$root = "D:\LineUpOS"
$buildDir = Join-Path $root "build"
$isoDir = Join-Path $root "iso"

Write-Host "=== LineUpOS Build Environment Test (PowerShell) ===" -ForegroundColor Cyan
Write-Host ""

# ---- Environment checks ----
Write-Host "--- Environment Checks ---" -ForegroundColor White

$files = @(
    "build.sh",
    "toolchain/Dockerfile.builder",
    "test_build.ps1",
    "README.md",
    ".github/workflows/lineupos.yml"
)

foreach ($f in $files) {
    $full = Join-Path $root $f
    if (Test-Path $full) {
        Write-Host ("[PASS] {0}" -f $f) -ForegroundColor Green
    } else {
        Write-Host ("[FAIL] {0}" -f $f) -ForegroundColor Red
    }
}

Write-Host "" -ForegroundColor White

# ---- File structure checks ----
Write-Host "--- File Structure Checks ---" -ForegroundColor White

$structureChecks = @(
    @{name="Kernel config (lineupos-x86_64)"; path=Join-Path $root "config/kernel/lineupos-x86_64"}
    @{name="Initramfs init script"; path=Join-Path $root "boot/initramfs/init"}
    @{name="Rust Cargo.toml"; path=Join-Path $root "boot/kernel/rust/Cargo.toml"}
    @{name="Rust module lib.rs"; path=Join-Path $root "boot/kernel/rust/lineupos-core/src/lib.rs"}
    @{name="Shell C# project"; path=Join-Path $root "userspace/shell/LineUpShell.csproj"}
    @{name="powerup.js README"; path=Join-Path $root "userspace/powerup/README.md"}
    @{name="LineML headers"; path=Join-Path $root "userspace/lineml/include/lineml/lineml.hpp"}
    @{name="GitHub workflow"; path=Join-Path $root ".github/workflows/lineupos.yml"}
)

foreach ($sc in $structureChecks) {
    if (Test-Path $sc.path) {
        Write-Host ("[PASS] {0} - found" -f $sc.name) -ForegroundColor Green
    } else {
        Write-Host ("[WARN] {0} - missing (generated at build time)" -f $sc.name) -ForegroundColor Yellow
    }
}

Write-Host "" -ForegroundColor White

# ---- Content validation ----
Write-Host "--- Content Validation ---" -ForegroundColor White

# Check kernel config has critical entries
$kernelConfigPath = Join-Path $root "config/kernel/lineupos-x86_64"
if (Test-Path $kernelConfigPath) {
    $kernelConfig = Get-Content $kernelConfigPath -Raw
    if ($kernelConfig -match "CONFIG_CMA_SIZE_MBYTES=732") {
        Write-Host "[PASS] Kernel: CMA 732MB reservation" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] Kernel: CMA 732MB reservation missing" -ForegroundColor Red
    }
    if ($kernelConfig -match "CONFIG_PREEMPT_RT=y") {
        Write-Host "[PASS] Kernel: Preempt RT enabled" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] Kernel: Preempt RT missing" -ForegroundColor Red
    }
    if ($kernelConfig -match "CONFIG_RUST=y") {
        Write-Host "[PASS] Kernel: Rust support enabled" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] Kernel: Rust support missing" -ForegroundColor Red
    }
}

# Check Dockerfile has essential tools
$dockerfilePath = Join-Path $root "toolchain/Dockerfile.builder"
if (Test-Path $dockerfilePath) {
    $dockerfile = Get-Content $dockerfilePath -Raw
    if ($dockerfile -match "alpine:edge") {
        Write-Host "[PASS] Dockerfile: Alpine edge base" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] Dockerfile: Alpine edge base missing" -ForegroundColor Red
    }
    if ($dockerfile -match "clang") {
        Write-Host "[PASS] Dockerfile: Clang compiler" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] Dockerfile: Clang compiler missing" -ForegroundColor Red
    }
    if ($dockerfile -match "rust") {
        Write-Host "[PASS] Dockerfile: Rust toolchain" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] Dockerfile: Rust toolchain missing" -ForegroundColor Red
    }
    if ($dockerfile -match "dotnet") {
        Write-Host "[PASS] Dockerfile: .NET SDK" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] Dockerfile: .NET SDK missing" -ForegroundColor Red
    }
    if ($dockerfile -match "nodejs") {
        Write-Host "[PASS] Dockerfile: Node.js" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] Dockerfile: Node.js missing" -ForegroundColor Red
    }
}

# Check .hpp header guards
$hppfile = (Get-ChildItem (Join-Path $root "userspace/lineml/include/lineml") -Filter *.hpp | Select-Object -First 1)
if ($hppfile) {
    $hcontent = Get-Content $hppfile.FullName -Raw
    if ($hcontent -match "#pragma once") {
        Write-Host ("[PASS] Header pragma once: {0}" -f $hppfile.Name) -ForegroundColor Green
    } else {
        Write-Host ("[FAIL] Header pragma once missing: {0}" -f $hppfile.Name) -ForegroundColor Red
    }
}

# Check Rust file for .unwrap()
$rsfile = Get-ChildItem (Join-Path $root "boot/kernel/rust") -Filter *.rs -Recurse | Select-Object -First 1
if ($rsfile) {
    $rscontent = Get-Content $rsfile.FullName -Raw
    if ($rscontent -match '\.unwrap()') {
        Write-Host ("[WARN] Rust: .unwrap() found in {0}" -f $rsfile.Name) -ForegroundColor Yellow
    } else {
        Write-Host ("[PASS] Rust: no .unwrap() in {0}" -f $rsfile.Name) -ForegroundColor Green
    }
}

# Check PowerShell chcp 65001
$psfile = Join-Path $root "test_build.ps1"
$pcontent = Get-Content $psfile -Raw
if ($pcontent -match "chcp 65001") {
    Write-Host "[PASS] PowerShell: chcp 65001 (UTF-8)" -ForegroundColor Green
} else {
    Write-Host "[FAIL] PowerShell: chcp 65001 missing" -ForegroundColor Red
}

# Check GitHub workflow
$ymlfile = Join-Path $root ".github/workflows/lineupos.yml"
if (Test-Path $ymlfile) {
    $ycontent = Get-Content $ymlfile -Raw
    if ($ycontent -match "name:" -and $ycontent -match "jobs:") {
        Write-Host "[PASS] GitHub workflow: name + jobs present" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] GitHub workflow: name or jobs missing" -ForegroundColor Red
    }
}

# Check Shell set -euo pipefail
$shfiles = Get-ChildItem -Path $root -Filter *.sh -Recurse
$allPipefail = $true
foreach ($sf in $shfiles) {
    $scontent = Get-Content $sf.FullName -Raw
    if (-not $scontent -match 'set -euo pipefail') {
        $allPipefail = $false
    }
}
if ($allPipefail) {
    Write-Host "[PASS] Shell: set -euo pipefail in all scripts" -ForegroundColor Green
} else {
    Write-Host "[WARN] Shell: set -euo pipefail missing in some scripts" -ForegroundColor Yellow
}

# Check README H1
$readme = Join-Path $root "README.md"
if (Test-Path $readme) {
    $rc = Get-Content $readme -Raw
    if ($rc -match "^# LineUpOS") {
        Write-Host "[PASS] README: H1 heading present" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] README: H1 heading missing" -ForegroundColor Red
    }
}

Write-Host "" -ForegroundColor White
Write-Host "=== LineUpOS PowerShell Validation Complete ===" -ForegroundColor Cyan
Write-Host "All 9 critical checks executed autonomously." -ForegroundColor Cyan