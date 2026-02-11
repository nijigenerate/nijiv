module directx.directx_backend;

version (EnableDirectXBackend) {

import std.algorithm : max;
import std.conv : to;
import std.exception : enforce;
import std.math : isNaN, cos, sin;
import std.stdio : writeln, stdout;
import std.string : fromStringz;
import core.stdc.string : memcpy;
import core.stdc.stdlib : getenv;
import core.sys.windows.com : CoInitializeEx, COINIT_MULTITHREADED;
import core.sys.windows.windows : HANDLE, HWND, RECT, CloseHandle, CreateEventW, WaitForSingleObject, INFINITE, GetClientRect;
import core.sys.windows.windef : HRESULT;

import bindbc.sdl;
import bindbc.sdl.dynload : loadedSDLVersion;
import bindbc.sdl.bind.sdlsyswm : SDL_SysWMinfo, SDL_GetWindowWMInfo, SDL_SYSWM_WINDOWS;
import bindbc.sdl.bind.sdlversion : SDL_VERSION;
import aurora.directx.d3d12 : D3D12_HEAP_TYPE;
import aurora.directx.com : DXPtr, uuidof;
import aurora.directx.d3d.d3dcommon : D3D_PRIMITIVE_TOPOLOGY;
import aurora.directx.d3d.d3dcompiler : D3DCompile, D3DCOMPILE_ENABLE_STRICTNESS, D3DCOMPILE_OPTIMIZATION_LEVEL3, ID3DBlob;
import aurora.directx.d3d12.d3d12;
import aurora.directx.d3d12.d3d12sdklayers : ID3D12Debug;
import aurora.directx.dxgi.dxgi : DXGI_ERROR_NOT_FOUND;
import aurora.directx.dxgi.dxgi1_3 : CreateDXGIFactory2;
import aurora.directx.dxgi.dxgi1_6;

alias RenderResourceHandle = size_t;

struct Vec2f {
    float x;
    float y;
}

struct Vec3f {
    float x;
    float y;
    float z;
}

struct Vec4f {
    float r;
    float g;
    float b;
    float a;
}

enum MaskDrawableKind : uint {
    Part,
    Mask,
}

enum NjgResult : int {
    Ok = 0,
    InvalidArgument = 1,
    Failure = 2,
}

enum BlendMode : int {
    Normal,
    Multiply,
    Screen,
    Overlay,
    Darken,
    Lighten,
    ColorDodge,
    LinearDodge,
    AddGlow,
    ColorBurn,
    HardLight,
    SoftLight,
    Difference,
    Exclusion,
    Subtract,
    Inverse,
    DestinationIn,
    ClipToLower,
    SliceFromLower,
    Count,
}

enum StencilMode : ubyte {
    None,
    Write,
    TestEqual,
}

enum uint D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING_VALUE = 5768;
enum HRESULT DXGI_ERROR_DEVICE_HUNG_HR = cast(HRESULT)0x887A0006u;
enum HRESULT DXGI_ERROR_DEVICE_REMOVED_HR = cast(HRESULT)0x887A0005u;
enum HRESULT DXGI_ERROR_DEVICE_RESET_HR = cast(HRESULT)0x887A0007u;

bool dxSucceeded(HRESULT hr) @safe pure nothrow {
    return hr >= 0;
}

bool dxFailed(HRESULT hr) @safe pure nothrow {
    return hr < 0;
}

bool isDeviceLossHr(HRESULT hr) @safe pure nothrow {
    return hr == DXGI_ERROR_DEVICE_REMOVED_HR ||
           hr == DXGI_ERROR_DEVICE_RESET_HR ||
           hr == DXGI_ERROR_DEVICE_HUNG_HR;
}

bool isDxTraceEnabled() {
    auto p = getenv("NJIV_DX_TRACE");
    if (p is null) return false;
    auto v = fromStringz(p).idup;
    return v == "1" || v == "true" || v == "TRUE";
}

bool isDxFlag(scope const(char)[] name) {
    auto p = getenv(name.ptr);
    if (p is null) return false;
    auto v = fromStringz(p).idup;
    return v == "1" || v == "true" || v == "TRUE";
}

void dxTrace(scope const(char)[] msg) {
    if (!isDxTraceEnabled()) return;
    writeln("[dx] ", msg);
    stdout.flush();
}

void enforceHr(HRESULT hr, lazy string message) {
    enforce(dxSucceeded(hr), message ~ " (hr=" ~ to!string(cast(uint)hr) ~ ")");
}

alias WinGUID = core.sys.windows.com.GUID;

const(WinGUID)* iid(T)() {
    static immutable WinGUID g = cast(WinGUID)uuidof!T;
    return &g;
}

__gshared immutable WinGUID IID_ID3D12Device_Win =
    WinGUID(0x189819f1, 0x1db6, 0x4b57, [0xbe, 0x54, 0x18, 0x21, 0x33, 0x9b, 0x85, 0xf7]);
__gshared immutable WinGUID IID_ID3D12CommandQueue_Win =
    WinGUID(0x0ec870a6, 0x5d7e, 0x4c22, [0x8c, 0xfc, 0x5b, 0xaa, 0xe0, 0x76, 0x16, 0xed]);
__gshared immutable WinGUID IID_ID3D12CommandAllocator_Win =
    WinGUID(0x6102dee4, 0xaf59, 0x4b09, [0xb9, 0x99, 0xb4, 0x4d, 0x73, 0xf0, 0x9b, 0x24]);
__gshared immutable WinGUID IID_ID3D12GraphicsCommandList_Win =
    WinGUID(0x5b160d0f, 0xac1b, 0x4185, [0x8b, 0xa8, 0xb3, 0xae, 0x42, 0xa5, 0xa4, 0x55]);
__gshared immutable WinGUID IID_ID3D12Fence_Win =
    WinGUID(0x0a753dcf, 0xc4d8, 0x4b91, [0xad, 0xf6, 0xbe, 0x5a, 0x60, 0xd9, 0x5a, 0x76]);
__gshared immutable WinGUID IID_ID3D12Device4_Win =
    WinGUID(0xe865df17, 0xa9ee, 0x46f9, [0xa4, 0x63, 0x30, 0x98, 0x31, 0x5a, 0xa2, 0xe5]);
__gshared immutable WinGUID IID_ID3D12Resource_Win =
    WinGUID(0x696442be, 0xa72e, 0x4059, [0xbc, 0x79, 0x5b, 0x5c, 0x98, 0x04, 0x0f, 0xad]);
__gshared immutable WinGUID IID_ID3D12DescriptorHeap_Win =
    WinGUID(0x8efb471d, 0x616c, 0x4f49, [0x90, 0xf7, 0x12, 0x7b, 0xb7, 0x63, 0xfa, 0x51]);
__gshared immutable WinGUID IID_ID3D12RootSignature_Win =
    WinGUID(0xc54a6b66, 0x72df, 0x4ee8, [0x8b, 0xe5, 0xa9, 0x46, 0xa1, 0x42, 0x92, 0x14]);
__gshared immutable WinGUID IID_ID3D12PipelineState_Win =
    WinGUID(0x765a30f3, 0xf624, 0x4c6f, [0xa8, 0x28, 0xac, 0xe9, 0x48, 0x62, 0x24, 0x45]);
__gshared immutable WinGUID IID_IDXGISwapChain3_Win =
    WinGUID(0x94d99bdb, 0xf1f8, 0x4ab0, [0xb2, 0x36, 0x7d, 0xa0, 0x17, 0x0e, 0xda, 0xb1]);

extern(Windows) pragma(mangle, "D3D12CreateDevice")
HRESULT WinD3D12CreateDevice(
    IUnknown pAdapter,
    D3D_FEATURE_LEVEL minimumFeatureLevel,
    const(WinGUID)* riid,
    void** ppDevice);

extern(Windows) pragma(mangle, "D3D12GetDebugInterface")
HRESULT WinD3D12GetDebugInterface(
    const(WinGUID)* riid,
    void** ppvDebug);

extern(Windows) pragma(mangle, "D3D12SerializeRootSignature")
HRESULT WinD3D12SerializeRootSignature(
    const(D3D12_ROOT_SIGNATURE_DESC)* pRootSignature,
    D3D_ROOT_SIGNATURE_VERSION sigVersion,
    ID3DBlob* ppBlob,
    ID3DBlob* ppErrorBlob);

alias RendererHandle = void*;
alias PuppetHandle = void*;

// Keep in sync with nijilive/source/nijilive/integration/unity.d
enum NjgRenderCommandKind : uint {
    DrawPart,
    DrawMask,
    BeginDynamicComposite,
    EndDynamicComposite,
    BeginMask,
    ApplyMask,
    BeginMaskContent,
    EndMask,
}

extern(C) struct UnityRendererConfig {
    int viewportWidth;
    int viewportHeight;
}

extern(C) struct FrameConfig {
    int viewportWidth;
    int viewportHeight;
}

extern(C) struct NjgPartDrawPacket {
    bool isMask;
    bool renderable;
    float[16] modelMatrix;
    float[16] renderMatrix;
    float renderRotation;
    Vec3f clampedTint;
    Vec3f clampedScreen;
    float opacity;
    float emissionStrength;
    float maskThreshold;
    int blendingMode;
    bool useMultistageBlend;
    bool hasEmissionOrBumpmap;
    size_t[3] textureHandles;
    size_t textureCount;
    Vec2f origin;
    size_t vertexOffset;
    size_t vertexAtlasStride;
    size_t uvOffset;
    size_t uvAtlasStride;
    size_t deformOffset;
    size_t deformAtlasStride;
    const(ushort)* indices;
    size_t indexCount;
    size_t vertexCount;
}

extern(C) struct NjgMaskDrawPacket {
    float[16] modelMatrix;
    float[16] mvp;
    Vec2f origin;
    size_t vertexOffset;
    size_t vertexAtlasStride;
    size_t deformOffset;
    size_t deformAtlasStride;
    const(ushort)* indices;
    size_t indexCount;
    size_t vertexCount;
}

extern(C) struct NjgMaskApplyPacket {
    MaskDrawableKind kind;
    bool isDodge;
    NjgPartDrawPacket partPacket;
    NjgMaskDrawPacket maskPacket;
}

extern(C) struct NjgDynamicCompositePass {
    size_t[3] textures;
    size_t textureCount;
    size_t stencil;
    Vec2f scale;
    float rotationZ;
    bool autoScaled;
    RenderResourceHandle origBuffer;
    int[4] origViewport;
    int drawBufferCount;
    bool hasStencil;
}

extern(C) struct NjgQueuedCommand {
    NjgRenderCommandKind kind;
    NjgPartDrawPacket partPacket;
    NjgMaskApplyPacket maskApplyPacket;
    NjgDynamicCompositePass dynamicPass;
    bool usesStencil;
}

extern(C) struct CommandQueueView {
    const(NjgQueuedCommand)* commands;
    size_t count;
}

extern(C) struct NjgBufferSlice {
    const(float)* data;
    size_t length;
}

extern(C) struct SharedBufferSnapshot {
    NjgBufferSlice vertices;
    NjgBufferSlice uvs;
    NjgBufferSlice deform;
    size_t vertexCount;
    size_t uvCount;
    size_t deformCount;
}

extern(C) struct UnityResourceCallbacks {
    void* userData;
    size_t function(int width, int height, int channels, int mipLevels, int format, bool renderTarget, bool stencil, void* userData) createTexture;
    void function(size_t handle, const(ubyte)* data, size_t dataLen, int width, int height, int channels, void* userData) updateTexture;
    void function(size_t handle, void* userData) releaseTexture;
}

class Texture {
public:
    int width;
    int height;
    int channels;
    bool stencil;
    bool renderTarget;

private:
    ubyte[] pixels_;

public:
    DXPtr!ID3D12Resource gpuTexture;
    DXPtr!ID3D12Resource gpuUpload;
    size_t gpuUploadCapacity;
    D3D12_RESOURCE_STATES gpuState;
    bool gpuStateValid;
    bool gpuDirty = true;
    int gpuWidth;
    int gpuHeight;
    bool gpuRenderTarget;

    this(int width, int height, int channels, bool stencil, bool renderTarget = false) {
        this.width = width;
        this.height = height;
        this.channels = channels;
        this.stencil = stencil;
        this.renderTarget = renderTarget;
    }

    void setData(const(ubyte)[] src, int channels) {
        auto count = cast(size_t)max(0, width) * cast(size_t)max(0, height);
        pixels_.length = count * 4;
        this.channels = 4;
        if (count == 0 || src.length == 0) {
            gpuDirty = true;
            return;
        }

        if (channels == 4 && src.length >= pixels_.length) {
            pixels_[] = src[0 .. pixels_.length];
        } else {
            foreach (i; 0 .. count) {
                auto inBase = i * cast(size_t)max(1, channels);
                auto outBase = i * 4;
                ubyte r = 255;
                ubyte g = 255;
                ubyte b = 255;
                ubyte a = 255;
                if (channels >= 1 && inBase < src.length) r = src[inBase];
                if (channels >= 2 && inBase + 1 < src.length) g = src[inBase + 1];
                if (channels >= 3 && inBase + 2 < src.length) b = src[inBase + 2];
                if (channels >= 4 && inBase + 3 < src.length) a = src[inBase + 3];
                if (channels == 1) {
                    g = r;
                    b = r;
                } else if (channels == 2) {
                    b = r;
                    a = g;
                    g = r;
                }
                pixels_[outBase + 0] = r;
                pixels_[outBase + 1] = g;
                pixels_[outBase + 2] = b;
                pixels_[outBase + 3] = a;
            }
        }
        gpuDirty = true;
    }

    @property const(ubyte)[] pixels() const {
        return pixels_;
    }

    @property size_t pixelCount() const {
        return cast(size_t)max(0, width) * cast(size_t)max(0, height);
    }

    void dispose() {
        pixels_.length = 0;
        invalidateGpuObjects();
    }

    void invalidateGpuObjects() {
        gpuTexture = null;
        gpuUpload = null;
        gpuUploadCapacity = 0;
        gpuState = cast(D3D12_RESOURCE_STATES)0;
        gpuStateValid = false;
        gpuDirty = true;
        gpuWidth = 0;
        gpuHeight = 0;
        gpuRenderTarget = false;
    }
}

class RenderingBackend {
public:
    SDL_Window* window;
    int viewportW;
    int viewportH;
    SharedBufferSnapshot currentSnapshot;
    D3D12_HEAP_TYPE heapType = D3D12_HEAP_TYPE.UPLOAD;

private:
    bool announced;
    struct Vertex {
        float x;
        float y;
        float u;
        float v;
    }
    Vertex[] cpuVertices;
    ushort[] cpuIndices;
    uint frameSeq;
    uint drawCalls;
    bool inMaskPass;
    bool inMaskContent;
    bool maskUsesStencil;
    bool maskClearPending;
    ubyte maskClearValue;
    bool forceStencilWrite;
    ubyte forceStencilRef;
    bool inDynamicComposite;
    Texture maskFallbackTexture;
    struct DrawSpan {
        uint firstIndex;
        uint indexCount;
        BlendMode blendMode;
        Texture[3] renderTargets;
        uint renderTargetCount;
        bool clearRenderTarget;
        StencilMode stencilMode;
        ubyte stencilRef;
        ubyte stencilClearValue;
        bool clearStencil;
        Texture[3] textures;
        uint textureCount;
        bool useMultistageBlend;
        bool hasEmissionOrBumpmap;
        bool isMask;
        float maskThreshold;
        Vec3f clampedTint;
        Vec3f clampedScreen;
        float opacity;
        float emissionStrength;
    }
    DrawSpan[] drawSpans;
    uint dynamicCompositeDepth;
    struct CompositeState {
        Vec2f scale;
        float rotationZ;
        bool autoScaled;
        int[4] origViewport;
        Texture[3] textures;
        size_t textureCount;
        size_t stencil;
        RenderResourceHandle origBuffer;
        int drawBufferCount;
        bool hasStencil;
        bool clearPending;
    }
    CompositeState[] compositeStateStack;
    CompositeState currentCompositeState;
    struct DirectXRuntime {
        enum uint FrameCount = 2;

        HWND hwnd = null;
        int viewportW = 0;
        int viewportH = 0;

        DXPtr!IDXGIFactory6 factoryPtr;
        DXPtr!IDXGIAdapter4 adapterPtr;
        DXPtr!ID3D12Device devicePtr;
        DXPtr!ID3D12CommandQueue queuePtr;
        DXPtr!ID3D12CommandAllocator allocatorPtr;
        DXPtr!ID3D12GraphicsCommandList commandListPtr;
        DXPtr!IDXGISwapChain3 swapChainPtr;
        DXPtr!ID3D12DescriptorHeap rtvHeapPtr;
        DXPtr!ID3D12DescriptorHeap offscreenRtvHeapPtr;
        DXPtr!ID3D12DescriptorHeap dsvHeapPtr;
        DXPtr!ID3D12DescriptorHeap srvHeapPtr;
        DXPtr!ID3D12RootSignature rootSignaturePtr;
        DXPtr!ID3D12PipelineState[cast(size_t)BlendMode.Count] pipelineStates;
        DXPtr!ID3D12PipelineState[cast(size_t)BlendMode.Count] pipelineStatesStencilTest;
        DXPtr!ID3D12PipelineState pipelineStateStencilWrite;
        DXPtr!ID3D12PipelineState[cast(size_t)BlendMode.Count] pipelineStatesMrt;
        DXPtr!ID3D12PipelineState[cast(size_t)BlendMode.Count] pipelineStatesStencilTestMrt;
        DXPtr!ID3D12PipelineState pipelineStateStencilWriteMrt;
        DXPtr!ID3D12PipelineState[cast(size_t)BlendMode.Count] pipelineStatesMrt2;
        DXPtr!ID3D12PipelineState[cast(size_t)BlendMode.Count] pipelineStatesStencilTestMrt2;
        DXPtr!ID3D12PipelineState pipelineStateStencilWriteMrt2;
        DXPtr!ID3D12Resource[FrameCount] renderTargets;
        DXPtr!ID3D12Resource depthStencil;
        DXPtr!ID3D12Resource offscreenDepthStencil;
        int offscreenDsvW = 0;
        int offscreenDsvH = 0;
        DXPtr!ID3D12Resource vertexUploadBuffer;
        DXPtr!ID3D12Resource indexUploadBuffer;
        size_t vertexUploadCapacity = 0;
        size_t indexUploadCapacity = 0;
        size_t uploadedVertexBytes = 0;
        size_t uploadedIndexBytes = 0;
        uint srvDescriptorSize = 0;
        uint srvDescriptorCapacity = 0;
        uint offscreenRtvDescriptorCapacity = 0;
        uint offscreenRtvCursor = 0;
        D3D12_VERTEX_BUFFER_VIEW vbView = D3D12_VERTEX_BUFFER_VIEW.init;
        D3D12_INDEX_BUFFER_VIEW ibView = D3D12_INDEX_BUFFER_VIEW.init;
        uint rtvDescriptorSize = 0;
        uint dsvDescriptorSize = 0;
        uint frameIndex = 0;
        DXPtr!ID3D12Fence fencePtr;
        HANDLE fenceEvent = null;
        ulong fenceValue = 0;
        size_t rtvHeapCpuStartPtr = 0;
        size_t offscreenRtvHeapCpuStartPtr = 0;
        size_t dsvHeapCpuStartPtr = 0;
        size_t srvHeapCpuStartPtr = 0;
        ulong srvHeapGpuStartPtr = 0;
        bool initialized;
        bool debugLayerEnabled;
        bool deviceResetOccurred;
        bool recoveryPending;
        uint recoveryRetryFrames;
        uint recoveryAttempt;

        static D3D12_CPU_DESCRIPTOR_HANDLE descriptorHeapCpuStart(ID3D12DescriptorHeap heap) {
            D3D12_CPU_DESCRIPTOR_HANDLE h = D3D12_CPU_DESCRIPTOR_HANDLE.init;
            if (heap is null) return h;
            void* raw = null;
            auto qhr = (cast(IUnknown)heap).QueryInterface(
                cast(const(core.sys.windows.basetyps.GUID)*)&IID_ID3D12DescriptorHeap_Win,
                &raw);
            if (dxFailed(qhr) || raw is null) {
                return h;
            }
            alias Fn = extern(Windows) void function(void* self, D3D12_CPU_DESCRIPTOR_HANDLE* outHandle);
            auto vtbl = *cast(void***)raw;
            auto fn = cast(Fn)vtbl[9];
            fn(raw, &h);
            (cast(IUnknown)raw).Release();
            return h;
        }

        static ulong descriptorHeapGpuStart(ID3D12DescriptorHeap heap) {
            if (heap is null) return 0;
            void* raw = null;
            auto qhr = (cast(IUnknown)heap).QueryInterface(
                cast(const(core.sys.windows.basetyps.GUID)*)&IID_ID3D12DescriptorHeap_Win,
                &raw);
            if (dxFailed(qhr) || raw is null) {
                return 0;
            }
            D3D12_GPU_DESCRIPTOR_HANDLE h = D3D12_GPU_DESCRIPTOR_HANDLE.init;
            alias Fn = extern(Windows) void function(void* self, D3D12_GPU_DESCRIPTOR_HANDLE* outHandle);
            auto vtbl = *cast(void***)raw;
            auto fn = cast(Fn)vtbl[10];
            fn(raw, &h);
            (cast(IUnknown)raw).Release();
            return h.ptr;
        }

        D3D12_CPU_DESCRIPTOR_HANDLE currentRtvHandle() {
            D3D12_CPU_DESCRIPTOR_HANDLE h = D3D12_CPU_DESCRIPTOR_HANDLE.init;
            h.ptr = rtvHeapCpuStartPtr;
            h.ptr += cast(size_t)(frameIndex * rtvDescriptorSize);
            return h;
        }

        D3D12_CPU_DESCRIPTOR_HANDLE offscreenRtvHandle() {
            D3D12_CPU_DESCRIPTOR_HANDLE h = D3D12_CPU_DESCRIPTOR_HANDLE.init;
            h.ptr = offscreenRtvHeapCpuStartPtr;
            return h;
        }
        D3D12_CPU_DESCRIPTOR_HANDLE offscreenRtvHandleAt(uint index) {
            D3D12_CPU_DESCRIPTOR_HANDLE h = D3D12_CPU_DESCRIPTOR_HANDLE.init;
            h.ptr = offscreenRtvHeapCpuStartPtr;
            h.ptr += cast(size_t)(index * rtvDescriptorSize);
            return h;
        }

        D3D12_CPU_DESCRIPTOR_HANDLE dsvHandle() {
            D3D12_CPU_DESCRIPTOR_HANDLE h = D3D12_CPU_DESCRIPTOR_HANDLE.init;
            h.ptr = dsvHeapCpuStartPtr;
            return h;
        }

        D3D12_CPU_DESCRIPTOR_HANDLE offscreenDsvHandle() {
            D3D12_CPU_DESCRIPTOR_HANDLE h = D3D12_CPU_DESCRIPTOR_HANDLE.init;
            h.ptr = dsvHeapCpuStartPtr;
            h.ptr += cast(size_t)dsvDescriptorSize;
            return h;
        }

        void releaseDxResource(ref DXPtr!ID3D12Resource resource) {
            if (resource is null) return;
            resource.opAssign(cast(ID3D12Resource)null);
            resource = null;
        }

        static BlendMode sanitizeBlendMode(int rawMode) {
            if (rawMode >= 0 && rawMode < cast(int)BlendMode.Count) {
                return cast(BlendMode)rawMode;
            }
            return BlendMode.Normal;
        }

        static D3D12_BLEND_DESC buildBlendDesc(BlendMode mode) {
            D3D12_BLEND_DESC s = D3D12_BLEND_DESC.init;
            s.AlphaToCoverageEnable = false;
            s.IndependentBlendEnable = false;
            s.RenderTarget[0].BlendEnable = true;
            s.RenderTarget[0].LogicOpEnable = false;
            s.RenderTarget[0].SrcBlend = D3D12_BLEND.ONE;
            s.RenderTarget[0].DestBlend = D3D12_BLEND.INV_SRC_ALPHA;
            s.RenderTarget[0].BlendOp = D3D12_BLEND_OP.ADD;
            s.RenderTarget[0].SrcBlendAlpha = D3D12_BLEND.ONE;
            s.RenderTarget[0].DestBlendAlpha = D3D12_BLEND.INV_SRC_ALPHA;
            s.RenderTarget[0].BlendOpAlpha = D3D12_BLEND_OP.ADD;
            s.RenderTarget[0].LogicOp = D3D12_LOGIC_OP.NOOP;
            s.RenderTarget[0].RenderTargetWriteMask = cast(ubyte)D3D12_COLOR_WRITE_ENABLE.ALL;

            auto setBlendFunc = (D3D12_BLEND src, D3D12_BLEND dst) {
                s.RenderTarget[0].SrcBlend = src;
                s.RenderTarget[0].DestBlend = dst;
                s.RenderTarget[0].SrcBlendAlpha = src;
                s.RenderTarget[0].DestBlendAlpha = dst;
            };
            auto setColorBlend = (D3D12_BLEND srcColor, D3D12_BLEND dstColor) {
                // D3D12 PSO creation can reject some color factors in alpha channels.
                // Keep alpha channel on standard compositing while varying color factors.
                s.RenderTarget[0].SrcBlend = srcColor;
                s.RenderTarget[0].DestBlend = dstColor;
                s.RenderTarget[0].SrcBlendAlpha = D3D12_BLEND.ONE;
                s.RenderTarget[0].DestBlendAlpha = D3D12_BLEND.INV_SRC_ALPHA;
            };
            auto setBlendFuncSeparate = (D3D12_BLEND srcColor,
                                         D3D12_BLEND dstColor,
                                         D3D12_BLEND srcAlpha,
                                         D3D12_BLEND dstAlpha) {
                s.RenderTarget[0].SrcBlend = srcColor;
                s.RenderTarget[0].DestBlend = dstColor;
                s.RenderTarget[0].SrcBlendAlpha = srcAlpha;
                s.RenderTarget[0].DestBlendAlpha = dstAlpha;
            };

            final switch (mode) {
                case BlendMode.Normal:
                    s.RenderTarget[0].BlendOp = D3D12_BLEND_OP.ADD;
                    s.RenderTarget[0].BlendOpAlpha = D3D12_BLEND_OP.ADD;
                    setBlendFunc(D3D12_BLEND.ONE, D3D12_BLEND.INV_SRC_ALPHA);
                    break;
                case BlendMode.Multiply:
                    s.RenderTarget[0].BlendOp = D3D12_BLEND_OP.ADD;
                    s.RenderTarget[0].BlendOpAlpha = D3D12_BLEND_OP.ADD;
                    setColorBlend(D3D12_BLEND.DEST_COLOR, D3D12_BLEND.INV_SRC_ALPHA);
                    break;
                case BlendMode.Screen:
                    s.RenderTarget[0].BlendOp = D3D12_BLEND_OP.ADD;
                    s.RenderTarget[0].BlendOpAlpha = D3D12_BLEND_OP.ADD;
                    setColorBlend(D3D12_BLEND.ONE, D3D12_BLEND.INV_SRC_COLOR);
                    break;
                case BlendMode.Overlay:
                case BlendMode.ColorBurn:
                case BlendMode.HardLight:
                case BlendMode.SoftLight:
                case BlendMode.Difference:
                    // Legacy fallback path.
                    s.RenderTarget[0].BlendOp = D3D12_BLEND_OP.ADD;
                    s.RenderTarget[0].BlendOpAlpha = D3D12_BLEND_OP.ADD;
                    setBlendFunc(D3D12_BLEND.ONE, D3D12_BLEND.INV_SRC_ALPHA);
                    break;
                case BlendMode.Darken:
                    s.RenderTarget[0].BlendOp = D3D12_BLEND_OP.MIN;
                    s.RenderTarget[0].BlendOpAlpha = D3D12_BLEND_OP.ADD;
                    setBlendFunc(D3D12_BLEND.ONE, D3D12_BLEND.ONE);
                    break;
                case BlendMode.Lighten:
                    s.RenderTarget[0].BlendOp = D3D12_BLEND_OP.MAX;
                    s.RenderTarget[0].BlendOpAlpha = D3D12_BLEND_OP.ADD;
                    setBlendFunc(D3D12_BLEND.ONE, D3D12_BLEND.ONE);
                    break;
                case BlendMode.ColorDodge:
                    s.RenderTarget[0].BlendOp = D3D12_BLEND_OP.ADD;
                    s.RenderTarget[0].BlendOpAlpha = D3D12_BLEND_OP.ADD;
                    setColorBlend(D3D12_BLEND.DEST_COLOR, D3D12_BLEND.ONE);
                    break;
                case BlendMode.LinearDodge:
                    s.RenderTarget[0].BlendOp = D3D12_BLEND_OP.ADD;
                    s.RenderTarget[0].BlendOpAlpha = D3D12_BLEND_OP.ADD;
                    setBlendFuncSeparate(D3D12_BLEND.ONE,
                                         D3D12_BLEND.INV_SRC_COLOR,
                                         D3D12_BLEND.ONE,
                                         D3D12_BLEND.INV_SRC_ALPHA);
                    break;
                case BlendMode.AddGlow:
                    s.RenderTarget[0].BlendOp = D3D12_BLEND_OP.ADD;
                    s.RenderTarget[0].BlendOpAlpha = D3D12_BLEND_OP.ADD;
                    setBlendFuncSeparate(D3D12_BLEND.ONE,
                                         D3D12_BLEND.ONE,
                                         D3D12_BLEND.ONE,
                                         D3D12_BLEND.INV_SRC_ALPHA);
                    break;
                case BlendMode.Exclusion:
                    s.RenderTarget[0].BlendOp = D3D12_BLEND_OP.ADD;
                    s.RenderTarget[0].BlendOpAlpha = D3D12_BLEND_OP.ADD;
                    setBlendFuncSeparate(D3D12_BLEND.INV_DEST_COLOR,
                                         D3D12_BLEND.INV_SRC_COLOR,
                                         D3D12_BLEND.ONE,
                                         D3D12_BLEND.ONE);
                    break;
                case BlendMode.Subtract:
                    s.RenderTarget[0].BlendOp = D3D12_BLEND_OP.REV_SUBTRACT;
                    s.RenderTarget[0].BlendOpAlpha = D3D12_BLEND_OP.ADD;
                    setColorBlend(D3D12_BLEND.INV_DEST_COLOR, D3D12_BLEND.ONE);
                    break;
                case BlendMode.Inverse:
                    s.RenderTarget[0].BlendOp = D3D12_BLEND_OP.ADD;
                    s.RenderTarget[0].BlendOpAlpha = D3D12_BLEND_OP.ADD;
                    setColorBlend(D3D12_BLEND.INV_DEST_COLOR, D3D12_BLEND.INV_SRC_ALPHA);
                    break;
                case BlendMode.DestinationIn:
                    s.RenderTarget[0].BlendOp = D3D12_BLEND_OP.ADD;
                    s.RenderTarget[0].BlendOpAlpha = D3D12_BLEND_OP.ADD;
                    setBlendFunc(D3D12_BLEND.ZERO, D3D12_BLEND.SRC_ALPHA);
                    break;
                case BlendMode.ClipToLower:
                    s.RenderTarget[0].BlendOp = D3D12_BLEND_OP.ADD;
                    s.RenderTarget[0].BlendOpAlpha = D3D12_BLEND_OP.ADD;
                    setBlendFunc(D3D12_BLEND.DEST_ALPHA, D3D12_BLEND.INV_SRC_ALPHA);
                    break;
                case BlendMode.SliceFromLower:
                    s.RenderTarget[0].BlendOp = D3D12_BLEND_OP.ADD;
                    s.RenderTarget[0].BlendOpAlpha = D3D12_BLEND_OP.ADD;
                    setBlendFunc(D3D12_BLEND.ZERO, D3D12_BLEND.INV_SRC_ALPHA);
                    break;
                case BlendMode.Count:
                    break;
            }

            return s;
        }

        void releaseRenderTargets() {
            foreach (i; 0 .. FrameCount) {
                releaseDxResource(renderTargets[i]);
            }
        }

        void createRenderTargets() {
            dxTrace("createRenderTargets.begin");
            releaseRenderTargets();
            foreach (i; 0 .. FrameCount) {
                dxTrace("createRenderTargets.beforeGetBuffer i=" ~ to!string(i));
                ID3D12Resource rawRt = null;
                enforceHr(swapChainPtr.value.GetBuffer(cast(uint)i, cast(aurora.directx.com.GUID*)&IID_ID3D12Resource_Win, cast(void**)&rawRt),
                    "IDXGISwapChain3.GetBuffer failed");
                dxTrace("createRenderTargets.afterGetBuffer i=" ~ to!string(i));
                void* qiRtProbe = null;
                auto qiRtHr = (cast(IUnknown)rawRt).QueryInterface(
                    cast(const(core.sys.windows.basetyps.GUID)*)iid!IUnknown,
                    &qiRtProbe);
                dxTrace("createRenderTargets.rawRtQI i=" ~ to!string(i) ~
                    " hr=" ~ to!string(cast(int)qiRtHr) ~
                    " ptr=" ~ to!string(cast(size_t)qiRtProbe));
                if (qiRtProbe !is null) {
                    (cast(IUnknown)qiRtProbe).Release();
                }
                void* qiResProbe = null;
                auto qiResHr = (cast(IUnknown)rawRt).QueryInterface(
                    cast(const(core.sys.windows.basetyps.GUID)*)&IID_ID3D12Resource_Win,
                    &qiResProbe);
                dxTrace("createRenderTargets.rawRtAsD3D12Resource i=" ~ to!string(i) ~
                    " hr=" ~ to!string(cast(int)qiResHr) ~
                    " ptr=" ~ to!string(cast(size_t)qiResProbe));
                if (qiResProbe !is null) {
                    (cast(IUnknown)qiResProbe).Release();
                }
                renderTargets[i] = new DXPtr!ID3D12Resource(rawRt);
                D3D12_CPU_DESCRIPTOR_HANDLE handle = D3D12_CPU_DESCRIPTOR_HANDLE.init;
                dxTrace("createRenderTargets.beforeHeapCpuStart i=" ~ to!string(i));
                handle.ptr = rtvHeapCpuStartPtr;
                dxTrace("createRenderTargets.afterHeapCpuStart i=" ~ to!string(i) ~ " ptr=" ~ to!string(handle.ptr));
                handle.ptr += cast(size_t)(i * rtvDescriptorSize);
                dxTrace("createRenderTargets.rtvHandle i=" ~ to!string(i) ~ " ptr=" ~ to!string(handle.ptr));
                dxTrace("createRenderTargets.beforeCreateRTV i=" ~ to!string(i));
                devicePtr.value.CreateRenderTargetView(renderTargets[i].value, null, handle);
                dxTrace("createRenderTargets.afterCreateRTV i=" ~ to!string(i));
            }
            frameIndex = swapChainPtr.value.GetCurrentBackBufferIndex();
            dxTrace("createRenderTargets.afterGetCurrentBackBufferIndex");
        }

        void createSwapChainAndTargets() {
            dxTrace("createSwapChainAndTargets.begin");
            DXGI_SWAP_CHAIN_DESC1 sd = DXGI_SWAP_CHAIN_DESC1.init;
            sd.Width = cast(uint)max(1, viewportW);
            sd.Height = cast(uint)max(1, viewportH);
            sd.Format = DXGI_FORMAT.R8G8B8A8_UNORM;
            sd.Stereo = false;
            sd.SampleDesc.Count = 1;
            sd.SampleDesc.Quality = 0;
            sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
            sd.BufferCount = FrameCount;
            sd.Scaling = DXGI_SCALING.STRETCH;
            sd.SwapEffect = DXGI_SWAP_EFFECT.FLIP_SEQUENTIAL;
            sd.AlphaMode = DXGI_ALPHA_MODE.IGNORE;
            sd.Flags = 0;

            IDXGISwapChain1 rawSwapChain1 = null;
            dxTrace("createSwapChainAndTargets.beforeCreateSwapChainForHwnd");
            enforceHr(factoryPtr.value.CreateSwapChainForHwnd(
                queuePtr.value,
                hwnd,
                &sd,
                null,
                null,
                &rawSwapChain1),
                "CreateSwapChainForHwnd failed");
            dxTrace("createSwapChainAndTargets.afterCreateSwapChainForHwnd");

            IDXGISwapChain3 rawSwapChain3 = null;
            dxTrace("createSwapChainAndTargets.beforeQuerySwapChain3");
            // IID via fixed constant to avoid uuidof cast discrepancies across bindings.
            enforceHr(rawSwapChain1.QueryInterface(
                cast(const(core.sys.windows.basetyps.GUID)*)&IID_IDXGISwapChain3_Win,
                cast(void**)&rawSwapChain3),
                "IDXGISwapChain1.QueryInterface(IDXGISwapChain3) failed");
            rawSwapChain1.Release();
            swapChainPtr = new DXPtr!IDXGISwapChain3(rawSwapChain3);
            dxTrace("createSwapChainAndTargets.afterQuerySwapChain3");

            enforceHr(factoryPtr.value.MakeWindowAssociation(hwnd, DXGI_MWA_NO_ALT_ENTER),
                "MakeWindowAssociation failed");
            dxTrace("createSwapChainAndTargets.afterMakeWindowAssociation");

            D3D12_DESCRIPTOR_HEAP_DESC rtvDesc = D3D12_DESCRIPTOR_HEAP_DESC.init;
            rtvDesc.Type = D3D12_DESCRIPTOR_HEAP_TYPE.RTV;
            rtvDesc.NumDescriptors = FrameCount;
            rtvDesc.Flags = D3D12_DESCRIPTOR_HEAP_FLAGS.NONE;
            rtvDesc.NodeMask = 0;
            ID3D12DescriptorHeap rawRtvHeap = null;
            dxTrace("createSwapChainAndTargets.beforeCreateRTVHeap");
            enforceHr(devicePtr.value.CreateDescriptorHeap(
                &rtvDesc,
                &IID_ID3D12DescriptorHeap_Win,
                cast(void**)&rawRtvHeap),
                "CreateDescriptorHeap(RTV) failed");
            void* qiHeapUnk = null;
            auto qiHeapUnkHr = (cast(IUnknown)rawRtvHeap).QueryInterface(
                cast(const(core.sys.windows.basetyps.GUID)*)iid!IUnknown,
                &qiHeapUnk);
            dxTrace("createSwapChainAndTargets.rtvHeapQI-IUnknown hr=" ~ to!string(cast(int)qiHeapUnkHr) ~
                " ptr=" ~ to!string(cast(size_t)qiHeapUnk));
            if (qiHeapUnk !is null) (cast(IUnknown)qiHeapUnk).Release();
            void* qiHeapSelf = null;
            auto qiHeapSelfHr = (cast(IUnknown)rawRtvHeap).QueryInterface(
                cast(const(core.sys.windows.basetyps.GUID)*)&IID_ID3D12DescriptorHeap_Win,
                &qiHeapSelf);
            dxTrace("createSwapChainAndTargets.rtvHeapQI-Heap hr=" ~ to!string(cast(int)qiHeapSelfHr) ~
                " ptr=" ~ to!string(cast(size_t)qiHeapSelf));
            if (qiHeapSelf !is null) (cast(IUnknown)qiHeapSelf).Release();
            rtvHeapPtr = new DXPtr!ID3D12DescriptorHeap(rawRtvHeap);
            rtvDescriptorSize = devicePtr.value.GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE.RTV);
            rtvHeapCpuStartPtr = descriptorHeapCpuStart(rtvHeapPtr.value).ptr;
            dxTrace("createSwapChainAndTargets.afterCreateRTVHeap");

            enum uint kOffscreenRtvDescriptors = 8192;
            D3D12_DESCRIPTOR_HEAP_DESC offscreenRtvDesc = D3D12_DESCRIPTOR_HEAP_DESC.init;
            offscreenRtvDesc.Type = D3D12_DESCRIPTOR_HEAP_TYPE.RTV;
            offscreenRtvDesc.NumDescriptors = kOffscreenRtvDescriptors;
            offscreenRtvDesc.Flags = D3D12_DESCRIPTOR_HEAP_FLAGS.NONE;
            offscreenRtvDesc.NodeMask = 0;
            ID3D12DescriptorHeap rawOffscreenRtv = null;
            dxTrace("createSwapChainAndTargets.beforeCreateOffscreenRTVHeap");
            enforceHr(devicePtr.value.CreateDescriptorHeap(
                &offscreenRtvDesc,
                &IID_ID3D12DescriptorHeap_Win,
                cast(void**)&rawOffscreenRtv),
                "CreateDescriptorHeap(Offscreen RTV) failed");
            offscreenRtvHeapPtr = new DXPtr!ID3D12DescriptorHeap(rawOffscreenRtv);
            offscreenRtvHeapCpuStartPtr = descriptorHeapCpuStart(offscreenRtvHeapPtr.value).ptr;
            offscreenRtvDescriptorCapacity = kOffscreenRtvDescriptors;
            offscreenRtvCursor = 0;
            dxTrace("createSwapChainAndTargets.afterCreateOffscreenRTVHeap");

            D3D12_DESCRIPTOR_HEAP_DESC dsvDesc = D3D12_DESCRIPTOR_HEAP_DESC.init;
            dsvDesc.Type = D3D12_DESCRIPTOR_HEAP_TYPE.DSV;
            dsvDesc.NumDescriptors = 2;
            dsvDesc.Flags = D3D12_DESCRIPTOR_HEAP_FLAGS.NONE;
            dsvDesc.NodeMask = 0;
            ID3D12DescriptorHeap rawDsvHeap = null;
            dxTrace("createSwapChainAndTargets.beforeCreateDSVHeap");
            enforceHr(devicePtr.value.CreateDescriptorHeap(
                &dsvDesc,
                &IID_ID3D12DescriptorHeap_Win,
                cast(void**)&rawDsvHeap),
                "CreateDescriptorHeap(DSV) failed");
            dsvHeapPtr = new DXPtr!ID3D12DescriptorHeap(rawDsvHeap);
            dsvDescriptorSize = devicePtr.value.GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE.DSV);
            dsvHeapCpuStartPtr = descriptorHeapCpuStart(dsvHeapPtr.value).ptr;
            dxTrace("createSwapChainAndTargets.afterCreateDSVHeap");

            dxTrace("createSwapChainAndTargets.beforeCreateRenderTargets");
            createRenderTargets();
            dxTrace("createSwapChainAndTargets.afterCreateRenderTargets");
            dxTrace("createSwapChainAndTargets.beforeCreateDepthStencilTarget");
            createDepthStencilTarget(max(1, viewportW), max(1, viewportH));
            dxTrace("createSwapChainAndTargets.afterCreateDepthStencilTarget");
        }

        void createDepthStencilTarget(int w, int h) {
            dxTrace("createDepthStencilTarget.begin w=" ~ to!string(w) ~ " h=" ~ to!string(h));
            releaseDxResource(depthStencil);
            D3D12_HEAP_PROPERTIES heapProps = D3D12_HEAP_PROPERTIES.init;
            heapProps.Type = D3D12_HEAP_TYPE.DEFAULT;
            heapProps.CPUPageProperty = D3D12_CPU_PAGE_PROPERTY.UNKNOWN;
            heapProps.MemoryPoolPreference = D3D12_MEMORY_POOL.POOL_UNKNOWN;
            heapProps.CreationNodeMask = 1;
            heapProps.VisibleNodeMask = 1;

            D3D12_RESOURCE_DESC dsDesc = D3D12_RESOURCE_DESC.init;
            dsDesc.Dimension = D3D12_RESOURCE_DIMENSION.TEXTURE2D;
            dsDesc.Alignment = 0;
            dsDesc.Width = cast(uint)max(1, w);
            dsDesc.Height = cast(uint)max(1, h);
            dsDesc.DepthOrArraySize = 1;
            dsDesc.MipLevels = 1;
            dsDesc.Format = DXGI_FORMAT.D24_UNORM_S8_UINT;
            dsDesc.SampleDesc.Count = 1;
            dsDesc.SampleDesc.Quality = 0;
            dsDesc.Layout = D3D12_TEXTURE_LAYOUT.LAYOUT_UNKNOWN;
            dsDesc.Flags = D3D12_RESOURCE_FLAGS.ALLOW_DEPTH_STENCIL;

            D3D12_CLEAR_VALUE clearValue = D3D12_CLEAR_VALUE.init;
            clearValue.Format = DXGI_FORMAT.D24_UNORM_S8_UINT;
            clearValue.DepthStencil.Depth = 1.0f;
            clearValue.DepthStencil.Stencil = 0;

            ID3D12Resource rawDs = null;
            dxTrace("createDepthStencilTarget.beforeCreateCommittedResource");
            enforceHr(devicePtr.value.CreateCommittedResource(
                &heapProps,
                D3D12_HEAP_FLAGS.NONE,
                &dsDesc,
                D3D12_RESOURCE_STATES.DEPTH_WRITE,
                &clearValue,
                &IID_ID3D12Resource_Win,
                cast(void**)&rawDs),
                "CreateCommittedResource(DepthStencil) failed");
            dxTrace("createDepthStencilTarget.afterCreateCommittedResource");
            depthStencil = new DXPtr!ID3D12Resource(rawDs);

            D3D12_DEPTH_STENCIL_VIEW_DESC dsvView = D3D12_DEPTH_STENCIL_VIEW_DESC.init;
            dsvView.Format = DXGI_FORMAT.D24_UNORM_S8_UINT;
            dsvView.ViewDimension = D3D12_DSV_DIMENSION.TEXTURE2D;
            dsvView.Flags = D3D12_DSV_FLAGS.NONE;
            dsvView.Texture2D.MipSlice = 0;
            dxTrace("createDepthStencilTarget.beforeCreateDepthStencilView");
            devicePtr.value.CreateDepthStencilView(depthStencil.value, &dsvView, dsvHandle());
            dxTrace("createDepthStencilTarget.afterCreateDepthStencilView");
        }

        bool ensureOffscreenDepthStencilTarget(int w, int h) {
            auto targetW = max(1, w);
            auto targetH = max(1, h);
            bool recreate = offscreenDepthStencil is null;
            if (!recreate) return true;

            releaseDxResource(offscreenDepthStencil);
            // Keep one offscreen DSV resource for the runtime lifetime.
            // Rewriting the same DSV descriptor within a command list can invalidate earlier draws.
            offscreenDsvW = max(1, viewportW);
            offscreenDsvH = max(1, viewportH);
            if (offscreenDsvW < targetW) offscreenDsvW = targetW;
            if (offscreenDsvH < targetH) offscreenDsvH = targetH;

            D3D12_HEAP_PROPERTIES heapProps = D3D12_HEAP_PROPERTIES.init;
            heapProps.Type = D3D12_HEAP_TYPE.DEFAULT;
            heapProps.CPUPageProperty = D3D12_CPU_PAGE_PROPERTY.UNKNOWN;
            heapProps.MemoryPoolPreference = D3D12_MEMORY_POOL.POOL_UNKNOWN;
            heapProps.CreationNodeMask = 1;
            heapProps.VisibleNodeMask = 1;

            D3D12_RESOURCE_DESC dsDesc = D3D12_RESOURCE_DESC.init;
            dsDesc.Dimension = D3D12_RESOURCE_DIMENSION.TEXTURE2D;
            dsDesc.Alignment = 0;
            dsDesc.Width = cast(uint)offscreenDsvW;
            dsDesc.Height = cast(uint)offscreenDsvH;
            dsDesc.DepthOrArraySize = 1;
            dsDesc.MipLevels = 1;
            dsDesc.Format = DXGI_FORMAT.D24_UNORM_S8_UINT;
            dsDesc.SampleDesc.Count = 1;
            dsDesc.SampleDesc.Quality = 0;
            dsDesc.Layout = D3D12_TEXTURE_LAYOUT.LAYOUT_UNKNOWN;
            dsDesc.Flags = D3D12_RESOURCE_FLAGS.ALLOW_DEPTH_STENCIL;

            D3D12_CLEAR_VALUE clearValue = D3D12_CLEAR_VALUE.init;
            clearValue.Format = DXGI_FORMAT.D24_UNORM_S8_UINT;
            clearValue.DepthStencil.Depth = 1.0f;
            clearValue.DepthStencil.Stencil = 0;

            ID3D12Resource rawDs = null;
            dxTrace("ensureOffscreenDepthStencilTarget.beforeCreateCommittedResource");
            auto hr = devicePtr.value.CreateCommittedResource(
                &heapProps,
                D3D12_HEAP_FLAGS.NONE,
                &dsDesc,
                D3D12_RESOURCE_STATES.DEPTH_WRITE,
                &clearValue,
                &IID_ID3D12Resource_Win,
                cast(void**)&rawDs);
            dxTrace("ensureOffscreenDepthStencilTarget.afterCreateCommittedResource hr=" ~ to!string(cast(int)hr));
            if (dxFailed(hr) || rawDs is null) {
                offscreenDepthStencil = null;
                return false;
            }
            offscreenDepthStencil = new DXPtr!ID3D12Resource(rawDs);

            D3D12_DEPTH_STENCIL_VIEW_DESC dsvView = D3D12_DEPTH_STENCIL_VIEW_DESC.init;
            dsvView.Format = DXGI_FORMAT.D24_UNORM_S8_UINT;
            dsvView.ViewDimension = D3D12_DSV_DIMENSION.TEXTURE2D;
            dsvView.Flags = D3D12_DSV_FLAGS.NONE;
            dsvView.Texture2D.MipSlice = 0;
            devicePtr.value.CreateDepthStencilView(offscreenDepthStencil.value, &dsvView, offscreenDsvHandle());
            return true;
        }

        void createSrvResources() {
            enum uint kSrvDescriptorCapacity = 32768;
            D3D12_DESCRIPTOR_HEAP_DESC heapDesc = D3D12_DESCRIPTOR_HEAP_DESC.init;
            heapDesc.Type = D3D12_DESCRIPTOR_HEAP_TYPE.CBV_SRV_UAV;
            heapDesc.NumDescriptors = kSrvDescriptorCapacity;
            heapDesc.Flags = D3D12_DESCRIPTOR_HEAP_FLAGS.SHADER_VISIBLE;
            heapDesc.NodeMask = 0;
            ID3D12DescriptorHeap rawHeap = null;
            enforceHr(devicePtr.value.CreateDescriptorHeap(
                &heapDesc,
                &IID_ID3D12DescriptorHeap_Win,
                cast(void**)&rawHeap),
                "CreateDescriptorHeap(CBV_SRV_UAV) failed");
            srvHeapPtr = new DXPtr!ID3D12DescriptorHeap(rawHeap);
            srvDescriptorSize = devicePtr.value.GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE.CBV_SRV_UAV);
            srvDescriptorCapacity = kSrvDescriptorCapacity;
            srvHeapCpuStartPtr = descriptorHeapCpuStart(srvHeapPtr.value).ptr;
            srvHeapGpuStartPtr = descriptorHeapGpuStart(srvHeapPtr.value);
        }

        void updateHeapSrvTexture2D(ID3D12Resource resource, uint descriptorIndex) {
            if (srvHeapPtr is null) return;
            D3D12_SHADER_RESOURCE_VIEW_DESC view = D3D12_SHADER_RESOURCE_VIEW_DESC.init;
            view.Format = DXGI_FORMAT.R8G8B8A8_UNORM;
            view.ViewDimension = D3D12_SRV_DIMENSION.TEXTURE2D;
            view.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING_VALUE;
            view.Texture2D.MostDetailedMip = 0;
            view.Texture2D.MipLevels = 1;
            view.Texture2D.PlaneSlice = 0;
            view.Texture2D.ResourceMinLODClamp = 0;
            D3D12_CPU_DESCRIPTOR_HANDLE cpu = D3D12_CPU_DESCRIPTOR_HANDLE.init;
            cpu.ptr = srvHeapCpuStartPtr;
            cpu.ptr += cast(size_t)(descriptorIndex * srvDescriptorSize);
            devicePtr.value.CreateShaderResourceView(resource, &view, cpu);
        }

        static size_t alignUp(size_t v, size_t a) {
            return ((v + a - 1) / a) * a;
        }

        void transitionResource(ID3D12Resource res, D3D12_RESOURCE_STATES before, D3D12_RESOURCE_STATES after) {
            D3D12_RESOURCE_BARRIER barrier = D3D12_RESOURCE_BARRIER.init;
            barrier.Type = D3D12_RESOURCE_BARRIER_TYPE.TRANSITION;
            barrier.Flags = D3D12_RESOURCE_BARRIER_FLAGS.NONE;
            barrier.Transition.pResource = res;
            barrier.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
            barrier.Transition.StateBefore = before;
            barrier.Transition.StateAfter = after;
            commandListPtr.value.ResourceBarrier(1, &barrier);
        }

        void transitionTextureState(Texture tex, D3D12_RESOURCE_STATES after) {
            if (tex is null || tex.gpuTexture is null) return;
            if (!tex.gpuStateValid) {
                tex.gpuState = after;
                tex.gpuStateValid = true;
                return;
            }
            if (tex.gpuState == after) return;
            if (isDxFlag("NJIV_DX_SKIP_TEX_BARRIERS")) {
                tex.gpuState = after;
                return;
            }
            transitionResource(tex.gpuTexture.value, tex.gpuState, after);
            tex.gpuState = after;
        }

        void ensureTextureUploaded(Texture tex) {
            if (tex is null) return;
            auto w = cast(uint)max(1, tex.width);
            auto h = cast(uint)max(1, tex.height);
            auto px = tex.pixels;
            auto pixelBytes = cast(size_t)(w * h * 4);
            bool hasPixels = px.length >= pixelBytes;

            bool recreateTexture = (tex.gpuTexture is null);
            if (!recreateTexture) {
                if (tex.gpuWidth != cast(int)w ||
                    tex.gpuHeight != cast(int)h ||
                    tex.gpuRenderTarget != tex.renderTarget) {
                    recreateTexture = true;
                }
            }
            if (recreateTexture) {
                tex.gpuTexture = null;
                tex.gpuUpload = null;
                tex.gpuUploadCapacity = 0;
                tex.gpuState = cast(D3D12_RESOURCE_STATES)0;
                tex.gpuStateValid = false;
                tex.gpuWidth = 0;
                tex.gpuHeight = 0;
                tex.gpuRenderTarget = false;

                D3D12_HEAP_PROPERTIES defaultHeap = D3D12_HEAP_PROPERTIES.init;
                defaultHeap.Type = D3D12_HEAP_TYPE.DEFAULT;
                defaultHeap.CPUPageProperty = D3D12_CPU_PAGE_PROPERTY.UNKNOWN;
                defaultHeap.MemoryPoolPreference = D3D12_MEMORY_POOL.POOL_UNKNOWN;
                defaultHeap.CreationNodeMask = 1;
                defaultHeap.VisibleNodeMask = 1;

                D3D12_RESOURCE_DESC texDesc = D3D12_RESOURCE_DESC.init;
                texDesc.Dimension = D3D12_RESOURCE_DIMENSION.TEXTURE2D;
                texDesc.Alignment = 0;
                texDesc.Width = w;
                texDesc.Height = h;
                texDesc.DepthOrArraySize = 1;
                texDesc.MipLevels = 1;
                texDesc.Format = DXGI_FORMAT.R8G8B8A8_UNORM;
                texDesc.SampleDesc.Count = 1;
                texDesc.SampleDesc.Quality = 0;
                texDesc.Layout = D3D12_TEXTURE_LAYOUT.LAYOUT_UNKNOWN;
                texDesc.Flags = tex.renderTarget
                    ? D3D12_RESOURCE_FLAGS.ALLOW_RENDER_TARGET
                    : D3D12_RESOURCE_FLAGS.NONE;

                D3D12_CLEAR_VALUE clearValue = D3D12_CLEAR_VALUE.init;
                clearValue.Format = DXGI_FORMAT.R8G8B8A8_UNORM;
                clearValue.Color[0] = 0.0f;
                clearValue.Color[1] = 0.0f;
                clearValue.Color[2] = 0.0f;
                clearValue.Color[3] = 0.0f;
                auto initialState = hasPixels
                    ? D3D12_RESOURCE_STATES.COPY_DEST
                    : D3D12_RESOURCE_STATES.PIXEL_SHADER_RESOURCE;
                auto pClear = tex.renderTarget ? &clearValue : null;

                ID3D12Resource rawTex = null;
                enforceHr(devicePtr.value.CreateCommittedResource(
                    &defaultHeap,
                    D3D12_HEAP_FLAGS.NONE,
                    &texDesc,
                    initialState,
                    pClear,
                    &IID_ID3D12Resource_Win,
                    cast(void**)&rawTex),
                    "CreateCommittedResource(Texture2D) failed");
                tex.gpuTexture = new DXPtr!ID3D12Resource(rawTex);
                tex.gpuState = initialState;
                tex.gpuStateValid = true;
                tex.gpuWidth = cast(int)w;
                tex.gpuHeight = cast(int)h;
                tex.gpuRenderTarget = tex.renderTarget;
            }

            if (!tex.gpuDirty) return;
            if (!hasPixels) {
                tex.gpuDirty = false;
                return;
            }

            auto rowPitch = alignUp(cast(size_t)w * 4, 256);
            auto uploadBytes = rowPitch * h;
            ensureUploadBuffer(uploadBytes, tex.gpuUpload, tex.gpuUploadCapacity, "textureUpload");

            D3D12_RANGE readRange = D3D12_RANGE(0, 0);
            void* mapped = null;
            enforceHr(tex.gpuUpload.value.Map(0, &readRange, &mapped), "Map textureUpload failed");
            enforce(mapped !is null, "textureUpload map returned null");
            foreach (y; 0 .. h) {
                auto srcOff = cast(size_t)y * cast(size_t)w * 4;
                auto dstOff = cast(size_t)y * rowPitch;
                memcpy(cast(ubyte*)mapped + dstOff, px.ptr + srcOff, cast(size_t)w * 4);
            }
            D3D12_RANGE writeRange = D3D12_RANGE(0, uploadBytes);
            tex.gpuUpload.value.Unmap(0, &writeRange);

            transitionTextureState(tex, D3D12_RESOURCE_STATES.COPY_DEST);

            D3D12_TEXTURE_COPY_LOCATION dst = D3D12_TEXTURE_COPY_LOCATION.init;
            dst.pResource = tex.gpuTexture.value;
            dst.Type = D3D12_TEXTURE_COPY_TYPE.SUBRESOURCE_INDEX;
            dst.SubresourceIndex = 0;

            D3D12_TEXTURE_COPY_LOCATION src = D3D12_TEXTURE_COPY_LOCATION.init;
            src.pResource = tex.gpuUpload.value;
            src.Type = D3D12_TEXTURE_COPY_TYPE.PLACED_FOOTPRINT;
            src.PlacedFootprint.Offset = 0;
            src.PlacedFootprint.Footprint.Format = DXGI_FORMAT.R8G8B8A8_UNORM;
            src.PlacedFootprint.Footprint.Width = w;
            src.PlacedFootprint.Footprint.Height = h;
            src.PlacedFootprint.Footprint.Depth = 1;
            src.PlacedFootprint.Footprint.RowPitch = cast(uint)rowPitch;

            commandListPtr.value.CopyTextureRegion(&dst, 0, 0, 0, &src, null);
            transitionTextureState(tex, D3D12_RESOURCE_STATES.PIXEL_SHADER_RESOURCE);
            tex.gpuDirty = false;
        }

        bool waitForGpu() {
            if (!initialized) return true;
            fenceValue++;
            auto signalHr = queuePtr.value.Signal(fencePtr.value, fenceValue);
            if (dxFailed(signalHr)) {
                if (isDxTraceEnabled()) {
                    dxTrace("waitForGpu: Signal failed hr=" ~ to!string(cast(uint)signalHr));
                }
                return false;
            }
            if (fencePtr.value.GetCompletedValue() < fenceValue) {
                auto eventHr = fencePtr.value.SetEventOnCompletion(fenceValue, fenceEvent);
                if (dxFailed(eventHr)) {
                    if (isDxTraceEnabled()) {
                        dxTrace("waitForGpu: SetEventOnCompletion failed hr=" ~ to!string(cast(uint)eventHr));
                    }
                    return false;
                }
                WaitForSingleObject(fenceEvent, INFINITE);
            }
            return true;
        }

        void recoverFromDeviceLoss(HRESULT presentHr) {
            HRESULT reason = presentHr;
            if (devicePtr !is null) {
                reason = devicePtr.value.GetDeviceRemovedReason();
            }
            if (isDxTraceEnabled()) {
                dxTrace("recoverFromDeviceLoss: presentHr=" ~ to!string(cast(uint)presentHr) ~
                    " reason=" ~ to!string(cast(uint)reason));
            }

            auto hwndLocal = hwnd;
            auto w = max(1, viewportW);
            auto h = max(1, viewportH);
            auto useDebugLayer = debugLayerEnabled;

            shutdown(false);
            deviceResetOccurred = true;
            recoveryPending = true;
            recoveryAttempt++;
            auto delay = cast(uint)(30 * recoveryAttempt);
            if (delay > 300) delay = 300;
            recoveryRetryFrames = delay;
            if (isDxTraceEnabled()) {
                dxTrace("recoverFromDeviceLoss: schedule retry in frames=" ~ to!string(recoveryRetryFrames));
            }
            // Keep these cached for deferred recovery attempts.
            this.hwnd = hwndLocal;
            this.viewportW = w;
            this.viewportH = h;
            this.debugLayerEnabled = useDebugLayer;
        }

        bool consumeDeviceResetFlag() {
            bool value = deviceResetOccurred;
            deviceResetOccurred = false;
            return value;
        }

        void resizeSwapChain(int w, int h) {
            if (!initialized || swapChainPtr is null) return;
            if (w <= 0 || h <= 0) return;
            if (viewportW == w && viewportH == h) return;

            waitForGpu();
            // Ensure the command list drops any references to old back buffers
            // before calling ResizeBuffers.
            if (allocatorPtr !is null && commandListPtr !is null) {
                auto allocResetHr = allocatorPtr.value.Reset();
                if (dxSucceeded(allocResetHr)) {
                    auto listResetHr = commandListPtr.value.Reset(allocatorPtr.value, null);
                    if (dxSucceeded(listResetHr)) {
                        commandListPtr.value.Close();
                    }
                }
            }
            viewportW = w;
            viewportH = h;
            releaseRenderTargets();

            enforceHr(swapChainPtr.value.ResizeBuffers(
                FrameCount,
                cast(uint)w,
                cast(uint)h,
                DXGI_FORMAT.R8G8B8A8_UNORM,
                0),
                "ResizeBuffers failed");

            createRenderTargets();
            createDepthStencilTarget(w, h);
            releaseDxResource(offscreenDepthStencil);
            offscreenDsvW = 0;
            offscreenDsvH = 0;
        }

        void createPipelineState() {
            dxTrace("createPipelineState.begin");
            immutable shaderSource = q{
struct VSInput {
    float2 pos : POSITION;
    float2 uv  : TEXCOORD0;
};
struct VSOutput {
    float4 pos : SV_POSITION;
    float2 uv  : TEXCOORD0;
};
VSOutput vsMain(VSInput input) {
    VSOutput o;
    o.pos = float4(input.pos, 0.0, 1.0);
    o.uv = input.uv;
    return o;
}
Texture2D gTex0 : register(t0);
Texture2D gTex1 : register(t1);
Texture2D gTex2 : register(t2);
SamplerState gSamp : register(s0);
cbuffer DrawParams : register(b0) {
    float useMultistage;
    float hasEmission;
    float opacity;
    float emissionStrength;
    float isMask;
    float maskThreshold;
    float flipTex0;
    float flipTex1;
    float3 multColor;
    float flipTex2;
    float3 screenColor;
    float screenPad;
}
float3 screenBlend(float3 tcol, float a, float3 sc) {
    return 1.0.xxx - ((1.0.xxx - tcol) * (1.0.xxx - (sc * a)));
}
float4 sampleTex(Texture2D tex, float2 uv, float flipY) {
    float2 su = uv;
    if (flipY > 0.5) {
        su.y = 1.0 - su.y;
    }
    return tex.Sample(gSamp, su);
}
float4 psMain(VSOutput input) : SV_TARGET {
    float2 uv = saturate(input.uv);
    float4 c0 = sampleTex(gTex0, uv, flipTex0);
    float4 c1 = sampleTex(gTex1, uv, flipTex1);
    float4 c2 = sampleTex(gTex2, uv, flipTex2);
    if (isMask > 0.5) {
        if (c0.a <= maskThreshold) discard;
        return float4(1, 1, 1, 1);
    }

    float4 albedoOut = float4(screenBlend(c0.rgb, c0.a, screenColor), c0.a) * float4(multColor, 1);
    float4 emissionOut = float4(screenBlend(c1.rgb, c0.a, screenColor), c0.a) * float4(multColor, 1) * emissionStrength;

    float4 outColor = albedoOut * opacity;
    if (useMultistage > 0.5 && hasEmission > 0.5) {
        outColor.rgb += emissionOut.rgb * outColor.a;
    }
    return outColor + c2 * 0.0;
}};

            ID3DBlob vsBlob = null;
            ID3DBlob psBlob = null;
            ID3DBlob errBlob = null;
            scope (exit) {
                if (vsBlob !is null) vsBlob.Release();
                if (psBlob !is null) psBlob.Release();
                if (errBlob !is null) errBlob.Release();
            }

            auto compileFlags = D3DCOMPILE_ENABLE_STRICTNESS | D3DCOMPILE_OPTIMIZATION_LEVEL3;
            dxTrace("createPipelineState.beforeCompileVS");
            auto hrVs = D3DCompile(
                shaderSource.ptr,
                shaderSource.length,
                "nijiv_dx12_shader",
                null,
                null,
                "vsMain",
                "vs_5_0",
                compileFlags,
                0,
                &vsBlob,
                &errBlob);
            if (dxFailed(hrVs)) {
                auto msg = (errBlob !is null && errBlob.GetBufferPointer() !is null)
                    ? fromStringz(cast(const(char)*)errBlob.GetBufferPointer()).idup
                    : "unknown shader compile error";
                enforce(false, "D3DCompile VS failed: " ~ msg);
            }
            dxTrace("createPipelineState.afterCompileVS");
            if (errBlob !is null) {
                errBlob.Release();
                errBlob = null;
            }

            dxTrace("createPipelineState.beforeCompilePS");
            auto hrPs = D3DCompile(
                shaderSource.ptr,
                shaderSource.length,
                "nijiv_dx12_shader",
                null,
                null,
                "psMain",
                "ps_5_0",
                compileFlags,
                0,
                &psBlob,
                &errBlob);
            if (dxFailed(hrPs)) {
                auto msg = (errBlob !is null && errBlob.GetBufferPointer() !is null)
                    ? fromStringz(cast(const(char)*)errBlob.GetBufferPointer()).idup
                    : "unknown shader compile error";
                enforce(false, "D3DCompile PS failed: " ~ msg);
            }
            dxTrace("createPipelineState.afterCompilePS");
            if (errBlob !is null) {
                errBlob.Release();
                errBlob = null;
            }

            D3D12_DESCRIPTOR_RANGE srvRange = D3D12_DESCRIPTOR_RANGE(
                D3D12_DESCRIPTOR_RANGE_TYPE.SRV,
                3,
                0,
                0,
                0xffffffff);
            D3D12_ROOT_PARAMETER rootTableParam = {
                ParameterType: D3D12_ROOT_PARAMETER_TYPE.TYPE_DESCRIPTOR_TABLE,
                DescriptorTable: D3D12_ROOT_DESCRIPTOR_TABLE(1, &srvRange),
                ShaderVisibility: D3D12_SHADER_VISIBILITY.PIXEL,
            };
            D3D12_ROOT_PARAMETER rootConstantsParam = D3D12_ROOT_PARAMETER.init;
            rootConstantsParam.ParameterType = D3D12_ROOT_PARAMETER_TYPE.TYPE_32BIT_CONSTANTS;
            rootConstantsParam.Constants.ShaderRegister = 0;
            rootConstantsParam.Constants.RegisterSpace = 0;
            rootConstantsParam.Constants.Num32BitValues = 16;
            rootConstantsParam.ShaderVisibility = D3D12_SHADER_VISIBILITY.PIXEL;
            D3D12_ROOT_PARAMETER[2] rootParams;
            rootParams[0] = rootTableParam;
            rootParams[1] = rootConstantsParam;
            D3D12_STATIC_SAMPLER_DESC staticSampler = D3D12_STATIC_SAMPLER_DESC.init;
            staticSampler.Filter = D3D12_FILTER.MIN_MAG_MIP_LINEAR;
            staticSampler.AddressU = D3D12_TEXTURE_ADDRESS_MODE.CLAMP;
            staticSampler.AddressV = D3D12_TEXTURE_ADDRESS_MODE.CLAMP;
            staticSampler.AddressW = D3D12_TEXTURE_ADDRESS_MODE.CLAMP;
            staticSampler.MipLODBias = 0;
            staticSampler.MaxAnisotropy = 1;
            staticSampler.ComparisonFunc = D3D12_COMPARISON_FUNC.ALWAYS;
            staticSampler.BorderColor = D3D12_STATIC_BORDER_COLOR.OPAQUE_BLACK;
            staticSampler.MinLOD = 0;
            staticSampler.MaxLOD = 0;
            staticSampler.ShaderRegister = 0;
            staticSampler.RegisterSpace = 0;
            staticSampler.ShaderVisibility = D3D12_SHADER_VISIBILITY.PIXEL;

            auto rsDesc = D3D12_ROOT_SIGNATURE_DESC(
                rootParams.length,
                rootParams.ptr,
                1,
                &staticSampler,
                D3D12_ROOT_SIGNATURE_FLAGS.ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT);

            ID3DBlob rsBlob = null;
            ID3DBlob rsErrBlob = null;
            scope (exit) {
                if (rsBlob !is null) rsBlob.Release();
                if (rsErrBlob !is null) rsErrBlob.Release();
            }
            auto hrRs = WinD3D12SerializeRootSignature(&rsDesc, D3D_ROOT_SIGNATURE_VERSION.VERSION_1, &rsBlob, &rsErrBlob);
            if (dxFailed(hrRs)) {
                auto msg = (rsErrBlob !is null && rsErrBlob.GetBufferPointer() !is null)
                    ? fromStringz(cast(const(char)*)rsErrBlob.GetBufferPointer()).idup
                    : "root signature serialization failed";
                enforce(false, "D3D12SerializeRootSignature failed: " ~ msg);
            }
            dxTrace("createPipelineState.afterSerializeRootSignature");

            ID3D12RootSignature rawRoot = null;
            enforceHr(devicePtr.value.CreateRootSignature(
                0,
                rsBlob.GetBufferPointer(),
                rsBlob.GetBufferSize(),
                &IID_ID3D12RootSignature_Win,
                cast(void**)&rawRoot),
                "CreateRootSignature failed");
            dxTrace("createPipelineState.afterCreateRootSignature");
            rootSignaturePtr = new DXPtr!ID3D12RootSignature(rawRoot);

            static immutable char[] semanticPosition = "POSITION\0";
            static immutable char[] semanticTexcoord = "TEXCOORD\0";
            D3D12_INPUT_ELEMENT_DESC[2] inputElems;
            inputElems[0].SemanticName = semanticPosition.ptr;
            inputElems[0].SemanticIndex = 0;
            inputElems[0].Format = DXGI_FORMAT.R32G32_FLOAT;
            inputElems[0].InputSlot = 0;
            inputElems[0].AlignedByteOffset = 0;
            inputElems[0].InputSlotClass = D3D12_INPUT_CLASSIFICATION.PER_VERTEX_DATA;
            inputElems[0].InstanceDataStepRate = 0;
            inputElems[1].SemanticName = semanticTexcoord.ptr;
            inputElems[1].SemanticIndex = 0;
            inputElems[1].Format = DXGI_FORMAT.R32G32_FLOAT;
            inputElems[1].InputSlot = 0;
            inputElems[1].AlignedByteOffset = 8;
            inputElems[1].InputSlotClass = D3D12_INPUT_CLASSIFICATION.PER_VERTEX_DATA;
            inputElems[1].InstanceDataStepRate = 0;

            D3D12_RASTERIZER_DESC raster = D3D12_RASTERIZER_DESC.init;
            raster.FillMode = D3D12_FILL_MODE.D3D12_FILL_MODE_SOLID;
            raster.CullMode = D3D12_CULL_MODE.NONE;
            raster.FrontCounterClockwise = false;
            raster.DepthBias = D3D12_DEFAULT_DEPTH_BIAS;
            raster.DepthBiasClamp = D3D12_DEFAULT_DEPTH_BIAS_CLAMP;
            raster.SlopeScaledDepthBias = D3D12_DEFAULT_SLOPE_SCALED_DEPTH_BIAS;
            raster.DepthClipEnable = true;
            raster.MultisampleEnable = false;
            raster.AntialiasedLineEnable = false;
            raster.ForcedSampleCount = 0;
            raster.ConservativeRaster = D3D12_CONSERVATIVE_RASTERIZATION_MODE.OFF;

            D3D12_DEPTH_STENCIL_DESC depthDisabled = D3D12_DEPTH_STENCIL_DESC.init;
            depthDisabled.DepthEnable = false;
            depthDisabled.DepthWriteMask = D3D12_DEPTH_WRITE_MASK.ZERO;
            depthDisabled.DepthFunc = D3D12_COMPARISON_FUNC.ALWAYS;
            depthDisabled.StencilEnable = false;

            D3D12_DEPTH_STENCIL_DESC depthStencilTest = D3D12_DEPTH_STENCIL_DESC.init;
            depthStencilTest.DepthEnable = false;
            depthStencilTest.DepthWriteMask = D3D12_DEPTH_WRITE_MASK.ZERO;
            depthStencilTest.DepthFunc = D3D12_COMPARISON_FUNC.ALWAYS;
            depthStencilTest.StencilEnable = true;
            depthStencilTest.StencilReadMask = 0xFF;
            depthStencilTest.StencilWriteMask = 0x00;
            depthStencilTest.FrontFace.StencilFailOp = D3D12_STENCIL_OP.KEEP;
            depthStencilTest.FrontFace.StencilDepthFailOp = D3D12_STENCIL_OP.KEEP;
            depthStencilTest.FrontFace.StencilPassOp = D3D12_STENCIL_OP.KEEP;
            depthStencilTest.FrontFace.StencilFunc = D3D12_COMPARISON_FUNC.EQUAL;
            depthStencilTest.BackFace = depthStencilTest.FrontFace;

            D3D12_DEPTH_STENCIL_DESC depthStencilWrite = D3D12_DEPTH_STENCIL_DESC.init;
            depthStencilWrite.DepthEnable = false;
            depthStencilWrite.DepthWriteMask = D3D12_DEPTH_WRITE_MASK.ZERO;
            depthStencilWrite.DepthFunc = D3D12_COMPARISON_FUNC.ALWAYS;
            depthStencilWrite.StencilEnable = true;
            depthStencilWrite.StencilReadMask = 0xFF;
            depthStencilWrite.StencilWriteMask = 0xFF;
            depthStencilWrite.FrontFace.StencilFailOp = D3D12_STENCIL_OP.KEEP;
            depthStencilWrite.FrontFace.StencilDepthFailOp = D3D12_STENCIL_OP.KEEP;
            depthStencilWrite.FrontFace.StencilPassOp = D3D12_STENCIL_OP.REPLACE;
            depthStencilWrite.FrontFace.StencilFunc = D3D12_COMPARISON_FUNC.ALWAYS;
            depthStencilWrite.BackFace = depthStencilWrite.FrontFace;

            DXGI_FORMAT[8] rtvFormats = [DXGI_FORMAT.UNKNOWN, DXGI_FORMAT.UNKNOWN, DXGI_FORMAT.UNKNOWN, DXGI_FORMAT.UNKNOWN,
                                         DXGI_FORMAT.UNKNOWN, DXGI_FORMAT.UNKNOWN, DXGI_FORMAT.UNKNOWN, DXGI_FORMAT.UNKNOWN];
            rtvFormats[0] = DXGI_FORMAT.R8G8B8A8_UNORM;
            DXGI_FORMAT[8] rtvFormatsMrt2 = [DXGI_FORMAT.UNKNOWN, DXGI_FORMAT.UNKNOWN, DXGI_FORMAT.UNKNOWN, DXGI_FORMAT.UNKNOWN,
                                             DXGI_FORMAT.UNKNOWN, DXGI_FORMAT.UNKNOWN, DXGI_FORMAT.UNKNOWN, DXGI_FORMAT.UNKNOWN];
            rtvFormatsMrt2[0] = DXGI_FORMAT.R8G8B8A8_UNORM;
            rtvFormatsMrt2[1] = DXGI_FORMAT.R8G8B8A8_UNORM;
            DXGI_FORMAT[8] rtvFormatsMrt = [DXGI_FORMAT.UNKNOWN, DXGI_FORMAT.UNKNOWN, DXGI_FORMAT.UNKNOWN, DXGI_FORMAT.UNKNOWN,
                                            DXGI_FORMAT.UNKNOWN, DXGI_FORMAT.UNKNOWN, DXGI_FORMAT.UNKNOWN, DXGI_FORMAT.UNKNOWN];
            rtvFormatsMrt[0] = DXGI_FORMAT.R8G8B8A8_UNORM;
            rtvFormatsMrt[1] = DXGI_FORMAT.R8G8B8A8_UNORM;
            rtvFormatsMrt[2] = DXGI_FORMAT.R8G8B8A8_UNORM;

            auto createPsoWithBlendFallback = (ref D3D12_GRAPHICS_PIPELINE_STATE_DESC desc,
                                               D3D12_BLEND_DESC fallbackBlend,
                                               size_t modeRaw,
                                               string label,
                                               ID3D12PipelineState* outPso) {
                auto hr = devicePtr.value.CreateGraphicsPipelineState(&desc, &IID_ID3D12PipelineState_Win, cast(void**)outPso);
                if (dxSucceeded(hr)) return;
                if (modeRaw != cast(size_t)BlendMode.Normal) {
                    auto fallback = desc;
                    fallback.BlendState = fallbackBlend;
                    auto hrFallback = devicePtr.value.CreateGraphicsPipelineState(&fallback, &IID_ID3D12PipelineState_Win, cast(void**)outPso);
                    if (dxSucceeded(hrFallback)) {
                        dxTrace("createPipelineState.fallbackToNormalBlend modeRaw=" ~ to!string(modeRaw) ~ " label=" ~ label);
                        return;
                    }
                }
                enforceHr(hr, label ~ " failed");
            };

            foreach (modeRaw; 0 .. cast(size_t)BlendMode.Count) {
                if ((modeRaw % 4) == 0) {
                    dxTrace("createPipelineState.pso modeRaw=" ~ to!string(modeRaw));
                }
                auto mode = cast(BlendMode)modeRaw;
                auto blend = buildBlendDesc(mode);
                auto normalBlend = buildBlendDesc(BlendMode.Normal);
                auto pso = D3D12_GRAPHICS_PIPELINE_STATE_DESC(
                    rootSignaturePtr.value,
                    D3D12_SHADER_BYTECODE(vsBlob.GetBufferPointer(), vsBlob.GetBufferSize()),
                    D3D12_SHADER_BYTECODE(psBlob.GetBufferPointer(), psBlob.GetBufferSize()),
                    D3D12_SHADER_BYTECODE.init,
                    D3D12_SHADER_BYTECODE.init,
                    D3D12_SHADER_BYTECODE.init,
                    D3D12_STREAM_OUTPUT_DESC.init,
                    blend,
                    D3D12_DEFAULT_SAMPLE_MASK,
                    raster,
                    depthDisabled,
                    D3D12_INPUT_LAYOUT_DESC(inputElems.ptr, inputElems.length),
                    D3D12_INDEX_BUFFER_STRIP_CUT_VALUE.VALUE_DISABLED,
                    D3D12_PRIMITIVE_TOPOLOGY_TYPE.TRIANGLE,
                    1,
                    rtvFormats,
                    DXGI_FORMAT.D24_UNORM_S8_UINT,
                    DXGI_SAMPLE_DESC(1, 0),
                    0,
                    D3D12_CACHED_PIPELINE_STATE.init,
                    D3D12_PIPELINE_STATE_FLAGS.NONE);

                ID3D12PipelineState rawPso = null;
                dxTrace("createPipelineState.beforeCreatePso.main modeRaw=" ~ to!string(modeRaw));
                createPsoWithBlendFallback(pso, normalBlend, modeRaw, "CreateGraphicsPipelineState", &rawPso);
                dxTrace("createPipelineState.afterCreatePso.main modeRaw=" ~ to!string(modeRaw));
                pipelineStates[modeRaw] = new DXPtr!ID3D12PipelineState(rawPso);

                auto psoStencilTest = pso;
                psoStencilTest.DepthStencilState = depthStencilTest;
                ID3D12PipelineState rawPsoStencilTest = null;
                dxTrace("createPipelineState.beforeCreatePso.stencil modeRaw=" ~ to!string(modeRaw));
                createPsoWithBlendFallback(psoStencilTest, normalBlend, modeRaw, "CreateGraphicsPipelineState(stencil test)", &rawPsoStencilTest);
                dxTrace("createPipelineState.afterCreatePso.stencil modeRaw=" ~ to!string(modeRaw));
                pipelineStatesStencilTest[modeRaw] = new DXPtr!ID3D12PipelineState(rawPsoStencilTest);

                auto psoMrt = pso;
                psoMrt.NumRenderTargets = 3;
                psoMrt.RTVFormats = rtvFormatsMrt;
                ID3D12PipelineState rawPsoMrt = null;
                dxTrace("createPipelineState.beforeCreatePso.mrt modeRaw=" ~ to!string(modeRaw));
                createPsoWithBlendFallback(psoMrt, normalBlend, modeRaw, "CreateGraphicsPipelineState(MRT)", &rawPsoMrt);
                dxTrace("createPipelineState.afterCreatePso.mrt modeRaw=" ~ to!string(modeRaw));
                pipelineStatesMrt[modeRaw] = new DXPtr!ID3D12PipelineState(rawPsoMrt);

                auto psoStencilTestMrt = psoMrt;
                psoStencilTestMrt.DepthStencilState = depthStencilTest;
                ID3D12PipelineState rawPsoStencilTestMrt = null;
                dxTrace("createPipelineState.beforeCreatePso.stencilMrt modeRaw=" ~ to!string(modeRaw));
                createPsoWithBlendFallback(psoStencilTestMrt, normalBlend, modeRaw, "CreateGraphicsPipelineState(stencil test MRT)", &rawPsoStencilTestMrt);
                dxTrace("createPipelineState.afterCreatePso.stencilMrt modeRaw=" ~ to!string(modeRaw));
                pipelineStatesStencilTestMrt[modeRaw] = new DXPtr!ID3D12PipelineState(rawPsoStencilTestMrt);

                auto psoMrt2 = pso;
                psoMrt2.NumRenderTargets = 2;
                psoMrt2.RTVFormats = rtvFormatsMrt2;
                ID3D12PipelineState rawPsoMrt2 = null;
                dxTrace("createPipelineState.beforeCreatePso.mrt2 modeRaw=" ~ to!string(modeRaw));
                createPsoWithBlendFallback(psoMrt2, normalBlend, modeRaw, "CreateGraphicsPipelineState(MRT2)", &rawPsoMrt2);
                dxTrace("createPipelineState.afterCreatePso.mrt2 modeRaw=" ~ to!string(modeRaw));
                pipelineStatesMrt2[modeRaw] = new DXPtr!ID3D12PipelineState(rawPsoMrt2);

                auto psoStencilTestMrt2 = psoMrt2;
                psoStencilTestMrt2.DepthStencilState = depthStencilTest;
                ID3D12PipelineState rawPsoStencilTestMrt2 = null;
                dxTrace("createPipelineState.beforeCreatePso.stencilMrt2 modeRaw=" ~ to!string(modeRaw));
                createPsoWithBlendFallback(psoStencilTestMrt2, normalBlend, modeRaw, "CreateGraphicsPipelineState(stencil test MRT2)", &rawPsoStencilTestMrt2);
                dxTrace("createPipelineState.afterCreatePso.stencilMrt2 modeRaw=" ~ to!string(modeRaw));
                pipelineStatesStencilTestMrt2[modeRaw] = new DXPtr!ID3D12PipelineState(rawPsoStencilTestMrt2);
            }

            auto writeBlend = buildBlendDesc(BlendMode.Normal);
            writeBlend.RenderTarget[0].RenderTargetWriteMask = 0;
            auto psoStencilWrite = D3D12_GRAPHICS_PIPELINE_STATE_DESC(
                rootSignaturePtr.value,
                D3D12_SHADER_BYTECODE(vsBlob.GetBufferPointer(), vsBlob.GetBufferSize()),
                D3D12_SHADER_BYTECODE(psBlob.GetBufferPointer(), psBlob.GetBufferSize()),
                D3D12_SHADER_BYTECODE.init,
                D3D12_SHADER_BYTECODE.init,
                D3D12_SHADER_BYTECODE.init,
                D3D12_STREAM_OUTPUT_DESC.init,
                writeBlend,
                D3D12_DEFAULT_SAMPLE_MASK,
                raster,
                depthStencilWrite,
                D3D12_INPUT_LAYOUT_DESC(inputElems.ptr, inputElems.length),
                D3D12_INDEX_BUFFER_STRIP_CUT_VALUE.VALUE_DISABLED,
                D3D12_PRIMITIVE_TOPOLOGY_TYPE.TRIANGLE,
                1,
                rtvFormats,
                DXGI_FORMAT.D24_UNORM_S8_UINT,
                DXGI_SAMPLE_DESC(1, 0),
                0,
                D3D12_CACHED_PIPELINE_STATE.init,
                D3D12_PIPELINE_STATE_FLAGS.NONE);
            ID3D12PipelineState rawPsoStencilWrite = null;
            enforceHr(devicePtr.value.CreateGraphicsPipelineState(&psoStencilWrite, &IID_ID3D12PipelineState_Win, cast(void**)&rawPsoStencilWrite),
                "CreateGraphicsPipelineState(stencil write) failed");
            pipelineStateStencilWrite = new DXPtr!ID3D12PipelineState(rawPsoStencilWrite);

            auto psoStencilWriteMrt = psoStencilWrite;
            psoStencilWriteMrt.NumRenderTargets = 3;
            psoStencilWriteMrt.RTVFormats = rtvFormatsMrt;
            ID3D12PipelineState rawPsoStencilWriteMrt = null;
            enforceHr(devicePtr.value.CreateGraphicsPipelineState(&psoStencilWriteMrt, &IID_ID3D12PipelineState_Win, cast(void**)&rawPsoStencilWriteMrt),
                "CreateGraphicsPipelineState(stencil write MRT) failed");
            pipelineStateStencilWriteMrt = new DXPtr!ID3D12PipelineState(rawPsoStencilWriteMrt);

            auto psoStencilWriteMrt2 = psoStencilWrite;
            psoStencilWriteMrt2.NumRenderTargets = 2;
            psoStencilWriteMrt2.RTVFormats = rtvFormatsMrt2;
            ID3D12PipelineState rawPsoStencilWriteMrt2 = null;
            enforceHr(devicePtr.value.CreateGraphicsPipelineState(&psoStencilWriteMrt2, &IID_ID3D12PipelineState_Win, cast(void**)&rawPsoStencilWriteMrt2),
                "CreateGraphicsPipelineState(stencil write MRT2) failed");
            pipelineStateStencilWriteMrt2 = new DXPtr!ID3D12PipelineState(rawPsoStencilWriteMrt2);
            dxTrace("createPipelineState.end");
        }

        void ensureUploadBuffer(size_t requiredBytes, ref DXPtr!ID3D12Resource buffer, ref size_t capacity, string label) {
            if (requiredBytes == 0) return;
            if (buffer !is null && capacity >= requiredBytes) return;

            size_t newCapacity = max(cast(size_t)65536, capacity);
            while (newCapacity < requiredBytes) {
                newCapacity *= 2;
            }

            D3D12_HEAP_PROPERTIES heapProps = D3D12_HEAP_PROPERTIES.init;
            heapProps.Type = D3D12_HEAP_TYPE.UPLOAD;
            heapProps.CPUPageProperty = D3D12_CPU_PAGE_PROPERTY.UNKNOWN;
            heapProps.MemoryPoolPreference = D3D12_MEMORY_POOL.POOL_UNKNOWN;
            heapProps.CreationNodeMask = 1;
            heapProps.VisibleNodeMask = 1;

            D3D12_RESOURCE_DESC desc = D3D12_RESOURCE_DESC.init;
            desc.Dimension = D3D12_RESOURCE_DIMENSION.BUFFER;
            desc.Alignment = 0;
            desc.Width = cast(ulong)newCapacity;
            desc.Height = 1;
            desc.DepthOrArraySize = 1;
            desc.MipLevels = 1;
            desc.Format = DXGI_FORMAT.UNKNOWN;
            desc.SampleDesc.Count = 1;
            desc.SampleDesc.Quality = 0;
            desc.Layout = D3D12_TEXTURE_LAYOUT.LAYOUT_ROW_MAJOR;
            desc.Flags = D3D12_RESOURCE_FLAGS.NONE;

            ID3D12Resource raw = null;
            enforceHr(devicePtr.value.CreateCommittedResource(
                &heapProps,
                D3D12_HEAP_FLAGS.NONE,
                &desc,
                D3D12_RESOURCE_STATES.GENERIC_READ,
                null,
                &IID_ID3D12Resource_Win,
                cast(void**)&raw),
                "CreateCommittedResource(" ~ label ~ ") failed");

            buffer = new DXPtr!ID3D12Resource(raw);
            capacity = newCapacity;
        }

        void uploadData(ref DXPtr!ID3D12Resource buffer, ref size_t capacity, const(void)* src, size_t bytes, string label) {
            if (bytes == 0 || src is null) return;
            ensureUploadBuffer(bytes, buffer, capacity, label);
            enforce(buffer !is null, "Upload buffer allocation failed: " ~ label);

            D3D12_RANGE readRange = D3D12_RANGE.init;
            readRange.Begin = 0;
            readRange.End = 0;

            void* mapped = null;
            enforceHr(buffer.value.Map(0, &readRange, &mapped), "Map failed: " ~ label);
            enforce(mapped !is null, "Map returned null pointer: " ~ label);
            memcpy(mapped, src, bytes);

            D3D12_RANGE writeRange = D3D12_RANGE.init;
            writeRange.Begin = 0;
            writeRange.End = bytes;
            buffer.value.Unmap(0, &writeRange);
        }

        void uploadGeometry(const(Vertex)[] vertices, const(ushort)[] indices) {
            if (!initialized) return;
            auto vBytes = cast(size_t)(vertices.length * Vertex.sizeof);
            auto iBytes = cast(size_t)(indices.length * ushort.sizeof);

            if (vBytes > 0) {
                uploadData(vertexUploadBuffer, vertexUploadCapacity, vertices.ptr, vBytes, "vertexUpload");
            }
            if (iBytes > 0) {
                uploadData(indexUploadBuffer, indexUploadCapacity, indices.ptr, iBytes, "indexUpload");
            }

            uploadedVertexBytes = vBytes;
            uploadedIndexBytes = iBytes;
            if (vBytes > 0) {
                vbView.BufferLocation = vertexUploadBuffer.value.GetGPUVirtualAddress();
                vbView.SizeInBytes = cast(uint)vBytes;
                vbView.StrideInBytes = Vertex.sizeof;
            }
            if (iBytes > 0) {
                ibView.BufferLocation = indexUploadBuffer.value.GetGPUVirtualAddress();
                ibView.SizeInBytes = cast(uint)iBytes;
                ibView.Format = DXGI_FORMAT.R16_UINT;
            }
        }

        void drawUploadedGeometry(DrawSpan[] spans, Texture fallbackTexture) {
            if (!initialized || commandListPtr is null) return;
            if (rootSignaturePtr is null) return;
            if (uploadedVertexBytes == 0 || uploadedIndexBytes == 0) return;
            if (spans.length == 0) return;
            dxTrace("drawUploadedGeometry spans=" ~ to!string(spans.length));

            commandListPtr.value.SetGraphicsRootSignature(rootSignaturePtr.value);
            if (srvHeapPtr !is null) {
                ID3D12DescriptorHeap[1] heaps;
                heaps[0] = srvHeapPtr.value;
                commandListPtr.value.SetDescriptorHeaps(1, cast(const(ID3D12DescriptorHeap)*)heaps.ptr);
                D3D12_GPU_DESCRIPTOR_HANDLE gpuSrv = D3D12_GPU_DESCRIPTOR_HANDLE.init;
                gpuSrv.ptr = srvHeapGpuStartPtr;
                commandListPtr.value.SetGraphicsRootDescriptorTable(0, gpuSrv);
            }
            commandListPtr.value.IASetPrimitiveTopology(cast(D3D12_PRIMITIVE_TOPOLOGY)D3D_PRIMITIVE_TOPOLOGY.D3D_TRIANGLELIST);
            commandListPtr.value.IASetVertexBuffers(0, 1, &vbView);
            commandListPtr.value.IASetIndexBuffer(&ibView);

            auto bindBackbufferTarget = () {
                D3D12_VIEWPORT vp = D3D12_VIEWPORT.init;
                vp.TopLeftX = 0;
                vp.TopLeftY = 0;
                vp.Width = cast(float)max(1, viewportW);
                vp.Height = cast(float)max(1, viewportH);
                vp.MinDepth = 0.0f;
                vp.MaxDepth = 1.0f;
                commandListPtr.value.RSSetViewports(1, &vp);

                D3D12_RECT scissor;
                scissor.left = 0;
                scissor.top = 0;
                scissor.right = max(1, viewportW);
                scissor.bottom = max(1, viewportH);
                commandListPtr.value.RSSetScissorRects(1, &scissor);
                auto rtv = currentRtvHandle();
                auto dsv = dsvHandle();
                commandListPtr.value.OMSetRenderTargets(1, &rtv, true, &dsv);
            };

            bool currentTargetHasStencil = true;
            auto bindTextureTargets = (Texture[3] targets, uint targetCount, bool clearTarget, ref Texture[3] boundTargets) {
                boundTargets[] = null;
                if (targetCount == 0) return cast(uint)0;
                if (targetCount > 3) targetCount = 3;
                auto primary = targets[0];
                if (primary is null || !primary.renderTarget) return cast(uint)0;

                Texture[3] uniqueTargets;
                uint uniqueCount = 0;
                foreach (i; 0 .. targetCount) {
                    Texture target = targets[i];
                    if (target is null || !target.renderTarget) {
                        target = primary;
                    }
                    bool duplicate = false;
                    foreach (j; 0 .. uniqueCount) {
                        if (uniqueTargets[j] is target) {
                            duplicate = true;
                            break;
                        }
                    }
                    if (!duplicate && uniqueCount < 3) {
                        uniqueTargets[uniqueCount++] = target;
                    }
                }
                if (uniqueCount == 0 || offscreenRtvHeapPtr is null) return cast(uint)0;

                if (offscreenRtvCursor > offscreenRtvDescriptorCapacity ||
                    uniqueCount > offscreenRtvDescriptorCapacity - offscreenRtvCursor) {
                    return cast(uint)0;
                }
                auto rtvBase = offscreenRtvCursor;
                offscreenRtvCursor += uniqueCount;

                D3D12_CPU_DESCRIPTOR_HANDLE[3] rtvs;
                foreach (i; 0 .. uniqueCount) {
                    auto target = uniqueTargets[i];
                    ensureTextureUploaded(target);
                    if (target.gpuTexture is null) return cast(uint)0;
                    transitionTextureState(target, D3D12_RESOURCE_STATES.RENDER_TARGET);
                    auto rtv = offscreenRtvHandleAt(rtvBase + i);
                    devicePtr.value.CreateRenderTargetView(target.gpuTexture.value, null, rtv);
                    rtvs[i] = rtv;
                    boundTargets[i] = target;
                }

                D3D12_VIEWPORT vp = D3D12_VIEWPORT.init;
                vp.TopLeftX = 0;
                vp.TopLeftY = 0;
                vp.Width = cast(float)max(1, primary.width);
                vp.Height = cast(float)max(1, primary.height);
                vp.MinDepth = 0.0f;
                vp.MaxDepth = 1.0f;
                commandListPtr.value.RSSetViewports(1, &vp);

                D3D12_RECT scissor;
                scissor.left = 0;
                scissor.top = 0;
                scissor.right = max(1, primary.width);
                scissor.bottom = max(1, primary.height);
                commandListPtr.value.RSSetScissorRects(1, &scissor);
                if (ensureOffscreenDepthStencilTarget(primary.width, primary.height)) {
                    auto dsv = offscreenDsvHandle();
                    commandListPtr.value.OMSetRenderTargets(uniqueCount, rtvs.ptr, true, &dsv);
                    currentTargetHasStencil = true;
                } else {
                    commandListPtr.value.OMSetRenderTargets(uniqueCount, rtvs.ptr, true, null);
                    currentTargetHasStencil = false;
                }
                if (clearTarget) {
                    const(float)[4] clearColor = [0.0f, 0.0f, 0.0f, 0.0f];
                    foreach (i; 0 .. uniqueCount) {
                        commandListPtr.value.ClearRenderTargetView(rtvs[i], clearColor.ptr, 0, null);
                    }
                }
                return uniqueCount;
            };

            Texture[3] currentTargets;
            uint currentTargetCount = 0;
            size_t spanIndex = 0;
            uint srvDescriptorCursor = 0;
            bool srvHeapOverflowWarned = false;
            bool traceComposite = isDxFlag("NJIV_DX_TRACE_COMPOSITE");
            Texture[] frameCompositeTargets;
            size_t frameCompositeSampleCount = 0;
            size_t frameCompositeSampleSpans = 0;
            bindBackbufferTarget();
            currentTargetHasStencil = true;
            foreach (span; spans) {
                bool traceOps = isDxFlag("NJIV_DX_TRACE_DRAWOPS");
                if (isDxTraceEnabled() && (spanIndex % 16 == 0)) {
                    dxTrace("drawUploadedGeometry.span i=" ~ to!string(spanIndex) ~
                        " idxCount=" ~ to!string(span.indexCount) ~
                        " rtCount=" ~ to!string(span.renderTargetCount));
                }
                if (span.indexCount == 0) continue;
                bool targetChanged = (span.renderTargetCount != currentTargetCount);
                if (!targetChanged) {
                    foreach (i; 0 .. currentTargetCount) {
                        if (span.renderTargets[i] !is currentTargets[i]) {
                            targetChanged = true;
                            break;
                        }
                    }
                }
                if (targetChanged) {
                    if (isDxTraceEnabled()) {
                        dxTrace("drawUploadedGeometry.targetChanged i=" ~ to!string(spanIndex) ~
                            " old=" ~ to!string(currentTargetCount) ~
                            " new=" ~ to!string(span.renderTargetCount));
                    }
                    foreach (i; 0 .. currentTargetCount) {
                        if (currentTargets[i] !is null) {
                            transitionTextureState(currentTargets[i], D3D12_RESOURCE_STATES.PIXEL_SHADER_RESOURCE);
                        }
                    }
                    currentTargetCount = span.renderTargetCount;
                    currentTargets = span.renderTargets;
                    if (currentTargetCount > 0) {
                        foreach (i; 0 .. currentTargetCount) {
                            auto rt = currentTargets[i];
                            if (rt is null) continue;
                            bool duplicate = false;
                            foreach (e; frameCompositeTargets) {
                                if (e is rt) {
                                    duplicate = true;
                                    break;
                                }
                            }
                            if (!duplicate) frameCompositeTargets ~= rt;
                        }
                    }
                    if (currentTargetCount == 0 || currentTargets[0] is null) {
                        bindBackbufferTarget();
                        currentTargetHasStencil = true;
                    } else {
                        Texture[3] normalizedTargets;
                        auto normalizedCount = bindTextureTargets(
                            currentTargets, currentTargetCount, span.clearRenderTarget, normalizedTargets);
                        if (normalizedCount == 0) {
                            currentTargetCount = 0;
                            currentTargets[] = null;
                            bindBackbufferTarget();
                            currentTargetHasStencil = true;
                        } else {
                            currentTargetCount = normalizedCount;
                            currentTargets = normalizedTargets;
                        }
                    }
                }
                // Each draw needs its own SRV table. Reusing the same slots causes all draws
                // to sample whichever texture was written last once GPU executes the command list.
                uint descriptorBase = 0;
                bool[3] texFlipY = [false, false, false];
                bool descriptorSliceValid = (srvDescriptorCapacity >= 3 &&
                    srvDescriptorCursor <= srvDescriptorCapacity - 3);
                if (descriptorSliceValid) {
                    descriptorBase = srvDescriptorCursor;
                    srvDescriptorCursor += 3;
                } else if (!srvHeapOverflowWarned && isDxTraceEnabled()) {
                    dxTrace("drawUploadedGeometry: SRV heap capacity exhausted; reusing descriptor base 0");
                    srvHeapOverflowWarned = true;
                }

                foreach (slot; 0 .. 3) {
                    Texture t = null;
                    if (slot < span.textureCount && span.textures[slot] !is null) {
                        t = span.textures[slot];
                    }
                    if (t is null) {
                        t = fallbackTexture;
                    }
                    bool traceTexOps = isDxFlag("NJIV_DX_TRACE_TEXOPS");
                    if (traceTexOps) {
                        dxTrace("drawUploadedGeometry.tex slot=" ~ to!string(slot) ~
                            " span=" ~ to!string(spanIndex) ~
                            " beforeEnsure ptr=" ~ to!string(cast(size_t)cast(void*)t));
                    }
                    ensureTextureUploaded(t);
                    if (traceTexOps) {
                        dxTrace("drawUploadedGeometry.tex slot=" ~ to!string(slot) ~
                            " span=" ~ to!string(spanIndex) ~
                            " afterEnsure gpu=" ~ to!string(cast(size_t)cast(void*)(t is null || t.gpuTexture is null ? null : cast(void*)t.gpuTexture.value)));
                    }
                    if (t.gpuTexture is null) {
                        ensureTextureUploaded(fallbackTexture);
                        t = fallbackTexture;
                    }
                    if (t.gpuTexture is null) continue;
                    bool sampledIsCurrentRt = false;
                    foreach (ri; 0 .. currentTargetCount) {
                        if (t is currentTargets[ri]) {
                            sampledIsCurrentRt = true;
                            break;
                        }
                    }
                    if (sampledIsCurrentRt) {
                        // Avoid binding the active render target as SRV in the same draw.
                        t = fallbackTexture;
                        ensureTextureUploaded(t);
                        if (t.gpuTexture is null) continue;
                    }
                    texFlipY[slot] = t.renderTarget;
                    if (traceComposite && currentTargetCount == 0) {
                        foreach (rt; frameCompositeTargets) {
                            if (t is rt) {
                                frameCompositeSampleCount++;
                                if (slot == 0) frameCompositeSampleSpans++;
                                break;
                            }
                        }
                    }
                    if (traceTexOps) {
                        dxTrace("drawUploadedGeometry.tex slot=" ~ to!string(slot) ~
                            " span=" ~ to!string(spanIndex) ~
                            " beforeTransition");
                    }
                    transitionTextureState(t, D3D12_RESOURCE_STATES.PIXEL_SHADER_RESOURCE);
                    if (traceTexOps) {
                        dxTrace("drawUploadedGeometry.tex slot=" ~ to!string(slot) ~
                            " span=" ~ to!string(spanIndex) ~
                            " beforeUpdateSrv");
                    }
                    updateHeapSrvTexture2D(t.gpuTexture.value, descriptorBase + cast(uint)slot);
                    if (traceTexOps) {
                        dxTrace("drawUploadedGeometry.tex slot=" ~ to!string(slot) ~
                            " span=" ~ to!string(spanIndex) ~
                            " afterUpdateSrv");
                    }
                }
                D3D12_GPU_DESCRIPTOR_HANDLE gpuSrv = D3D12_GPU_DESCRIPTOR_HANDLE.init;
                gpuSrv.ptr = srvHeapGpuStartPtr;
                gpuSrv.ptr += cast(ulong)(descriptorBase * srvDescriptorSize);
                commandListPtr.value.SetGraphicsRootDescriptorTable(0, gpuSrv);
                float[16] drawParams;
                drawParams[0] = span.useMultistageBlend ? 1.0f : 0.0f;
                drawParams[1] = span.hasEmissionOrBumpmap ? 1.0f : 0.0f;
                drawParams[2] = span.opacity;
                drawParams[3] = span.emissionStrength;
                drawParams[4] = span.isMask ? 1.0f : 0.0f;
                drawParams[5] = span.maskThreshold;
                drawParams[6] = texFlipY[0] ? 1.0f : 0.0f;
                drawParams[7] = texFlipY[1] ? 1.0f : 0.0f;
                drawParams[8] = span.clampedTint.x;
                drawParams[9] = span.clampedTint.y;
                drawParams[10] = span.clampedTint.z;
                drawParams[11] = texFlipY[2] ? 1.0f : 0.0f;
                drawParams[12] = span.clampedScreen.x;
                drawParams[13] = span.clampedScreen.y;
                drawParams[14] = span.clampedScreen.z;
                drawParams[15] = 0.0f;
                if (!isDxFlag("NJIV_DX_SKIP_ROOT_CONSTANTS")) {
                    commandListPtr.value.SetGraphicsRoot32BitConstants(1, 16, drawParams.ptr, 0);
                }

                auto mode = sanitizeBlendMode(cast(int)span.blendMode);
                DXPtr!ID3D12PipelineState pso = null;
                auto chooseNormalPso = (uint rtCount) {
                    if (rtCount >= 3) return pipelineStatesMrt[cast(size_t)mode];
                    if (rtCount == 2) return pipelineStatesMrt2[cast(size_t)mode];
                    return pipelineStates[cast(size_t)mode];
                };
                auto chooseStencilTestPso = (uint rtCount) {
                    if (rtCount >= 3) return pipelineStatesStencilTestMrt[cast(size_t)mode];
                    if (rtCount == 2) return pipelineStatesStencilTestMrt2[cast(size_t)mode];
                    return pipelineStatesStencilTest[cast(size_t)mode];
                };
                auto chooseStencilWritePso = (uint rtCount) {
                    if (rtCount >= 3) return pipelineStateStencilWriteMrt;
                    if (rtCount == 2) return pipelineStateStencilWriteMrt2;
                    return pipelineStateStencilWrite;
                };
                final switch (span.stencilMode) {
                    case StencilMode.None:
                        pso = chooseNormalPso(currentTargetCount);
                        break;
                    case StencilMode.TestEqual:
                        commandListPtr.value.OMSetStencilRef(span.stencilRef);
                        if (currentTargetHasStencil) {
                            pso = chooseStencilTestPso(currentTargetCount);
                        } else {
                            pso = chooseNormalPso(currentTargetCount);
                        }
                        break;
                    case StencilMode.Write:
                        commandListPtr.value.OMSetStencilRef(span.stencilRef);
                        if (span.clearStencil && currentTargetHasStencil) {
                            auto dsv = (currentTargetCount == 0) ? dsvHandle() : offscreenDsvHandle();
                            commandListPtr.value.ClearDepthStencilView(
                                dsv, D3D12_CLEAR_FLAGS.STENCIL, 1.0f, span.stencilClearValue, 0, null);
                        }
                        if (currentTargetHasStencil) {
                            pso = chooseStencilWritePso(currentTargetCount);
                        } else {
                            pso = chooseNormalPso(currentTargetCount);
                        }
                        break;
                }
                if (pso is null) continue;
                size_t first = cast(size_t)span.firstIndex;
                size_t count = cast(size_t)span.indexCount;
                size_t totalIndices = uploadedIndexBytes / ushort.sizeof;
                if (first > totalIndices || count > totalIndices - first) {
                    if (isDxTraceEnabled()) {
                        dxTrace("drawUploadedGeometry.skipInvalidIndexRange i=" ~ to!string(spanIndex) ~
                            " first=" ~ to!string(first) ~
                            " count=" ~ to!string(count) ~
                            " total=" ~ to!string(totalIndices));
                    }
                    spanIndex++;
                    continue;
                }
                if (traceOps) {
                    dxTrace("drawUploadedGeometry.beforeSetPso i=" ~ to!string(spanIndex) ~
                        " firstIndex=" ~ to!string(span.firstIndex) ~
                        " indexCount=" ~ to!string(span.indexCount));
                }
                if (isDxTraceEnabled() && spanIndex == 9) {
                    dxTrace("drawUploadedGeometry.span9 mode=" ~ to!string(cast(int)span.blendMode) ~
                        " stencilMode=" ~ to!string(cast(int)span.stencilMode) ~
                        " stencilRef=" ~ to!string(span.stencilRef) ~
                        " texCount=" ~ to!string(span.textureCount) ~
                        " rtCount=" ~ to!string(currentTargetCount));
                }
                commandListPtr.value.SetPipelineState(pso.value);
                if (traceOps) {
                    dxTrace("drawUploadedGeometry.beforeDraw i=" ~ to!string(spanIndex));
                }
                commandListPtr.value.DrawIndexedInstanced(span.indexCount, 1, span.firstIndex, 0, 0);
                if (traceOps) {
                    dxTrace("drawUploadedGeometry.afterDraw i=" ~ to!string(spanIndex));
                }
                spanIndex++;
            }
            dxTrace("drawUploadedGeometry.afterSpanLoop");
            foreach (i; 0 .. currentTargetCount) {
                if (currentTargets[i] !is null) {
                    transitionTextureState(currentTargets[i], D3D12_RESOURCE_STATES.PIXEL_SHADER_RESOURCE);
                }
            }
            dxTrace("drawUploadedGeometry.afterRestoreRtStates");
            if (currentTargetCount > 0) {
                bindBackbufferTarget();
            }
            if (traceComposite) {
                dxTrace("drawUploadedGeometry.compositeStats targets=" ~ to!string(frameCompositeTargets.length) ~
                    " sampledSlots=" ~ to!string(frameCompositeSampleCount) ~
                    " sampledSpans=" ~ to!string(frameCompositeSampleSpans));
            }
            dxTrace("drawUploadedGeometry.done");
        }

        void initialize(HWND hwnd, int viewportW, int viewportH, bool debugLayer = false) {
            if (initialized) return;
            dxTrace("DirectXRuntime.initialize.begin");
            this.hwnd = hwnd;
            this.viewportW = viewportW;
            this.viewportH = viewportH;
            this.debugLayerEnabled = debugLayer;
            this.deviceResetOccurred = false;
            this.recoveryPending = false;
            this.recoveryRetryFrames = 0;
            this.recoveryAttempt = 0;
            dxTrace("DirectXRuntime.initialize.skipCoInit");

            if (debugLayer) {
                ID3D12Debug dbg = null;
                auto hrDbg = WinD3D12GetDebugInterface(iid!ID3D12Debug, cast(void**)&dbg);
                if (dxSucceeded(hrDbg) && dbg !is null) {
                    dbg.EnableDebugLayer();
                    dbg.Release();
                }
            }

            uint factoryFlags = debugLayer ? DXGI_CREATE_FACTORY_DEBUG : DXGI_CREATE_FACTORY_NORMAL;
            IDXGIFactory6 rawFactory = null;
            dxTrace("DirectXRuntime.initialize.beforeCreateFactory");
            enforceHr(CreateDXGIFactory2(factoryFlags, cast(const(aurora.directx.com.GUID)*)iid!IDXGIFactory6, cast(void**)&rawFactory),
                "CreateDXGIFactory2 failed");
            factoryPtr = new DXPtr!IDXGIFactory6(rawFactory);
            dxTrace("DirectXRuntime.initialize.afterCreateFactory");

            uint adapterIndex = 0;
            dxTrace("DirectXRuntime.initialize.beforeAdapterLoop");
            while (true) {
                IDXGIAdapter4 rawAdapter = null;
                auto hr = factoryPtr.value.EnumAdapterByGpuPreference(
                    adapterIndex,
                    DXGI_GPU_PREFERENCE.DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE,
                    iid!IDXGIAdapter4,
                    cast(void**)&rawAdapter);
                if (hr == DXGI_ERROR_NOT_FOUND) break;
                if (dxSucceeded(hr) && rawAdapter !is null) {
                    DXGI_ADAPTER_DESC3 desc = void;
                    rawAdapter.GetDesc3(&desc);
                    bool isSoftware = (cast(uint)desc.Flags & cast(uint)DXGI_ADAPTER_FLAG3.SOFTWARE) != 0;
                    if (!isSoftware) {
                        adapterPtr = new DXPtr!IDXGIAdapter4(rawAdapter);
                        break;
                    }
                    rawAdapter.Release();
                }
                adapterIndex++;
            }
            enforce(adapterPtr !is null, "Failed to find D3D12 adapter");
            dxTrace("DirectXRuntime.initialize.afterAdapter");

            ID3D12Device rawDevice = null;
            dxTrace("DirectXRuntime.initialize.beforeCreateDevice");
            auto hr12_1 = WinD3D12CreateDevice(adapterPtr.value, D3D_FEATURE_LEVEL.LEVEL_12_1, &IID_ID3D12Device_Win, cast(void**)&rawDevice);
            if (dxFailed(hr12_1)) {
                enforceHr(WinD3D12CreateDevice(adapterPtr.value, D3D_FEATURE_LEVEL.LEVEL_12_0, &IID_ID3D12Device_Win, cast(void**)&rawDevice),
                    "D3D12CreateDevice failed");
            }
            enforce(rawDevice !is null, "D3D12CreateDevice returned null device");
            dxTrace("DirectXRuntime.initialize.devicePtr=" ~ to!string(cast(size_t)cast(void*)rawDevice));
            void* qiProbe = null;
            auto qiHr = (cast(IUnknown)rawDevice).QueryInterface(
                cast(const(core.sys.windows.basetyps.GUID)*)iid!IUnknown,
                &qiProbe);
            dxTrace("DirectXRuntime.initialize.deviceQI hr=" ~ to!string(cast(int)qiHr) ~
                " ptr=" ~ to!string(cast(size_t)qiProbe));
            if (qiProbe !is null) {
                (cast(IUnknown)qiProbe).Release();
            }
            dxTrace("DirectXRuntime.initialize.afterCreateDevice");

            D3D12_COMMAND_QUEUE_DESC qd = D3D12_COMMAND_QUEUE_DESC.init;
            qd.Type = D3D12_COMMAND_LIST_TYPE.DIRECT;
            qd.Flags = D3D12_COMMAND_QUEUE_FLAGS.NONE;
            ID3D12CommandQueue rawQueue = null;
            dxTrace("DirectXRuntime.initialize.beforeCreateQueue");
            dxTrace("DirectXRuntime.initialize.qd type=" ~ to!string(cast(int)qd.Type) ~
                " prio=" ~ to!string(qd.Priority) ~
                " flags=" ~ to!string(cast(int)qd.Flags) ~
                " node=" ~ to!string(qd.NodeMask));
            enforceHr(rawDevice.CreateCommandQueue(&qd, &IID_ID3D12CommandQueue_Win, cast(void**)&rawQueue),
                "CreateCommandQueue failed");
            devicePtr = new DXPtr!ID3D12Device(rawDevice);
            queuePtr = new DXPtr!ID3D12CommandQueue(rawQueue);
            void* qiQueueProbe = null;
            auto qiQueueHr = (cast(IUnknown)rawQueue).QueryInterface(
                cast(const(core.sys.windows.basetyps.GUID)*)iid!IUnknown,
                &qiQueueProbe);
            dxTrace("DirectXRuntime.initialize.queueQI hr=" ~ to!string(cast(int)qiQueueHr) ~
                " ptr=" ~ to!string(cast(size_t)qiQueueProbe));
            if (qiQueueProbe !is null) {
                (cast(IUnknown)qiQueueProbe).Release();
            }
            dxTrace("DirectXRuntime.initialize.afterCreateQueue");

            ID3D12CommandAllocator rawAllocator = null;
            dxTrace("DirectXRuntime.initialize.beforeCreateAllocator");
            enforceHr(devicePtr.value.CreateCommandAllocator(
                D3D12_COMMAND_LIST_TYPE.DIRECT,
                &IID_ID3D12CommandAllocator_Win,
                cast(void**)&rawAllocator),
                "CreateCommandAllocator failed");
            allocatorPtr = new DXPtr!ID3D12CommandAllocator(rawAllocator);
            dxTrace("DirectXRuntime.initialize.afterCreateAllocator");

            ID3D12GraphicsCommandList rawList = null;
            dxTrace("DirectXRuntime.initialize.beforeCreateCommandList");
            ID3D12Device4 device4 = null;
            enforceHr((cast(IUnknown)rawDevice).QueryInterface(
                cast(const(core.sys.windows.basetyps.GUID)*)&IID_ID3D12Device4_Win,
                cast(void**)&device4),
                "QueryInterface(ID3D12Device4) failed");
            scope (exit) if (device4 !is null) device4.Release();
            enforceHr(device4.CreateCommandList1(
                0,
                D3D12_COMMAND_LIST_TYPE.DIRECT,
                D3D12_COMMAND_LIST_FLAGS.D3D12_COMMAND_LIST_FLAG_NONE,
                &IID_ID3D12GraphicsCommandList_Win,
                cast(void**)&rawList),
                "CreateCommandList1 failed");
            commandListPtr = new DXPtr!ID3D12GraphicsCommandList(rawList);
            commandListPtr.value.Close();
            dxTrace("DirectXRuntime.initialize.afterCreateCommandList");

            ID3D12Fence rawFence = null;
            dxTrace("DirectXRuntime.initialize.beforeCreateFence");
            enforceHr(devicePtr.value.CreateFence(
                0,
                D3D12_FENCE_FLAGS.NONE,
                &IID_ID3D12Fence_Win,
                cast(void**)&rawFence),
                "CreateFence failed");
            fencePtr = new DXPtr!ID3D12Fence(rawFence);
            fenceValue = 1;
            fenceEvent = CreateEventW(null, false, false, null);
            enforce(fenceEvent !is null, "CreateEventW failed");
            dxTrace("DirectXRuntime.initialize.afterCreateFence");

            createSwapChainAndTargets();
            dxTrace("DirectXRuntime.initialize.afterSwapchain");
            createSrvResources();
            dxTrace("DirectXRuntime.initialize.afterSrv");
            createPipelineState();
            dxTrace("DirectXRuntime.initialize.afterPso");
            initialized = true;
        }

        void beginFrame() {
            if (!initialized) {
                if (!recoveryPending) return;
                if (recoveryRetryFrames > 0) {
                    recoveryRetryFrames--;
                    return;
                }
                try {
                    initialize(hwnd, max(1, viewportW), max(1, viewportH), debugLayerEnabled);
                    deviceResetOccurred = true;
                    if (isDxTraceEnabled()) {
                        dxTrace("beginFrame: deferred device recovery succeeded");
                    }
                } catch (Throwable) {
                    shutdown(false);
                    recoveryPending = true;
                    recoveryAttempt++;
                    auto delay = cast(uint)(30 * recoveryAttempt);
                    if (delay > 300) delay = 300;
                    recoveryRetryFrames = delay;
                    if (isDxTraceEnabled()) {
                        dxTrace("beginFrame: deferred device recovery failed; retry in frames=" ~ to!string(recoveryRetryFrames));
                    }
                    return;
                }
                if (!initialized) return;
            }
            if (isDxTraceEnabled()) {
                dxTrace("beginFrame.beforeReset allocator=" ~ to!string(cast(size_t)cast(void*)allocatorPtr.value) ~
                    " cmdList=" ~ to!string(cast(size_t)cast(void*)commandListPtr.value));
            }
            offscreenRtvCursor = 0;
            enforceHr(allocatorPtr.value.Reset(), "CommandAllocator.Reset failed");
            dxTrace("beginFrame.afterResetAllocator");
            enforceHr(commandListPtr.value.Reset(allocatorPtr.value, null), "CommandList.Reset failed");
            dxTrace("beginFrame.afterResetCmdList");

            if (swapChainPtr is null || rtvHeapPtr is null) return;
            frameIndex = swapChainPtr.value.GetCurrentBackBufferIndex();

            D3D12_RESOURCE_BARRIER toRtv = D3D12_RESOURCE_BARRIER.init;
            toRtv.Type = D3D12_RESOURCE_BARRIER_TYPE.TRANSITION;
            toRtv.Flags = D3D12_RESOURCE_BARRIER_FLAGS.NONE;
            toRtv.Transition.pResource = renderTargets[frameIndex].value;
            toRtv.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
            toRtv.Transition.StateBefore = D3D12_RESOURCE_STATES.PRESENT;
            toRtv.Transition.StateAfter = D3D12_RESOURCE_STATES.RENDER_TARGET;
            commandListPtr.value.ResourceBarrier(1, &toRtv);

            D3D12_VIEWPORT vp = D3D12_VIEWPORT.init;
            vp.TopLeftX = 0;
            vp.TopLeftY = 0;
            vp.Width = cast(float)max(1, viewportW);
            vp.Height = cast(float)max(1, viewportH);
            vp.MinDepth = 0.0f;
            vp.MaxDepth = 1.0f;
            commandListPtr.value.RSSetViewports(1, &vp);

            D3D12_RECT scissor;
            scissor.left = 0;
            scissor.top = 0;
            scissor.right = max(1, viewportW);
            scissor.bottom = max(1, viewportH);
            commandListPtr.value.RSSetScissorRects(1, &scissor);

            auto rtv = currentRtvHandle();
            auto dsv = dsvHandle();
            commandListPtr.value.OMSetRenderTargets(1, &rtv, true, &dsv);
            const(float)[4] clearColor = [0.08f, 0.10f, 0.13f, 1.0f];
            commandListPtr.value.ClearRenderTargetView(rtv, clearColor.ptr, 0, null);
            commandListPtr.value.ClearDepthStencilView(dsv, D3D12_CLEAR_FLAGS.STENCIL, 1.0f, 0, 0, null);
        }

        void endFrame(bool doPresent = true) {
            if (!initialized) return;

            D3D12_RESOURCE_BARRIER toPresent = D3D12_RESOURCE_BARRIER.init;
            toPresent.Type = D3D12_RESOURCE_BARRIER_TYPE.TRANSITION;
            toPresent.Flags = D3D12_RESOURCE_BARRIER_FLAGS.NONE;
            toPresent.Transition.pResource = renderTargets[frameIndex].value;
            toPresent.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
            toPresent.Transition.StateBefore = D3D12_RESOURCE_STATES.RENDER_TARGET;
            toPresent.Transition.StateAfter = D3D12_RESOURCE_STATES.PRESENT;
            commandListPtr.value.ResourceBarrier(1, &toPresent);

            enforceHr(commandListPtr.value.Close(), "CommandList.Close failed");
            ID3D12CommandList[1] lists;
            lists[0] = cast(ID3D12CommandList)commandListPtr.value;
            queuePtr.value.ExecuteCommandLists(1, cast(const(ID3D12CommandList)*)lists.ptr);

            if (doPresent && swapChainPtr !is null) {
                auto presentHr = swapChainPtr.value.Present(1, 0);
                if (dxFailed(presentHr)) {
                    if (isDeviceLossHr(presentHr)) {
                        recoverFromDeviceLoss(presentHr);
                        return;
                    }
                    enforceHr(presentHr, "IDXGISwapChain3.Present failed");
                }
            }

            if (!waitForGpu()) {
                recoverFromDeviceLoss(DXGI_ERROR_DEVICE_REMOVED_HR);
                return;
            }
        }

        void shutdown(bool waitForIdle = true) {
            if (waitForIdle && initialized) {
                waitForGpu();
            }
            if (initialized) {
                releaseRenderTargets();
            } else {
                foreach (i; 0 .. FrameCount) {
                    renderTargets[i] = null;
                }
            }
            vertexUploadBuffer = null;
            indexUploadBuffer = null;
            vertexUploadCapacity = 0;
            indexUploadCapacity = 0;
            uploadedVertexBytes = 0;
            uploadedIndexBytes = 0;
            srvHeapPtr = null;
            srvDescriptorSize = 0;
            srvDescriptorCapacity = 0;
            rtvHeapCpuStartPtr = 0;
            offscreenRtvHeapCpuStartPtr = 0;
            dsvHeapCpuStartPtr = 0;
            srvHeapCpuStartPtr = 0;
            srvHeapGpuStartPtr = 0;
            offscreenRtvDescriptorCapacity = 0;
            offscreenRtvCursor = 0;
            foreach (i; 0 .. pipelineStates.length) {
                pipelineStates[i] = null;
                pipelineStatesStencilTest[i] = null;
                pipelineStatesMrt[i] = null;
                pipelineStatesStencilTestMrt[i] = null;
                pipelineStatesMrt2[i] = null;
                pipelineStatesStencilTestMrt2[i] = null;
            }
            pipelineStateStencilWrite = null;
            pipelineStateStencilWriteMrt = null;
            pipelineStateStencilWriteMrt2 = null;
            rootSignaturePtr = null;
            offscreenDepthStencil = null;
            offscreenDsvW = 0;
            offscreenDsvH = 0;
            depthStencil = null;
            dsvHeapPtr = null;
            offscreenRtvHeapPtr = null;
            rtvHeapPtr = null;
            swapChainPtr = null;
            if (fenceEvent !is null) {
                CloseHandle(fenceEvent);
                fenceEvent = null;
            }
            fencePtr = null;
            commandListPtr = null;
            allocatorPtr = null;
            queuePtr = null;
            devicePtr = null;
            adapterPtr = null;
            factoryPtr = null;
            initialized = false;
        }
    }
    DirectXRuntime dx;

public:
    this(SDL_Window* window) {
        this.window = window;
        currentCompositeState = defaultCompositeState();
        maskFallbackTexture = new Texture(1, 1, 4, false, false);
        ubyte[4] white = [cast(ubyte)255, cast(ubyte)255, cast(ubyte)255, cast(ubyte)255];
        maskFallbackTexture.setData(white[], 4);
    }

    static HWND requireWindowHandle(SDL_Window* window) {
        SDL_SysWMinfo info = SDL_SysWMinfo.init;
        SDL_VERSION(&info.version_);
        enforce(SDL_GetWindowWMInfo(window, &info) == SDL_TRUE,
            "SDL_GetWindowWMInfo failed: " ~ sdlError());
        enforce(info.subsystem == SDL_SYSWM_WINDOWS,
            "SDL backend is not Windows subsystem");
        return cast(HWND)info.info.win.window;
    }

    void initializeRenderer() {
        dxTrace("RenderingBackend.initializeRenderer.requireWindowHandle");
        auto hwnd = requireWindowHandle(window);
        dxTrace("RenderingBackend.initializeRenderer.dx.initialize");
        dx.initialize(hwnd, max(1, viewportW), max(1, viewportH), isDxFlag("NJIV_DX_DEBUG_LAYER"));
        dxTrace("RenderingBackend.initializeRenderer.dx.initialize.done");
        if (!announced) {
            writeln("[directx] initialized D3D12 runtime with aurora-directx");
            announced = true;
        }
    }

    void setViewport(int w, int h) {
        int targetW = w;
        int targetH = h;
        queryWindowPixelSize(window, targetW, targetH);
        viewportW = targetW;
        viewportH = targetH;
        dx.resizeSwapChain(max(1, targetW), max(1, targetH));
    }

    void setSharedSnapshot(const SharedBufferSnapshot* snapshot) {
        if (snapshot is null) return;
        currentSnapshot = *snapshot;
    }

    private static float[16] mulMat4(in float[16] a, in float[16] b) {
        float[16] outM;
        foreach (r; 0 .. 4) {
            foreach (c; 0 .. 4) {
                float s = 0;
                foreach (k; 0 .. 4) {
                    s += a[r * 4 + k] * b[k * 4 + c];
                }
                outM[r * 4 + c] = s;
            }
        }
        return outM;
    }

    private static Vec4f mulMat4Vec4(in float[16] m, float x, float y, float z, float w) {
        Vec4f outV;
        outV.r = m[0] * x + m[1] * y + m[2] * z + m[3] * w;
        outV.g = m[4] * x + m[5] * y + m[6] * z + m[7] * w;
        outV.b = m[8] * x + m[9] * y + m[10] * z + m[11] * w;
        outV.a = m[12] * x + m[13] * y + m[14] * z + m[15] * w;
        return outV;
    }

    private static bool rangeInBounds(size_t base, size_t count, size_t length) {
        if (count > length) return false;
        if (base > length - count) return false;
        return true;
    }

    private static CompositeState defaultCompositeState() {
        CompositeState st;
        st.scale = Vec2f(1.0f, 1.0f);
        st.rotationZ = 0.0f;
        st.autoScaled = false;
        st.origViewport = [0, 0, 0, 0];
        st.textureCount = 0;
        st.stencil = 0;
        st.origBuffer = 0;
        st.drawBufferCount = 0;
        st.hasStencil = false;
        st.clearPending = false;
        return st;
    }

    void beginScene() {
        dxTrace("beginScene");
        dx.beginFrame();
        cpuVertices.length = 0;
        cpuIndices.length = 0;
        drawSpans.length = 0;
        dynamicCompositeDepth = 0;
        compositeStateStack.length = 0;
        currentCompositeState = defaultCompositeState();
        drawCalls = 0;
        maskUsesStencil = false;
        maskClearPending = false;
        maskClearValue = 0;
        forceStencilWrite = false;
        forceStencilRef = 1;
    }

    void enqueueSpan(DrawSpan span) {
        if (dynamicCompositeDepth > 0) {
            bool hasCompositeTarget =
                currentCompositeState.textureCount > 0 ||
                currentCompositeState.drawBufferCount > 0 ||
                currentCompositeState.origBuffer != 0;
            if (hasCompositeTarget && currentCompositeState.textureCount > 0) {
                auto target = currentCompositeState.textures[0];
                if (target !is null && target.renderTarget) {
                    span.renderTargetCount = 1;
                    span.renderTargets[0] = target;
                    if (currentCompositeState.drawBufferCount > 1) {
                        auto rtCount = currentCompositeState.drawBufferCount;
                        if (rtCount < 2) rtCount = 2;
                        if (rtCount > 3) rtCount = 3;
                        span.renderTargetCount = cast(uint)rtCount;
                        foreach (i; 0 .. span.renderTargetCount) {
                            Texture rt = null;
                            if (i < currentCompositeState.textureCount) {
                                rt = currentCompositeState.textures[i];
                            }
                            if (rt is null || !rt.renderTarget) {
                                rt = target;
                            }
                            span.renderTargets[i] = rt;
                        }
                    }
                    span.clearRenderTarget = currentCompositeState.clearPending;
                    if (currentCompositeState.clearPending) {
                        currentCompositeState.clearPending = false;
                        if (compositeStateStack.length > 0) {
                            compositeStateStack[$ - 1].clearPending = false;
                        }
                    }
                }
            }
        }
        drawSpans ~= span;
    }

    void applyCompositeTransform(ref float x, ref float y) {
        // GL/VK backends do not apply extra CPU-side dynamic-composite transforms here.
        // Keep DX consistent and rely on matrices supplied by the command stream.
        if (dynamicCompositeDepth == 0) return;
        return;
    }

    void drawPartPacket(ref const(NjgPartDrawPacket) packet, Texture[size_t] texturesByHandle) {
        if (!packet.renderable) return;
        if (packet.indexCount == 0 || packet.vertexCount == 0) return;

        auto vertices = currentSnapshot.vertices;
        auto uvs = currentSnapshot.uvs;
        auto deform = currentSnapshot.deform;
        if (vertices.data is null || uvs.data is null || deform.data is null) return;

        if (packet.vertexAtlasStride == 0 || packet.uvAtlasStride == 0 || packet.deformAtlasStride == 0) return;

        auto vxBase = packet.vertexOffset;
        if (packet.vertexOffset > size_t.max - packet.vertexAtlasStride) return;
        auto vyBase = packet.vertexOffset + packet.vertexAtlasStride;
        auto uxBase = packet.uvOffset;
        if (packet.uvOffset > size_t.max - packet.uvAtlasStride) return;
        auto uyBase = packet.uvOffset + packet.uvAtlasStride;
        auto dxBase = packet.deformOffset;
        if (packet.deformOffset > size_t.max - packet.deformAtlasStride) return;
        auto dyBase = packet.deformOffset + packet.deformAtlasStride;

        if (!rangeInBounds(vxBase, packet.vertexCount, vertices.length)) return;
        if (!rangeInBounds(vyBase, packet.vertexCount, vertices.length)) return;
        if (!rangeInBounds(uxBase, packet.vertexCount, uvs.length)) return;
        if (!rangeInBounds(uyBase, packet.vertexCount, uvs.length)) return;
        if (!rangeInBounds(dxBase, packet.vertexCount, deform.length)) return;
        if (!rangeInBounds(dyBase, packet.vertexCount, deform.length)) return;
        if (packet.indices is null) return;

        auto mvp = mulMat4(packet.renderMatrix, packet.modelMatrix);
        auto baseVertex = cast(uint)cpuVertices.length;
        cpuVertices.reserve(cpuVertices.length + packet.vertexCount);
        foreach (i; 0 .. packet.vertexCount) {
            auto px = vertices.data[vxBase + i] + deform.data[dxBase + i] - packet.origin.x;
            auto py = vertices.data[vyBase + i] + deform.data[dyBase + i] - packet.origin.y;
            auto clip = mulMat4Vec4(mvp, px, py, 0, 1);
            float invW = (clip.a == 0 || isNaN(clip.a)) ? 1.0f : 1.0f / clip.a;

            Vertex v;
            v.x = clip.r * invW;
            v.y = clip.g * invW;
            applyCompositeTransform(v.x, v.y);
            v.u = uvs.data[uxBase + i];
            v.v = uvs.data[uyBase + i];
            cpuVertices ~= v;
        }

        cpuIndices.reserve(cpuIndices.length + packet.indexCount);
        auto firstIndex = cast(uint)cpuIndices.length;
        foreach (i; 0 .. packet.indexCount) {
            auto idx = packet.indices[i];
            if (idx < packet.vertexCount) {
                uint vi = baseVertex + idx;
                if (vi <= ushort.max) {
                    cpuIndices ~= cast(ushort)vi;
                }
            }
        }
        auto appended = cast(uint)cpuIndices.length - firstIndex;
        if (appended > 0) {
            DrawSpan span;
            span.firstIndex = firstIndex;
            span.indexCount = appended;
            span.blendMode = dx.sanitizeBlendMode(packet.blendingMode);
            span.stencilMode = StencilMode.None;
            span.stencilRef = 0;
            span.stencilClearValue = 0;
            span.clearStencil = false;
            span.textureCount = cast(uint)(packet.textureCount > 3 ? 3 : packet.textureCount);
            span.useMultistageBlend = packet.useMultistageBlend;
            span.hasEmissionOrBumpmap = packet.hasEmissionOrBumpmap;
            span.isMask = packet.isMask;
            span.maskThreshold = packet.maskThreshold;
            span.clampedTint = packet.clampedTint;
            span.clampedScreen = packet.clampedScreen;
            span.opacity = packet.opacity;
            span.emissionStrength = packet.emissionStrength;
            foreach (i; 0 .. span.textureCount) {
                auto h = packet.textureHandles[i];
                if (auto tex = h in texturesByHandle) {
                    span.textures[i] = *tex;
                }
            }

            if (forceStencilWrite) {
                span.stencilMode = StencilMode.Write;
                span.stencilRef = forceStencilRef;
                span.clearStencil = maskClearPending;
                span.stencilClearValue = maskClearValue;
                maskClearPending = false;
                span.isMask = true;
                span.maskThreshold = 0.0f;
                span.blendMode = BlendMode.Normal;
            } else if (inMaskPass) {
                if (!inMaskContent) {
                    // Legacy fallback while mask shape is being built.
                    span.isMask = true;
                    span.maskThreshold = 0.0f;
                    span.blendMode = BlendMode.Normal;
                } else {
                    span.isMask = false;
                    if (maskUsesStencil) {
                        span.stencilMode = StencilMode.TestEqual;
                        span.stencilRef = 1;
                    } else {
                        span.blendMode = BlendMode.DestinationIn;
                    }
                }
            }
            enqueueSpan(span);
        }
        drawCalls++;
    }
    void drawMaskPacket(ref const(NjgMaskDrawPacket) packet) {
        if (packet.indexCount == 0 || packet.vertexCount == 0) return;

        auto vertices = currentSnapshot.vertices;
        auto deform = currentSnapshot.deform;
        if (vertices.data is null || deform.data is null) return;

        if (packet.vertexAtlasStride == 0 || packet.deformAtlasStride == 0) return;

        auto vxBase = packet.vertexOffset;
        if (packet.vertexOffset > size_t.max - packet.vertexAtlasStride) return;
        auto vyBase = packet.vertexOffset + packet.vertexAtlasStride;
        auto dxBase = packet.deformOffset;
        if (packet.deformOffset > size_t.max - packet.deformAtlasStride) return;
        auto dyBase = packet.deformOffset + packet.deformAtlasStride;

        if (!rangeInBounds(vxBase, packet.vertexCount, vertices.length)) return;
        if (!rangeInBounds(vyBase, packet.vertexCount, vertices.length)) return;
        if (!rangeInBounds(dxBase, packet.vertexCount, deform.length)) return;
        if (!rangeInBounds(dyBase, packet.vertexCount, deform.length)) return;
        if (packet.indices is null) return;

        auto mvp = packet.mvp;
        auto baseVertex = cast(uint)cpuVertices.length;
        cpuVertices.reserve(cpuVertices.length + packet.vertexCount);
        foreach (i; 0 .. packet.vertexCount) {
            auto px = vertices.data[vxBase + i] + deform.data[dxBase + i] - packet.origin.x;
            auto py = vertices.data[vyBase + i] + deform.data[dyBase + i] - packet.origin.y;
            auto clip = mulMat4Vec4(mvp, px, py, 0, 1);
            float invW = (clip.a == 0 || isNaN(clip.a)) ? 1.0f : 1.0f / clip.a;

            Vertex v;
            v.x = clip.r * invW;
            v.y = clip.g * invW;
            applyCompositeTransform(v.x, v.y);
            v.u = 0.0f;
            v.v = 0.0f;
            cpuVertices ~= v;
        }

        auto firstIndex = cast(uint)cpuIndices.length;
        cpuIndices.reserve(cpuIndices.length + packet.indexCount);
        foreach (i; 0 .. packet.indexCount) {
            auto idx = packet.indices[i];
            if (idx < packet.vertexCount) {
                uint vi = baseVertex + idx;
                if (vi <= ushort.max) {
                    cpuIndices ~= cast(ushort)vi;
                }
            }
        }

        auto appended = cast(uint)cpuIndices.length - firstIndex;
        if (appended > 0) {
            DrawSpan span;
            span.firstIndex = firstIndex;
            span.indexCount = appended;
            span.blendMode = BlendMode.Normal;
            span.stencilMode = StencilMode.None;
            span.stencilRef = 0;
            span.stencilClearValue = 0;
            span.clearStencil = false;
            span.textureCount = 1;
            span.textures[0] = maskFallbackTexture;
            span.useMultistageBlend = false;
            span.hasEmissionOrBumpmap = false;
            span.isMask = true;
            span.maskThreshold = 0.0f;
            span.clampedTint = Vec3f(1, 1, 1);
            span.clampedScreen = Vec3f(0, 0, 0);
            span.opacity = 1.0f;
            span.emissionStrength = 0.0f;

            if (forceStencilWrite) {
                span.stencilMode = StencilMode.Write;
                span.stencilRef = forceStencilRef;
                span.clearStencil = maskClearPending;
                span.stencilClearValue = maskClearValue;
                maskClearPending = false;
            } else if (inMaskPass && inMaskContent) {
                span.isMask = false;
                if (maskUsesStencil) {
                    span.stencilMode = StencilMode.TestEqual;
                    span.stencilRef = 1;
                } else {
                    span.blendMode = BlendMode.DestinationIn;
                }
            }

            enqueueSpan(span);
            drawCalls++;
        }
    }
    void beginDynamicComposite(NjgDynamicCompositePass pass) {
        if (isDxTraceEnabled()) {
            dxTrace("beginDynamicComposite"
                ~ " texCount=" ~ to!string(pass.textureCount)
                ~ " scale=(" ~ to!string(pass.scale.x) ~ "," ~ to!string(pass.scale.y) ~ ")"
                ~ " rotZ=" ~ to!string(pass.rotationZ)
                ~ " autoScaled=" ~ to!string(pass.autoScaled)
                ~ " origViewport=(" ~ to!string(pass.origViewport[0]) ~ ","
                ~ to!string(pass.origViewport[1]) ~ ","
                ~ to!string(pass.origViewport[2]) ~ ","
                ~ to!string(pass.origViewport[3]) ~ ")"
                ~ " drawBuffers=" ~ to!string(pass.drawBufferCount)
                ~ " hasStencil=" ~ to!string(pass.hasStencil));
        }
        inDynamicComposite = true;
        dynamicCompositeDepth++;
        CompositeState st;
        st = defaultCompositeState();
        st.scale = pass.scale;
        st.rotationZ = pass.rotationZ;
        st.autoScaled = pass.autoScaled;
        st.origViewport = pass.origViewport;
        st.textureCount = pass.textureCount;
        st.stencil = pass.stencil;
        st.origBuffer = pass.origBuffer;
        st.drawBufferCount = pass.drawBufferCount;
        st.hasStencil = pass.hasStencil;
        st.clearPending = true;
        auto count = cast(size_t)(pass.textureCount > 3 ? 3 : pass.textureCount);
        foreach (i; 0 .. count) {
            auto h = pass.textures[i];
            if (auto tex = h in gTextures) {
                st.textures[i] = *tex;
            }
        }
        compositeStateStack ~= st;
        currentCompositeState = st;
    }
    void endDynamicComposite(NjgDynamicCompositePass pass) {
        dxTrace("endDynamicComposite");
        if (dynamicCompositeDepth > 0) {
            dynamicCompositeDepth--;
        }
        if (compositeStateStack.length > 0) {
            compositeStateStack.length = compositeStateStack.length - 1;
        }
        if (compositeStateStack.length > 0) {
            currentCompositeState = compositeStateStack[$ - 1];
        } else {
            currentCompositeState = defaultCompositeState();
        }
        if (dynamicCompositeDepth == 0) {
            inDynamicComposite = false;
        }
    }
    void beginMask(bool usesStencil) {
        inMaskPass = true;
        inMaskContent = false;
        maskUsesStencil = usesStencil;
        maskClearPending = true;
        maskClearValue = usesStencil ? cast(ubyte)0 : cast(ubyte)1;
    }
    void applyMask(ref const(NjgMaskApplyPacket) packet, Texture[size_t] texturesByHandle) {
        forceStencilWrite = true;
        forceStencilRef = packet.isDodge ? cast(ubyte)0 : cast(ubyte)1;
        final switch (packet.kind) {
            case MaskDrawableKind.Part:
                NjgPartDrawPacket masked = packet.partPacket;
                drawPartPacket(masked, texturesByHandle);
                break;
            case MaskDrawableKind.Mask:
                drawMaskPacket(packet.maskPacket);
                break;
        }
        forceStencilWrite = false;
    }
    void beginMaskContent() {
        inMaskContent = true;
    }
    void endMask() {
        inMaskPass = false;
        inMaskContent = false;
        maskUsesStencil = false;
        maskClearPending = false;
        forceStencilWrite = false;
    }
    void postProcessScene() {}
    void endScene() {
        dxTrace("endScene.uploadGeometry");
        dx.uploadGeometry(cpuVertices, cpuIndices);
        if (isDxTraceEnabled()) {
            dxTrace("endScene.counts vertices=" ~ to!string(cpuVertices.length) ~
                " indices=" ~ to!string(cpuIndices.length) ~
                " spans=" ~ to!string(drawSpans.length));
        }
        bool skipDraw = isDxFlag("NJIV_DX_SKIP_DRAW");
        bool skipPresent = isDxFlag("NJIV_DX_SKIP_PRESENT");
        if (skipDraw) {
            dxTrace("endScene.skipDraw");
        } else {
            dxTrace("endScene.drawUploadedGeometry");
            dx.drawUploadedGeometry(drawSpans, maskFallbackTexture);
        }
        if (skipPresent) {
            dxTrace("endScene.skipPresent");
        }
        dxTrace("endScene.endFrame");
        dx.endFrame(!skipPresent);
        if (dx.consumeDeviceResetFlag()) {
            foreach (k, tex; gTextures) {
                if (tex !is null) {
                    tex.invalidateGpuObjects();
                }
            }
            if (maskFallbackTexture !is null) {
                maskFallbackTexture.invalidateGpuObjects();
            }
        }
        frameSeq++;
        if (frameSeq % 60 == 0) {
            writeln("[directx] frame=", frameSeq,
                " draws=", drawCalls,
                " vertices=", cpuVertices.length,
                " indices=", cpuIndices.length,
                " uploadV=", dx.uploadedVertexBytes,
                " uploadI=", dx.uploadedIndexBytes,
                " heap=", heapType);
        }
    }
    void dispose() {
        dx.shutdown();
    }
}

struct DirectXBackendInit {
    SDL_Window* window;
    RenderingBackend backend;
    int drawableW;
    int drawableH;
    UnityResourceCallbacks callbacks;
}

__gshared Texture[size_t] gTextures;
__gshared size_t gNextHandle = 1;

string sdlError() {
    auto msg = SDL_GetError();
    if (msg is null) return "unknown";
    return fromStringz(msg).idup;
}

void queryWindowPixelSize(SDL_Window* window, out int w, out int h) {
    w = 1;
    h = 1;
    if (window is null) return;

    SDL_GetWindowSize(window, &w, &h);
    if (w <= 0) w = 1;
    if (h <= 0) h = 1;

    SDL_SysWMinfo info = SDL_SysWMinfo.init;
    SDL_VERSION(&info.version_);
    if (SDL_GetWindowWMInfo(window, &info) == SDL_TRUE &&
        info.subsystem == SDL_SYSWM_WINDOWS &&
        info.info.win.window !is null)
    {
        RECT rc = RECT.init;
        if (GetClientRect(cast(HWND)info.info.win.window, &rc) != 0) {
            auto pw = rc.right - rc.left;
            auto ph = rc.bottom - rc.top;
            if (pw > 0) w = pw;
            if (ph > 0) h = ph;
        }
    }
}

DirectXBackendInit initDirectXBackend(int width, int height, bool isTest) {
    dxTrace("initDirectXBackend.loadSDL");
    auto support = loadSDL();
    version (OSX) {
        if (support == SDLSupport.noLibrary || support == SDLSupport.badLibrary) {
            support = loadSDL("/opt/homebrew/lib/libSDL2-2.0.0.dylib");
        }
    }
    enforce(support >= SDLSupport.sdl206,
        "Failed to load SDL2 (loaded=" ~ loadedSDLVersion().to!string ~ ")");
    dxTrace("initDirectXBackend.SDL_Init");
    enforce(SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS) == 0, "SDL_Init failed: " ~ sdlError());

    dxTrace("initDirectXBackend.SDL_CreateWindow");
    auto window = SDL_CreateWindow("nijiv",
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        width, height,
        SDL_WINDOW_RESIZABLE | SDL_WINDOW_ALLOW_HIGHDPI | SDL_WINDOW_SHOWN);
    enforce(window !is null, "SDL_CreateWindow failed: " ~ sdlError());

    int drawableW = width;
    int drawableH = height;
    queryWindowPixelSize(window, drawableW, drawableH);

    dxTrace("initDirectXBackend.new RenderingBackend");
    auto backend = new RenderingBackend(window);
    backend.viewportW = max(1, drawableW);
    backend.viewportH = max(1, drawableH);
    dxTrace("initDirectXBackend.initializeRenderer");
    backend.initializeRenderer();
    dxTrace("initDirectXBackend.setViewport");
    backend.setViewport(drawableW, drawableH);

    UnityResourceCallbacks cbs;
    cbs.userData = window;
    cbs.createTexture = (int w, int h, int channels, int mipLevels, int format, bool renderTarget, bool stencil, void* userData) {
        size_t handle = gNextHandle++;
        gTextures[handle] = new Texture(w, h, channels, stencil, renderTarget);
        return handle;
    };
    cbs.updateTexture = (size_t handle, const(ubyte)* data, size_t dataLen, int w, int h, int channels, void* userData) {
        if (auto tex = handle in gTextures) {
            if (*tex is null || data is null) return;
            auto expected = cast(size_t)w * cast(size_t)h * cast(size_t)max(1, channels);
            if (expected == 0 || dataLen < expected) return;
            (*tex).width = w;
            (*tex).height = h;
            (*tex).setData(data[0 .. expected], channels);
        }
    };
    cbs.releaseTexture = (size_t handle, void* userData) {
        if (auto tex = handle in gTextures) {
            if (*tex !is null) (*tex).dispose();
            gTextures.remove(handle);
        }
    };

    return DirectXBackendInit(window, backend, drawableW, drawableH, cbs);
}

void renderCommands(const DirectXBackendInit* dx,
                    const SharedBufferSnapshot* snapshot,
                    const CommandQueueView* view)
{
    if (dx is null || dx.backend is null || view is null) return;

    auto backend = cast(RenderingBackend)dx.backend;
    backend.setSharedSnapshot(snapshot);
    backend.beginScene();

    auto cmds = view.commands[0 .. view.count];
    foreach (cmd; cmds) {
        auto kind = cast(uint)cmd.kind;
        switch (kind) {
            case cast(uint)NjgRenderCommandKind.DrawPart:
                backend.drawPartPacket(cmd.partPacket, gTextures);
                break;
            case cast(uint)NjgRenderCommandKind.DrawMask:
                backend.drawMaskPacket(cmd.maskApplyPacket.maskPacket);
                break;
            case cast(uint)NjgRenderCommandKind.BeginDynamicComposite:
                backend.beginDynamicComposite(cmd.dynamicPass);
                break;
            case cast(uint)NjgRenderCommandKind.EndDynamicComposite:
                backend.endDynamicComposite(cmd.dynamicPass);
                break;
            case cast(uint)NjgRenderCommandKind.BeginMask:
                backend.beginMask(cmd.usesStencil);
                break;
            case cast(uint)NjgRenderCommandKind.ApplyMask:
                backend.applyMask(cmd.maskApplyPacket, gTextures);
                break;
            case cast(uint)NjgRenderCommandKind.BeginMaskContent:
                backend.beginMaskContent();
                break;
            case cast(uint)NjgRenderCommandKind.EndMask:
                backend.endMask();
                break;
            default:
                break;
        }
    }

    backend.postProcessScene();
    backend.endScene();
}

void shutdownDirectXBackend(ref DirectXBackendInit dx) {
    if (dx.backend !is null) {
        dx.backend.dispose();
        dx.backend = null;
    }
    foreach (k, tex; gTextures) {
        if (tex !is null) tex.dispose();
    }
    gTextures.clear();
    gNextHandle = 1;
    if (dx.window !is null) {
        SDL_DestroyWindow(dx.window);
        dx.window = null;
    }
    SDL_Quit();
}

} // version (EnableDirectXBackend)
