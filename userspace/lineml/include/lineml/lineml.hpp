# LineML - Tensor Compute Engine
# FP8->INT8, FP16 2:1, Tensor Router, Safetensors JIT

# Structure:
# userspace/lineml/
# ├── CMakeLists.txt
# ├── include/lineml/
# │   ├── fp8_int8_emulation.hpp
# │   ├── fp16_bitpacking.hpp
# │   ├── tensor_router.hpp
# │   ├── safetensors_parser.hpp
# │   ├── onnx_jit.hpp
# │   ├── dma_channels.hpp
# │   ├── cpu_fallback.hpp
# │   └── lineml.hpp
# ├── src/
# │   ├── fp8_int8_emulation.cpp
# │   ├── fp16_bitpacking.cpp
# │   ├── tensor_router.cpp
# │   ├── safetensors_parser.cpp
# │   ├── onnx_jit.cpp
# │   ├── dma_channels.cpp
# │   ├── cpu_fallback.cpp
# │   └── lineml.cpp
# ├── shaders/
# │   ├── fp8_to_int8.comp
# │   ├── fp16_pack2x.comp
# │   ├── matmul_int8.comp
# │   ├── matmul_fp16_2x.comp
# │   ├── softmax.comp
# │   ├── layernorm.comp
# │   ├── attention.comp
# │   └── cpu_fallback.comp
# ├── bindings/
# │   ├── python_bindings.cpp
# │   └── c_api.h
# └── tests/

# CMakeLists.txt (já no build.sh, aqui versão completa)

# include/lineml/lineml.hpp
#pragma once
#include <cstdint>
#include <cstddef>
#include <string>
#include <vector>
#include <memory>
#include <expected>
#include <span>

namespace lineml {

// Forward declarations
class VulkanContext;
class ComputePipeline;
class TensorRouter;
class SafetensorsModel;
class ONNXJIT;
class DMAChannelManager;
class CPUFallback;

// ============================================================
// Tensor Metadata
// ============================================================
enum class DataType : uint8_t {
    FP8_E4M3 = 0,
    FP8_E5M2 = 1,
    FP16 = 2,
    BF16 = 3,
    FP32 = 4,
    FP64 = 5,
    INT8 = 6,
    INT16 = 7,
    INT32 = 8,
    INT64 = 9,
    UINT8 = 10,
    BOOL = 11
};

enum class TensorLayout : uint8_t {
    RowMajor = 0,
    ColMajor = 1,
    ChannelsLast = 2,
    Blocked = 3
};

struct TensorShape {
    std::vector<int64_t> dims;
    
    int64_t numel() const {
        int64_t n = 1;
        for (auto d : dims) n *= d;
        return n;
    }
    
    size_t bytes(DataType dt) const {
        return numel() * data_type_size(dt);
    }
};

struct TensorInfo {
    std::string name;
    DataType dtype;
    TensorShape shape;
    TensorLayout layout;
    size_t offset;           // Offset no arquivo
    size_t size_bytes;       // Tamanho real (pode ter padding)
    bool is_quantized;       // Tem scale/zero_point?
    float scale;             // Para quantização
    int32_t zero_point;
};

inline size_t data_type_size(DataType dt) {
    switch (dt) {
        case DataType::FP8_E4M3:
        case DataType::FP8_E5M2:
        case DataType::INT8:
        case DataType::UINT8:
        case DataType::BOOL: return 1;
        case DataType::FP16:
        case DataType::BF16:
        case DataType::INT16: return 2;
        case DataType::FP32:
        case DataType::INT32: return 4;
        case DataType::FP64:
        case DataType::INT64: return 8;
    }
    return 0;
}

// ============================================================
// FP8 -> INT8 Emulation
// ============================================================
class FP8Int8Emulator {
public:
    explicit FP8Int8Emulator(VulkanContext* ctx);
    ~FP8Int8Emulator();

    // Converte tensor FP8 -> INT8 escalado
    // Preserva bandwidth (1 byte), usa INT8 nativo da GPU
    void convert(const void* fp8_input, void* int8_output, 
                 size_t num_elements, float scale,
                 DataType fp8_type = DataType::FP8_E4M3);

    // Converte em lote múltiplos tensores
    void convert_batch(const std::vector<TensorInfo>& inputs,
                       std::vector<void*>& outputs,
                       const std::vector<float>& scales);

private:
    VulkanContext* ctx_;
    std::unique_ptr<ComputePipeline> pipeline_;
    VkDescriptorSetLayout desc_layout_;
    VkPipelineLayout pipeline_layout_;
    
    void create_pipeline();
    void create_descriptor_sets();
};

// ============================================================
// FP16 2:1 Bit-packing (Polaris/RX 580)
// ============================================================
class FP16Bitpacker {
public:
    explicit FP16Bitpacker(VulkanContext* ctx);
    ~FP16Bitpacker();

    // Empacota 2x FP16 em 1x 32-bit register
    // Força hardware a calcular 2 ops por ciclo
    void pack2x(const void* fp16_input, void* packed_output, size_t num_pairs);
    
    // Desempacota resultado
    void unpack2x(const void* packed_input, void* fp16_output, size_t num_pairs);
    
    // MatMul direto com FP16 2:1
    void matmul_packed(const void* a_packed, const void* b_packed, 
                       void* c_output, int M, int N, int K);

private:
    VulkanContext* ctx_;
    std::unique_ptr<ComputePipeline> pack_pipeline_;
    std::unique_ptr<ComputePipeline> unpack_pipeline_;
    std::unique_ptr<ComputePipeline> matmul_pipeline_;
};

// ============================================================
// Tensor Router (CPU/GPU Split)
// ============================================================
struct RouterPlan {
    std::vector<std::string> cpu_tensors;
    std::vector<std::string> gpu_tensors;
    size_t cpu_memory_used = 0;
    size_t gpu_memory_used = 0;
    std::vector<DMAOp> dma_ops;  // Operações DMA para sincronizar
};

class TensorRouter {
public:
    explicit TensorRouter(size_t cpu_memory_budget_mb = 732);
    
    // Analisa modelo e decide CPU vs GPU
    RouterPlan analyze(const SafetensorsModel& model);
    
    // Executa plano de roteamento
    void execute(const RouterPlan& plan, 
                 const SafetensorsModel& model,
                 DMAChannelManager* dma);

    // Heurísticas configuráveis
    struct Heuristics {
        size_t large_tensor_threshold_mb = 100;
        bool offload_embeddings = true;
        bool offload_positional = true;
        bool offload_norms_large = true;
        bool prefer_gpu_for_matmul = true;
    } heuristics;

private:
    size_t cpu_budget_bytes_;
    
    bool should_offload_to_cpu(const TensorInfo& t, const std::string& name);
    bool is_pure_matmul(const std::string& name);
    size_t estimate_cpu_memory(const RouterPlan& plan);
};

// ============================================================
// Safetensors Parser (zero-copy mmap)
// ============================================================
class SafetensorsModel {
public:
    static std::expected<std::unique_ptr<SafetensorsModel>, std::string> 
    load(const std::string& path);

    static std::expected<std::unique_ptr<SafetensorsModel>, std::string>
    load_from_memory(std::span<const uint8_t> data);

    const std::unordered_map<std::string, TensorInfo>& tensors() const { return tensors_; }
    const std::vector<uint8_t>& data() const { return data_; }
    const std::string& metadata() const { return metadata_; }

    // Acesso direto ao tensor (pointer into mmap'd data)
    std::span<const uint8_t> tensor_data(const std::string& name) const;
    std::span<uint8_t> tensor_data_mutable(const std::string& name);

private:
    SafetensorsModel() = default;
    
    std::vector<uint8_t> data_;
    std::string metadata_;
    std::unordered_map<std::string, TensorInfo> tensors_;
    size_t header_size_ = 0;
};

// ============================================================
// ONNX JIT Compiler (Load-time)
// ============================================================
class ONNXJIT {
public:
    explicit ONNXJIT(VulkanContext* ctx);
    
    // Converte Safetensors -> ONNX graph (em memória)
    // Analisa topologia, aplica otimizações, gera Vulkan pipelines
    std::expected<std::unique_ptr<CompiledGraph>, std::string>
    compile(const SafetensorsModel& model, const RouterPlan& plan);

    // Executa grafo compilado
    void execute(CompiledGraph* graph, 
                 const std::unordered_map<std::string, void*>& inputs,
                 std::unordered_map<std::string, void*>& outputs);

private:
    VulkanContext* ctx_;
    
    struct CompiledGraph {
        std::vector<std::unique_ptr<ComputePipeline>> pipelines;
        std::vector<TensorInfo> intermediate_tensors;
        std::vector<DMAOp> dma_sync_points;
        std::unordered_map<std::string, size_t> tensor_to_pipeline;
    };
};

// ============================================================
// DMA Channel Manager (CPU <-> GPU zero-copy)
// ============================================================
struct DMAOp {
    enum class Direction : uint8_t { CPU_TO_GPU, GPU_TO_CPU, GPU_TO_GPU };
    
    Direction dir;
    void* src;
    void* dst;
    size_t size;
    uint64_t src_handle;  // DMA-BUF fd ou handle
    uint64_t dst_handle;
    VkFence fence;
    VkSemaphore semaphore;
};

class DMAChannelManager {
public:
    explicit DMAChannelManager(VulkanContext* ctx, int kernel_fd);
    
    // Aloca buffer compartilhado CPU/GPU (DMA-BUF)
    std::expected<void*, std::string> allocate_shared(size_t size, 
                                                       VkMemoryPropertyFlags flags);
    
    // Submete operação DMA assíncrona
    void submit_dma(const DMAOp& op);
    
    // Aguarda conclusão (com timeout)
    bool wait_dma(VkFence fence, uint64_t timeout_ns = 1'000'000'000);
    
    // Sincroniza múltiplas ops
    void wait_all(const std::vector<VkFence>& fences);

    // Memory map para CPU access
    void* map_cpu(void* gpu_ptr, size_t size);
    void unmap_cpu(void* cpu_ptr);

private:
    VulkanContext* ctx_;
    int kernel_fd_;  // /dev/lineupos para ioctl DMA
    
    struct SharedBuffer {
        void* cpu_ptr;
        void* gpu_ptr;
        int dmabuf_fd;
        VkDeviceMemory memory;
        size_t size;
    };
    
    std::vector<SharedBuffer> buffers_;
};

// ============================================================
// CPU Fallback (FP64, ops não suportadas)
// ============================================================
class CPUFallback {
public:
    CPUFallback();
    
    // Executa qualquer op no CPU (referência)
    void execute(const std::string& op_name,
                 const std::vector<TensorInfo>& inputs,
                 const std::vector<TensorInfo>& outputs,
                 void* attr_data, size_t attr_size);

    // Kernels de referência otimizados (AVX2/AVX-512)
    static void matmul_fp64(const double* a, const double* b, double* c, 
                            int M, int N, int K);
    static void conv2d_fp64(const double* input, const double* weight, double* output,
                            int N, int C, int H, int W, int K, int stride, int padding);
    static void softmax_fp64(double* data, int64_t rows, int64_t cols);
    static void layernorm_fp64(double* data, const double* weight, const double* bias,
                               int64_t rows, int64_t cols, double eps);

private:
    // Thread pool para parallelismo
    class ThreadPool* pool_;
};

// ============================================================
// Main LineML Engine
// ============================================================
class LineMLEngine {
public:
    struct Config {
        size_t cpu_memory_budget_mb = 732;
        bool enable_fp8_int8 = true;
        bool enable_fp16_2x = true;
        bool enable_cpu_fallback = true;
        bool enable_profiling = false;
        std::string vulkan_device_selector = "";  // Empty = auto
    };

    explicit LineMLEngine(const Config& config = {});
    ~LineMLEngine();

    // Carrega modelo .safetensors, compila, prepara execução
    std::expected<ModelHandle, std::string> 
    load_model(const std::string& path);

    // Executa inferência
    void infer(ModelHandle handle,
               const std::unordered_map<std::string, void*>& inputs,
               std::unordered_map<std::string, void*>& outputs);

    // Estatísticas
    struct Stats {
        double load_time_ms;
        double compile_time_ms;
        double infer_time_ms;
        size_t cpu_memory_used;
        size_t gpu_memory_used;
        uint32_t cpu_ops;
        uint32_t gpu_ops;
    };
    
    Stats get_stats(ModelHandle handle);

private:
    Config config_;
    std::unique_ptr<VulkanContext> vulkan_;
    std::unique_ptr<FP8Int8Emulator> fp8_emulator_;
    std::unique_ptr<FP16Bitpacker> fp16_packer_;
    std::unique_ptr<TensorRouter> router_;
    std::unique_ptr<ONNXJIT> jit_;
    std::unique_ptr<DMAChannelManager> dma_;
    std::unique_ptr<CPUFallback> cpu_fallback_;
    
    struct ModelInstance {
        std::unique_ptr<SafetensorsModel> model;
        RouterPlan plan;
        std::unique_ptr<ONNXJIT::CompiledGraph> compiled;
        Stats stats;
    };
    
    std::vector<std::unique_ptr<ModelInstance>> models_;
};

} // namespace lineml