module vulkan_backend;

version (EnableVulkanBackend) {

import std.algorithm : min;
import std.algorithm.comparison : max;
import std.algorithm.searching : canFind;
import std.conv : to;
import std.exception : enforce;
import std.math : isNaN;
import std.process : environment;
import std.stdio : writeln;
import std.string : fromStringz, toStringz;
import core.thread : thread_attachThis;

import core.stdc.string : memcpy;
import core.stdc.stdint : uint32_t;
import core.stdc.stdio : fprintf, stderr;

import bindbc.sdl;
import bindbc.sdl.bind.sdlvulkan;
import bindbc.sdl.dynload : loadedSDLVersion;

import erupted;
import erupted.vulkan_lib_loader;

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

enum NjgResult : int {
    Ok = 0,
    InvalidArgument = 1,
    Failure = 2,
}

alias RendererHandle = void*;
alias PuppetHandle = void*;

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

struct VulkanBackendInit {
    SDL_Window* window;
    RenderingBackend backend;
    int drawableW;
    int drawableH;
    UnityResourceCallbacks callbacks;
}

struct Vertex {
    float x;
    float y;
    float u;
    float v;
}

enum PipelineKind : uint {
    Part = 0,
    PartStage1 = 1,
    PartStage2 = 2,
    PartMask = 3,
    Mask = 4,
    PartStencilTest = 5,
    PartStencilWrite = 6,
    PartMaskStencilWrite = 7,
    MaskStencilWrite = 8,
    Count = 9,
}

struct PushConstants {
    float[4] tintOpacity;
    float[4] screenEmission;
}

struct DrawBatch {
    uint firstIndex;
    uint indexCount;
    int vertexOffset;
    PipelineKind pipelineKind;
    PushConstants pushConstants;
    size_t[3] textureHandles;
    size_t textureCount;
    BlendMode blendMode;
    size_t targetHandle;
    bool clearTarget;
    bool clearStencil;
    uint32_t clearStencilValue;
    uint32_t stencilReference;
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
    ulong version_;

public:
    this(int width, int height, int channels, bool stencil, bool renderTarget = false) {
        this.width = width;
        this.height = height;
        this.channels = channels;
        this.stencil = stencil;
        this.renderTarget = renderTarget;
    }

    void setData(const(ubyte)[] data, int inChannels = -1) {
        if (inChannels > 0) channels = inChannels;
        auto expected = cast(size_t)width * cast(size_t)height * cast(size_t)max(1, channels);
        pixels_.length = expected;
        auto copyLen = min(expected, data.length);
        if (copyLen > 0) {
            pixels_[0 .. copyLen] = data[0 .. copyLen];
        }
        if (copyLen < expected) {
            pixels_[copyLen .. expected] = 0;
        }
        version_++;
    }

    const(ubyte)[] data() const {
        return pixels_;
    }

    void dispose() {
        pixels_.length = 0;
        version_++;
    }

    ulong revision() const {
        return version_;
    }
}

private __gshared Texture[size_t] gTextures;
private __gshared size_t gNextHandle = 1;
private __gshared Object gTexturesGuard;

shared static this() {
    gTexturesGuard = new Object();
}

private void ensureDThreadAttached() {
    if (gTexturesGuard is null) {
        gTexturesGuard = new Object();
    }
    thread_attachThis();
}

private string sdlError() {
    auto err = SDL_GetError();
    return err is null ? "" : fromStringz(err).idup;
}

private void vkEnforce(VkResult result, string message) {
    enforce(result == VK_SUCCESS, message ~ " (VkResult=" ~ result.to!string ~ ")");
}

private VkCompositeAlphaFlagBitsKHR chooseCompositeAlpha(VkCompositeAlphaFlagsKHR supported) {
    VkCompositeAlphaFlagBitsKHR[4] preferred = [
        VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR,
        VK_COMPOSITE_ALPHA_POST_MULTIPLIED_BIT_KHR,
        VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR,
        VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR
    ];
    foreach (mode; preferred) {
        if ((supported & cast(VkCompositeAlphaFlagsKHR)mode) != 0) {
            return mode;
        }
    }
    return VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
}

private bool envEnabled(string name) {
    auto value = environment.get(name, "");
    return value == "1" || value == "true" || value == "TRUE";
}

private extern(System) nothrow @nogc VkBool32 vulkanValidationCallback(
    VkDebugUtilsMessageSeverityFlagBitsEXT severity,
    VkDebugUtilsMessageTypeFlagsEXT types,
    const(VkDebugUtilsMessengerCallbackDataEXT)* callbackData,
    void* userData) {
    if (callbackData !is null && callbackData.pMessage !is null) {
        fprintf(stderr,
                "[vulkan][validation] sev=%u type=%u %s\n",
                cast(uint)severity,
                cast(uint)types,
                callbackData.pMessage);
    }
    return VK_FALSE;
}

private float[16] mulMat4(ref const(float[16]) a, ref const(float[16]) b) {
    float[16] r;
    foreach (row; 0 .. 4) {
        foreach (col; 0 .. 4) {
            float sum = 0;
            foreach (k; 0 .. 4) {
                sum += a[row * 4 + k] * b[k * 4 + col];
            }
            r[row * 4 + col] = sum;
        }
    }
    return r;
}

private Vec4f mulMat4Vec4(ref const(float[16]) m, float x, float y, float z, float w) {
    float[4] v = [x, y, z, w];
    float[4] r;
    foreach (row; 0 .. 4) {
        float sum = 0;
        foreach (col; 0 .. 4) {
            sum += m[row * 4 + col] * v[col];
        }
        r[row] = sum;
    }
    return Vec4f(r[0], r[1], r[2], r[3]);
}

private uint findMemoryType(VkPhysicalDevice phys,
                            uint typeFilter,
                            VkMemoryPropertyFlags properties)
{
    VkPhysicalDeviceMemoryProperties memProps;
    vkGetPhysicalDeviceMemoryProperties(phys, &memProps);
    foreach (i; 0 .. memProps.memoryTypeCount) {
        auto mask = 1u << i;
        if ((typeFilter & mask) != 0 &&
            (memProps.memoryTypes[i].propertyFlags & properties) == properties) {
            return i;
        }
    }
    enforce(false, "No matching Vulkan memory type");
    return 0;
}

private VkFormat findSupportedFormat(VkPhysicalDevice phys,
                                     const(VkFormat)[] candidates,
                                     VkImageTiling tiling,
                                     VkFormatFeatureFlags features)
{
    foreach (f; candidates) {
        VkFormatProperties props;
        vkGetPhysicalDeviceFormatProperties(phys, f, &props);
        if (tiling == VK_IMAGE_TILING_LINEAR) {
            if ((props.linearTilingFeatures & features) == features) return f;
        } else {
            if ((props.optimalTilingFeatures & features) == features) return f;
        }
    }
    enforce(false, "No supported depth/stencil format");
    return VK_FORMAT_UNDEFINED;
}

class RenderingBackend {
private:
    struct VkTextureResource {
        VkImage image;
        VkDeviceMemory memory;
        VkImageView view;
        VkSampler sampler;
        VkFramebuffer framebuffer;
        int width;
        int height;
        int channels;
        bool renderTarget;
        ulong revision;
    }

    SDL_Window* window;
    bool isTest;

    VkInstance instance;
    bool validationEnabled;
    VkDebugUtilsMessengerEXT debugMessenger;
    VkSurfaceKHR surface;
    VkPhysicalDevice physicalDevice;
    VkDevice device;
    uint graphicsQueueFamily = uint.max;
    uint presentQueueFamily = uint.max;
    VkQueue graphicsQueue;
    VkQueue presentQueue;

    VkSwapchainKHR swapchain;
    VkFormat swapchainFormat;
    VkFormat depthStencilFormat;
    VkExtent2D swapchainExtent;
    VkImage[] swapchainImages;
    VkImageView[] swapchainImageViews;
    VkImage[] swapchainDepthImages;
    VkDeviceMemory[] swapchainDepthMemories;
    VkImageView[] swapchainDepthImageViews;
    bool[] swapchainImageInitialized;
    VkFramebuffer[] framebuffers;

    VkRenderPass renderPass;
    VkRenderPass offscreenRenderPass;
    VkDescriptorSetLayout descriptorSetLayout;
    VkDescriptorPool[] descriptorPools;
    VkDescriptorPool activeDescriptorPool;
    VkPipelineLayout pipelineLayout;
    VkPipeline[cast(size_t)BlendMode.Count][cast(size_t)PipelineKind.Count] pipelines;
    VkPipeline[cast(size_t)BlendMode.Count][cast(size_t)PipelineKind.Count] offscreenPipelines;
    static assert(pipelines.length == cast(size_t)PipelineKind.Count);
    static assert(pipelines[0].length == cast(size_t)BlendMode.Count);
    static assert(offscreenPipelines.length == cast(size_t)PipelineKind.Count);
    static assert(offscreenPipelines[0].length == cast(size_t)BlendMode.Count);

    VkCommandPool commandPool;
    VkCommandBuffer[] commandBuffers;

    enum MaxFramesInFlight = 2;
    VkSemaphore[MaxFramesInFlight] imageAvailable;
    VkSemaphore[] renderFinishedByImage;
    VkFence[MaxFramesInFlight] inFlight;
    VkFence[] inFlightByImage;
    uint frameIndex;

    VkBuffer vertexBuffer;
    VkDeviceMemory vertexMemory;
    size_t vertexCapacity;

    VkBuffer indexBuffer;
    VkDeviceMemory indexMemory;
    size_t indexCapacity;

    Vertex[] cpuVertices;
    ushort[] cpuIndices;
    DrawBatch[] batches;
    size_t[] dynamicCompositeStack;
    size_t[3] activeTargetHandles;
    size_t activeTargetCount;
    bool clearActiveTarget;
    bool maskBuildActive;
    bool maskContentActive;
    bool maskStencilAvailable;
    bool maskStencilWritten;
    bool pendingMaskStencilClear;
    uint32_t pendingMaskStencilClearValue = 1;
    uint32_t pendingMaskWriteReference = 1;
    bool advancedBlendSupported;
    VkTextureResource[size_t] textureResources;
    VkTextureResource fallbackWhite;
    VkTextureResource fallbackBlack;
    bool textureMutationSynced;

    const(SharedBufferSnapshot)* currentSnapshot;

public:
    this(SDL_Window* window, bool isTest) {
        this.window = window;
        this.isTest = isTest;
    }

    ~this() {
        dispose();
    }

    void dispose() {
        if (device != VK_NULL_HANDLE) {
            vkDeviceWaitIdle(device);
        }

        destroySwapchainResources();
        destroyTextureResource(fallbackWhite);
        destroyTextureResource(fallbackBlack);
        foreach (_h, ref tex; textureResources) {
            destroyTextureResource(tex);
        }
        textureResources.clear();

        if (vertexBuffer != VK_NULL_HANDLE) vkDestroyBuffer(device, vertexBuffer, null);
        if (vertexMemory != VK_NULL_HANDLE) vkFreeMemory(device, vertexMemory, null);
        if (indexBuffer != VK_NULL_HANDLE) vkDestroyBuffer(device, indexBuffer, null);
        if (indexMemory != VK_NULL_HANDLE) vkFreeMemory(device, indexMemory, null);

        foreach (i; 0 .. MaxFramesInFlight) {
            if (imageAvailable[i] != VK_NULL_HANDLE) vkDestroySemaphore(device, imageAvailable[i], null);
            if (inFlight[i] != VK_NULL_HANDLE) vkDestroyFence(device, inFlight[i], null);
        }

        if (commandPool != VK_NULL_HANDLE) vkDestroyCommandPool(device, commandPool, null);
        if (debugMessenger != VK_NULL_HANDLE && instance != VK_NULL_HANDLE) {
            vkDestroyDebugUtilsMessengerEXT(instance, debugMessenger, null);
        }
        if (device != VK_NULL_HANDLE) vkDestroyDevice(device, null);
        if (surface != VK_NULL_HANDLE) vkDestroySurfaceKHR(instance, surface, null);
        if (instance != VK_NULL_HANDLE) vkDestroyInstance(instance, null);

        imageAvailable[] = VK_NULL_HANDLE;
        inFlight[] = VK_NULL_HANDLE;
        renderFinishedByImage.length = 0;
        inFlightByImage.length = 0;
        commandPool = VK_NULL_HANDLE;
        device = VK_NULL_HANDLE;
        surface = VK_NULL_HANDLE;
        instance = VK_NULL_HANDLE;
        debugMessenger = VK_NULL_HANDLE;
        validationEnabled = false;

        // The Vulkan loader may be owned by another component (e.g. capture tooling).
        // Do not force dlclose here to avoid invalid-handle crashes on shutdown paths.
    }

    void initializeRenderer() {
        enforce(loadGlobalLevelFunctions(), "Failed to load Vulkan global functions");
        createInstance();
        createSurface();
        pickPhysicalDevice();
        createLogicalDevice();
        createCommandPool();
        createSyncObjects();
        recreateSwapchain();
    }

    void setViewport(int width, int height) {
        if (width <= 0 || height <= 0) return;
        if (swapchainExtent.width == cast(uint)width && swapchainExtent.height == cast(uint)height) {
            return;
        }
        recreateSwapchain();
    }

    void initializePartBackendResources() {
        // Pipeline resources are created in recreateSwapchain.
    }

    void initializeMaskBackend() {
        // Not yet implemented in Vulkan path.
    }

    void resizeViewportTargets(int width, int height) {
        setViewport(width, height);
    }

    void bindDrawableVao() {
        // Not applicable in Vulkan.
    }

    void rebindActiveTargets() {
        // Not applicable in Vulkan.
    }

    uint sharedVertexBufferHandle() {
        return 0;
    }

    uint sharedUvBufferHandle() {
        return 0;
    }

    uint sharedDeformBufferHandle() {
        return 0;
    }

    void setSharedSnapshot(const SharedBufferSnapshot* snapshot) {
        currentSnapshot = snapshot;
    }

    void beginScene() {
        textureMutationSynced = false;
        pruneTextureCache();
        cpuVertices.length = 0;
        cpuIndices.length = 0;
        batches.length = 0;
        dynamicCompositeStack.length = 0;
        activeTargetHandles[] = 0;
        activeTargetCount = 0;
        clearActiveTarget = false;
        maskBuildActive = false;
        maskContentActive = false;
        maskStencilAvailable = false;
        maskStencilWritten = false;
        pendingMaskStencilClear = false;
        pendingMaskStencilClearValue = 1;
        pendingMaskWriteReference = 1;
    }

    void postProcessScene() {
        // Post-processing is not yet implemented in Vulkan path.
    }

    void endScene() {
        drawFrame();
    }

    void beginMask(bool useStencil) {
        // Current Vulkan backend only has stencil attachment on the root swapchain target.
        maskStencilAvailable = (activeTargetCount == 0 || activeTargetHandles[0] == 0);
        if (!maskStencilAvailable) {
            maskBuildActive = false;
            maskContentActive = false;
            pendingMaskStencilClear = false;
            return;
        }
        maskBuildActive = true;
        maskContentActive = false;
        maskStencilWritten = false;
        pendingMaskStencilClear = true;
        pendingMaskStencilClearValue = useStencil ? 0 : 1;
        // Ensure stencil is cleared even if no mask geometry is emitted.
        DrawBatch clearOnly;
        clearOnly.targetHandle = (activeTargetCount > 0) ? activeTargetHandles[0] : 0;
        clearOnly.clearStencil = true;
        clearOnly.clearStencilValue = pendingMaskStencilClearValue;
        batches ~= clearOnly;
        pendingMaskStencilClear = false;
    }

    void applyMask(ref const(NjgMaskApplyPacket) packet) {
        if (!maskBuildActive || !maskStencilAvailable) return;
        pendingMaskWriteReference = packet.isDodge ? 0u : 1u;
        if (packet.kind == MaskDrawableKind.Part) {
            drawPartPacket(packet.partPacket);
        } else {
            drawMaskPacket(packet.maskPacket);
        }
    }

    void beginMaskContent() {
        if (!maskStencilAvailable) {
            maskBuildActive = false;
            maskContentActive = false;
            return;
        }
        if (!maskStencilWritten) {
            // Avoid clipping everything when no mask geometry was actually written.
            maskBuildActive = false;
            maskContentActive = false;
            return;
        }
        maskBuildActive = false;
        maskContentActive = true;
    }

    void endMask() {
        maskBuildActive = false;
        maskContentActive = false;
        maskStencilAvailable = false;
        maskStencilWritten = false;
        pendingMaskStencilClear = false;
    }

    void beginDynamicComposite(NjgDynamicCompositePass pass) {
        dynamicCompositeStack ~= activeTargetHandles[0];
        dynamicCompositeStack ~= activeTargetHandles[1];
        dynamicCompositeStack ~= activeTargetHandles[2];
        dynamicCompositeStack ~= activeTargetCount;
        activeTargetHandles[] = 0;
        activeTargetCount = min(pass.textureCount, pass.textures.length);
        foreach (i; 0 .. activeTargetCount) {
            activeTargetHandles[i] = pass.textures[i];
        }
        clearActiveTarget = true;
    }

    void endDynamicComposite(NjgDynamicCompositePass pass) {
        if (dynamicCompositeStack.length >= 4) {
            activeTargetCount = dynamicCompositeStack[$ - 1];
            activeTargetHandles[2] = dynamicCompositeStack[$ - 2];
            activeTargetHandles[1] = dynamicCompositeStack[$ - 3];
            activeTargetHandles[0] = dynamicCompositeStack[$ - 4];
            dynamicCompositeStack.length = dynamicCompositeStack.length - 4;
        } else {
            activeTargetHandles[] = 0;
            activeTargetCount = 0;
        }
        clearActiveTarget = false;
    }

    size_t framebufferHandle() {
        return 0;
    }

    void drawPartPacket(ref const(NjgPartDrawPacket) packet)
    {
        if (packet.indexCount == 0 || packet.vertexCount == 0) return;
        if (currentSnapshot is null) return;

        auto vertices = currentSnapshot.vertices;
        auto uvs = currentSnapshot.uvs;
        auto deform = currentSnapshot.deform;
        if (vertices.data is null || uvs.data is null || deform.data is null) return;

        if (packet.vertexAtlasStride == 0 || packet.uvAtlasStride == 0 || packet.deformAtlasStride == 0) return;

        auto vxBase = packet.vertexOffset;
        auto vyBase = packet.vertexOffset + packet.vertexAtlasStride;
        auto uxBase = packet.uvOffset;
        auto uyBase = packet.uvOffset + packet.uvAtlasStride;
        auto dxBase = packet.deformOffset;
        auto dyBase = packet.deformOffset + packet.deformAtlasStride;

        if (vxBase + packet.vertexCount > vertices.length) return;
        if (vyBase + packet.vertexCount > vertices.length) return;
        if (uxBase + packet.vertexCount > uvs.length) return;
        if (uyBase + packet.vertexCount > uvs.length) return;
        if (dxBase + packet.vertexCount > deform.length) return;
        if (dyBase + packet.vertexCount > deform.length) return;

        auto mvp = mulMat4(packet.renderMatrix, packet.modelMatrix);

        int baseVertex = cast(int)cpuVertices.length;
        cpuVertices.reserve(cpuVertices.length + packet.vertexCount);
        foreach (i; 0 .. packet.vertexCount) {
            auto px = vertices.data[vxBase + i] + deform.data[dxBase + i] - packet.origin.x;
            auto py = vertices.data[vyBase + i] + deform.data[dyBase + i] - packet.origin.y;

            auto clip = mulMat4Vec4(mvp, px, py, 0, 1);
            float invW = (clip.a == 0 || isNaN(clip.a)) ? 1.0f : 1.0f / clip.a;

            Vertex v;
            v.x = clip.r * invW;
            v.y = clip.g * invW;
            v.u = uvs.data[uxBase + i];
            v.v = uvs.data[uyBase + i];
            cpuVertices ~= v;
        }

        if (packet.indices is null) return;
        auto firstIndex = cast(uint)cpuIndices.length;
        cpuIndices.reserve(cpuIndices.length + packet.indexCount);
        foreach (i; 0 .. packet.indexCount) {
            cpuIndices ~= packet.indices[i];
        }

        if (cpuIndices.length > firstIndex) {
            DrawBatch base;
            base.firstIndex = firstIndex;
            base.indexCount = cast(uint)(cpuIndices.length - firstIndex);
            base.vertexOffset = baseVertex;
            base.pushConstants.tintOpacity = [packet.clampedTint.x, packet.clampedTint.y, packet.clampedTint.z, packet.opacity];
            base.pushConstants.screenEmission = [packet.clampedScreen.x, packet.clampedScreen.y, packet.clampedScreen.z, packet.emissionStrength];
            base.textureCount = min(packet.textureCount, packet.textureHandles.length);
            foreach (i; 0 .. base.textureCount) {
                base.textureHandles[i] = packet.textureHandles[i];
            }
            auto rawBlend = packet.blendingMode;
            if (rawBlend >= 0 && rawBlend < cast(int)BlendMode.Count) {
                base.blendMode = cast(BlendMode)rawBlend;
            } else {
                base.blendMode = BlendMode.Normal;
            }

            auto pushToTarget = (DrawBatch b, size_t targetHandle) {
                b.targetHandle = targetHandle;
                b.clearTarget = clearActiveTarget;
                clearActiveTarget = false;
                batches ~= b;
            };

            if (maskBuildActive) {
                auto b = base;
                b.pipelineKind = PipelineKind.PartStencilWrite;
                b.blendMode = BlendMode.Normal;
                b.clearStencil = pendingMaskStencilClear;
                b.clearStencilValue = pendingMaskStencilClearValue;
                b.stencilReference = pendingMaskWriteReference;
                pendingMaskStencilClear = false;
                maskStencilWritten = true;
                auto t = (activeTargetCount > 0) ? activeTargetHandles[0] : 0;
                pushToTarget(b, t);
            } else if (packet.isMask) {
                auto b = base;
                b.pipelineKind = PipelineKind.PartMask;
                b.pushConstants.screenEmission[3] = packet.maskThreshold;
                auto t = (activeTargetCount > 0) ? activeTargetHandles[0] : 0;
                pushToTarget(b, t);
            } else if (maskContentActive) {
                auto b = base;
                b.pipelineKind = PipelineKind.PartStencilTest;
                b.stencilReference = 1;
                auto t = (activeTargetCount > 0) ? activeTargetHandles[0] : 0;
                pushToTarget(b, t);
            } else {
                auto t0 = (activeTargetCount > 0) ? activeTargetHandles[0] : 0;
                // Use single-pass part shading for stability until full MRT/stencil parity.
                auto b = base;
                b.pipelineKind = PipelineKind.Part;
                pushToTarget(b, t0);
            }
        }
    }

    void drawMaskPacket(ref const(NjgMaskDrawPacket) packet) {
        if (packet.indexCount == 0 || packet.vertexCount == 0) return;
        if (currentSnapshot is null) return;
        auto vertices = currentSnapshot.vertices;
        auto deform = currentSnapshot.deform;
        if (vertices.data is null || deform.data is null) return;
        if (packet.vertexAtlasStride == 0 || packet.deformAtlasStride == 0) return;

        auto vxBase = packet.vertexOffset;
        auto vyBase = packet.vertexOffset + packet.vertexAtlasStride;
        auto dxBase = packet.deformOffset;
        auto dyBase = packet.deformOffset + packet.deformAtlasStride;
        if (vxBase + packet.vertexCount > vertices.length) return;
        if (vyBase + packet.vertexCount > vertices.length) return;
        if (dxBase + packet.vertexCount > deform.length) return;
        if (dyBase + packet.vertexCount > deform.length) return;

        auto mvp = packet.mvp;
        int baseVertex = cast(int)cpuVertices.length;
        foreach (i; 0 .. packet.vertexCount) {
            auto px = vertices.data[vxBase + i] + deform.data[dxBase + i] - packet.origin.x;
            auto py = vertices.data[vyBase + i] + deform.data[dyBase + i] - packet.origin.y;
            auto clip = mulMat4Vec4(mvp, px, py, 0, 1);
            float invW = (clip.a == 0 || isNaN(clip.a)) ? 1.0f : 1.0f / clip.a;
            Vertex v;
            v.x = clip.r * invW;
            v.y = clip.g * invW;
            v.u = 0;
            v.v = 0;
            cpuVertices ~= v;
        }

        if (packet.indices is null) return;
        auto firstIndex = cast(uint)cpuIndices.length;
        foreach (i; 0 .. packet.indexCount) {
            cpuIndices ~= packet.indices[i];
        }

        if (cpuIndices.length > firstIndex) {
            DrawBatch b;
            b.firstIndex = firstIndex;
            b.indexCount = cast(uint)(cpuIndices.length - firstIndex);
            b.vertexOffset = baseVertex;
            if (maskBuildActive) {
                b.pipelineKind = PipelineKind.MaskStencilWrite;
                b.blendMode = BlendMode.Normal;
                b.clearStencil = pendingMaskStencilClear;
                b.clearStencilValue = pendingMaskStencilClearValue;
                b.stencilReference = pendingMaskWriteReference;
                pendingMaskStencilClear = false;
                maskStencilWritten = true;
            } else {
                b.pipelineKind = PipelineKind.Mask;
                b.blendMode = BlendMode.Normal;
                b.stencilReference = 1;
            }
            b.pushConstants.tintOpacity = [1, 1, 1, 1];
            b.pushConstants.screenEmission = [0, 0, 0, 1];
            b.targetHandle = (activeTargetCount > 0) ? activeTargetHandles[0] : 0;
            b.clearTarget = clearActiveTarget;
            clearActiveTarget = false;
            batches ~= b;
        }
    }

private:
    void createInstance() {
        validationEnabled = envEnabled("NJIV_VK_VALIDATION");

        uint extCount = 0;
        enforce(SDL_Vulkan_GetInstanceExtensions(window, &extCount, null) == SDL_TRUE,
            "SDL_Vulkan_GetInstanceExtensions (count) failed");

        const(char)*[] extPtrs;
        extPtrs.length = extCount;
        enforce(SDL_Vulkan_GetInstanceExtensions(window, &extCount, cast(const(char)**)extPtrs.ptr) == SDL_TRUE,
            "SDL_Vulkan_GetInstanceExtensions failed");

        string[] extNames;
        extNames.length = extCount;
        foreach (i; 0 .. extCount) {
            extNames[i] = fromStringz(extPtrs[i]).idup;
        }

        version (OSX) {
            if (!extNames.canFind("VK_KHR_portability_enumeration")) {
                extNames ~= "VK_KHR_portability_enumeration";
            }
        }
        if (validationEnabled && !extNames.canFind("VK_EXT_debug_utils")) {
            extNames ~= "VK_EXT_debug_utils";
        }

        const(char)*[] instExts;
        instExts.length = extNames.length;
        foreach (i, name; extNames) instExts[i] = name.toStringz();

        const(char)*[] instanceLayers;
        if (validationEnabled) {
            uint32_t layerCount = 0;
            auto layerEnumRes = vkEnumerateInstanceLayerProperties(&layerCount, null);
            if (layerEnumRes == VK_SUCCESS && layerCount > 0) {
                VkLayerProperties[] layers;
                layers.length = layerCount;
                layerEnumRes = vkEnumerateInstanceLayerProperties(&layerCount, layers.ptr);
                if (layerEnumRes == VK_SUCCESS) {
                    bool hasValidationLayer = false;
                    foreach (layer; layers) {
                        auto layerName = fromStringz(layer.layerName.ptr);
                        if (layerName == "VK_LAYER_KHRONOS_validation") {
                            hasValidationLayer = true;
                            break;
                        }
                    }
                    if (hasValidationLayer) {
                        instanceLayers ~= "VK_LAYER_KHRONOS_validation".toStringz();
                    } else {
                        validationEnabled = false;
                        writeln("[vulkan] validation requested but VK_LAYER_KHRONOS_validation is unavailable");
                    }
                } else {
                    validationEnabled = false;
                    writeln("[vulkan] validation requested but instance layer enumeration failed");
                }
            } else {
                validationEnabled = false;
                writeln("[vulkan] validation requested but no instance layers are available");
            }
        }

        VkApplicationInfo appInfo;
        appInfo.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
        appInfo.pApplicationName = "nijiv-vulkan".toStringz();
        appInfo.applicationVersion = VK_API_VERSION_1_0;
        appInfo.pEngineName = "nijiv".toStringz();
        appInfo.engineVersion = VK_API_VERSION_1_0;
        appInfo.apiVersion = VK_API_VERSION_1_0;

        VkInstanceCreateInfo createInfo;
        createInfo.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
        createInfo.pApplicationInfo = &appInfo;
        createInfo.enabledExtensionCount = cast(uint32_t)instExts.length;
        createInfo.ppEnabledExtensionNames = instExts.ptr;
        createInfo.enabledLayerCount = cast(uint32_t)instanceLayers.length;
        createInfo.ppEnabledLayerNames = instanceLayers.length > 0 ? instanceLayers.ptr : null;

        version (OSX) {
            createInfo.flags |= VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;
        }

        vkEnforce(vkCreateInstance(&createInfo, null, &instance), "vkCreateInstance failed");
        loadInstanceLevelFunctions(instance);

        if (validationEnabled) {
            VkDebugUtilsMessengerCreateInfoEXT debugInfo;
            debugInfo.sType = VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT;
            debugInfo.messageSeverity =
                VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT |
                VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT;
            debugInfo.messageType =
                VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT |
                VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT |
                VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT;
            debugInfo.pfnUserCallback = &vulkanValidationCallback;
            auto dbgRes = vkCreateDebugUtilsMessengerEXT(instance, &debugInfo, null, &debugMessenger);
            if (dbgRes != VK_SUCCESS) {
                writeln("[vulkan] vkCreateDebugUtilsMessengerEXT failed: ", dbgRes);
                validationEnabled = false;
                debugMessenger = VK_NULL_HANDLE;
            }
        }
    }

    void createSurface() {
        auto ok = SDL_Vulkan_CreateSurface(window, instance, cast(VkSurfaceKHR*)&surface);
        enforce(ok == SDL_TRUE, "SDL_Vulkan_CreateSurface failed: " ~ sdlError());
    }

    void pickPhysicalDevice() {
        uint32_t count = 0;
        vkEnforce(vkEnumeratePhysicalDevices(instance, &count, null), "vkEnumeratePhysicalDevices count failed");
        enforce(count > 0, "No Vulkan physical devices found");

        VkPhysicalDevice[] devices;
        devices.length = count;
        vkEnforce(vkEnumeratePhysicalDevices(instance, &count, devices.ptr), "vkEnumeratePhysicalDevices failed");

        foreach (dev; devices) {
            uint32_t qCount = 0;
            vkGetPhysicalDeviceQueueFamilyProperties(dev, &qCount, null);
            if (qCount == 0) continue;

            VkQueueFamilyProperties[] qProps;
            qProps.length = qCount;
            vkGetPhysicalDeviceQueueFamilyProperties(dev, &qCount, qProps.ptr);

            uint g = uint.max;
            uint p = uint.max;
            foreach (i; 0 .. qCount) {
                if ((qProps[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) != 0) {
                    g = i;
                }
                VkBool32 presentSupport = VK_FALSE;
                vkGetPhysicalDeviceSurfaceSupportKHR(dev, i, surface, &presentSupport);
                if (presentSupport == VK_TRUE) {
                    p = i;
                }
            }

            if (g != uint.max && p != uint.max) {
                physicalDevice = dev;
                graphicsQueueFamily = g;
                presentQueueFamily = p;
                break;
            }
        }

        enforce(physicalDevice != VK_NULL_HANDLE, "No Vulkan device with graphics+present queue found");
    }

    void createLogicalDevice() {
        float priority = 1.0f;

        VkDeviceQueueCreateInfo[] queueInfos;
        if (graphicsQueueFamily == presentQueueFamily) {
            queueInfos.length = 1;
            queueInfos[0].sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
            queueInfos[0].queueFamilyIndex = graphicsQueueFamily;
            queueInfos[0].queueCount = 1;
            queueInfos[0].pQueuePriorities = &priority;
        } else {
            queueInfos.length = 2;
            queueInfos[0].sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
            queueInfos[0].queueFamilyIndex = graphicsQueueFamily;
            queueInfos[0].queueCount = 1;
            queueInfos[0].pQueuePriorities = &priority;

            queueInfos[1].sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
            queueInfos[1].queueFamilyIndex = presentQueueFamily;
            queueInfos[1].queueCount = 1;
            queueInfos[1].pQueuePriorities = &priority;
        }

        uint32_t devExtCount = 0;
        vkEnforce(vkEnumerateDeviceExtensionProperties(physicalDevice, null, &devExtCount, null),
            "vkEnumerateDeviceExtensionProperties count failed");
        VkExtensionProperties[] availableExts;
        availableExts.length = devExtCount;
        if (devExtCount > 0) {
            vkEnforce(vkEnumerateDeviceExtensionProperties(physicalDevice, null, &devExtCount, availableExts.ptr),
                "vkEnumerateDeviceExtensionProperties failed");
        }
        auto hasDevExt = (string name) {
            foreach (e; availableExts) {
                if (fromStringz(e.extensionName.ptr) == name) return true;
            }
            return false;
        };

        string[] devExtNames;
        devExtNames ~= "VK_KHR_swapchain";
        version (OSX) {
            devExtNames ~= "VK_KHR_portability_subset";
        }
        advancedBlendSupported = hasDevExt("VK_EXT_blend_operation_advanced");
        if (advancedBlendSupported) {
            devExtNames ~= "VK_EXT_blend_operation_advanced";
        }

        const(char)*[] devExts;
        devExts.length = devExtNames.length;
        foreach (i, ext; devExtNames) devExts[i] = ext.toStringz();

        VkPhysicalDeviceFeatures features;

        VkDeviceCreateInfo createInfo;
        createInfo.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
        createInfo.queueCreateInfoCount = cast(uint32_t)queueInfos.length;
        createInfo.pQueueCreateInfos = queueInfos.ptr;
        createInfo.enabledExtensionCount = cast(uint32_t)devExts.length;
        createInfo.ppEnabledExtensionNames = devExts.ptr;
        createInfo.pEnabledFeatures = &features;

        vkEnforce(vkCreateDevice(physicalDevice, &createInfo, null, &device), "vkCreateDevice failed");
        loadDeviceLevelFunctions(device);
        vkGetDeviceQueue(device, graphicsQueueFamily, 0, &graphicsQueue);
        vkGetDeviceQueue(device, presentQueueFamily, 0, &presentQueue);
    }

    void createCommandPool() {
        VkCommandPoolCreateInfo poolInfo;
        poolInfo.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
        poolInfo.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
        poolInfo.queueFamilyIndex = graphicsQueueFamily;
        vkEnforce(vkCreateCommandPool(device, &poolInfo, null, &commandPool), "vkCreateCommandPool failed");
    }

    void createSyncObjects() {
        VkSemaphoreCreateInfo semInfo;
        semInfo.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;

        VkFenceCreateInfo fenceInfo;
        fenceInfo.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
        fenceInfo.flags = VK_FENCE_CREATE_SIGNALED_BIT;

        foreach (i; 0 .. MaxFramesInFlight) {
            vkEnforce(vkCreateSemaphore(device, &semInfo, null, &imageAvailable[i]), "vkCreateSemaphore imageAvailable failed");
            vkEnforce(vkCreateFence(device, &fenceInfo, null, &inFlight[i]), "vkCreateFence failed");
        }
    }

    void createSwapchainSyncObjects() {
        VkSemaphoreCreateInfo semInfo;
        semInfo.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;

        renderFinishedByImage.length = swapchainImages.length;
        foreach (i; 0 .. renderFinishedByImage.length) {
            vkEnforce(vkCreateSemaphore(device, &semInfo, null, &renderFinishedByImage[i]),
                "vkCreateSemaphore renderFinishedByImage failed");
        }

        inFlightByImage.length = swapchainImages.length;
        foreach (i; 0 .. inFlightByImage.length) {
            inFlightByImage[i] = VK_NULL_HANDLE;
        }
    }

    void recreateSwapchain() {
        vkDeviceWaitIdle(device);
        destroySwapchainResources();

        VkSurfaceCapabilitiesKHR caps;
        vkEnforce(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physicalDevice, surface, &caps),
            "vkGetPhysicalDeviceSurfaceCapabilitiesKHR failed");

        uint32_t formatCount = 0;
        vkEnforce(vkGetPhysicalDeviceSurfaceFormatsKHR(physicalDevice, surface, &formatCount, null),
            "vkGetPhysicalDeviceSurfaceFormatsKHR count failed");
        enforce(formatCount > 0, "No Vulkan surface formats available");

        VkSurfaceFormatKHR[] formats;
        formats.length = formatCount;
        vkEnforce(vkGetPhysicalDeviceSurfaceFormatsKHR(physicalDevice, surface, &formatCount, formats.ptr),
            "vkGetPhysicalDeviceSurfaceFormatsKHR failed");

        VkSurfaceFormatKHR chosen = formats[0];
        VkFormat[3] preferredFormats = [
            VK_FORMAT_B8G8R8A8_UNORM,
            VK_FORMAT_R8G8B8A8_UNORM,
            VK_FORMAT_B8G8R8A8_SRGB
        ];
        bool foundPreferred = false;
        foreach (fmt; preferredFormats) {
            foreach (f; formats) {
                if (f.format == fmt &&
                    f.colorSpace == VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) {
                    chosen = f;
                    foundPreferred = true;
                    break;
                }
            }
            if (foundPreferred) break;
        }
        swapchainFormat = chosen.format;

        // Keep behavior aligned with OpenGL backend: always present on vblank.
        VkPresentModeKHR presentMode = VK_PRESENT_MODE_FIFO_KHR;

        if (caps.currentExtent.width != uint.max) {
            swapchainExtent = caps.currentExtent;
        } else {
            int dw = 0;
            int dh = 0;
            SDL_Vulkan_GetDrawableSize(window, &dw, &dh);
            swapchainExtent.width = cast(uint32_t)dw;
            swapchainExtent.height = cast(uint32_t)dh;
            if (swapchainExtent.width < caps.minImageExtent.width) swapchainExtent.width = caps.minImageExtent.width;
            if (swapchainExtent.width > caps.maxImageExtent.width) swapchainExtent.width = caps.maxImageExtent.width;
            if (swapchainExtent.height < caps.minImageExtent.height) swapchainExtent.height = caps.minImageExtent.height;
            if (swapchainExtent.height > caps.maxImageExtent.height) swapchainExtent.height = caps.maxImageExtent.height;
        }

        uint32_t imageCount = caps.minImageCount + 1;
        if (caps.maxImageCount > 0 && imageCount > caps.maxImageCount) {
            imageCount = caps.maxImageCount;
        }

        uint32_t[2] queueFamilies = [graphicsQueueFamily, presentQueueFamily];

        VkSwapchainCreateInfoKHR scInfo;
        scInfo.sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR;
        scInfo.surface = surface;
        scInfo.minImageCount = imageCount;
        scInfo.imageFormat = chosen.format;
        scInfo.imageColorSpace = chosen.colorSpace;
        scInfo.imageExtent = swapchainExtent;
        scInfo.imageArrayLayers = 1;
        scInfo.imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
        if (graphicsQueueFamily != presentQueueFamily) {
            scInfo.imageSharingMode = VK_SHARING_MODE_CONCURRENT;
            scInfo.queueFamilyIndexCount = 2;
            scInfo.pQueueFamilyIndices = queueFamilies.ptr;
        } else {
            scInfo.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE;
        }
        scInfo.preTransform = caps.currentTransform;
        scInfo.compositeAlpha = chooseCompositeAlpha(caps.supportedCompositeAlpha);
        writeln("[vulkan] supportedCompositeAlpha=", cast(uint)caps.supportedCompositeAlpha,
            " chosen=", cast(uint)scInfo.compositeAlpha);
        scInfo.presentMode = presentMode;
        scInfo.clipped = VK_TRUE;
        scInfo.oldSwapchain = VK_NULL_HANDLE;

        vkEnforce(vkCreateSwapchainKHR(device, &scInfo, null, &swapchain), "vkCreateSwapchainKHR failed");

        uint32_t scImageCount = 0;
        vkEnforce(vkGetSwapchainImagesKHR(device, swapchain, &scImageCount, null), "vkGetSwapchainImagesKHR count failed");
        swapchainImages.length = scImageCount;
        vkEnforce(vkGetSwapchainImagesKHR(device, swapchain, &scImageCount, swapchainImages.ptr), "vkGetSwapchainImagesKHR failed");
        swapchainImageInitialized.length = scImageCount;
        foreach (i; 0 .. swapchainImageInitialized.length) {
            swapchainImageInitialized[i] = false;
        }

        createSwapchainSyncObjects();
        createSwapchainImageViews();
        createSwapchainDepthResources();
        createRenderPasses();
        createPipeline();
        createFramebuffers();
        allocateCommandBuffers();
    }

    void destroySwapchainResources() {
        foreach (fb; framebuffers) {
            if (fb != VK_NULL_HANDLE) vkDestroyFramebuffer(device, fb, null);
        }
        framebuffers.length = 0;

        foreach (sem; renderFinishedByImage) {
            if (sem != VK_NULL_HANDLE) vkDestroySemaphore(device, sem, null);
        }
        renderFinishedByImage.length = 0;
        inFlightByImage.length = 0;

        foreach (k; 0 .. pipelines.length) {
            foreach (m; 0 .. pipelines[k].length) {
                if (pipelines[k][m] != VK_NULL_HANDLE) vkDestroyPipeline(device, pipelines[k][m], null);
                pipelines[k][m] = VK_NULL_HANDLE;
                if (offscreenPipelines[k][m] != VK_NULL_HANDLE) vkDestroyPipeline(device, offscreenPipelines[k][m], null);
                offscreenPipelines[k][m] = VK_NULL_HANDLE;
            }
        }
        if (pipelineLayout != VK_NULL_HANDLE) vkDestroyPipelineLayout(device, pipelineLayout, null);
        foreach (pool; descriptorPools) {
            if (pool != VK_NULL_HANDLE) vkDestroyDescriptorPool(device, pool, null);
        }
        if (descriptorSetLayout != VK_NULL_HANDLE) vkDestroyDescriptorSetLayout(device, descriptorSetLayout, null);
        if (renderPass != VK_NULL_HANDLE) vkDestroyRenderPass(device, renderPass, null);
        if (offscreenRenderPass != VK_NULL_HANDLE) vkDestroyRenderPass(device, offscreenRenderPass, null);
        pipelineLayout = VK_NULL_HANDLE;
        descriptorPools.length = 0;
        activeDescriptorPool = VK_NULL_HANDLE;
        descriptorSetLayout = VK_NULL_HANDLE;
        renderPass = VK_NULL_HANDLE;
        offscreenRenderPass = VK_NULL_HANDLE;

        foreach (iv; swapchainImageViews) {
            if (iv != VK_NULL_HANDLE) vkDestroyImageView(device, iv, null);
        }
        swapchainImageViews.length = 0;

        foreach (i, iv; swapchainDepthImageViews) {
            if (iv != VK_NULL_HANDLE) vkDestroyImageView(device, iv, null);
            if (i < swapchainDepthImages.length && swapchainDepthImages[i] != VK_NULL_HANDLE) {
                vkDestroyImage(device, swapchainDepthImages[i], null);
            }
            if (i < swapchainDepthMemories.length && swapchainDepthMemories[i] != VK_NULL_HANDLE) {
                vkFreeMemory(device, swapchainDepthMemories[i], null);
            }
        }
        swapchainDepthImageViews.length = 0;
        swapchainDepthImages.length = 0;
        swapchainDepthMemories.length = 0;
        swapchainImageInitialized.length = 0;
        swapchainImages.length = 0;

        if (swapchain != VK_NULL_HANDLE) {
            vkDestroySwapchainKHR(device, swapchain, null);
            swapchain = VK_NULL_HANDLE;
        }
    }

    void createSwapchainImageViews() {
        swapchainImageViews.length = swapchainImages.length;
        foreach (i, image; swapchainImages) {
            VkImageViewCreateInfo info;
            info.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
            info.image = image;
            info.viewType = VK_IMAGE_VIEW_TYPE_2D;
            info.format = swapchainFormat;
            info.components.r = VK_COMPONENT_SWIZZLE_IDENTITY;
            info.components.g = VK_COMPONENT_SWIZZLE_IDENTITY;
            info.components.b = VK_COMPONENT_SWIZZLE_IDENTITY;
            info.components.a = VK_COMPONENT_SWIZZLE_IDENTITY;
            info.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
            info.subresourceRange.baseMipLevel = 0;
            info.subresourceRange.levelCount = 1;
            info.subresourceRange.baseArrayLayer = 0;
            info.subresourceRange.layerCount = 1;
            vkEnforce(vkCreateImageView(device, &info, null, &swapchainImageViews[i]), "vkCreateImageView failed");
        }
    }

    void createSwapchainDepthResources() {
        if (depthStencilFormat == VK_FORMAT_UNDEFINED) {
            depthStencilFormat = findSupportedFormat(
                physicalDevice,
                [
                    VK_FORMAT_D32_SFLOAT_S8_UINT,
                    VK_FORMAT_D24_UNORM_S8_UINT,
                    VK_FORMAT_D16_UNORM_S8_UINT,
                ],
                VK_IMAGE_TILING_OPTIMAL,
                VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT
            );
        }

        swapchainDepthImages.length = swapchainImages.length;
        swapchainDepthMemories.length = swapchainImages.length;
        swapchainDepthImageViews.length = swapchainImages.length;
        foreach (i; 0 .. swapchainImages.length) {
            createImage2D(
                swapchainExtent.width,
                swapchainExtent.height,
                depthStencilFormat,
                VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT,
                VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
                swapchainDepthImages[i],
                swapchainDepthMemories[i]
            );
            swapchainDepthImageViews[i] = createImageView(
                swapchainDepthImages[i],
                depthStencilFormat,
                VK_IMAGE_ASPECT_DEPTH_BIT | VK_IMAGE_ASPECT_STENCIL_BIT
            );
        }
    }

    void createRenderPasses() {
        VkAttachmentDescription color;
        color.format = swapchainFormat;
        color.samples = VK_SAMPLE_COUNT_1_BIT;
        color.loadOp = VK_ATTACHMENT_LOAD_OP_LOAD;
        color.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
        color.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
        color.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
        color.initialLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
        color.finalLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;

        VkAttachmentReference colorRef;
        colorRef.attachment = 0;
        colorRef.layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;

        VkAttachmentDescription ds;
        ds.format = depthStencilFormat;
        ds.samples = VK_SAMPLE_COUNT_1_BIT;
        ds.loadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
        ds.storeOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
        // Keep stencil across root render passes in the same frame.
        ds.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_LOAD;
        ds.stencilStoreOp = VK_ATTACHMENT_STORE_OP_STORE;
        ds.initialLayout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;
        ds.finalLayout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;

        VkAttachmentReference dsRef;
        dsRef.attachment = 1;
        dsRef.layout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;

        VkSubpassDescription subpass;
        subpass.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
        subpass.colorAttachmentCount = 1;
        subpass.pColorAttachments = &colorRef;
        subpass.pDepthStencilAttachment = &dsRef;

        VkSubpassDependency dep;
        dep.srcSubpass = VK_SUBPASS_EXTERNAL;
        dep.dstSubpass = 0;
        dep.srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        dep.dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        dep.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;

        VkAttachmentDescription[2] attachments = [color, ds];

        VkRenderPassCreateInfo info;
        info.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
        info.attachmentCount = cast(uint32_t)attachments.length;
        info.pAttachments = attachments.ptr;
        info.subpassCount = 1;
        info.pSubpasses = &subpass;
        info.dependencyCount = 1;
        info.pDependencies = &dep;

        vkEnforce(vkCreateRenderPass(device, &info, null, &renderPass), "vkCreateRenderPass(swapchain) failed");

        VkAttachmentDescription offColor = attachments[0];
        offColor.format = VK_FORMAT_R8G8B8A8_UNORM;
        offColor.initialLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
        offColor.finalLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
        VkSubpassDescription offSubpass;
        offSubpass.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
        offSubpass.colorAttachmentCount = 1;
        offSubpass.pColorAttachments = &colorRef;
        VkRenderPassCreateInfo offInfo;
        offInfo.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
        offInfo.attachmentCount = 1;
        offInfo.pAttachments = &offColor;
        offInfo.subpassCount = 1;
        offInfo.pSubpasses = &offSubpass;
        offInfo.dependencyCount = 1;
        offInfo.pDependencies = &dep;
        vkEnforce(vkCreateRenderPass(device, &offInfo, null, &offscreenRenderPass), "vkCreateRenderPass(offscreen) failed");
    }

    void createPipeline() {
        createDescriptorResources();

        VkPushConstantRange pushRange;
        pushRange.stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
        pushRange.offset = 0;
        pushRange.size = PushConstants.sizeof;

        VkPipelineLayoutCreateInfo layoutInfo;
        layoutInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        layoutInfo.setLayoutCount = 1;
        layoutInfo.pSetLayouts = &descriptorSetLayout;
        layoutInfo.pushConstantRangeCount = 1;
        layoutInfo.pPushConstantRanges = &pushRange;
        vkEnforce(vkCreatePipelineLayout(device, &layoutInfo, null, &pipelineLayout), "vkCreatePipelineLayout failed");

        foreach (modeRaw; 0 .. cast(size_t)BlendMode.Count) {
            auto mode = cast(BlendMode)modeRaw;
            pipelines[cast(size_t)PipelineKind.Part][modeRaw] = createSinglePipeline(PipelineKind.Part, mode, renderPass);
            pipelines[cast(size_t)PipelineKind.PartStage1][modeRaw] = createSinglePipeline(PipelineKind.PartStage1, mode, renderPass);
            pipelines[cast(size_t)PipelineKind.PartStage2][modeRaw] = createSinglePipeline(PipelineKind.PartStage2, mode, renderPass);
            pipelines[cast(size_t)PipelineKind.PartMask][modeRaw] = createSinglePipeline(PipelineKind.PartMask, mode, renderPass);
            pipelines[cast(size_t)PipelineKind.Mask][modeRaw] = createSinglePipeline(PipelineKind.Mask, mode, renderPass);
            pipelines[cast(size_t)PipelineKind.PartStencilTest][modeRaw] = createSinglePipeline(PipelineKind.PartStencilTest, mode, renderPass);
            pipelines[cast(size_t)PipelineKind.PartStencilWrite][modeRaw] = createSinglePipeline(PipelineKind.PartStencilWrite, mode, renderPass);
            pipelines[cast(size_t)PipelineKind.PartMaskStencilWrite][modeRaw] = createSinglePipeline(PipelineKind.PartMaskStencilWrite, mode, renderPass);
            pipelines[cast(size_t)PipelineKind.MaskStencilWrite][modeRaw] = createSinglePipeline(PipelineKind.MaskStencilWrite, mode, renderPass);

            offscreenPipelines[cast(size_t)PipelineKind.Part][modeRaw] = createSinglePipeline(PipelineKind.Part, mode, offscreenRenderPass);
            offscreenPipelines[cast(size_t)PipelineKind.PartStage1][modeRaw] = createSinglePipeline(PipelineKind.PartStage1, mode, offscreenRenderPass);
            offscreenPipelines[cast(size_t)PipelineKind.PartStage2][modeRaw] = createSinglePipeline(PipelineKind.PartStage2, mode, offscreenRenderPass);
            offscreenPipelines[cast(size_t)PipelineKind.PartMask][modeRaw] = createSinglePipeline(PipelineKind.PartMask, mode, offscreenRenderPass);
            offscreenPipelines[cast(size_t)PipelineKind.Mask][modeRaw] = createSinglePipeline(PipelineKind.Mask, mode, offscreenRenderPass);
            offscreenPipelines[cast(size_t)PipelineKind.PartStencilTest][modeRaw] = VK_NULL_HANDLE;
            offscreenPipelines[cast(size_t)PipelineKind.PartStencilWrite][modeRaw] = VK_NULL_HANDLE;
            offscreenPipelines[cast(size_t)PipelineKind.PartMaskStencilWrite][modeRaw] = VK_NULL_HANDLE;
            offscreenPipelines[cast(size_t)PipelineKind.MaskStencilWrite][modeRaw] = VK_NULL_HANDLE;
        }
        createFallbackTextures();
    }

    const(ubyte)[] vertexShaderCode(PipelineKind kind) {
        final switch (kind) {
            case PipelineKind.Mask:
                return cast(const(ubyte)[])import("vulkan/shaders/mask.vert.spv");
            case PipelineKind.Part:
            case PipelineKind.PartStage1:
            case PipelineKind.PartStage2:
            case PipelineKind.PartMask:
            case PipelineKind.PartStencilTest:
            case PipelineKind.PartStencilWrite:
            case PipelineKind.PartMaskStencilWrite:
                return cast(const(ubyte)[])import("vulkan/shaders/part.vert.spv");
            case PipelineKind.MaskStencilWrite:
            case PipelineKind.Count:
                return cast(const(ubyte)[])import("vulkan/shaders/part.vert.spv");
        }
    }

    const(ubyte)[] fragmentShaderCode(PipelineKind kind) {
        final switch (kind) {
            case PipelineKind.Part:
                return cast(const(ubyte)[])import("vulkan/shaders/part.frag.spv");
            case PipelineKind.PartStage1:
                return cast(const(ubyte)[])import("vulkan/shaders/part_stage1.frag.spv");
            case PipelineKind.PartStage2:
                return cast(const(ubyte)[])import("vulkan/shaders/part_stage2.frag.spv");
            case PipelineKind.PartMask:
                return cast(const(ubyte)[])import("vulkan/shaders/part_mask.frag.spv");
            case PipelineKind.Mask:
                return cast(const(ubyte)[])import("vulkan/shaders/mask.frag.spv");
            case PipelineKind.PartStencilTest:
            case PipelineKind.PartStencilWrite:
                return cast(const(ubyte)[])import("vulkan/shaders/part.frag.spv");
            case PipelineKind.PartMaskStencilWrite:
                return cast(const(ubyte)[])import("vulkan/shaders/part_mask.frag.spv");
            case PipelineKind.MaskStencilWrite:
                return cast(const(ubyte)[])import("vulkan/shaders/mask.frag.spv");
            case PipelineKind.Count:
                return cast(const(ubyte)[])import("vulkan/shaders/part.frag.spv");
        }
    }

    VkPipeline createSinglePipeline(PipelineKind kind, BlendMode blendMode, VkRenderPass pass) {
        auto vertSpv = vertexShaderCode(kind);
        auto fragSpv = fragmentShaderCode(kind);

        VkShaderModule vertModule = createShaderModule(vertSpv);
        VkShaderModule fragModule = createShaderModule(fragSpv);
        scope (exit) {
            if (vertModule != VK_NULL_HANDLE) vkDestroyShaderModule(device, vertModule, null);
            if (fragModule != VK_NULL_HANDLE) vkDestroyShaderModule(device, fragModule, null);
        }

        VkPipelineShaderStageCreateInfo[2] stages;
        stages[0].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT;
        stages[0].module_ = vertModule;
        stages[0].pName = "main".toStringz();

        stages[1].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT;
        stages[1].module_ = fragModule;
        stages[1].pName = "main".toStringz();

        VkVertexInputBindingDescription binding;
        binding.binding = 0;
        binding.stride = Vertex.sizeof;
        binding.inputRate = VK_VERTEX_INPUT_RATE_VERTEX;

        VkVertexInputAttributeDescription[2] attrs;
        attrs[0].location = 0;
        attrs[0].binding = 0;
        attrs[0].format = VK_FORMAT_R32G32_SFLOAT;
        attrs[0].offset = 0;
        attrs[1].location = 1;
        attrs[1].binding = 0;
        attrs[1].format = VK_FORMAT_R32G32_SFLOAT;
        attrs[1].offset = 2 * float.sizeof;

        VkPipelineVertexInputStateCreateInfo vertexInput;
        vertexInput.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
        vertexInput.vertexBindingDescriptionCount = 1;
        vertexInput.pVertexBindingDescriptions = &binding;
        vertexInput.vertexAttributeDescriptionCount = attrs.length;
        vertexInput.pVertexAttributeDescriptions = attrs.ptr;

        VkPipelineInputAssemblyStateCreateInfo ia;
        ia.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
        ia.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;

        VkViewport viewport;
        viewport.x = 0;
        viewport.y = 0;
        viewport.width = 1;
        viewport.height = 1;
        viewport.minDepth = 0;
        viewport.maxDepth = 1;

        VkRect2D scissor;
        scissor.offset.x = 0;
        scissor.offset.y = 0;
        scissor.extent.width = 1;
        scissor.extent.height = 1;

        VkPipelineViewportStateCreateInfo viewportState;
        viewportState.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
        viewportState.viewportCount = 1;
        viewportState.pViewports = &viewport;
        viewportState.scissorCount = 1;
        viewportState.pScissors = &scissor;

        VkDynamicState[3] dynamicStates = [
            VK_DYNAMIC_STATE_VIEWPORT,
            VK_DYNAMIC_STATE_SCISSOR,
            VK_DYNAMIC_STATE_STENCIL_REFERENCE
        ];
        VkPipelineDynamicStateCreateInfo dynamicInfo;
        dynamicInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
        dynamicInfo.dynamicStateCount = cast(uint32_t)dynamicStates.length;
        dynamicInfo.pDynamicStates = dynamicStates.ptr;

        VkPipelineRasterizationStateCreateInfo raster;
        raster.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
        raster.depthClampEnable = VK_FALSE;
        raster.rasterizerDiscardEnable = VK_FALSE;
        raster.polygonMode = VK_POLYGON_MODE_FILL;
        raster.cullMode = VK_CULL_MODE_NONE;
        raster.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE;
        raster.depthBiasEnable = VK_FALSE;
        raster.depthBiasConstantFactor = 0;
        raster.depthBiasClamp = 0;
        raster.depthBiasSlopeFactor = 0;
        raster.lineWidth = 1;

        VkPipelineMultisampleStateCreateInfo ms;
        ms.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
        ms.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;

        VkPipelineColorBlendAttachmentState blendAtt = buildBlendAttachment(blendMode);
        bool stencilWriteKind = kind == PipelineKind.PartStencilWrite ||
                                kind == PipelineKind.PartMaskStencilWrite ||
                                kind == PipelineKind.MaskStencilWrite;
        bool useAdvancedEquation = advancedBlendSupported && isAdvancedEquationMode(blendMode);
        if (useAdvancedEquation) {
            auto advOp = advancedBlendOpFor(blendMode);
            blendAtt.colorBlendOp = advOp;
            blendAtt.alphaBlendOp = advOp;
            blendAtt.srcColorBlendFactor = VK_BLEND_FACTOR_ONE;
            blendAtt.dstColorBlendFactor = VK_BLEND_FACTOR_ONE;
            blendAtt.srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE;
            blendAtt.dstAlphaBlendFactor = VK_BLEND_FACTOR_ONE;
        }
        blendAtt.colorWriteMask = stencilWriteKind
            ? 0
            : (VK_COLOR_COMPONENT_R_BIT |
               VK_COLOR_COMPONENT_G_BIT |
               VK_COLOR_COMPONENT_B_BIT |
               VK_COLOR_COMPONENT_A_BIT);

        VkPipelineColorBlendAdvancedStateCreateInfoEXT advancedBlendInfo;
        if (useAdvancedEquation) {
            advancedBlendInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_ADVANCED_STATE_CREATE_INFO_EXT;
            advancedBlendInfo.srcPremultiplied = VK_TRUE;
            advancedBlendInfo.dstPremultiplied = VK_TRUE;
            advancedBlendInfo.blendOverlap = VK_BLEND_OVERLAP_UNCORRELATED_EXT;
        }

        VkPipelineColorBlendStateCreateInfo blend;
        blend.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
        if (useAdvancedEquation) {
            blend.pNext = &advancedBlendInfo;
        }
        blend.attachmentCount = 1;
        blend.pAttachments = &blendAtt;

        VkPipelineDepthStencilStateCreateInfo ds;
        ds.sType = VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO;
        ds.depthTestEnable = VK_FALSE;
        ds.depthWriteEnable = VK_FALSE;
        ds.depthCompareOp = VK_COMPARE_OP_ALWAYS;
        ds.stencilTestEnable = VK_FALSE;
        ds.front.compareMask = 0xFF;
        ds.front.writeMask = 0xFF;
        ds.front.reference = 1;
        ds.back = ds.front;

        bool stencilTestKind = kind == PipelineKind.PartStencilTest;
        if (stencilWriteKind) {
            ds.stencilTestEnable = VK_TRUE;
            ds.front.compareOp = VK_COMPARE_OP_ALWAYS;
            ds.front.passOp = VK_STENCIL_OP_REPLACE;
            ds.front.failOp = VK_STENCIL_OP_KEEP;
            ds.front.depthFailOp = VK_STENCIL_OP_KEEP;
            ds.back = ds.front;
        } else if (stencilTestKind) {
            ds.stencilTestEnable = VK_TRUE;
            ds.front.compareOp = VK_COMPARE_OP_EQUAL;
            ds.front.passOp = VK_STENCIL_OP_KEEP;
            ds.front.failOp = VK_STENCIL_OP_KEEP;
            ds.front.depthFailOp = VK_STENCIL_OP_KEEP;
            ds.front.writeMask = 0;
            ds.back = ds.front;
        }

        VkGraphicsPipelineCreateInfo pipeInfo;
        pipeInfo.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
        pipeInfo.stageCount = cast(uint32_t)stages.length;
        pipeInfo.pStages = stages.ptr;
        pipeInfo.pVertexInputState = &vertexInput;
        pipeInfo.pInputAssemblyState = &ia;
        pipeInfo.pViewportState = &viewportState;
        pipeInfo.pRasterizationState = &raster;
        pipeInfo.pMultisampleState = &ms;
        pipeInfo.pColorBlendState = &blend;
        pipeInfo.pDepthStencilState = &ds;
        pipeInfo.pDynamicState = &dynamicInfo;
        pipeInfo.layout = pipelineLayout;
        pipeInfo.renderPass = pass;
        pipeInfo.subpass = 0;

        VkPipeline outPipeline;
        vkEnforce(vkCreateGraphicsPipelines(device, VK_NULL_HANDLE, 1, &pipeInfo, null, &outPipeline),
            "vkCreateGraphicsPipelines failed");
        return outPipeline;
    }

    VkShaderModule createShaderModule(const(ubyte)[] code) {
        VkShaderModuleCreateInfo info;
        info.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
        info.codeSize = code.length;
        info.pCode = cast(const(uint32_t)*)code.ptr;
        VkShaderModule shaderModule;
        vkEnforce(vkCreateShaderModule(device, &info, null, &shaderModule), "vkCreateShaderModule failed");
        return shaderModule;
    }

    bool isAdvancedEquationMode(BlendMode mode) const {
        final switch (mode) {
            case BlendMode.Multiply:
            case BlendMode.Screen:
            case BlendMode.Overlay:
            case BlendMode.Darken:
            case BlendMode.Lighten:
            case BlendMode.ColorDodge:
            case BlendMode.ColorBurn:
            case BlendMode.HardLight:
            case BlendMode.SoftLight:
            case BlendMode.Difference:
            case BlendMode.Exclusion:
                return true;
            case BlendMode.Normal:
            case BlendMode.LinearDodge:
            case BlendMode.AddGlow:
            case BlendMode.Subtract:
            case BlendMode.Inverse:
            case BlendMode.DestinationIn:
            case BlendMode.ClipToLower:
            case BlendMode.SliceFromLower:
            case BlendMode.Count:
                return false;
        }
    }

    VkBlendOp advancedBlendOpFor(BlendMode mode) const {
        final switch (mode) {
            case BlendMode.Multiply:
                return VK_BLEND_OP_MULTIPLY_EXT;
            case BlendMode.Screen:
                return VK_BLEND_OP_SCREEN_EXT;
            case BlendMode.Overlay:
                return VK_BLEND_OP_OVERLAY_EXT;
            case BlendMode.Darken:
                return VK_BLEND_OP_DARKEN_EXT;
            case BlendMode.Lighten:
                return VK_BLEND_OP_LIGHTEN_EXT;
            case BlendMode.ColorDodge:
                return VK_BLEND_OP_COLORDODGE_EXT;
            case BlendMode.ColorBurn:
                return VK_BLEND_OP_COLORBURN_EXT;
            case BlendMode.HardLight:
                return VK_BLEND_OP_HARDLIGHT_EXT;
            case BlendMode.SoftLight:
                return VK_BLEND_OP_SOFTLIGHT_EXT;
            case BlendMode.Difference:
                return VK_BLEND_OP_DIFFERENCE_EXT;
            case BlendMode.Exclusion:
                return VK_BLEND_OP_EXCLUSION_EXT;
            case BlendMode.Normal:
            case BlendMode.LinearDodge:
            case BlendMode.AddGlow:
            case BlendMode.Subtract:
            case BlendMode.Inverse:
            case BlendMode.DestinationIn:
            case BlendMode.ClipToLower:
            case BlendMode.SliceFromLower:
            case BlendMode.Count:
                return VK_BLEND_OP_ADD;
        }
    }

    VkPipelineColorBlendAttachmentState buildBlendAttachment(BlendMode mode) {
        VkPipelineColorBlendAttachmentState s;
        s.blendEnable = VK_TRUE;
        s.srcColorBlendFactor = VK_BLEND_FACTOR_ONE;
        s.dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
        s.colorBlendOp = VK_BLEND_OP_ADD;
        s.srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE;
        s.dstAlphaBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
        s.alphaBlendOp = VK_BLEND_OP_ADD;

        auto setBlendFunc = (VkBlendFactor src, VkBlendFactor dst) {
            s.srcColorBlendFactor = src;
            s.dstColorBlendFactor = dst;
            s.srcAlphaBlendFactor = src;
            s.dstAlphaBlendFactor = dst;
        };
        auto setBlendFuncSeparate = (VkBlendFactor srcColor,
                                     VkBlendFactor dstColor,
                                     VkBlendFactor srcAlpha,
                                     VkBlendFactor dstAlpha) {
            s.srcColorBlendFactor = srcColor;
            s.dstColorBlendFactor = dstColor;
            s.srcAlphaBlendFactor = srcAlpha;
            s.dstAlphaBlendFactor = dstAlpha;
        };

        final switch (mode) {
            case BlendMode.Normal:
                s.colorBlendOp = VK_BLEND_OP_ADD;
                s.alphaBlendOp = VK_BLEND_OP_ADD;
                setBlendFunc(VK_BLEND_FACTOR_ONE, VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA);
                break;
            case BlendMode.Multiply:
                s.colorBlendOp = VK_BLEND_OP_ADD;
                s.alphaBlendOp = VK_BLEND_OP_ADD;
                setBlendFunc(VK_BLEND_FACTOR_DST_COLOR, VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA);
                break;
            case BlendMode.Screen:
                s.colorBlendOp = VK_BLEND_OP_ADD;
                s.alphaBlendOp = VK_BLEND_OP_ADD;
                setBlendFunc(VK_BLEND_FACTOR_ONE, VK_BLEND_FACTOR_ONE_MINUS_SRC_COLOR);
                break;
            case BlendMode.Overlay:
            case BlendMode.ColorBurn:
            case BlendMode.HardLight:
            case BlendMode.SoftLight:
            case BlendMode.Difference:
                // Legacy fallback path: approximate unsupported equations.
                s.colorBlendOp = VK_BLEND_OP_ADD;
                s.alphaBlendOp = VK_BLEND_OP_ADD;
                setBlendFunc(VK_BLEND_FACTOR_ONE, VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA);
                break;
            case BlendMode.Darken:
                s.colorBlendOp = VK_BLEND_OP_MIN;
                s.alphaBlendOp = VK_BLEND_OP_ADD;
                setBlendFunc(VK_BLEND_FACTOR_ONE, VK_BLEND_FACTOR_ONE);
                break;
            case BlendMode.Lighten:
                s.colorBlendOp = VK_BLEND_OP_MAX;
                s.alphaBlendOp = VK_BLEND_OP_ADD;
                setBlendFunc(VK_BLEND_FACTOR_ONE, VK_BLEND_FACTOR_ONE);
                break;
            case BlendMode.ColorDodge:
                s.colorBlendOp = VK_BLEND_OP_ADD;
                s.alphaBlendOp = VK_BLEND_OP_ADD;
                setBlendFunc(VK_BLEND_FACTOR_DST_COLOR, VK_BLEND_FACTOR_ONE);
                break;
            case BlendMode.LinearDodge:
                s.colorBlendOp = VK_BLEND_OP_ADD;
                s.alphaBlendOp = VK_BLEND_OP_ADD;
                setBlendFuncSeparate(VK_BLEND_FACTOR_ONE,
                                     VK_BLEND_FACTOR_ONE_MINUS_SRC_COLOR,
                                     VK_BLEND_FACTOR_ONE,
                                     VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA);
                break;
            case BlendMode.AddGlow:
                s.colorBlendOp = VK_BLEND_OP_ADD;
                s.alphaBlendOp = VK_BLEND_OP_ADD;
                setBlendFuncSeparate(VK_BLEND_FACTOR_ONE,
                                     VK_BLEND_FACTOR_ONE,
                                     VK_BLEND_FACTOR_ONE,
                                     VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA);
                break;
            case BlendMode.Exclusion:
                s.colorBlendOp = VK_BLEND_OP_ADD;
                s.alphaBlendOp = VK_BLEND_OP_ADD;
                setBlendFuncSeparate(VK_BLEND_FACTOR_ONE_MINUS_DST_COLOR,
                                     VK_BLEND_FACTOR_ONE_MINUS_SRC_COLOR,
                                     VK_BLEND_FACTOR_ONE,
                                     VK_BLEND_FACTOR_ONE);
                break;
            case BlendMode.Subtract:
                s.colorBlendOp = VK_BLEND_OP_REVERSE_SUBTRACT;
                s.alphaBlendOp = VK_BLEND_OP_ADD;
                setBlendFunc(VK_BLEND_FACTOR_ONE_MINUS_DST_COLOR, VK_BLEND_FACTOR_ONE);
                break;
            case BlendMode.Inverse:
                s.colorBlendOp = VK_BLEND_OP_ADD;
                s.alphaBlendOp = VK_BLEND_OP_ADD;
                setBlendFunc(VK_BLEND_FACTOR_ONE_MINUS_DST_COLOR, VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA);
                break;
            case BlendMode.DestinationIn:
                s.colorBlendOp = VK_BLEND_OP_ADD;
                s.alphaBlendOp = VK_BLEND_OP_ADD;
                setBlendFunc(VK_BLEND_FACTOR_ZERO, VK_BLEND_FACTOR_SRC_ALPHA);
                break;
            case BlendMode.ClipToLower:
                s.colorBlendOp = VK_BLEND_OP_ADD;
                s.alphaBlendOp = VK_BLEND_OP_ADD;
                setBlendFunc(VK_BLEND_FACTOR_DST_ALPHA, VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA);
                break;
            case BlendMode.SliceFromLower:
                s.colorBlendOp = VK_BLEND_OP_ADD;
                s.alphaBlendOp = VK_BLEND_OP_ADD;
                setBlendFunc(VK_BLEND_FACTOR_ZERO, VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA);
                break;
            case BlendMode.Count:
                break;
        }
        return s;
    }

    void createDescriptorResources() {
        VkDescriptorSetLayoutBinding[3] bindings;
        foreach (i; 0 .. 3) {
            bindings[i].binding = cast(uint32_t)i;
            bindings[i].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
            bindings[i].descriptorCount = 1;
            bindings[i].stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
        }

        VkDescriptorSetLayoutCreateInfo layoutInfo;
        layoutInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        layoutInfo.bindingCount = cast(uint32_t)bindings.length;
        layoutInfo.pBindings = bindings.ptr;
        vkEnforce(vkCreateDescriptorSetLayout(device, &layoutInfo, null, &descriptorSetLayout),
            "vkCreateDescriptorSetLayout failed");

        VkDescriptorPoolSize poolSize;
        poolSize.type = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        poolSize.descriptorCount = 3 * 8192;

        VkDescriptorPoolCreateInfo poolInfo;
        poolInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
        poolInfo.flags = VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT;
        poolInfo.maxSets = 8192;
        poolInfo.poolSizeCount = 1;
        poolInfo.pPoolSizes = &poolSize;
        descriptorPools.length = MaxFramesInFlight;
        foreach (i; 0 .. MaxFramesInFlight) {
            vkEnforce(vkCreateDescriptorPool(device, &poolInfo, null, &descriptorPools[i]),
                "vkCreateDescriptorPool failed");
        }
        activeDescriptorPool = descriptorPools[0];
    }

    VkCommandBuffer beginSingleTimeCommands() {
        VkCommandBufferAllocateInfo alloc;
        alloc.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        alloc.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        alloc.commandPool = commandPool;
        alloc.commandBufferCount = 1;

        VkCommandBuffer cmd;
        vkEnforce(vkAllocateCommandBuffers(device, &alloc, &cmd), "vkAllocateCommandBuffers(single) failed");

        VkCommandBufferBeginInfo beginInfo;
        beginInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        beginInfo.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        vkEnforce(vkBeginCommandBuffer(cmd, &beginInfo), "vkBeginCommandBuffer(single) failed");
        return cmd;
    }

    void endSingleTimeCommands(VkCommandBuffer cmd) {
        vkEnforce(vkEndCommandBuffer(cmd), "vkEndCommandBuffer(single) failed");
        VkSubmitInfo submit;
        submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submit.commandBufferCount = 1;
        submit.pCommandBuffers = &cmd;
        vkEnforce(vkQueueSubmit(graphicsQueue, 1, &submit, VK_NULL_HANDLE), "vkQueueSubmit(single) failed");
        vkEnforce(vkQueueWaitIdle(graphicsQueue), "vkQueueWaitIdle(single) failed");
        vkFreeCommandBuffers(device, commandPool, 1, &cmd);
    }

    private void fillImageLayoutTransitionBarrier(ref VkImageMemoryBarrier barrier,
                                                  out VkPipelineStageFlags srcStage,
                                                  out VkPipelineStageFlags dstStage,
                                                  VkImage image,
                                                  VkImageLayout oldLayout,
                                                  VkImageLayout newLayout) {
        barrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        barrier.oldLayout = oldLayout;
        barrier.newLayout = newLayout;
        barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        barrier.image = image;
        barrier.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        barrier.subresourceRange.baseMipLevel = 0;
        barrier.subresourceRange.levelCount = 1;
        barrier.subresourceRange.baseArrayLayer = 0;
        barrier.subresourceRange.layerCount = 1;

        if (oldLayout == VK_IMAGE_LAYOUT_UNDEFINED && newLayout == VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL) {
            barrier.srcAccessMask = 0;
            barrier.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
            srcStage = VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT;
            dstStage = VK_PIPELINE_STAGE_TRANSFER_BIT;
        } else if (oldLayout == VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL && newLayout == VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL) {
            barrier.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
            barrier.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
            srcStage = VK_PIPELINE_STAGE_TRANSFER_BIT;
            dstStage = VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
        } else if (oldLayout == VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL && newLayout == VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL) {
            barrier.srcAccessMask = VK_ACCESS_SHADER_READ_BIT;
            barrier.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
            srcStage = VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
            dstStage = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        } else if (oldLayout == VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL && newLayout == VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL) {
            barrier.srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
            barrier.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
            srcStage = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
            dstStage = VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
        } else {
            barrier.srcAccessMask = 0;
            barrier.dstAccessMask = 0;
            srcStage = VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT;
            dstStage = VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT;
        }
    }

    void initializeSwapchainImageLayouts(uint32_t imageIndex) {
        if (imageIndex >= swapchainImages.length || imageIndex >= swapchainDepthImages.length) return;
        auto cmd = beginSingleTimeCommands();

        VkImageMemoryBarrier colorBarrier;
        colorBarrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        colorBarrier.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        colorBarrier.newLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
        colorBarrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        colorBarrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        colorBarrier.image = swapchainImages[imageIndex];
        colorBarrier.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        colorBarrier.subresourceRange.baseMipLevel = 0;
        colorBarrier.subresourceRange.levelCount = 1;
        colorBarrier.subresourceRange.baseArrayLayer = 0;
        colorBarrier.subresourceRange.layerCount = 1;

        VkImageMemoryBarrier depthBarrier;
        depthBarrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        depthBarrier.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        depthBarrier.newLayout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;
        depthBarrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        depthBarrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        depthBarrier.image = swapchainDepthImages[imageIndex];
        depthBarrier.subresourceRange.aspectMask = VK_IMAGE_ASPECT_DEPTH_BIT | VK_IMAGE_ASPECT_STENCIL_BIT;
        depthBarrier.subresourceRange.baseMipLevel = 0;
        depthBarrier.subresourceRange.levelCount = 1;
        depthBarrier.subresourceRange.baseArrayLayer = 0;
        depthBarrier.subresourceRange.layerCount = 1;
        depthBarrier.dstAccessMask = VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_READ_BIT |
                                     VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;

        VkImageMemoryBarrier[2] barriers = [colorBarrier, depthBarrier];
        vkCmdPipelineBarrier(cmd,
                             VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                             VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,
                             0,
                             0, null,
                             0, null,
                             cast(uint32_t)barriers.length, barriers.ptr);
        endSingleTimeCommands(cmd);
    }

    private void recordImageLayoutTransition(VkCommandBuffer cmd,
                                             VkImage image,
                                             VkImageLayout oldLayout,
                                             VkImageLayout newLayout) {
        VkImageMemoryBarrier barrier;
        VkPipelineStageFlags srcStage;
        VkPipelineStageFlags dstStage;
        fillImageLayoutTransitionBarrier(barrier, srcStage, dstStage, image, oldLayout, newLayout);

        vkCmdPipelineBarrier(cmd,
                             srcStage,
                             dstStage,
                             0,
                             0, null,
                             0, null,
                             1, &barrier);
    }

    void transitionImageLayout(VkImage image, VkImageLayout oldLayout, VkImageLayout newLayout) {
        auto cmd = beginSingleTimeCommands();
        recordImageLayoutTransition(cmd, image, oldLayout, newLayout);
        endSingleTimeCommands(cmd);
    }

    void copyBufferToImage(VkBuffer buffer, VkImage image, uint width, uint height) {
        auto cmd = beginSingleTimeCommands();
        VkBufferImageCopy region;
        region.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        region.imageSubresource.mipLevel = 0;
        region.imageSubresource.baseArrayLayer = 0;
        region.imageSubresource.layerCount = 1;
        region.imageExtent.width = width;
        region.imageExtent.height = height;
        region.imageExtent.depth = 1;
        vkCmdCopyBufferToImage(cmd, buffer, image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
        endSingleTimeCommands(cmd);
    }

    ubyte[] toRgbaBytes(const(Texture) tex) {
        auto src = tex.data();
        auto pixelCount = cast(size_t)max(1, tex.width) * cast(size_t)max(1, tex.height);
        ubyte[] rgba;
        rgba.length = pixelCount * 4;
        auto c = max(1, tex.channels);
        foreach (i; 0 .. pixelCount) {
            size_t s = i * cast(size_t)c;
            size_t d = i * 4;
            ubyte r = (s + 0 < src.length) ? src[s + 0] : 255;
            ubyte g = (c > 1 && s + 1 < src.length) ? src[s + 1] : r;
            ubyte b = (c > 2 && s + 2 < src.length) ? src[s + 2] : r;
            ubyte a = (c > 3 && s + 3 < src.length) ? src[s + 3] : 255;
            if (c == 1) {
                g = r;
                b = r;
            }
            rgba[d + 0] = r;
            rgba[d + 1] = g;
            rgba[d + 2] = b;
            rgba[d + 3] = a;
        }
        return rgba;
    }

    void createBuffer(VkDeviceSize size,
                      VkBufferUsageFlags usage,
                      VkMemoryPropertyFlags properties,
                      out VkBuffer buffer,
                      out VkDeviceMemory memory)
    {
        VkBufferCreateInfo binfo;
        binfo.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
        binfo.size = size;
        binfo.usage = usage;
        binfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
        vkEnforce(vkCreateBuffer(device, &binfo, null, &buffer), "vkCreateBuffer(texture staging) failed");

        VkMemoryRequirements req;
        vkGetBufferMemoryRequirements(device, buffer, &req);
        VkMemoryAllocateInfo ainfo;
        ainfo.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        ainfo.allocationSize = req.size;
        ainfo.memoryTypeIndex = findMemoryType(physicalDevice, req.memoryTypeBits, properties);
        vkEnforce(vkAllocateMemory(device, &ainfo, null, &memory), "vkAllocateMemory(texture staging) failed");
        vkEnforce(vkBindBufferMemory(device, buffer, memory, 0), "vkBindBufferMemory(texture staging) failed");
    }

    void createImage2D(uint width, uint height,
                       VkFormat format,
                       VkImageUsageFlags usage,
                       VkMemoryPropertyFlags properties,
                       out VkImage image,
                       out VkDeviceMemory memory)
    {
        VkImageCreateInfo info;
        info.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        info.imageType = VK_IMAGE_TYPE_2D;
        info.extent.width = width;
        info.extent.height = height;
        info.extent.depth = 1;
        info.mipLevels = 1;
        info.arrayLayers = 1;
        info.format = format;
        info.tiling = VK_IMAGE_TILING_OPTIMAL;
        info.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        info.usage = usage;
        info.samples = VK_SAMPLE_COUNT_1_BIT;
        info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
        vkEnforce(vkCreateImage(device, &info, null, &image), "vkCreateImage failed");

        VkMemoryRequirements req;
        vkGetImageMemoryRequirements(device, image, &req);
        VkMemoryAllocateInfo ainfo;
        ainfo.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        ainfo.allocationSize = req.size;
        ainfo.memoryTypeIndex = findMemoryType(physicalDevice, req.memoryTypeBits, properties);
        vkEnforce(vkAllocateMemory(device, &ainfo, null, &memory), "vkAllocateMemory(image) failed");
        vkEnforce(vkBindImageMemory(device, image, memory, 0), "vkBindImageMemory failed");
    }

    VkImageView createImageView(VkImage image,
                                VkFormat format,
                                VkImageAspectFlags aspectMask = VK_IMAGE_ASPECT_COLOR_BIT) {
        VkImageViewCreateInfo info;
        info.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        info.image = image;
        info.viewType = VK_IMAGE_VIEW_TYPE_2D;
        info.format = format;
        info.subresourceRange.aspectMask = aspectMask;
        info.subresourceRange.baseMipLevel = 0;
        info.subresourceRange.levelCount = 1;
        info.subresourceRange.baseArrayLayer = 0;
        info.subresourceRange.layerCount = 1;
        VkImageView view;
        vkEnforce(vkCreateImageView(device, &info, null, &view), "vkCreateImageView(texture) failed");
        return view;
    }

    VkSampler createSampler() {
        VkSamplerCreateInfo info;
        info.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
        info.magFilter = VK_FILTER_LINEAR;
        info.minFilter = VK_FILTER_LINEAR;
        info.addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER;
        info.addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER;
        info.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER;
        info.maxAnisotropy = 1;
        info.anisotropyEnable = VK_FALSE;
        info.borderColor = VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK;
        info.unnormalizedCoordinates = VK_FALSE;
        info.compareEnable = VK_FALSE;
        info.mipmapMode = VK_SAMPLER_MIPMAP_MODE_LINEAR;
        VkSampler sampler;
        vkEnforce(vkCreateSampler(device, &info, null, &sampler), "vkCreateSampler failed");
        return sampler;
    }

    void destroyTextureResource(ref VkTextureResource tex) {
        if (tex.framebuffer != VK_NULL_HANDLE) vkDestroyFramebuffer(device, tex.framebuffer, null);
        if (tex.sampler != VK_NULL_HANDLE) vkDestroySampler(device, tex.sampler, null);
        if (tex.view != VK_NULL_HANDLE) vkDestroyImageView(device, tex.view, null);
        if (tex.image != VK_NULL_HANDLE) vkDestroyImage(device, tex.image, null);
        if (tex.memory != VK_NULL_HANDLE) vkFreeMemory(device, tex.memory, null);
        tex = VkTextureResource.init;
    }

    private void syncBeforeTextureMutation() {
        if (textureMutationSynced) return;
        vkEnforce(vkDeviceWaitIdle(device), "vkDeviceWaitIdle(texture mutation) failed");
        textureMutationSynced = true;
    }

    VkTextureResource uploadTextureDataToGpu(const(Texture) tex) {
        auto rgba = toRgbaBytes(tex);
        auto width = cast(uint32_t)max(1, tex.width);
        auto height = cast(uint32_t)max(1, tex.height);
        auto bytes = cast(VkDeviceSize)rgba.length;

        VkBuffer staging;
        VkDeviceMemory stagingMem;
        createBuffer(bytes,
                     VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                     VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                     staging, stagingMem);
        scope (exit) {
            if (staging != VK_NULL_HANDLE) vkDestroyBuffer(device, staging, null);
            if (stagingMem != VK_NULL_HANDLE) vkFreeMemory(device, stagingMem, null);
        }

        void* mapped = null;
        vkEnforce(vkMapMemory(device, stagingMem, 0, bytes, 0, &mapped), "vkMapMemory(staging texture) failed");
        memcpy(mapped, rgba.ptr, rgba.length);
        vkUnmapMemory(device, stagingMem);

        VkTextureResource texRes;
        texRes.width = tex.width;
        texRes.height = tex.height;
        texRes.channels = tex.channels;
        texRes.renderTarget = tex.renderTarget;
        texRes.revision = tex.revision();

        VkImageUsageFlags usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT;
        if (tex.renderTarget) {
            usage |= VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
        }
        createImage2D(width, height,
                      VK_FORMAT_R8G8B8A8_UNORM,
                      usage,
                      VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
                      texRes.image, texRes.memory);
        texRes.view = createImageView(texRes.image, VK_FORMAT_R8G8B8A8_UNORM);
        texRes.sampler = createSampler();

        transitionImageLayout(texRes.image, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL);
        copyBufferToImage(staging, texRes.image, width, height);
        transitionImageLayout(texRes.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
        return texRes;
    }

    VkFramebuffer getOrCreateOffscreenFramebuffer(ref VkTextureResource texRes) {
        if (texRes.framebuffer != VK_NULL_HANDLE) {
            return texRes.framebuffer;
        }
        VkImageView[1] attachments = [texRes.view];
        VkFramebufferCreateInfo info;
        info.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
        info.renderPass = offscreenRenderPass;
        info.attachmentCount = 1;
        info.pAttachments = attachments.ptr;
        info.width = cast(uint32_t)max(1, texRes.width);
        info.height = cast(uint32_t)max(1, texRes.height);
        info.layers = 1;
        vkEnforce(vkCreateFramebuffer(device, &info, null, &texRes.framebuffer),
            "vkCreateFramebuffer(offscreen texture) failed");
        return texRes.framebuffer;
    }

    void createFallbackTextures() {
        Texture white = new Texture(1, 1, 4, false);
        white.setData([cast(ubyte)255, 255, 255, 255], 4);
        Texture black = new Texture(1, 1, 4, false);
        black.setData([cast(ubyte)0, 0, 0, 255], 4);
        fallbackWhite = uploadTextureDataToGpu(white);
        fallbackBlack = uploadTextureDataToGpu(black);
    }

    VkTextureResource* resolveTextureHandle(size_t handle, bool wantBlackFallback = false) {
        if (handle == 0) {
            return wantBlackFallback ? &fallbackBlack : &fallbackWhite;
        }
        synchronized (gTexturesGuard) {
            if (auto tex = handle in gTextures) {
                if (*tex is null) {
                    return wantBlackFallback ? &fallbackBlack : &fallbackWhite;
                }
                if (auto cached = handle in textureResources) {
                    if (cached.revision == (*tex).revision() &&
                        cached.width == (*tex).width &&
                        cached.height == (*tex).height &&
                        cached.channels == (*tex).channels) {
                        return cached;
                    }
                    syncBeforeTextureMutation();
                    auto old = *cached;
                    destroyTextureResource(old);
                }
                auto uploaded = uploadTextureDataToGpu(*tex);
                textureResources[handle] = uploaded;
                return handle in textureResources;
            }
        }
        return wantBlackFallback ? &fallbackBlack : &fallbackWhite;
    }

    VkTextureResource snapshotTextureHandle(size_t handle, bool wantBlackFallback = false) {
        auto texRes = resolveTextureHandle(handle, wantBlackFallback);
        if (texRes is null) {
            return wantBlackFallback ? fallbackBlack : fallbackWhite;
        }
        return *texRes;
    }

    VkDescriptorSet allocateBatchDescriptorSet(ref const(DrawBatch) batch) {
        if (activeDescriptorPool == VK_NULL_HANDLE) {
            return VK_NULL_HANDLE;
        }
        VkDescriptorSetLayout setLayout = descriptorSetLayout;
        VkDescriptorSetAllocateInfo alloc;
        alloc.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        alloc.descriptorPool = activeDescriptorPool;
        alloc.descriptorSetCount = 1;
        alloc.pSetLayouts = &setLayout;
        VkDescriptorSet set;
        vkEnforce(vkAllocateDescriptorSets(device, &alloc, &set), "vkAllocateDescriptorSets failed");

        VkDescriptorImageInfo[3] infos;
        foreach (i; 0 .. 3) {
            bool blackFallback = (i != 0);
            size_t handle = (i < batch.textureCount) ? batch.textureHandles[i] : 0;
            // Vulkan forbids sampling from an image while simultaneously writing to it
            // as a color attachment in the same subpass.
            if (batch.targetHandle != 0 && handle == batch.targetHandle) {
                handle = 0;
                blackFallback = true;
            }
            auto texRes = snapshotTextureHandle(handle, blackFallback);
            infos[i].imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
            infos[i].imageView = texRes.view;
            infos[i].sampler = texRes.sampler;
        }

        VkWriteDescriptorSet[3] writes;
        foreach (i; 0 .. 3) {
            writes[i].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            writes[i].dstSet = set;
            writes[i].dstBinding = cast(uint32_t)i;
            writes[i].dstArrayElement = 0;
            writes[i].descriptorCount = 1;
            writes[i].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
            writes[i].pImageInfo = &infos[i];
        }
        vkUpdateDescriptorSets(device, cast(uint32_t)writes.length, writes.ptr, 0, null);
        return set;
    }

    void pruneTextureCache() {
        size_t[] stale;
        foreach (h, _res; textureResources) {
            bool alive = false;
            synchronized (gTexturesGuard) {
                alive = (h in gTextures) !is null;
            }
            if (!alive) {
                stale ~= h;
            }
        }
        foreach (h; stale) {
            if (auto res = h in textureResources) {
                syncBeforeTextureMutation();
                auto tmp = *res;
                destroyTextureResource(tmp);
            }
            textureResources.remove(h);
        }
    }

    void createFramebuffers() {
        framebuffers.length = swapchainImageViews.length;
        foreach (i, view; swapchainImageViews) {
            VkImageView[2] attachments = [view, swapchainDepthImageViews[i]];
            VkFramebufferCreateInfo info;
            info.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
            info.renderPass = renderPass;
            info.attachmentCount = cast(uint32_t)attachments.length;
            info.pAttachments = attachments.ptr;
            info.width = swapchainExtent.width;
            info.height = swapchainExtent.height;
            info.layers = 1;
            vkEnforce(vkCreateFramebuffer(device, &info, null, &framebuffers[i]), "vkCreateFramebuffer failed");
        }
    }

    void allocateCommandBuffers() {
        commandBuffers.length = framebuffers.length;
        VkCommandBufferAllocateInfo alloc;
        alloc.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        alloc.commandPool = commandPool;
        alloc.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        alloc.commandBufferCount = cast(uint32_t)commandBuffers.length;
        vkEnforce(vkAllocateCommandBuffers(device, &alloc, commandBuffers.ptr), "vkAllocateCommandBuffers failed");
    }

    void ensureBufferCapacity(size_t vertexBytes, size_t indexBytes) {
        if (vertexBytes > vertexCapacity) {
            recreateHostVisibleBuffer(vertexBuffer, vertexMemory, vertexCapacity,
                VK_BUFFER_USAGE_VERTEX_BUFFER_BIT, vertexBytes);
        }
        if (indexBytes > indexCapacity) {
            recreateHostVisibleBuffer(indexBuffer, indexMemory, indexCapacity,
                VK_BUFFER_USAGE_INDEX_BUFFER_BIT, indexBytes);
        }
    }

    void recreateHostVisibleBuffer(ref VkBuffer buffer,
                                   ref VkDeviceMemory memory,
                                   ref size_t capacity,
                                   VkBufferUsageFlags usage,
                                   size_t minBytes)
    {
        if (buffer != VK_NULL_HANDLE) vkDestroyBuffer(device, buffer, null);
        if (memory != VK_NULL_HANDLE) vkFreeMemory(device, memory, null);

        capacity = 1;
        while (capacity < minBytes) capacity <<= 1;

        VkBufferCreateInfo binfo;
        binfo.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
        binfo.size = capacity;
        binfo.usage = usage;
        binfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
        vkEnforce(vkCreateBuffer(device, &binfo, null, &buffer), "vkCreateBuffer failed");

        VkMemoryRequirements req;
        vkGetBufferMemoryRequirements(device, buffer, &req);

        VkMemoryAllocateInfo ainfo;
        ainfo.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        ainfo.allocationSize = req.size;
        ainfo.memoryTypeIndex = findMemoryType(physicalDevice,
            req.memoryTypeBits,
            VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        vkEnforce(vkAllocateMemory(device, &ainfo, null, &memory), "vkAllocateMemory failed");
        vkEnforce(vkBindBufferMemory(device, buffer, memory, 0), "vkBindBufferMemory failed");
    }

    void uploadGeometry() {
        auto vBytes = cpuVertices.length * Vertex.sizeof;
        auto iBytes = cpuIndices.length * ushort.sizeof;
        if (vBytes == 0 || iBytes == 0) return;

        ensureBufferCapacity(vBytes, iBytes);

        void* mapped = null;
        vkEnforce(vkMapMemory(device, vertexMemory, 0, vBytes, 0, &mapped), "vkMapMemory vertex failed");
        memcpy(mapped, cpuVertices.ptr, vBytes);
        vkUnmapMemory(device, vertexMemory);

        mapped = null;
        vkEnforce(vkMapMemory(device, indexMemory, 0, iBytes, 0, &mapped), "vkMapMemory index failed");
        memcpy(mapped, cpuIndices.ptr, iBytes);
        vkUnmapMemory(device, indexMemory);
    }

    void recordCommandBuffer(VkCommandBuffer cmd, uint imageIndex) {
        VkCommandBufferBeginInfo beginInfo;
        beginInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        vkEnforce(vkBeginCommandBuffer(cmd, &beginInfo), "vkBeginCommandBuffer failed");

        auto renderBatchRange = (size_t start, size_t stop,
                                 VkRenderPass pass,
                                 VkFramebuffer framebuffer,
                                 VkExtent2D extent,
                                 bool shouldClear,
                                 bool offscreen) {
            VkRenderPassBeginInfo rp;
            rp.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
            rp.renderPass = pass;
            rp.framebuffer = framebuffer;
            rp.renderArea.offset.x = 0;
            rp.renderArea.offset.y = 0;
            rp.renderArea.extent = extent;
            rp.clearValueCount = 0;
            rp.pClearValues = null;
            vkCmdBeginRenderPass(cmd, &rp, VK_SUBPASS_CONTENTS_INLINE);

            VkViewport vp;
            vp.x = 0;
            // Root/swapchain pass uses flipped Y to match OpenGL presentation.
            // Offscreen (dynamic composite targets) stays unflipped.
            vp.y = offscreen ? 0.0f : cast(float)extent.height;
            vp.width = cast(float)extent.width;
            vp.height = offscreen ? cast(float)extent.height : -cast(float)extent.height;
            vp.minDepth = 0;
            vp.maxDepth = 1;
            vkCmdSetViewport(cmd, 0, 1, &vp);

            VkRect2D sc;
            sc.offset.x = 0;
            sc.offset.y = 0;
            sc.extent = extent;
            vkCmdSetScissor(cmd, 0, 1, &sc);

            if (shouldClear) {
                VkClearAttachment clr;
                clr.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
                clr.colorAttachment = 0;
                clr.clearValue.color.float32[0] = 0;
                clr.clearValue.color.float32[1] = 0;
                clr.clearValue.color.float32[2] = 0;
                clr.clearValue.color.float32[3] = 0;
                VkClearRect cr;
                cr.baseArrayLayer = 0;
                cr.layerCount = 1;
                cr.rect.offset.x = 0;
                cr.rect.offset.y = 0;
                cr.rect.extent = extent;
                vkCmdClearAttachments(cmd, 1, &clr, 1, &cr);
            }

            if (vertexBuffer != VK_NULL_HANDLE && indexBuffer != VK_NULL_HANDLE) {
                VkDeviceSize offset = 0;
                vkCmdBindVertexBuffers(cmd, 0, 1, &vertexBuffer, &offset);
                vkCmdBindIndexBuffer(cmd, indexBuffer, 0, VK_INDEX_TYPE_UINT16);

                foreach (i; start .. stop) {
                    auto ref b = batches[i];
                    auto kind = b.pipelineKind;
                    bool stencilKind = kind == PipelineKind.PartStencilTest ||
                                       kind == PipelineKind.PartStencilWrite ||
                                       kind == PipelineKind.PartMaskStencilWrite ||
                                       kind == PipelineKind.MaskStencilWrite;
                    if (offscreen && stencilKind) {
                        // Offscreen path currently has no stencil attachment.
                        // Fall back to color pipeline to avoid disappearing parts.
                        final switch (kind) {
                            case PipelineKind.PartStencilTest:
                            case PipelineKind.PartStencilWrite:
                                kind = PipelineKind.Part;
                                break;
                            case PipelineKind.PartMaskStencilWrite:
                                kind = PipelineKind.PartMask;
                                break;
                            case PipelineKind.MaskStencilWrite:
                                kind = PipelineKind.Mask;
                                break;
                            case PipelineKind.Part:
                            case PipelineKind.PartStage1:
                            case PipelineKind.PartStage2:
                            case PipelineKind.PartMask:
                            case PipelineKind.Mask:
                            case PipelineKind.Count:
                                break;
                        }
                        stencilKind = false;
                    }

                    if (b.clearStencil && !offscreen) {
                        VkClearAttachment stencilClr;
                        stencilClr.aspectMask = VK_IMAGE_ASPECT_STENCIL_BIT;
                        stencilClr.clearValue.depthStencil.depth = 1.0f;
                        stencilClr.clearValue.depthStencil.stencil = b.clearStencilValue;
                        VkClearRect sr;
                        sr.baseArrayLayer = 0;
                        sr.layerCount = 1;
                        sr.rect.offset.x = 0;
                        sr.rect.offset.y = 0;
                        sr.rect.extent = extent;
                        vkCmdClearAttachments(cmd, 1, &stencilClr, 1, &sr);
                    }

                    if (b.indexCount == 0) continue;

                    auto pipeline = offscreen
                        ? offscreenPipelines[cast(size_t)kind][cast(size_t)b.blendMode]
                        : pipelines[cast(size_t)kind][cast(size_t)b.blendMode];
                    if (pipeline == VK_NULL_HANDLE) continue;
                    vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
                    if (stencilKind && !offscreen) {
                        vkCmdSetStencilReference(cmd, VK_STENCIL_FACE_FRONT_AND_BACK, b.stencilReference);
                    }
                    auto dset = allocateBatchDescriptorSet(b);
                    if (dset == VK_NULL_HANDLE) continue;
                    vkCmdBindDescriptorSets(cmd,
                                            VK_PIPELINE_BIND_POINT_GRAPHICS,
                                            pipelineLayout,
                                            0,
                                            1,
                                            &dset,
                                            0,
                                            null);
                    vkCmdPushConstants(cmd,
                                       pipelineLayout,
                                       VK_SHADER_STAGE_FRAGMENT_BIT,
                                       0,
                                       PushConstants.sizeof,
                                       &b.pushConstants);
                    vkCmdDrawIndexed(cmd, b.indexCount, 1, b.firstIndex, b.vertexOffset, 0);
                }
            }

            vkCmdEndRenderPass(cmd);
        };

        bool rootTouched;
        bool[size_t] targetTouched;
        if (batches.length == 0) {
            renderBatchRange(0, 0, renderPass, framebuffers[imageIndex], swapchainExtent, true, false);
        } else {
            size_t i = 0;
            while (i < batches.length) {
                auto target = batches[i].targetHandle;
                auto start = i;
                while (i < batches.length && batches[i].targetHandle == target) {
                    i++;
                }
                auto stop = i;

                if (target == 0) {
                    bool shouldClear = !rootTouched || batches[start].clearTarget;
                    renderBatchRange(start, stop, renderPass, framebuffers[imageIndex], swapchainExtent, shouldClear, false);
                    rootTouched = true;
                } else {
                    auto texRes = resolveTextureHandle(target, false);
                    if (texRes is null || !texRes.renderTarget || texRes.image == VK_NULL_HANDLE) {
                        continue;
                    }
                    auto targetImage = texRes.image;
                    auto fb = getOrCreateOffscreenFramebuffer(*texRes);
                    if (fb == VK_NULL_HANDLE) continue;
                    auto targetWidth = texRes.width;
                    auto targetHeight = texRes.height;
                    recordImageLayoutTransition(cmd,
                                                targetImage,
                                                VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                                                VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL);
                    VkExtent2D extent;
                    extent.width = cast(uint32_t)max(1, targetWidth);
                    extent.height = cast(uint32_t)max(1, targetHeight);
                    bool touched = false;
                    if (auto p = target in targetTouched) touched = *p;
                    bool shouldClear = !touched || batches[start].clearTarget;
                    renderBatchRange(start, stop, offscreenRenderPass, fb, extent, shouldClear, true);
                    targetTouched[target] = true;
                    recordImageLayoutTransition(cmd,
                                                targetImage,
                                                VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                                                VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
                }
            }
        }

        vkEnforce(vkEndCommandBuffer(cmd), "vkEndCommandBuffer failed");
    }

    void drawFrame() {
        vkWaitForFences(device, 1, &inFlight[frameIndex], VK_TRUE, ulong.max);

        uint32_t imageIndex = 0;
        auto acquire = vkAcquireNextImageKHR(device,
                                             swapchain,
                                             ulong.max,
                                             imageAvailable[frameIndex],
                                             VK_NULL_HANDLE,
                                             &imageIndex);
        bool swapchainNeedsRecreate = false;
        if (acquire == VK_ERROR_OUT_OF_DATE_KHR) {
            recreateSwapchain();
            return;
        }
        if (acquire == VK_SUBOPTIMAL_KHR) {
            // Image acquisition succeeded; continue this frame and recreate right after present.
            swapchainNeedsRecreate = true;
        } else {
            vkEnforce(acquire, "vkAcquireNextImageKHR failed");
        }

        if (imageIndex < inFlightByImage.length && inFlightByImage[imageIndex] != VK_NULL_HANDLE) {
            vkWaitForFences(device, 1, &inFlightByImage[imageIndex], VK_TRUE, ulong.max);
        }
        if (imageIndex < swapchainImageInitialized.length && !swapchainImageInitialized[imageIndex]) {
            initializeSwapchainImageLayouts(imageIndex);
            swapchainImageInitialized[imageIndex] = true;
        }
        if (imageIndex < inFlightByImage.length) {
            inFlightByImage[imageIndex] = inFlight[frameIndex];
        }

        vkResetFences(device, 1, &inFlight[frameIndex]);
        vkResetCommandBuffer(commandBuffers[imageIndex], 0);
        enforce(frameIndex < descriptorPools.length, "Invalid frameIndex for descriptor pool");
        activeDescriptorPool = descriptorPools[frameIndex];
        vkEnforce(vkResetDescriptorPool(device, activeDescriptorPool, 0), "vkResetDescriptorPool failed");

        uploadGeometry();
        recordCommandBuffer(commandBuffers[imageIndex], imageIndex);

        VkPipelineStageFlags waitStage = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        VkSubmitInfo submit;
        submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submit.waitSemaphoreCount = 1;
        submit.pWaitSemaphores = &imageAvailable[frameIndex];
        submit.pWaitDstStageMask = &waitStage;
        submit.commandBufferCount = 1;
        submit.pCommandBuffers = &commandBuffers[imageIndex];
        submit.signalSemaphoreCount = 1;
        auto signalSemaphore = renderFinishedByImage[imageIndex];
        submit.pSignalSemaphores = &signalSemaphore;
        vkEnforce(vkQueueSubmit(graphicsQueue, 1, &submit, inFlight[frameIndex]), "vkQueueSubmit failed");

        VkPresentInfoKHR present;
        present.sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR;
        present.waitSemaphoreCount = 1;
        present.pWaitSemaphores = &signalSemaphore;
        present.swapchainCount = 1;
        present.pSwapchains = &swapchain;
        present.pImageIndices = &imageIndex;

        auto presentRes = vkQueuePresentKHR(presentQueue, &present);
        if (swapchainNeedsRecreate ||
            presentRes == VK_ERROR_OUT_OF_DATE_KHR ||
            presentRes == VK_SUBOPTIMAL_KHR) {
            recreateSwapchain();
        } else {
            vkEnforce(presentRes, "vkQueuePresentKHR failed");
        }

        frameIndex = (frameIndex + 1) % MaxFramesInFlight;
    }
}

/// Initialize SDL, Vulkan loader/device, create window and renderer callbacks.
VulkanBackendInit initVulkanBackend(int width, int height, bool isTest) {
    ensureDThreadAttached();
    auto support = loadSDL();
    if (support == SDLSupport.noLibrary || support == SDLSupport.badLibrary) {
        version (OSX) {
            support = loadSDL("/opt/homebrew/lib/libSDL2-2.0.0.dylib");
        }
    }
    enforce(support >= SDLSupport.sdl206,
        "Failed to load SDL2 or version too old for Vulkan (loaded=" ~ loadedSDLVersion().to!string ~ ")");
    enforce(SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS) == 0, "SDL_Init failed: " ~ sdlError());

    auto window = SDL_CreateWindow("nijiv",
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        width, height,
        SDL_WINDOW_VULKAN | SDL_WINDOW_RESIZABLE | SDL_WINDOW_ALLOW_HIGHDPI | SDL_WINDOW_SHOWN);
    enforce(window !is null, "SDL_CreateWindow failed: " ~ sdlError());

    int drawableW = width;
    int drawableH = height;
    SDL_Vulkan_GetDrawableSize(window, &drawableW, &drawableH);

    auto backend = new RenderingBackend(window, isTest);
    backend.initializeRenderer();

    UnityResourceCallbacks cbs;
    cbs.userData = window;
    cbs.createTexture = (int w, int h, int channels, int mipLevels, int format, bool renderTarget, bool stencil, void* userData) {
        ensureDThreadAttached();
        size_t handle = 0;
        synchronized (gTexturesGuard) {
            handle = gNextHandle++;
            gTextures[handle] = new Texture(w, h, channels, stencil, renderTarget);
        }
        return handle;
    };
    cbs.updateTexture = (size_t handle, const(ubyte)* data, size_t dataLen, int w, int h, int channels, void* userData) {
        ensureDThreadAttached();
        if (data is null) return;
        auto expected = cast(size_t)w * cast(size_t)h * cast(size_t)max(1, channels);
        if (expected == 0 || dataLen < expected) return;
        synchronized (gTexturesGuard) {
            if (auto tex = handle in gTextures) {
                if (*tex is null) return;
                (*tex).width = w;
                (*tex).height = h;
                (*tex).setData(data[0 .. expected], channels);
            }
        }
    };
    cbs.releaseTexture = (size_t handle, void* userData) {
        ensureDThreadAttached();
        synchronized (gTexturesGuard) {
            if (auto tex = handle in gTextures) {
                if (*tex !is null) (*tex).dispose();
                gTextures.remove(handle);
            }
        }
    };

    return VulkanBackendInit(window, backend, drawableW, drawableH, cbs);
}

/// Execute command queue on Vulkan backend.
void renderCommands(const VulkanBackendInit* vk,
                    const SharedBufferSnapshot* snapshot,
                    const CommandQueueView* view)
{
    ensureDThreadAttached();
    if (vk is null || vk.backend is null || view is null) return;

    auto backend = cast(RenderingBackend)vk.backend;
    backend.setSharedSnapshot(snapshot);
    backend.beginScene();

    auto cmds = view.commands[0 .. view.count];
    foreach (cmd; cmds) {
        final switch (cmd.kind) {
            case NjgRenderCommandKind.DrawPart:
                backend.drawPartPacket(cmd.partPacket);
                break;
            case NjgRenderCommandKind.DrawMask:
                break;
            case NjgRenderCommandKind.BeginDynamicComposite:
                backend.beginDynamicComposite(cmd.dynamicPass);
                break;
            case NjgRenderCommandKind.EndDynamicComposite:
                backend.endDynamicComposite(cmd.dynamicPass);
                break;
            case NjgRenderCommandKind.BeginMask:
                backend.beginMask(cmd.usesStencil);
                break;
            case NjgRenderCommandKind.ApplyMask:
                backend.applyMask(cmd.maskApplyPacket);
                break;
            case NjgRenderCommandKind.BeginMaskContent:
                backend.beginMaskContent();
                break;
            case NjgRenderCommandKind.EndMask:
                backend.endMask();
                break;
        }
    }

    backend.postProcessScene();
    backend.endScene();
}

} // version (EnableVulkanBackend)
