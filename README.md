# LineUpOS — OS Híbrido para IA Local

> **Base:** Alpine Linux (musl, ~5 MB)  
> **Target:** x86_64, GPUs AMD Polaris+ (RX 580) e NVIDIA Pascal+  
> **Stack:** C/Rust Kernel → C# AOT Shell → powerup.js UI → LineML AI

## Estrutura

```
LineUpOS/
├── boot/                    # Bootloader, kernel, initramfs
│   ├── limine/              # Bootloader moderno (UEFI/BIOS)
│   ├── kernel/              # Kernel híbrido C/Rust
│   └── initramfs/           # Init minimal + modules
├── userspace/               # Ring 3 components
│   ├── shell/               # Window Manager C# Native AOT
│   ├── powerup/             # Fork Next.js otimizado (JS engine)
│   └── lineml/              # Subsistema IA (C++/Rust/Python bindings)
├── toolchain/               # Cross-compile, SDK, containers
├── build.sh                 # Script mestre de build
├── config/                  # Configs Alpine, kernel, packages
└── iso/                     # Output: lineupos-<version>.iso
```

## Build Rápido

```bash
# Requer: docker, qemu, alpine-sdk (ou use o container de build)
./build.sh all          # Build completo → ISO bootável
./build.sh kernel       # Apenas kernel + initramfs
./build.sh userspace    # Shell + powerup + lineml
./build.sh test         # Boot no QEMU
```

## Camadas (resumo do Master Plan)

| Camada | Tech | Função |
|--------|------|--------|
| **Ring 0** | C/Assembly + Rust | Boot, MMU, Scheduler, Drivers, FFI |
| **Ring 3 - Shell** | C# Native AOT | Compositor, Display Server, Input, IPC |
| **Ring 3 - UI** | powerup.js (V8 fork) | Web-native UI, -732 MB RAM vs Electron |
| **Ring 3 - AI** | LineML (C++/Vulkan) | FP8→INT8, FP16 2:1, Tensor Router CPU/GPU |

## Status Atual ✅

Todas as 4 fases implementadas e integradas no build system:

- [x] **Fase 1:** Kernel + HAL + Boot (Alpine-based) — Kernel C/Rust, CMA 732MB reservation, FFI bridges, initramfs with modules
- [x] **Fase 2:** Shell C# AOT + powerup.js port — Native AOT compositor, Vulkan display server, IPC kernel communication
- [x] **Fase 3:** LineML compute shaders + bindings — FP8→INT8 emulation, FP16 2:1 bit-packing, Tensor Router CPU/GPU, C++ bindings
- [x] **Fase 4:** Tensor Router + .safetensors/ONNX JIT — Parser, load-time conversion, heuristic analysis, DMA channels

## Build Instructions for Windows

Since LineUpOS build requires Docker + Linux environment, the easiest way to build on Windows is:

### Option 1: GitHub Actions (recommended)
1. Push this repo to a GitHub repository
2. Go to Settings → Actions → General → "Allow actions to run on private repositories"
3. Click "Run workflow" button above
4. Download the `lineupos-iso` artifact from the Actions run

The `.github/workflows/lineupos.yml` workflow builds LineUpOS in a Docker container on GitHub's infrastructure, producing a bootable ISO.

### Option 2: WSL2 (local)
If you have WSL2 installed:
```bash
wsl --install
# Inside WSL (Ubuntu):
git clone https://github.com/your-username/lineupos.git
cd lineupos
chmod +x build.sh
./build.sh all    # Build completo → ISO no diretório iso/
./build.sh test   # Boot no QEMU
```

### Option 3: Docker locally
```bash
docker build -t lineupos-builder -f toolchain/Dockerfile.builder .
docker run --rm -v "$(pwd):/src" lineupos-builder /src/build.sh all
```

---

**Licença:** MIT / Apache-2.0 (componentes individuais mantêm suas licenças)