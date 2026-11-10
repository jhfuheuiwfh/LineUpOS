# LineUpOS - Shell C# Native AOT
# Compositor + Display Server + IPC Kernel

# Project structure:
# userspace/shell/
# ├── LineUpShell.csproj
# ├── Program.cs                 # Entry point
# ├── Compositor/
# │   ├── Compositor.cs          # Main compositor loop
# │   ├── WindowManager.cs       # Window management
# │   ├── Layer.cs               # Compositor layers
# │   └── DamageTracker.cs       # Damage regions
# ├── Display/
# │   ├── DisplayServer.cs       # Display server protocol
# │   ├── Output.cs              # Output configuration
# │   ├── DrmBackend.cs          # DRM/KMS backend
# │   └── VulkanBackend.cs       # Vulkan backend (preferred)
# ├── Input/
# │   ├── InputManager.cs        # Input handling
# │   ├── LibInputWrapper.cs     # libinput bindings
# │   ├── Keyboard.cs            # Keyboard handling
# │   ├── Pointer.cs             # Mouse/touch
# │   └── Touch.cs               # Touchscreen
# ├── IPC/
# │   ├── KernelChannel.cs       # Kernel communication (/dev/lineupos)
# │   ├── PowerUpChannel.cs      # powerup.js communication
# │   ├── LineMLChannel.cs       # LineML communication
# │   └── Protocol.cs            # Message definitions
# ├── Render/
# │   ├── VulkanRenderer.cs      # Vulkan rendering
# │   ├── Swapchain.cs           # Swapchain management
# │   ├── ShaderCompiler.cs      # SPIR-V compilation
# │   └── ResourcePool.cs        # Buffer/image pooling
# ├── Memory/
# │   ├── BufferManager.cs       # DMA-BUF management
# │   ├── AIRegionManager.cs     # 732MB AI memory region
# │   └── SharedMemory.cs        # Shared memory helpers
# └── Platform/
#     ├── LinuxPlatform.cs       # Linux-specific
#     └── PlatformFactory.cs

# LineUpShell.csproj
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
    <AllowUnsafeBlocks>true</AllowUnsafeBlocks>
    <DebugSymbols>false</DebugSymbols>
    <DebugType>none</DebugType>
  </PropertyGroup>

  <ItemGroup>
    <PackageReference Include="Silk.NET" Version="2.22.0" />
    <PackageReference Include="Silk.NET.Vulkan" Version="2.22.0" />
    <PackageReference Include="Silk.NET.Vulkan.Extensions.KHR" Version="2.22.0" />
    <PackageReference Include="Silk.NET.Vulkan.Extensions.EXT" Version="2.22.0" />
    <PackageReference Include="Silk.NET.Windowing.Sdl3" Version="2.22.0" />
    <PackageReference Include="Silk.NET.Input.Sdl3" Version="2.22.0" />
    <PackageReference Include="System.IO.Pipelines" Version="9.0.0" />
    <PackageReference Include="System.Memory.Data" Version="9.0.0" />
    <PackageReference Include="Microsoft.Extensions.Logging" Version="9.0.0" />
    <PackageReference Include="Microsoft.Extensions.Logging.Console" Version="9.0.0" />
  </ItemGroup>

  <ItemGroup>
    <TrimmerRootAssembly Include="Silk.NET.Vulkan" />
    <TrimmerRootAssembly Include="Silk.NET.Windowing.Sdl3" />
  </ItemGroup>
</Project>

# Program.cs
using System;
using System.Runtime.InteropServices;
using System.Threading;
using Silk.NET.Vulkan;
using Silk.NET.Windowing;
using Silk.NET.Windowing.Sdl3;
using LineUpShell.Compositor;
using LineUpShell.Display;
using LineUpShell.Input;
using LineUpShell.IPC;
using LineUpShell.Render;
using LineUpShell.Memory;

namespace LineUpShell;

unsafe class Program {
    static Vk* vk;
    static IWindow window;
    static Compositor compositor;
    static DisplayServer displayServer;
    static InputManager inputManager;
    static KernelChannel kernelChannel;
    static PowerUpChannel powerUpChannel;
    static LineMLChannel lineMLChannel;
    static VulkanRenderer renderer;
    static BufferManager bufferManager;
    static AIRegionManager aiRegionManager;
    static CancellationTokenSource cts = new();

    static uint width = 1920, height = 1080;

    [DllImport("libc", SetLastError = true)]
    static extern int ioctl(int fd, ulong request, void* argp);

    [DllImport("libc", SetLastError = true)]
    static extern int open(string pathname, int flags, int mode = 0);

    [DllImport("libc", SetLastError = true)]
    static extern int close(int fd);

    static int Main(string[] args) {
        Console.WriteLine("[LineUpShell] Starting LineUpOS Compositor v0.1");
        Console.WriteLine($"[LineUpShell] Target: {width}x{height}, AI Memory: 732MB");

        try {
            InitializeVulkan();
            InitializeDisplayServer();
            InitializeCompositor();
            InitializeInput();
            InitializeIPC();
            InitializeRender();
            InitializeMemory();
            
            // Signal kernel we're ready
            kernelChannel.Send(new KernelMessage {
                Type = KernelMessageType.ShellReady,
                Payload = new ShellReadyPayload { Width = width, Height = height }
            });

            // Main loop
            RunMainLoop();

            return 0;
        } catch (Exception ex) {
            Console.Error.WriteLine($"[LineUpShell] FATAL: {ex}");
            return 1;
        } finally {
            Cleanup();
        }
    }

    static void InitializeVulkan() {
        vk = Vk.GetApi();
        
        var appInfo = new VkApplicationInfo {
            SType = VkStructureType.ApplicationInfo,
            PApplicationName = (byte*)Marshal.StringToHGlobalAnsi("LineUpShell").ToPointer(),
            ApplicationVersion = VkMakeVersion(0, 1, 0),
            PEngineName = (byte*)Marshal.StringToHGlobalAnsi("LineUpOS").ToPointer(),
            EngineVersion = VkMakeVersion(0, 1, 0),
            ApiVersion = VkVersion12
        };

        var extensions = new[] {
            VkExtSurface.ExtensionName,
            VkKhrXcbSurface.ExtensionName,
            VkExtDebugUtils.ExtensionName
        };

        var createInfo = new VkInstanceCreateInfo {
            SType = VkStructureType.InstanceCreateInfo,
            PApplicationInfo = &appInfo,
            EnabledExtensionCount = (uint)extensions.Length,
            PpEnabledExtensionNames = (byte**)Marshal.AllocHGlobal(extensions.Length * IntPtr.Size)
        };

        for (int i = 0; i < extensions.Length; i++) {
            var ptr = Marshal.StringToHGlobalAnsi(extensions[i]);
            Marshal.WriteIntPtr(createInfo.PpEnabledExtensionNames, i * IntPtr.Size, ptr);
        }

        VkInstance instance;
        var result = vk->CreateInstance(&createInfo, null, &instance);
        if (result != VkResult.Success) {
            throw new Exception($"Failed to create Vulkan instance: {result}");
        }

        // Load instance functions
        vk->LoadInstance(instance);
    }

    static void InitializeDisplayServer() {
        displayServer = new DisplayServer(vk);
        displayServer.Initialize(width, height);
        
        // Get the window from display server
        window = displayServer.Window;
    }

    static void InitializeCompositor() {
        compositor = new Compositor(displayServer, renderer);
        compositor.Initialize();
    }

    static void InitializeInput() {
        inputManager = new InputManager(window);
        inputManager.Initialize();
        inputManager.OnInputEvent += OnInputEvent;
    }

    static void InitializeIPC() {
        // Open kernel device
        int fd = open("/dev/lineupos", 0x0002); // O_RDWR
        if (fd < 0) {
            Console.WriteLine("[LineUpShell] Warning: /dev/lineupos not found, using mock");
            kernelChannel = new KernelChannelMock();
        } else {
            kernelChannel = new KernelChannel(fd);
        }

        // Connect to powerup.js (Unix socket)
        powerUpChannel = new PowerUpChannel("/run/lineupos/powerup.sock");
        powerUpChannel.Connect();

        // Connect to LineML
        lineMLChannel = new LineMLChannel("/run/lineupos/lineml.sock");
        lineMLChannel.Connect();

        kernelChannel.StartListening(OnKernelMessage);
    }

    static void InitializeRender() {
        renderer = new VulkanRenderer(vk, displayServer.PhysicalDevice, displayServer.Device);
        renderer.Initialize(width, height);
    }

    static void InitializeMemory() {
        bufferManager = new BufferManager(renderer.Device, renderer.PhysicalDevice);
        aiRegionManager = new AIRegionManager(bufferManager, 732 * 1024 * 1024); // 732MB
        aiRegionManager.Reserve();
    }

    static void RunMainLoop() {
        var frameTime = TimeSpan.FromMilliseconds(16.666); // 60 FPS target
        var nextFrame = DateTime.UtcNow;

        while (!cts.Token.IsCancellationRequested) {
            var frameStart = DateTime.UtcNow;

            // 1. Poll input
            inputManager.Poll();

            // 2. Process IPC messages
            kernelChannel.ProcessMessages();
            powerUpChannel.ProcessMessages();
            lineMLChannel.ProcessMessages();

            // 3. Update compositor (layout, damage)
            compositor.Update();

            // 4. Render frame
            renderer.BeginFrame();
            compositor.Render(renderer);
            renderer.EndFrame();

            // 5. Present
            displayServer.Present();

            // Frame timing
            var elapsed = DateTime.UtcNow - frameStart;
            var sleepTime = frameTime - elapsed;
            if (sleepTime > TimeSpan.Zero) {
                Thread.Sleep(sleepTime);
            }

            nextFrame += frameTime;
        }
    }

    static void OnInputEvent(InputEvent e) {
        // Forward to powerup.js
        powerUpChannel.SendInput(e);
        
        // Also forward to compositor for window management
        compositor.HandleInput(e);
    }

    static void OnKernelMessage(KernelMessage msg) {
        switch (msg.Type) {
            case KernelMessageType.AIMemoryPressure:
                aiRegionManager.HandlePressure(msg.Payload);
                break;
            case KernelMessageType.DisplayHotplug:
                displayServer.HandleHotplug(msg.Payload);
                break;
            case KernelMessageType.TensorDMAComplete:
                lineMLChannel.NotifyDMAComplete(msg.Payload);
                break;
        }
    }

    static void Cleanup() {
        cts.Cancel();
        aiRegionManager?.Release();
        bufferManager?.Dispose();
        renderer?.Dispose();
        powerUpChannel?.Disconnect();
        lineMLChannel?.Disconnect();
        kernelChannel?.Dispose();
        inputManager?.Dispose();
        compositor?.Dispose();
        displayServer?.Dispose();
        window?.Dispose();
    }

    static uint VkMakeVersion(uint major, uint minor, uint patch) 
        => (major << 22) | (minor << 12) | patch;
}

# Kernel IPC Protocol
namespace LineUpShell.IPC {
    enum KernelMessageType : uint {
        ShellReady = 1,
        AIMemoryPressure = 2,
        DisplayHotplug = 3,
        TensorDMAComplete = 4,
        InputEvent = 5,
        BufferAllocate = 6,
        BufferFree = 7,
        VSync = 8
    }

    struct KernelMessage {
        public KernelMessageType Type;
        public uint Sequence;
        public ulong Timestamp;
        public MessagePayload Payload;
    }

    [StructLayout(LayoutKind.Explicit, Size = 256)]
    struct MessagePayload {
        [FieldOffset(0)] public ShellReadyPayload ShellReady;
        [FieldOffset(0)] public AIMemoryPressurePayload AIMemoryPressure;
        [FieldOffset(0)] public DisplayHotplugPayload DisplayHotplug;
        [FieldOffset(0)] public TensorDMACompletePayload TensorDMAComplete;
        [FieldOffset(0)] public InputEventPayload InputEvent;
        [FieldOffset(0)] public BufferAllocatePayload BufferAllocate;
        [FieldOffset(0)] public byte[] RawData;
    }

    struct ShellReadyPayload {
        public uint Width;
        public uint Height;
        public uint RefreshRate;
        public ulong AIRegionOffset;
        public ulong AIRegionSize;
    }

    struct AIMemoryPressurePayload {
        public ulong RequestedBytes;
        public uint Priority;
        public uint TensorCount;
    }

    struct DisplayHotplugPayload {
        public uint ConnectorId;
        public bool Connected;
        public uint Width;
        public uint Height;
        public uint RefreshRate;
    }

    struct TensorDMACompletePayload {
        public ulong BufferHandle;
        public uint TensorId;
        public bool Success;
        public ulong ErrorCode;
    }

    struct InputEventPayload {
        public uint Type;
        public uint DeviceId;
        public int X;
        public int Y;
        public uint ButtonMask;
        public uint KeyCode;
        public ulong Timestamp;
    }

    struct BufferAllocatePayload {
        public ulong Size;
        public uint UsageFlags;
        public uint MemoryFlags;
        public ulong Handle;
    }

    class KernelChannel : IDisposable {
        private readonly int _fd;
        private readonly Thread _listenThread;
        private readonly CancellationTokenSource _cts = new();
        private Action<KernelMessage> _handler;

        public KernelChannel(int fd) {
            _fd = fd;
            _listenThread = new Thread(ListenLoop) { IsBackground = true };
        }

        public void StartListening(Action<KernelMessage> handler) {
            _handler = handler;
            _listenThread.Start();
        }

        public void Send(KernelMessage msg) {
            // Write to device
            var bytes = StructureToBytes(msg);
            var written = 0;
            while (written < bytes.Length) {
                var n = write(_fd, bytes, written, bytes.Length - written);
                if (n <= 0) throw new IOException("Kernel channel write failed");
                written += n;
            }
        }

        public void ProcessMessages() {
            // Non-blocking check
        }

        private void ListenLoop() {
            var buffer = new byte[4096];
            while (!_cts.Token.IsCancellationRequested) {
                var n = read(_fd, buffer, 0, buffer.Length);
                if (n > 0) {
                    var msg = BytesToStructure<KernelMessage>(buffer);
                    _handler?.Invoke(msg);
                } else if (n < 0) {
                    Thread.Sleep(1);
                }
            }
        }

        public void Dispose() {
            _cts.Cancel();
            close(_fd);
        }

        [DllImport("libc")] static extern int read(int fd, byte[] buf, int offset, int count);
        [DllImport("libc")] static extern int write(int fd, byte[] buf, int offset, int count);
    }

    class KernelChannelMock : KernelChannel {
        public KernelChannelMock() : base(-1) { }
        public override void Send(KernelMessage msg) { /* no-op */ }
    }
}