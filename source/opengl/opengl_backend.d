module opengl.opengl_backend;

import std.exception : enforce;
import std.string : fromStringz;
import std.conv : to;

import bindbc.sdl;
import bindbc.opengl;
import opengl.opengl_thumb : currentDebugTextureBackend;

// OpenGL backend is provided by top-level opengl/* modules; avoid importing nlshim copies.

import bindbc.opengl.context;

import std.algorithm : min;
version (OSX) {
    import core.sys.posix.dlfcn : dlopen, dlsym, RTLD_NOW, RTLD_LOCAL;
}

import std.algorithm.comparison : max;
import std.algorithm.mutation : swap;
import core.stdc.string : memcpy;

// Composite backend removed; no-op imports.

version(Windows) {
    // Ask Windows nicely to use dedicated GPUs :)
    export extern(C) int NvOptimusEnablement = 0x00000001;
    export extern(C) int AmdPowerXpressRequestHighPerformance = 0x00000001;
}

struct PostProcessingShader {
private:
    GLint[string] uniformCache;

public:
    Shader shader;
    this(Shader shader) {
        this.shader = shader;

        shader.use();
        shader.setUniform(shader.getUniformLocation("albedo"), 0);
        shader.setUniform(shader.getUniformLocation("emissive"), 1);
        shader.setUniform(shader.getUniformLocation("bumpmap"), 2);
    }

    /**
        Gets the location of the specified uniform
    */
    GLuint getUniform(string name) {
        if (this.hasUniform(name)) return uniformCache[name];
        GLint element = shader.getUniformLocation(name);
        uniformCache[name] = element;
        return element;
    }

    /**
        Returns true if the uniform is present in the shader cache
    */
    bool hasUniform(string name) {
        return (name in uniformCache) !is null;
    }
}

import std.exception;
import std.string : toStringz;

struct ShaderProgramHandle {
    uint program;
    uint vert;
    uint frag;
}

private void checkShader(GLuint shader) {
    GLint status;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &status);
    if (status == GL_FALSE) {
        GLint length;
        glGetShaderiv(shader, GL_INFO_LOG_LENGTH, &length);
        if (length > 0) {
            char[] log = new char[length];
            glGetShaderInfoLog(shader, length, null, log.ptr);
            throw new Exception(cast(string)log);
        }
        throw new Exception("Shader compile failed");
    }
}

private void checkProgram(GLuint program) {
    GLint status;
    glGetProgramiv(program, GL_LINK_STATUS, &status);
    if (status == GL_FALSE) {
        GLint length;
        glGetProgramiv(program, GL_INFO_LOG_LENGTH, &length);
        if (length > 0) {
            char[] log = new char[length];
            glGetProgramInfoLog(program, length, null, log.ptr);
            throw new Exception(cast(string)log);
        }
        throw new Exception("Program link failed");
    }
}

alias GLId = uint;

// Provide anisotropy constants if not exposed by the bindings in use.
static if (!__traits(compiles, GL_TEXTURE_MAX_ANISOTROPY))
enum GL_TEXTURE_MAX_ANISOTROPY = 0x84FE;
static if (!__traits(compiles, GL_MAX_TEXTURE_MAX_ANISOTROPY))
enum GL_MAX_TEXTURE_MAX_ANISOTROPY = 0x84FF;

private GLuint channelFormat(int channels) {
    switch (channels) {
        case 1: return GL_RED;
        case 2: return GL_RG;
        case 3: return GL_RGB;
        default: return GL_RGBA;
    }
}

/// Struct for backend-cached shared GPU state
alias RenderResourceHandle = size_t;

alias RenderBackend = RenderingBackend;

/// GPU command kinds; backends switch on these during rendering.
enum RenderCommandKind {
    DrawPart,
    DrawMask,
    BeginDynamicComposite,
    EndDynamicComposite,
    BeginMask,
    ApplyMask,
    BeginMaskContent,
    EndMask,
    BeginComposite,
    DrawCompositeQuad,
    EndComposite,
}

enum MaskDrawableKind {
    Part,
    Mask,
}

struct PartDrawPacket {
    bool isMask;
    bool renderable;
    mat4 modelMatrix;
    mat4 renderMatrix;
    float renderRotation;
    vec3 clampedTint;
    vec3 clampedScreen;
    float opacity;
    float emissionStrength;
    float maskThreshold;
    BlendMode blendingMode;
    bool useMultistageBlend;
    bool hasEmissionOrBumpmap;
    Texture[] textures;
    vec2 origin;
    size_t vertexOffset;
    size_t vertexAtlasStride;
    size_t uvOffset;
    size_t uvAtlasStride;
    size_t deformOffset;
    size_t deformAtlasStride;
    RenderResourceHandle indexBuffer;
    uint indexCount;
    uint vertexCount;
}

struct MaskDrawPacket {
    mat4 modelMatrix;
    mat4 mvp;
    vec2 origin;
    size_t vertexOffset;
    size_t vertexAtlasStride;
    size_t deformOffset;
    size_t deformAtlasStride;
    RenderResourceHandle indexBuffer;
    uint indexCount;
    uint vertexCount;
}

struct MaskApplyPacket {
    MaskDrawableKind kind;
    bool isDodge;
    PartDrawPacket partPacket;
    MaskDrawPacket maskPacket;
}

class DynamicCompositeSurface {
    Texture[3] textures;
    size_t[3] textureHandles;
    size_t textureCount;
    Texture stencil;
    size_t stencilHandle;
    RenderResourceHandle framebuffer;
}

class DynamicCompositePass {
    DynamicCompositeSurface surface;
    vec2 scale;
    float rotationZ;
    RenderResourceHandle origBuffer;
    int[4] origViewport;
    bool autoScaled;
    int drawBufferCount;   // number of color attachments active when begun
    bool hasStencil;
}

/// Render target scope kinds.
enum RenderPassKind {
    Root,
    DynamicComposite,
}

import inmath.linalg : Vector;

public enum BlendMode {
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
    SliceFromLower
}

import fghj : deserializeValue;
import core.stdc.string : memcpy;

public vec4 inClearColor = vec4(0, 0, 0, 0);
public bool useColorKeyTransparency = false;
vec3 inSceneAmbientLight = vec3(1, 1, 1);

private __gshared RenderBackend cachedRenderBackend;

version (OSX) {
    private void configureMacOpenGLSurfaceOpacity(SDL_GLContext glContext) {
        if (glContext is null) return;

        alias ObjcId = void*;
        alias ObjcSel = void*;
        alias ObjcRegisterSelFn = extern(C) ObjcSel function(const(char)*);
        alias MsgSendSetValuesFn = extern(C) void function(ObjcId, ObjcSel, const(int)*, int);

        auto objcHandle = dlopen("/usr/lib/libobjc.A.dylib".toStringz, RTLD_NOW | RTLD_LOCAL);
        if (objcHandle is null) return;

        auto selRegisterName = cast(ObjcRegisterSelFn)dlsym(objcHandle, "sel_registerName".toStringz);
        auto objcMsgSendRaw = dlsym(objcHandle, "objc_msgSend".toStringz);
        if (selRegisterName is null || objcMsgSendRaw is null) return;

        auto msgSendSetValues = cast(MsgSendSetValuesFn)objcMsgSendRaw;
        auto selSetValuesForParameter = selRegisterName("setValues:forParameter:".toStringz);
        if (selSetValuesForParameter is null) return;

        // NSOpenGLCPSurfaceOpacity
        enum NSOpenGLCPSurfaceOpacity = 236;
        int zero = 0;
        msgSendSetValues(cast(ObjcId)glContext, selSetValuesForParameter, &zero, NSOpenGLCPSurfaceOpacity);
    }
}

private void ensureRenderBackend() {
    if (cachedRenderBackend is null) {
        cachedRenderBackend = new RenderBackend();
    }
}

public void inSetRenderBackend(RenderBackend backend) {
    cachedRenderBackend = backend;
}

public RenderBackend tryRenderBackend() {
    ensureRenderBackend();
    return cachedRenderBackend;
}

private RenderBackend requireRenderBackend() {
    auto backend = tryRenderBackend();
    enforce(backend !is null, "RenderBackend is not available.");
    return backend;
}

public RenderBackend currentRenderBackend() {
    return requireRenderBackend();
}

alias GLuint = uint;

struct ShaderStageSource {
    string vertex;
    string fragment;
}

struct ShaderAsset {
    ShaderStageSource stage;

    static ShaderAsset fromOpenGLSource(string vertexSource, string fragmentSource) {
        ShaderAsset asset;
        asset.stage = ShaderStageSource(vertexSource, fragmentSource);
        return asset;
    }
}

auto shaderAsset(string vertexPath, string fragmentPath)()
{
    enum ShaderAsset asset = ShaderAsset(
        ShaderStageSource(import(vertexPath), import(fragmentPath))
    );
    return asset;
}

/**
    A shader
*/
class Shader {
private:
    GLShaderHandle handle;

public:
    ~this() {
        if (handle is null) return;
        auto backend = tryRenderBackend();
        if (backend !is null) {
            backend.destroyShader(handle);
        }
        handle = null;
    }

    this(ShaderAsset sources) {
        handle = currentRenderBackend().createShader(sources.stage.vertex, sources.stage.fragment);
    }

    this(string vertex, string fragment) {
        this(ShaderAsset.fromOpenGLSource(vertex, fragment));
    }

    void use() {
        if (handle is null) return;
        currentRenderBackend().useShader(handle);
    }

    int getUniformLocation(string name) {
        if (handle is null) return -1;
        return currentRenderBackend().getShaderUniformLocation(handle, name);
    }

    void setUniform(int uniform, bool value) {
        if (handle is null) return;
        currentRenderBackend().setShaderUniform(handle, uniform, value);
    }

    void setUniform(int uniform, int value) {
        if (handle is null) return;
        currentRenderBackend().setShaderUniform(handle, uniform, value);
    }

    void setUniform(int uniform, float value) {
        if (handle is null) return;
        currentRenderBackend().setShaderUniform(handle, uniform, value);
    }

    void setUniform(int uniform, vec2 value) {
        if (handle is null) return;
        currentRenderBackend().setShaderUniform(handle, uniform, value);
    }

    void setUniform(int uniform, vec3 value) {
        if (handle is null) return;
        currentRenderBackend().setShaderUniform(handle, uniform, value);
    }

    void setUniform(int uniform, vec4 value) {
        if (handle is null) return;
        currentRenderBackend().setShaderUniform(handle, uniform, value);
    }

    void setUniform(int uniform, mat4 value) {
        if (handle is null) return;
        currentRenderBackend().setShaderUniform(handle, uniform, value);
    }
}

import std.exception;
import std.algorithm : clamp;

/**
    A texture, only format supported is unsigned 8 bit RGBA
*/
class Texture {
private:
    static float maxAnisotropy() {
        auto backend = tryRenderBackend();
        return backend is null ? 1 : backend.maxTextureAnisotropy();
    }

    static void unPremultiplyRgba(ref ubyte[] data) {
        foreach (i; 0 .. data.length / 4) {
            auto alpha = data[i * 4 + 3];
            if (alpha == 0) continue;
            data[i * 4 + 0] = cast(ubyte)(cast(int)data[i * 4 + 0] * 255 / cast(int)alpha);
            data[i * 4 + 1] = cast(ubyte)(cast(int)data[i * 4 + 1] * 255 / cast(int)alpha);
            data[i * 4 + 2] = cast(ubyte)(cast(int)data[i * 4 + 2] * 255 / cast(int)alpha);
        }
    }

    GLTextureHandle handle;
    int width_;
    int height_;
    int channels_;
    bool stencil_;
    bool useMipmaps_ = true;

    uint uuid;

    ubyte[] lockedData = null;
    bool locked = false;
    bool modified = false;

public:
    this(int width, int height, int channels = 4, bool stencil = false, bool useMipmaps = true) {
        // Create an empty texture array with no data
        ubyte[] empty = stencil ? null : new ubyte[width_ * height_ * channels];

        // Pass it on to the other texturing
        this(empty, width, height, channels, channels, stencil, useMipmaps);
    }

    this(ubyte[] data, int width, int height, int inChannels = 4, int outChannels = 4, bool stencil = false, bool useMipmaps = true) {
        this.width_ = width;
        this.height_ = height;
        this.channels_ = outChannels;
        this.stencil_ = stencil;
        this.useMipmaps_ = useMipmaps;

        auto backend = currentRenderBackend();
        handle = backend.createTextureHandle();
        this.setData(data, inChannels);

        this.setFiltering(Filtering.Linear);
        this.setWrapping(Wrapping.Clamp);
        this.setAnisotropy(maxAnisotropy() / 2.0f);

        uuid = 0;
    }

    ~this() {
        dispose();
    }

    int width() {
        return width_;
    }

    int height() {
        return height_;
    }

    void setFiltering(Filtering filtering) {
        if (handle is null) return;
        currentRenderBackend().applyTextureFiltering(handle, filtering, useMipmaps_);
    }

    void setAnisotropy(float value) {
        if (handle is null) return;
        currentRenderBackend().applyTextureAnisotropy(handle, clamp(value, 1, maxAnisotropy()));
    }

    void setWrapping(Wrapping wrapping) {
        if (handle is null) return;
        currentRenderBackend().applyTextureWrapping(handle, wrapping);
    }

    void setData(ubyte[] data, int inChannels = -1) {
        int actualChannels = inChannels == -1 ? channels_ : inChannels;
        if (locked) {
            lockedData = data;
            modified = true;
        } else {
            if (handle is null) return;
            currentRenderBackend().uploadTextureData(handle, width_, height_, actualChannels, channels_, stencil_, data);
            this.genMipmap();
        }
    }

    void genMipmap() {
        if (!stencil_ && handle !is null && useMipmaps_) {
            currentRenderBackend().generateTextureMipmap(handle);
        }
    }

    void bind(uint unit = 0) {
        assert(unit <= 31u, "Outside maximum texture unit value");
        if (handle is null) return;
        currentRenderBackend().bindTextureHandle(handle, unit);
    }

    uint getTextureId() {
        if (handle is null) return 0;
        auto backend = tryRenderBackend();
        if (backend is null) return 0;
        return cast(uint)backend.textureNativeHandle(handle);
    }

    ubyte[] getTextureData(bool unmultiply = false) {
        if (locked) {
            return lockedData;
        } else {
            ubyte[] buf = new ubyte[width_ * height_ * channels_];
            if (handle is null) return buf;
            currentRenderBackend().readTextureData(handle, channels_, stencil_, buf);
            if (unmultiply && channels_ == 4) {
                unPremultiplyRgba(buf);
            }
            return buf;
        }
    }

    void dispose() {
        if (handle is null) return;
        auto backend = tryRenderBackend();
        if (backend !is null) backend.destroyTextureHandle(handle);
        handle = null;
    }

    GLTextureHandle backendHandle() {
        return handle;
    }
}

enum Filtering {
    Linear,
    Point,
}

enum Wrapping {
    Clamp,
    Repeat,
    Mirror,
}

import inmath.util;
public import inmath.linalg;
public import inmath.math;
public import std.math : isNaN;
public import inmath.interpolate;

// AUTOGENERATED BY GITVER, DO NOT MODIFY

// trans rights

class GLShaderHandle {
    ShaderProgramHandle shader;
}

class GLTextureHandle {
    GLId id;
}

// ---- Shader Asset Definitions (centralized) ----
private enum ShaderAsset MaskShaderSource = shaderAsset!("opengl/shaders/mask.vert","opengl/shaders/mask.frag")();
private enum ShaderAsset AdvancedBlendShaderSource = shaderAsset!("opengl/shaders/basic.vert","opengl/shaders/advanced_blend.frag")();
private enum ShaderAsset PartShaderSource = shaderAsset!("opengl/shaders/basic.vert","opengl/shaders/basic.frag")();
private enum ShaderAsset PartShaderStage1Source = shaderAsset!("opengl/shaders/basic.vert","opengl/shaders/basic-stage1.frag")();
private enum ShaderAsset PartShaderStage2Source = shaderAsset!("opengl/shaders/basic.vert","opengl/shaders/basic-stage2.frag")();
private enum ShaderAsset PartMaskShaderSource = shaderAsset!("opengl/shaders/basic.vert","opengl/shaders/basic-mask.frag")();

// queue/backend not used in this binary; avoid pulling queue modules
import inmath.linalg : rect;

class RenderingBackend {
    private struct IboKey {
        size_t ptr;
        size_t count;
        bool opEquals(ref const IboKey other) const nothrow @safe {
            return ptr == other.ptr && count == other.count;
        }
        size_t toHash() const nothrow @safe {
            // simple pointer/count mix; sufficient for stable index buffers
            return (ptr ^ (count + 0x9e3779b97f4a7c15UL + (ptr << 6) + (ptr >> 2)));
        }
    }

    private struct IndexRange {
        size_t offset;
        size_t count;
        size_t capacity;
        const(ushort)[] data;
    }

    private int pointCount;
    private bool bufferIsSoA;

    private GLuint drawableVAO;
    private bool drawableBuffersInitialized = false;
    private GLuint sharedDeformBuffer;
    private GLuint sharedVertexBuffer;
    private GLuint sharedUvBuffer;
    private GLuint presentVao;
    private GLuint presentVbo;
    private GLuint presentProgram;
    private GLint presentTexUniform = -1;
    private GLint presentUseColorKeyUniform = -1;
    private GLuint sharedIndexBuffer;
    private size_t sharedIndexCapacity;
    private size_t sharedIndexOffset;
    private RenderResourceHandle nextIndexHandle = 1;
    private IndexRange[RenderResourceHandle] sharedIndexRanges;

    private Shader maskShader;
    private GLint maskOffsetUniform;
    private GLint maskMvpUniform;
    private bool maskBackendInitialized = false;

    private Texture boundAlbedo;
    private Shader partShader;
    private Shader partShaderStage1;
    private Shader partShaderStage2;
    private Shader partMaskShader;
    private GLint mvp;
    private GLint offset;
    private GLint gopacity;
    private GLint gMultColor;
    private GLint gScreenColor;
    private GLint gEmissionStrength;
    private GLint gs1mvp;
    private GLint gs1offset;
    private GLint gs1opacity;
    private GLint gs1MultColor;
    private GLint gs1ScreenColor;
    private GLint gs2mvp;
    private GLint gs2offset;
    private GLint gs2opacity;
    private GLint gs2EmissionStrength;
    private GLint gs2MultColor;
    private GLint gs2ScreenColor;
    private GLint mmvp;
    private GLint mthreshold;
    private bool partBackendInitialized = false;

    private GLuint sceneVAO;
    private GLuint sceneVBO;

    private GLuint fBuffer;
    private GLuint fAlbedo;
    private GLuint fEmissive;
    private GLuint fBump;
    private GLuint fStencil;

    private GLuint cfBuffer;
    private GLuint cfAlbedo;
    private GLuint cfEmissive;
    private GLuint cfBump;
    private GLuint cfStencil;

    private PostProcessingShader[] postProcessingStack;

    private GLuint debugVao;
    private GLuint debugVbo;
    private GLuint debugIbo;
    private GLuint debugCurrentVbo;
    private int debugIndexCount;

    private bool advancedBlending;
    private bool advancedBlendingCoherent;
    private int[] viewportWidthStack;
    private int[] viewportHeightStack;

    private RenderResourceHandle[IboKey] iboCache;

public:
    void bindPartShader() {
        if (partShader !is null) {
            partShader.use();
        }
    }

    void setViewport(int width, int height) {
        if (viewportWidthStack.length == 0) {
            pushViewport(width, height);
        } else {
            if (width == viewportWidthStack[$-1] && height == viewportHeightStack[$-1]) {
                if (fBuffer != 0) {
                    resizeViewportTargets(width, height);
                }
                return;
            }
            viewportWidthStack[$-1] = width;
            viewportHeightStack[$-1] = height;
        }
        if (fBuffer != 0) {
            resizeViewportTargets(width, height);
        }
    }

    void initializeRenderer() {
        // Set a default logical viewport before first explicit size arrives.
        setViewport(640, 480);

        glGenVertexArrays(1, &sceneVAO);
        glGenBuffers(1, &sceneVBO);

        // Generate the framebuffer we'll be using to render the model and composites
        glGenFramebuffers(1, &fBuffer);
        glGenFramebuffers(1, &cfBuffer);

        // Generate the color and stencil-depth textures needed
        // Note: we're not using the depth buffer but OpenGL 3.4 does not support stencil-only buffers
        glGenTextures(1, &fAlbedo);
        glGenTextures(1, &fEmissive);
        glGenTextures(1, &fBump);
        glGenTextures(1, &fStencil);

        glGenTextures(1, &cfAlbedo);
        glGenTextures(1, &cfEmissive);
        glGenTextures(1, &cfBump);
        glGenTextures(1, &cfStencil);

        // Attach textures to framebuffer
        glBindFramebuffer(GL_FRAMEBUFFER, fBuffer);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, fAlbedo, 0);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT1, GL_TEXTURE_2D, fEmissive, 0);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT2, GL_TEXTURE_2D, fBump, 0);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_TEXTURE_2D, fStencil, 0);

        glBindFramebuffer(GL_FRAMEBUFFER, cfBuffer);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, cfAlbedo, 0);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT1, GL_TEXTURE_2D, cfEmissive, 0);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT2, GL_TEXTURE_2D, cfBump, 0);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_TEXTURE_2D, cfStencil, 0);

        // go back to default fb
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        applyBlendingCapabilities();
    }

    void initializePartBackendResources() {
        if (partBackendInitialized) return;
        partBackendInitialized = true;

        partShader = new Shader(PartShaderSource);
        partShaderStage1 = new Shader(PartShaderStage1Source);
        partShaderStage2 = new Shader(PartShaderStage2Source);
        partMaskShader = new Shader(PartMaskShaderSource);

        bindDrawableVao();

        partShader.use();
        partShader.setUniform(partShader.getUniformLocation("albedo"), 0);
        partShader.setUniform(partShader.getUniformLocation("emissive"), 1);
        partShader.setUniform(partShader.getUniformLocation("bumpmap"), 2);
        mvp = partShader.getUniformLocation("mvp");
        offset = partShader.getUniformLocation("offset");
        gopacity = partShader.getUniformLocation("opacity");
        gMultColor = partShader.getUniformLocation("multColor");
        gScreenColor = partShader.getUniformLocation("screenColor");
        gEmissionStrength = partShader.getUniformLocation("emissionStrength");

        partShaderStage1.use();
        partShaderStage1.setUniform(partShader.getUniformLocation("albedo"), 0);
        gs1mvp = partShaderStage1.getUniformLocation("mvp");
        gs1offset = partShaderStage1.getUniformLocation("offset");
        gs1opacity = partShaderStage1.getUniformLocation("opacity");
        gs1MultColor = partShaderStage1.getUniformLocation("multColor");
        gs1ScreenColor = partShaderStage1.getUniformLocation("screenColor");

        partShaderStage2.use();
        partShaderStage2.setUniform(partShaderStage2.getUniformLocation("emissive"), 1);
        partShaderStage2.setUniform(partShaderStage2.getUniformLocation("bumpmap"), 2);
        gs2mvp = partShaderStage2.getUniformLocation("mvp");
        gs2offset = partShaderStage2.getUniformLocation("offset");
        gs2opacity = partShaderStage2.getUniformLocation("opacity");
        gs2MultColor = partShaderStage2.getUniformLocation("multColor");
        gs2ScreenColor = partShaderStage2.getUniformLocation("screenColor");
        gs2EmissionStrength = partShaderStage2.getUniformLocation("emissionStrength");

        partMaskShader.use();
        partMaskShader.setUniform(partMaskShader.getUniformLocation("albedo"), 0);
        partMaskShader.setUniform(partMaskShader.getUniformLocation("emissive"), 1);
        partMaskShader.setUniform(partMaskShader.getUniformLocation("bumpmap"), 2);
        mmvp = partMaskShader.getUniformLocation("mvp");
        mthreshold = partMaskShader.getUniformLocation("threshold");
    }

    void initializeMaskBackend() {
        ensureMaskBackendInitialized();
    }

    void resizeViewportTargets(int width, int height) {
        // Work on texture unit 0 to avoid "no texture bound" errors.
        glActiveTexture(GL_TEXTURE0);
        // Render Framebuffer
        glBindTexture(GL_TEXTURE_2D, fAlbedo);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, null);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);

        glBindTexture(GL_TEXTURE_2D, fEmissive);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA, GL_FLOAT, null);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);

        glBindTexture(GL_TEXTURE_2D, fBump);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, null);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);

        glBindTexture(GL_TEXTURE_2D, fStencil);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_DEPTH24_STENCIL8, width, height, 0, GL_DEPTH_STENCIL, GL_UNSIGNED_INT_24_8, null);

        glBindFramebuffer(GL_FRAMEBUFFER, fBuffer);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, fAlbedo, 0);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT1, GL_TEXTURE_2D, fEmissive, 0);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT2, GL_TEXTURE_2D, fBump, 0);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_TEXTURE_2D, fStencil, 0);

        // Composite framebuffer
        glBindTexture(GL_TEXTURE_2D, cfAlbedo);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, null);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);

        glBindTexture(GL_TEXTURE_2D, cfEmissive);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA, GL_FLOAT, null);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);

        glBindTexture(GL_TEXTURE_2D, cfBump);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, null);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);

        glBindTexture(GL_TEXTURE_2D, cfStencil);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_DEPTH24_STENCIL8, width, height, 0, GL_DEPTH_STENCIL, GL_UNSIGNED_INT_24_8, null);

        glBindFramebuffer(GL_FRAMEBUFFER, cfBuffer);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, cfAlbedo, 0);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT1, GL_TEXTURE_2D, cfEmissive, 0);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT2, GL_TEXTURE_2D, cfBump, 0);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_TEXTURE_2D, cfStencil, 0);

        glBindFramebuffer(GL_FRAMEBUFFER, 0);

        glViewport(0, 0, width, height);
    }

    void bindDrawableVao() {
        ensureDrawableBackendInitialized();
        glBindVertexArray(drawableVAO);
    }

    RenderResourceHandle getOrCreateIbo(const(ushort)* indices, size_t count) {
        if (indices is null || count == 0) return RenderResourceHandle.init;
        IboKey key = IboKey(cast(size_t)indices, count);
        if (auto existing = key in iboCache) {
            return *existing;
        }
        RenderResourceHandle ibo;
        createDrawableBuffers(ibo);
        auto idxSlice = indices[0 .. count];
        uploadDrawableIndices(ibo, idxSlice);
        iboCache[key] = ibo;
        return ibo;
    }

    void rebindActiveTargets() {
        GLint prev;
        glGetIntegerv(GL_FRAMEBUFFER_BINDING, &prev);

        glBindFramebuffer(GL_FRAMEBUFFER, fBuffer);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, fAlbedo, 0);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT1, GL_TEXTURE_2D, fEmissive, 0);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT2, GL_TEXTURE_2D, fBump, 0);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_TEXTURE_2D, fStencil, 0);

        glBindFramebuffer(GL_FRAMEBUFFER, cfBuffer);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, cfAlbedo, 0);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT1, GL_TEXTURE_2D, cfEmissive, 0);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT2, GL_TEXTURE_2D, cfBump, 0);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_TEXTURE_2D, cfStencil, 0);

        glBindFramebuffer(GL_FRAMEBUFFER, prev);
    }

    GLuint sharedVertexBufferHandle() {
        if (sharedVertexBuffer == 0) {
            glGenBuffers(1, &sharedVertexBuffer);
        }
        return sharedVertexBuffer;
    }

    GLuint sharedUvBufferHandle() {
        if (sharedUvBuffer == 0) {
            glGenBuffers(1, &sharedUvBuffer);
        }
        return sharedUvBuffer;
    }

    GLuint sharedDeformBufferHandle() {
        if (sharedDeformBuffer == 0) {
            glGenBuffers(1, &sharedDeformBuffer);
        }
        return sharedDeformBuffer;
    }

    void beginScene() {
        while (glGetError() != GL_NO_ERROR) {}

        boundAlbedo = null;
        glBindVertexArray(sceneVAO);
        glEnable(GL_BLEND);
        glEnablei(GL_BLEND, 0);
        glEnablei(GL_BLEND, 1);
        glEnablei(GL_BLEND, 2);
        glDisable(GL_DEPTH_TEST);
        glDisable(GL_CULL_FACE);

        int viewportWidth;
        int viewportHeight;
        getViewport(viewportWidth, viewportHeight);
        glViewport(0, 0, viewportWidth, viewportHeight);

        glBindFramebuffer(GL_FRAMEBUFFER, fBuffer);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, fAlbedo, 0);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT1, GL_TEXTURE_2D, fEmissive, 0);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT2, GL_TEXTURE_2D, fBump, 0);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_TEXTURE_2D, fStencil, 0);

        glBindFramebuffer(GL_FRAMEBUFFER, cfBuffer);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, cfAlbedo, 0);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT1, GL_TEXTURE_2D, cfEmissive, 0);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT2, GL_TEXTURE_2D, cfBump, 0);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_TEXTURE_2D, cfStencil, 0);

        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, cfBuffer);
        immutable(GLenum[3]) cfTargets = [GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2];
        glDrawBuffers(cast(GLsizei)cfTargets.length, cfTargets.ptr);
        glClearColor(0, 0, 0, 0);

        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, fBuffer);

        glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER);
        glGetError();

        glDrawBuffers(1, [GL_COLOR_ATTACHMENT0].ptr);
        glClearColor(inClearColor.r, inClearColor.g, inClearColor.b, inClearColor.a);
        glClear(GL_COLOR_BUFFER_BIT);

        glDrawBuffers(2, [GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2].ptr);
        glClearColor(0, 0, 0, 1);
        glClear(GL_COLOR_BUFFER_BIT);

        glActiveTexture(GL_TEXTURE0);
        glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
        glDrawBuffers(3, [GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2].ptr);
    }

    void endScene() {
        glBindFramebuffer(GL_FRAMEBUFFER, 0);

        glDisablei(GL_BLEND, 0);
        glDisablei(GL_BLEND, 1);
        glDisablei(GL_BLEND, 2);
        glEnable(GL_DEPTH_TEST);
        glEnable(GL_CULL_FACE);
        glDisable(GL_BLEND);
        glFlush();
        glDrawBuffers(1, [GL_COLOR_ATTACHMENT0].ptr);
    }

    private void ensurePresentProgram() {
        if (presentProgram != 0 && presentVao != 0 && presentVbo != 0) return;

        immutable presentVs = q{
#version 330
layout(location = 0) in vec2 inPos;
layout(location = 1) in vec2 inUv;
out vec2 texUVs;
void main() {
    texUVs = inUv;
    gl_Position = vec4(inPos, 0.0, 1.0);
}};

        immutable presentFs = q{
#version 330
in vec2 texUVs;
out vec4 outColor;
uniform sampler2D srcTex;
uniform int useColorKey;
void main() {
    vec4 c = texture(srcTex, texUVs);
    if (useColorKey != 0) {
        if (c.a <= 0.001) {
            outColor = vec4(1.0, 0.0, 1.0, 1.0);
        } else {
            vec3 straight = clamp(c.rgb / max(c.a, 0.0001), 0.0, 1.0);
            outColor = vec4(straight, 1.0);
        }
    } else {
        outColor = c;
    }
}};

        auto vs = glCreateShader(GL_VERTEX_SHADER);
        auto vsrc = presentVs.toStringz;
        glShaderSource(vs, 1, &vsrc, null);
        glCompileShader(vs);
        checkShader(vs);

        auto fs = glCreateShader(GL_FRAGMENT_SHADER);
        auto fsrc = presentFs.toStringz;
        glShaderSource(fs, 1, &fsrc, null);
        glCompileShader(fs);
        checkShader(fs);

        presentProgram = glCreateProgram();
        glAttachShader(presentProgram, vs);
        glAttachShader(presentProgram, fs);
        glLinkProgram(presentProgram);
        checkProgram(presentProgram);
        glDeleteShader(vs);
        glDeleteShader(fs);

        presentTexUniform = glGetUniformLocation(presentProgram, "srcTex".toStringz);
        presentUseColorKeyUniform = glGetUniformLocation(presentProgram, "useColorKey".toStringz);

        glGenVertexArrays(1, &presentVao);
        glGenBuffers(1, &presentVbo);
        glBindVertexArray(presentVao);
        glBindBuffer(GL_ARRAY_BUFFER, presentVbo);
        immutable float[] quad = [
            -1.0f, -1.0f, 0.0f, 0.0f,
             1.0f, -1.0f, 1.0f, 0.0f,
             1.0f,  1.0f, 1.0f, 1.0f,
            -1.0f, -1.0f, 0.0f, 0.0f,
             1.0f,  1.0f, 1.0f, 1.0f,
            -1.0f,  1.0f, 0.0f, 1.0f,
        ];
        glBufferData(GL_ARRAY_BUFFER, cast(GLsizeiptr)(quad.length * float.sizeof), quad.ptr, GL_STATIC_DRAW);
        glEnableVertexAttribArray(0);
        glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 4 * float.sizeof, null);
        glEnableVertexAttribArray(1);
        glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 4 * float.sizeof, cast(void*)(2 * float.sizeof));
        glBindVertexArray(0);
        glBindBuffer(GL_ARRAY_BUFFER, 0);
    }

    void presentSceneToBackbuffer(int width, int height) {
        ensurePresentProgram();

        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0);
        glDrawBuffer(GL_BACK);
        glViewport(0, 0, width, height);
        glDisable(GL_DEPTH_TEST);
        glDisable(GL_CULL_FACE);
        glDisable(GL_BLEND);
        if (useColorKeyTransparency) {
            glClearColor(1, 0, 1, 1);
        } else {
            glClearColor(0, 0, 0, 0);
        }
        glClear(GL_COLOR_BUFFER_BIT);

        glUseProgram(presentProgram);
        if (presentTexUniform != -1) glUniform1i(presentTexUniform, 0);
        if (presentUseColorKeyUniform != -1) glUniform1i(presentUseColorKeyUniform, useColorKeyTransparency ? 1 : 0);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, fAlbedo);
        glBindVertexArray(presentVao);
        glDrawArrays(GL_TRIANGLES, 0, 6);
        glBindVertexArray(0);
    }

    void postProcessScene() {
        if (postProcessingStack.length == 0) return;

        bool targetBuffer;
        auto clearColor = inClearColor;

        int viewportWidth;
        int viewportHeight;
        getViewport(viewportWidth, viewportHeight);

        vec4 area = vec4(0, 0, viewportWidth, viewportHeight);

        float[] data = [
            area.x,         area.y + area.w,          0, 0,
            area.x,         area.y,                   0, 1,
            area.x + area.z,area.y + area.w,          1, 0,

            area.x + area.z,area.y + area.w,          1, 0,
            area.x,         area.y,                   0, 1,
            area.x + area.z,area.y,                   1, 1,
        ];
        glBindBuffer(GL_ARRAY_BUFFER, sceneVBO);
        glBufferData(GL_ARRAY_BUFFER, 24 * float.sizeof, data.ptr, GL_DYNAMIC_DRAW);

        glActiveTexture(GL_TEXTURE1);
        glBindTexture(GL_TEXTURE_2D, fEmissive);
        glGenerateMipmap(GL_TEXTURE_2D);

        glBindFramebuffer(GL_FRAMEBUFFER, cfBuffer);
        glDrawBuffers(3, [GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2].ptr);
        glClearColor(clearColor.r, clearColor.g, clearColor.b, clearColor.a);
        glClear(GL_COLOR_BUFFER_BIT);

        glBindFramebuffer(GL_FRAMEBUFFER, fBuffer);
        glDrawBuffers(3, [GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2].ptr);

        foreach (shader; postProcessingStack) {
            targetBuffer = !targetBuffer;
            if (targetBuffer) {
                glBindFramebuffer(GL_FRAMEBUFFER, cfBuffer);
                renderScene(area, shader, fAlbedo, fEmissive, fBump);
            } else {
                glBindFramebuffer(GL_FRAMEBUFFER, fBuffer);
                renderScene(area, shader, cfAlbedo, cfEmissive, cfBump);
            }
        }

        if (targetBuffer) {
            glBindFramebuffer(GL_READ_FRAMEBUFFER, cfBuffer);
            glBindFramebuffer(GL_DRAW_FRAMEBUFFER, fBuffer);
            glBlitFramebuffer(
                0, 0, viewportWidth, viewportHeight,
                0, 0, viewportWidth, viewportHeight,
                GL_COLOR_BUFFER_BIT,
                GL_LINEAR
            );
        }

        glBindFramebuffer(GL_FRAMEBUFFER, 0);
    }

    // drawTexture* helpers removed; viewer uses packet-driven path only.

    void drawPartPacket(ref PartDrawPacket packet) {
        auto textures = packet.textures;
        if (textures.length == 0) return;

        bindDrawableVao();

        if (boundAlbedo !is textures[0]) {
            foreach (i, ref tex; textures) {
                if (tex !is null) {
                    tex.bind(cast(uint)i);
                } else {
                    glActiveTexture(GL_TEXTURE0 + cast(uint)i);
                    glBindTexture(GL_TEXTURE_2D, 0);
                }
            }
            boundAlbedo = textures[0];
        }

        auto matrix = packet.modelMatrix;
        mat4 renderMatrix = packet.renderMatrix;

        if (packet.isMask) {
            mat4 mvpMatrix = renderMatrix * matrix;

            partMaskShader.use();
            partMaskShader.setUniform(offset, packet.origin);
            partMaskShader.setUniform(mmvp, mvpMatrix);
            partMaskShader.setUniform(mthreshold, packet.maskThreshold);

            glBlendEquation(GL_FUNC_ADD);
            glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);

            renderStage(packet, false);
        } else {
            if (packet.useMultistageBlend) {
                setupShaderStage(packet, 0, matrix, renderMatrix);
                renderStage(packet, true);

                if (packet.hasEmissionOrBumpmap) {
                    setupShaderStage(packet, 1, matrix, renderMatrix);
                    renderStage(packet, false);
                }
            } else {
                setupShaderStage(packet, 2, matrix, renderMatrix);
                renderStage(packet, false);
            }
        }

        glDrawBuffers(3, [GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2].ptr);
        glBlendEquation(GL_FUNC_ADD);
    }

    void drawPartPacket(ref const(NjgPartDrawPacket) packet, Texture[size_t] texturesByHandle) {
        if (packet.textureCount == 0) return;

        bindDrawableVao();

        Texture currentAlbedo = null;
        if (auto tex = packet.textureHandles[0] in texturesByHandle) {
            currentAlbedo = *tex;
        }
        if (boundAlbedo !is currentAlbedo) {
            auto textureCount = min(packet.textureCount, packet.textureHandles.length);
            foreach (i; 0 .. textureCount) {
                auto handle = packet.textureHandles[i];
                if (auto tex = handle in texturesByHandle) {
                    if (*tex !is null) {
                        (*tex).bind(cast(uint)i);
                    } else {
                        glActiveTexture(GL_TEXTURE0 + cast(uint)i);
                        glBindTexture(GL_TEXTURE_2D, 0);
                    }
                } else {
                    glActiveTexture(GL_TEXTURE0 + cast(uint)i);
                    glBindTexture(GL_TEXTURE_2D, 0);
                }
            }
            boundAlbedo = currentAlbedo;
        }

        auto matrix = *cast(mat4*)&packet.modelMatrix;
        auto renderMatrix = *cast(mat4*)&packet.renderMatrix;

        if (packet.isMask) {
            mat4 mvpMatrix = renderMatrix * matrix;

            partMaskShader.use();
            partMaskShader.setUniform(offset, *cast(vec2*)&packet.origin);
            partMaskShader.setUniform(mmvp, mvpMatrix);
            partMaskShader.setUniform(mthreshold, packet.maskThreshold);

            glBlendEquation(GL_FUNC_ADD);
            glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);

            renderStage(packet, false);
        } else {
            if (packet.useMultistageBlend) {
                setupShaderStage(packet, 0, matrix, renderMatrix);
                renderStage(packet, true);

                if (packet.hasEmissionOrBumpmap) {
                    setupShaderStage(packet, 1, matrix, renderMatrix);
                    renderStage(packet, false);
                }
            } else {
                setupShaderStage(packet, 2, matrix, renderMatrix);
                renderStage(packet, false);
            }
        }

        glDrawBuffers(3, [GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2].ptr);
        glBlendEquation(GL_FUNC_ADD);
    }

    void beginDynamicComposite(DynamicCompositePass pass) {
        if (pass is null) {
            return;
        }
        auto surface = pass.surface;
        if (surface is null) {
            return;
        }
        if (surface.textureCount == 0) {
            return;
        }
        auto tex = surface.textures[0];
        if (tex is null) {
            return;
        }

        if (surface.framebuffer == 0) {
            surface.framebuffer = acquireDynamicFramebuffer(
                surface.textureHandles,
                surface.textureCount,
                surface.stencilHandle
            );
        }

        GLint previousFramebuffer;
        GLint previousReadFramebuffer;
        glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &previousFramebuffer);
        glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &previousReadFramebuffer);
        pass.origBuffer = cast(RenderResourceHandle)previousFramebuffer;
        glGetIntegerv(GL_VIEWPORT, pass.origViewport.ptr);

        glBindFramebuffer(GL_FRAMEBUFFER, cast(GLuint)surface.framebuffer);

        GLuint[3] drawBuffers;
        size_t bufferCount;
        foreach (i; 0 .. surface.textureCount) {
            auto attachment = GL_COLOR_ATTACHMENT0 + cast(GLenum)i;
            auto attachmentTexture = surface.textures[i];
            if (attachmentTexture !is null) {
                glFramebufferTexture2D(GL_FRAMEBUFFER, attachment, GL_TEXTURE_2D, textureId(attachmentTexture), 0);
                drawBuffers[bufferCount++] = attachment;
            } else {
                glFramebufferTexture2D(GL_FRAMEBUFFER, attachment, GL_TEXTURE_2D, 0, 0);
            }
        }

        if (bufferCount == 0) {
            drawBuffers[bufferCount++] = GL_COLOR_ATTACHMENT0;
        }

        if (surface.stencil !is null) {
            glFramebufferTexture2D(GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT, GL_TEXTURE_2D, textureId(surface.stencil), 0);
            glClear(GL_STENCIL_BUFFER_BIT);
            pass.hasStencil = true;
        } else {
            glFramebufferTexture2D(GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT, GL_TEXTURE_2D, 0, 0);
            pass.hasStencil = false;
        }

        pushViewport(tex.width, tex.height);

        glDrawBuffers(cast(int)bufferCount, drawBuffers.ptr);
        pass.drawBufferCount = cast(int)bufferCount;
        glViewport(0, 0, tex.width, tex.height);
        glClearColor(0, 0, 0, 0);
        glClear(GL_COLOR_BUFFER_BIT);
        glActiveTexture(GL_TEXTURE0);
        glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);

    }

    void endDynamicComposite(DynamicCompositePass pass) {
        if (pass is null) {
            return;
        }
        if (pass.surface is null) {
            return;
        }

        rebindActiveTargets();

        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, cast(GLuint)pass.origBuffer);
        glBindFramebuffer(GL_READ_FRAMEBUFFER, cast(GLuint)pass.origBuffer);
        popViewport();
        glViewport(pass.origViewport[0], pass.origViewport[1],
            pass.origViewport[2], pass.origViewport[3]);
        if (pass.origBuffer != 0) {
            GLuint[3] bufs = [GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2];
            glDrawBuffers(3, bufs.ptr);
        } else {
            glBindFramebuffer(GL_READ_FRAMEBUFFER, 0);
            glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0);
            glReadBuffer(GL_BACK);
            glDrawBuffer(GL_BACK);
        }
    }

    void beginMask(bool useStencil) {
        glEnable(GL_STENCIL_TEST);
        glClearStencil(useStencil ? 0 : 1);
        glClear(GL_STENCIL_BUFFER_BIT);
        glStencilMask(0xFF);
        glStencilFunc(GL_ALWAYS, useStencil ? 0 : 1, 0xFF);
        glStencilOp(GL_KEEP, GL_KEEP, GL_KEEP);
    }

    void applyMask(ref MaskApplyPacket packet) {
        ensureMaskBackendInitialized();
        glColorMask(GL_FALSE, GL_FALSE, GL_FALSE, GL_FALSE);
        glStencilOp(GL_KEEP, GL_KEEP, GL_REPLACE);
        glStencilFunc(GL_ALWAYS, packet.isDodge ? 0 : 1, 0xFF);
        glStencilMask(0xFF);

        final switch (packet.kind) {
            case MaskDrawableKind.Part:
                drawPartPacket(packet.partPacket);
                break;
            case MaskDrawableKind.Mask:
                executeMaskPacket(packet.maskPacket);
                break;
        }

        glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
    }

    void applyMask(ref const(NjgMaskApplyPacket) packet, Texture[size_t] texturesByHandle) {
        ensureMaskBackendInitialized();
        glColorMask(GL_FALSE, GL_FALSE, GL_FALSE, GL_FALSE);
        glStencilOp(GL_KEEP, GL_KEEP, GL_REPLACE);
        glStencilFunc(GL_ALWAYS, packet.isDodge ? 0 : 1, 0xFF);
        glStencilMask(0xFF);

        final switch (packet.kind) {
            case MaskDrawableKind.Part:
                drawPartPacket(packet.partPacket, texturesByHandle);
                break;
            case MaskDrawableKind.Mask:
                executeMaskPacket(packet.maskPacket);
                break;
        }

        glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
    }

    void beginMaskContent() {
        glStencilFunc(GL_EQUAL, 1, 0xFF);
        glStencilMask(0x00);
    }

    void endMask() {
        glStencilMask(0xFF);
        glStencilFunc(GL_ALWAYS, 1, 0xFF);
        glDisable(GL_STENCIL_TEST);
    }

    RenderResourceHandle framebufferHandle() {
        return cast(RenderResourceHandle)fBuffer;
    }

    void useShader(GLShaderHandle shader) {
        auto handle = shader;
        glUseProgram(handle.shader.program);
    }

    GLShaderHandle createShader(string vertexSource, string fragmentSource) {
        auto handle = new GLShaderHandle();
        handle.shader.vert = glCreateShader(GL_VERTEX_SHADER);
        auto vsrc = vertexSource.toStringz;
        glShaderSource(handle.shader.vert, 1, &vsrc, null);
        glCompileShader(handle.shader.vert);
        checkShader(handle.shader.vert);

        handle.shader.frag = glCreateShader(GL_FRAGMENT_SHADER);
        auto fsrc = fragmentSource.toStringz;
        glShaderSource(handle.shader.frag, 1, &fsrc, null);
        glCompileShader(handle.shader.frag);
        checkShader(handle.shader.frag);

        handle.shader.program = glCreateProgram();
        glAttachShader(handle.shader.program, handle.shader.vert);
        glAttachShader(handle.shader.program, handle.shader.frag);
        glLinkProgram(handle.shader.program);
        checkProgram(handle.shader.program);
        return handle;
    }

    void destroyShader(GLShaderHandle shader) {
        auto handle = shader;
        if (handle.shader.program) {
            glDetachShader(handle.shader.program, handle.shader.vert);
            glDetachShader(handle.shader.program, handle.shader.frag);
            glDeleteProgram(handle.shader.program);
        }
        if (handle.shader.vert) glDeleteShader(handle.shader.vert);
        if (handle.shader.frag) glDeleteShader(handle.shader.frag);
        handle.shader = ShaderProgramHandle.init;
    }

    int getShaderUniformLocation(GLShaderHandle shader, string name) {
        auto handle = shader;
        return glGetUniformLocation(handle.shader.program, name.toStringz);
    }

    void setShaderUniform(GLShaderHandle _shader, int location, bool value) {
        glUniform1i(location, value ? 1 : 0);
    }

    void setShaderUniform(GLShaderHandle _shader, int location, int value) {
        glUniform1i(location, value);
    }

    void setShaderUniform(GLShaderHandle _shader, int location, float value) {
        glUniform1f(location, value);
    }

    void setShaderUniform(GLShaderHandle _shader, int location, vec2 value) {
        glUniform2f(location, value.x, value.y);
    }

    void setShaderUniform(GLShaderHandle _shader, int location, vec3 value) {
        glUniform3f(location, value.x, value.y, value.z);
    }

    void setShaderUniform(GLShaderHandle _shader, int location, vec4 value) {
        glUniform4f(location, value.x, value.y, value.z, value.w);
    }

    void setShaderUniform(GLShaderHandle _shader, int location, mat4 value) {
        glUniformMatrix4fv(location, 1, GL_TRUE, value.ptr);
    }

    GLTextureHandle createTextureHandle() {
        auto handle = new GLTextureHandle();
        GLuint textureId;
        glGenTextures(1, &textureId);
        enforce(textureId != 0, "Failed to create texture");
        handle.id = textureId;
        return handle;
    }

    void destroyTextureHandle(GLTextureHandle texture) {
        auto handle = texture;
        if (handle.id) {
            GLuint textureId = handle.id;
            glDeleteTextures(1, &textureId);
        }
        handle.id = 0;
    }

    void bindTextureHandle(GLTextureHandle texture, uint unit) {
        auto handle = texture;
        glActiveTexture(GL_TEXTURE0 + (unit <= 31 ? unit : 31));
        glBindTexture(GL_TEXTURE_2D, handle.id);
    }

    void uploadTextureData(GLTextureHandle texture, int width, int height,
                                    int inChannels, int outChannels, bool stencil,
                                    ubyte[] data) {
        auto handle = texture;
        glBindTexture(GL_TEXTURE_2D, handle.id);
        if (stencil) {
            glTexImage2D(GL_TEXTURE_2D, 0, GL_DEPTH24_STENCIL8, width, height, 0, GL_DEPTH_STENCIL, GL_UNSIGNED_INT_24_8, null);
            return;
        }
        glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
        glPixelStorei(GL_PACK_ALIGNMENT, 1);
        auto inFormat = channelFormat(inChannels);
        auto outFormat = channelFormat(outChannels);
        glTexImage2D(GL_TEXTURE_2D, 0, outFormat, width, height, 0, inFormat, GL_UNSIGNED_BYTE, data.ptr);
    }

    void generateTextureMipmap(GLTextureHandle texture) {
        auto handle = texture;
        glBindTexture(GL_TEXTURE_2D, handle.id);
        glGenerateMipmap(GL_TEXTURE_2D);
    }

    void applyTextureFiltering(GLTextureHandle texture, Filtering filtering, bool useMipmaps = true) {
        auto handle = texture;
        glBindTexture(GL_TEXTURE_2D, handle.id);
        bool linear = filtering == Filtering.Linear;
        auto minFilter = useMipmaps
            ? (linear ? GL_LINEAR_MIPMAP_LINEAR : GL_NEAREST_MIPMAP_NEAREST)
            : (linear ? GL_LINEAR : GL_NEAREST);
        auto magFilter = linear ? GL_LINEAR : GL_NEAREST;
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, minFilter);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, magFilter);
    }

    void applyTextureWrapping(GLTextureHandle texture, Wrapping wrapping) {
        auto handle = texture;
        glBindTexture(GL_TEXTURE_2D, handle.id);
        GLint wrapValue;
        switch (wrapping) {
            case Wrapping.Clamp: wrapValue = GL_CLAMP_TO_BORDER; break;
            case Wrapping.Repeat: wrapValue = GL_REPEAT; break;
            case Wrapping.Mirror: wrapValue = GL_MIRRORED_REPEAT; break;
            default: wrapValue = GL_CLAMP_TO_BORDER; break;
        }
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, wrapValue);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, wrapValue);
        if (wrapping == Wrapping.Clamp) {
            glTexParameterfv(GL_TEXTURE_2D, GL_TEXTURE_BORDER_COLOR, [0f, 0f, 0f, 0f].ptr);
        }
    }

    void applyTextureAnisotropy(GLTextureHandle texture, float value) {
        auto handle = texture;
        glBindTexture(GL_TEXTURE_2D, handle.id);
        glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_MAX_ANISOTROPY, value);
    }

    float maxTextureAnisotropy() {
        float max;
        glGetFloatv(GL_MAX_TEXTURE_MAX_ANISOTROPY, &max);
        return max;
    }

    void readTextureData(GLTextureHandle texture, int channels, bool stencil,
                                  ubyte[] buffer) {
        auto handle = texture;
        glBindTexture(GL_TEXTURE_2D, handle.id);
        GLuint format = stencil ? GL_DEPTH_STENCIL : channelFormat(channels);
        glGetTexImage(GL_TEXTURE_2D, 0, format, GL_UNSIGNED_BYTE, buffer.ptr);
    }

private:
    void pushViewport(int width, int height) {
        viewportWidthStack ~= width;
        viewportHeightStack ~= height;
    }

    void popViewport() {
        if (viewportWidthStack.length > 1) {
            viewportWidthStack.length = viewportWidthStack.length - 1;
            viewportHeightStack.length = viewportHeightStack.length - 1;
        }
    }

    void getViewport(out int width, out int height) {
        if (viewportWidthStack.length == 0) {
            width = 0;
            height = 0;
            return;
        }
        width = viewportWidthStack[$-1];
        height = viewportHeightStack[$-1];
    }

    void createDrawableBuffers(ref RenderResourceHandle ibo) {
        ensureDrawableBackendInitialized();
        if (ibo == 0) {
            ibo = nextIndexHandle++;
        }
    }

    void uploadDrawableIndices(RenderResourceHandle ibo, const(ushort)[] indices) {
        if (ibo == 0 || indices.length == 0) return;
        auto bytes = cast(size_t)indices.length * ushort.sizeof;
        ensureSharedIndexBuffer(bytes + sharedIndexOffset);

        IndexRange range;
        auto existing = ibo in sharedIndexRanges;
        if (existing !is null) {
            range = *existing;
        }
        if (existing is null || bytes > range.capacity) {
            range.offset = sharedIndexOffset;
            range.count = indices.length;
            range.capacity = bytes;
            sharedIndexOffset += bytes;
        } else {
            range.count = indices.length;
        }
        range.data = indices.dup;
        sharedIndexRanges[ibo] = range;
        glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, sharedIndexBuffer);
        glBufferSubData(GL_ELEMENT_ARRAY_BUFFER, cast(GLintptr)range.offset, bytes, indices.ptr);
    }

    void ensureMaskBackendInitialized() {
        if (maskBackendInitialized) return;
        maskBackendInitialized = true;

        maskShader = new Shader(MaskShaderSource);
        maskOffsetUniform = maskShader.getUniformLocation("offset");
        maskMvpUniform = maskShader.getUniformLocation("mvp");
    }

    void ensureSharedIndexBuffer(size_t bytes) {
        if (sharedIndexBuffer == 0) {
            glGenBuffers(1, &sharedIndexBuffer);
            sharedIndexCapacity = 0;
            sharedIndexOffset = 0;
        }
        if (bytes > sharedIndexCapacity) {
            size_t newCap = sharedIndexCapacity == 0 ? 1024 : sharedIndexCapacity;
            while (newCap < bytes) newCap *= 2;
            glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, sharedIndexBuffer);
            glBufferData(GL_ELEMENT_ARRAY_BUFFER, newCap, null, GL_DYNAMIC_DRAW);
            sharedIndexCapacity = newCap;
            sharedIndexOffset = 0;
            foreach (key, ref entry; sharedIndexRanges) {
                if (entry.data.length == 0) continue;
                auto entryBytes = cast(size_t)entry.data.length * ushort.sizeof;
                entry.offset = sharedIndexOffset;
                entry.count = entry.data.length;
                entry.capacity = entryBytes;
                glBufferSubData(GL_ELEMENT_ARRAY_BUFFER, cast(GLintptr)entry.offset, entryBytes, entry.data.ptr);
                sharedIndexOffset += entryBytes;
            }
        }
    }

    void ensureDebugRendererInitialized() {
        if (debugVao != 0) return;
        glGenVertexArrays(1, &debugVao);
        glGenBuffers(1, &debugVbo);
        glGenBuffers(1, &debugIbo);
        debugCurrentVbo = debugVbo;
        debugIndexCount = 0;
    }

    GLuint textureId(Texture texture) {
        if (texture is null) return 0;
        auto handle = texture.backendHandle();
        if (handle is null) return 0;
        return handle.id;
    }

    void renderScene(vec4 area, PostProcessingShader shaderToUse, GLuint albedo, GLuint emissive, GLuint bump) {
        glViewport(0, 0, cast(int)area.z, cast(int)area.w);

        glBindVertexArray(sceneVAO);

        glDisable(GL_CULL_FACE);
        glDisable(GL_DEPTH_TEST);
        glEnable(GL_BLEND);
        glBlendEquation(GL_FUNC_ADD);
        glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);

        shaderToUse.shader.use();
        shaderToUse.shader.setUniform(shaderToUse.getUniform("mvp"),
            mat4.orthographic(0, area.z, area.w, 0, 0, max(area.z, area.w)) *
            mat4.translation(area.x, area.y, 0)
        );

        GLint ambientLightUniform = shaderToUse.getUniform("ambientLight");
        if (ambientLightUniform != -1) shaderToUse.shader.setUniform(ambientLightUniform, inSceneAmbientLight);

        GLint fbSizeUniform = shaderToUse.getUniform("fbSize");
        int viewportWidth;
        int viewportHeight;
        getViewport(viewportWidth, viewportHeight);
        if (fbSizeUniform != -1) shaderToUse.shader.setUniform(fbSizeUniform, vec2(viewportWidth, viewportHeight));

        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, albedo);
        glActiveTexture(GL_TEXTURE1);
        glBindTexture(GL_TEXTURE_2D, emissive);
        glActiveTexture(GL_TEXTURE2);
        glBindTexture(GL_TEXTURE_2D, bump);

        glEnableVertexAttribArray(0);
        glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 4 * float.sizeof, null);

        glEnableVertexAttribArray(1);
        glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 4 * float.sizeof, cast(float*)(2 * float.sizeof));

        glDrawArrays(GL_TRIANGLES, 0, 6);

        glDisableVertexAttribArray(0);
        glDisableVertexAttribArray(1);

        glDisable(GL_BLEND);
    }

    bool supportsAdvancedBlend() {
        return hasKHRBlendEquationAdvanced;
    }

    bool supportsAdvancedBlendCoherent() {
        return hasKHRBlendEquationAdvancedCoherent;
    }

    void applyBlendingCapabilities() {
        bool desiredAdvanced = supportsAdvancedBlend();
        bool desiredCoherent = supportsAdvancedBlendCoherent();
        if (desiredCoherent != advancedBlendingCoherent) {
            setAdvancedBlendCoherent(desiredCoherent);
        }
        advancedBlending = desiredAdvanced;
        advancedBlendingCoherent = desiredCoherent;
    }

    void setAdvancedBlendCoherent(bool enabled) {
        // Fallback backend: advanced coherent mode is unavailable.
        advancedBlendingCoherent = enabled;
    }

    void setLegacyBlendMode(BlendMode mode) {
        switch (mode) {
            case BlendMode.Normal:
                glBlendEquation(GL_FUNC_ADD);
                glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
                break;
            case BlendMode.Multiply:
                glBlendEquation(GL_FUNC_ADD);
                glBlendFunc(GL_DST_COLOR, GL_ONE_MINUS_SRC_ALPHA);
                break;
            case BlendMode.Screen:
                glBlendEquation(GL_FUNC_ADD);
                glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_COLOR);
                break;
            case BlendMode.Lighten:
                glBlendEquation(GL_MAX);
                glBlendFunc(GL_ONE, GL_ONE);
                break;
            case BlendMode.ColorDodge:
                glBlendEquation(GL_FUNC_ADD);
                glBlendFunc(GL_DST_COLOR, GL_ONE);
                break;
            case BlendMode.LinearDodge:
                glBlendEquation(GL_FUNC_ADD);
                glBlendFuncSeparate(GL_ONE, GL_ONE_MINUS_SRC_COLOR, GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
                break;
            case BlendMode.AddGlow:
                glBlendEquation(GL_FUNC_ADD);
                glBlendFuncSeparate(GL_ONE, GL_ONE, GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
                break;
            case BlendMode.Subtract:
                glBlendEquationSeparate(GL_FUNC_REVERSE_SUBTRACT, GL_FUNC_ADD);
                glBlendFunc(GL_ONE_MINUS_DST_COLOR, GL_ONE);
                break;
            case BlendMode.Exclusion:
                glBlendEquation(GL_FUNC_ADD);
                glBlendFuncSeparate(GL_ONE_MINUS_DST_COLOR, GL_ONE_MINUS_SRC_COLOR, GL_ONE, GL_ONE);
                break;
            case BlendMode.Inverse:
                glBlendEquation(GL_FUNC_ADD);
                glBlendFunc(GL_ONE_MINUS_DST_COLOR, GL_ONE_MINUS_SRC_ALPHA);
                break;
            case BlendMode.DestinationIn:
                glBlendEquation(GL_FUNC_ADD);
                glBlendFunc(GL_ZERO, GL_SRC_ALPHA);
                break;
            case BlendMode.ClipToLower:
                glBlendEquation(GL_FUNC_ADD);
                glBlendFunc(GL_DST_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
                break;
            case BlendMode.SliceFromLower:
                glBlendEquation(GL_FUNC_ADD);
                glBlendFunc(GL_ZERO, GL_ONE_MINUS_SRC_ALPHA);
                break;
            default:
                glBlendEquation(GL_FUNC_ADD);
                glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
                break;
        }
    }

    void setAdvancedBlendEquation(BlendMode mode) {
        // Fallback: use legacy equation path.
        setLegacyBlendMode(mode);
    }

    bool isAdvancedBlendMode(BlendMode mode) const {
        switch(mode) {
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
            default:
                return false;
        }
    }

    void applyBlendMode(BlendMode mode, bool legacyOnly=false) {
        if (!advancedBlending || legacyOnly) setLegacyBlendMode(mode);
        else setAdvancedBlendEquation(mode);
    }

    void blendModeBarrier(BlendMode mode) {
        if (advancedBlending && !advancedBlendingCoherent && isAdvancedBlendMode(mode))
            issueBlendBarrier();
    }

    void issueBlendBarrier() {
        // no-op when advanced blend barrier is unavailable
    }

    void ensureDrawableBackendInitialized() {
        if (drawableBuffersInitialized) return;
        drawableBuffersInitialized = true;
        glGenVertexArrays(1, &drawableVAO);
    }

    void drawDrawableElements(RenderResourceHandle ibo, size_t indexCount) {
        if (ibo == 0 || indexCount == 0) return;
        auto rangePtr = ibo in sharedIndexRanges;
        if (rangePtr is null || sharedIndexBuffer == 0) return;
        glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, sharedIndexBuffer);
        auto offset = rangePtr.offset;
        glDrawElements(GL_TRIANGLES, cast(int)indexCount, GL_UNSIGNED_SHORT, cast(void*)offset);
    }

    void executeMaskPacket(ref MaskDrawPacket packet) {
        ensureMaskBackendInitialized();
        if (packet.indexCount == 0) return;

        bindDrawableVao();

        maskShader.use();
        maskShader.setUniform(maskOffsetUniform, packet.origin);
        maskShader.setUniform(maskMvpUniform, packet.mvp);

        if (packet.vertexCount == 0 || packet.vertexAtlasStride == 0 || packet.deformAtlasStride == 0) return;
        auto sharedVbo = sharedVertexBufferHandle();
        auto sharedDbo = sharedDeformBufferHandle();
        if (sharedVbo == 0 || sharedDbo == 0) return;
        auto vertexOffsetBytes = cast(ptrdiff_t)packet.vertexOffset * float.sizeof;
        auto vertexStrideBytes = cast(ptrdiff_t)packet.vertexAtlasStride * float.sizeof;
        auto vertexLane1Offset = vertexStrideBytes + vertexOffsetBytes;
        auto deformOffsetBytes = cast(ptrdiff_t)packet.deformOffset * float.sizeof;
        auto deformStrideBytes = cast(ptrdiff_t)packet.deformAtlasStride * float.sizeof;
        auto deformLane1Offset = deformStrideBytes + deformOffsetBytes;

        glEnableVertexAttribArray(0);
        glBindBuffer(GL_ARRAY_BUFFER, sharedVbo);
        glVertexAttribPointer(0, 1, GL_FLOAT, GL_FALSE, 0, cast(void*)vertexOffsetBytes);

        glEnableVertexAttribArray(1);
        glBindBuffer(GL_ARRAY_BUFFER, sharedVbo);
        glVertexAttribPointer(1, 1, GL_FLOAT, GL_FALSE, 0, cast(void*)vertexLane1Offset);

        glEnableVertexAttribArray(2);
        glBindBuffer(GL_ARRAY_BUFFER, sharedDbo);
        glVertexAttribPointer(2, 1, GL_FLOAT, GL_FALSE, 0, cast(void*)deformOffsetBytes);

        glEnableVertexAttribArray(3);
        glBindBuffer(GL_ARRAY_BUFFER, sharedDbo);
        glVertexAttribPointer(3, 1, GL_FLOAT, GL_FALSE, 0, cast(void*)deformLane1Offset);

        drawDrawableElements(packet.indexBuffer, packet.indexCount);
        glDisableVertexAttribArray(0);
        glDisableVertexAttribArray(1);
        glDisableVertexAttribArray(2);
        glDisableVertexAttribArray(3);
    }

    void executeMaskPacket(ref const(NjgMaskDrawPacket) packet) {
        ensureMaskBackendInitialized();
        if (packet.indexCount == 0) return;

        bindDrawableVao();

        maskShader.use();
        maskShader.setUniform(maskOffsetUniform, *cast(vec2*)&packet.origin);
        maskShader.setUniform(maskMvpUniform, *cast(mat4*)&packet.mvp);

        if (packet.vertexCount == 0 || packet.vertexAtlasStride == 0 || packet.deformAtlasStride == 0) return;
        auto sharedVbo = sharedVertexBufferHandle();
        auto sharedDbo = sharedDeformBufferHandle();
        if (sharedVbo == 0 || sharedDbo == 0) return;
        auto vertexOffsetBytes = cast(ptrdiff_t)packet.vertexOffset * float.sizeof;
        auto vertexStrideBytes = cast(ptrdiff_t)packet.vertexAtlasStride * float.sizeof;
        auto vertexLane1Offset = vertexStrideBytes + vertexOffsetBytes;
        auto deformOffsetBytes = cast(ptrdiff_t)packet.deformOffset * float.sizeof;
        auto deformStrideBytes = cast(ptrdiff_t)packet.deformAtlasStride * float.sizeof;
        auto deformLane1Offset = deformStrideBytes + deformOffsetBytes;

        glEnableVertexAttribArray(0);
        glBindBuffer(GL_ARRAY_BUFFER, sharedVbo);
        glVertexAttribPointer(0, 1, GL_FLOAT, GL_FALSE, 0, cast(void*)vertexOffsetBytes);

        glEnableVertexAttribArray(1);
        glBindBuffer(GL_ARRAY_BUFFER, sharedVbo);
        glVertexAttribPointer(1, 1, GL_FLOAT, GL_FALSE, 0, cast(void*)vertexLane1Offset);

        glEnableVertexAttribArray(2);
        glBindBuffer(GL_ARRAY_BUFFER, sharedDbo);
        glVertexAttribPointer(2, 1, GL_FLOAT, GL_FALSE, 0, cast(void*)deformOffsetBytes);

        glEnableVertexAttribArray(3);
        glBindBuffer(GL_ARRAY_BUFFER, sharedDbo);
        glVertexAttribPointer(3, 1, GL_FLOAT, GL_FALSE, 0, cast(void*)deformLane1Offset);

        auto ibo = getOrCreateIbo(packet.indices, packet.indexCount);
        drawDrawableElements(ibo, packet.indexCount);
        glDisableVertexAttribArray(0);
        glDisableVertexAttribArray(1);
        glDisableVertexAttribArray(2);
        glDisableVertexAttribArray(3);
    }

    void setupShaderStage(ref PartDrawPacket packet, int stage, mat4 matrix, mat4 renderMatrix) {
        mat4 mvpMatrix = renderMatrix * matrix;

        auto setDrawBuffersSafe = (int desired) {
            GLenum[3] bufs;
            int count = 0;
            auto addIfPresent = (GLenum att) {
                GLint type = GL_NONE;
                glGetFramebufferAttachmentParameteriv(GL_DRAW_FRAMEBUFFER, att,
                    GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE, &type);
                if (type != GL_NONE) {
                    bufs[count++] = att;
                }
            };
            addIfPresent(GL_COLOR_ATTACHMENT0);
            if (desired > 1) addIfPresent(GL_COLOR_ATTACHMENT1);
            if (desired > 2) addIfPresent(GL_COLOR_ATTACHMENT2);
            if (count == 0) {
                glDrawBuffer(GL_BACK);
            } else {
                glDrawBuffers(count, bufs.ptr);
            }
            return count;
        };

        switch (stage) {
            case 0:
                setDrawBuffersSafe(1);
                partShaderStage1.use();
                partShaderStage1.setUniform(gs1offset, packet.origin);
                partShaderStage1.setUniform(gs1mvp, mvpMatrix);
                partShaderStage1.setUniform(gs1opacity, packet.opacity);
                partShaderStage1.setUniform(gs1MultColor, packet.clampedTint);
                partShaderStage1.setUniform(gs1ScreenColor, packet.clampedScreen);
                applyBlendMode(packet.blendingMode, false);
                break;
            case 1:
                setDrawBuffersSafe(2);
                partShaderStage2.use();
                partShaderStage2.setUniform(gs2offset, packet.origin);
                partShaderStage2.setUniform(gs2mvp, mvpMatrix);
                partShaderStage2.setUniform(gs2opacity, packet.opacity);
                partShaderStage2.setUniform(gs2EmissionStrength, packet.emissionStrength);
                partShaderStage2.setUniform(gs2MultColor, packet.clampedTint);
                partShaderStage2.setUniform(gs2ScreenColor, packet.clampedScreen);
                applyBlendMode(packet.blendingMode, true);
                break;
            case 2:
                setDrawBuffersSafe(3);
                partShader.use();
                partShader.setUniform(offset, packet.origin);
                partShader.setUniform(mvp, mvpMatrix);
                partShader.setUniform(gopacity, packet.opacity);
                partShader.setUniform(gEmissionStrength, packet.emissionStrength);
                partShader.setUniform(gMultColor, packet.clampedTint);
                partShader.setUniform(gScreenColor, packet.clampedScreen);
                applyBlendMode(packet.blendingMode, true);
                break;
            default:
                return;
        }
    }

    void setupShaderStage(ref const(NjgPartDrawPacket) packet, int stage, mat4 matrix, mat4 renderMatrix) {
        mat4 mvpMatrix = renderMatrix * matrix;

        auto setDrawBuffersSafe = (int desired) {
            GLenum[3] bufs;
            int count = 0;
            auto addIfPresent = (GLenum att) {
                GLint type = GL_NONE;
                glGetFramebufferAttachmentParameteriv(GL_DRAW_FRAMEBUFFER, att,
                    GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE, &type);
                if (type != GL_NONE) {
                    bufs[count++] = att;
                }
            };
            addIfPresent(GL_COLOR_ATTACHMENT0);
            if (desired > 1) addIfPresent(GL_COLOR_ATTACHMENT1);
            if (desired > 2) addIfPresent(GL_COLOR_ATTACHMENT2);
            if (count == 0) {
                glDrawBuffer(GL_BACK);
            } else {
                glDrawBuffers(count, bufs.ptr);
            }
            return count;
        };

        auto origin = *cast(vec2*)&packet.origin;
        auto clampedTint = *cast(vec3*)&packet.clampedTint;
        auto clampedScreen = *cast(vec3*)&packet.clampedScreen;
        auto blendMode = cast(BlendMode)packet.blendingMode;

        switch (stage) {
            case 0:
                setDrawBuffersSafe(1);
                partShaderStage1.use();
                partShaderStage1.setUniform(gs1offset, origin);
                partShaderStage1.setUniform(gs1mvp, mvpMatrix);
                partShaderStage1.setUniform(gs1opacity, packet.opacity);
                partShaderStage1.setUniform(gs1MultColor, clampedTint);
                partShaderStage1.setUniform(gs1ScreenColor, clampedScreen);
                applyBlendMode(blendMode, false);
                break;
            case 1:
                setDrawBuffersSafe(2);
                partShaderStage2.use();
                partShaderStage2.setUniform(gs2offset, origin);
                partShaderStage2.setUniform(gs2mvp, mvpMatrix);
                partShaderStage2.setUniform(gs2opacity, packet.opacity);
                partShaderStage2.setUniform(gs2EmissionStrength, packet.emissionStrength);
                partShaderStage2.setUniform(gs2MultColor, clampedTint);
                partShaderStage2.setUniform(gs2ScreenColor, clampedScreen);
                applyBlendMode(blendMode, true);
                break;
            case 2:
                setDrawBuffersSafe(3);
                partShader.use();
                partShader.setUniform(offset, origin);
                partShader.setUniform(mvp, mvpMatrix);
                partShader.setUniform(gopacity, packet.opacity);
                partShader.setUniform(gEmissionStrength, packet.emissionStrength);
                partShader.setUniform(gMultColor, clampedTint);
                partShader.setUniform(gScreenColor, clampedScreen);
                applyBlendMode(blendMode, true);
                break;
            default:
                return;
        }
    }

    void renderStage(ref PartDrawPacket packet, bool advanced) {
        auto ibo = cast(GLuint)packet.indexBuffer;
        auto indexCount = packet.indexCount;

        if (!ibo || indexCount == 0 || packet.vertexCount == 0) return;
        if (packet.vertexAtlasStride == 0 || packet.uvAtlasStride == 0 || packet.deformAtlasStride == 0) return;

        auto vertexBuffer = sharedVertexBufferHandle();
        auto uvBuffer = sharedUvBufferHandle();
        auto deformBuffer = sharedDeformBufferHandle();
        if (vertexBuffer == 0 || uvBuffer == 0 || deformBuffer == 0) return;

        auto vertexOffsetBytes = cast(ptrdiff_t)packet.vertexOffset * float.sizeof;
        auto uvOffsetBytes = cast(ptrdiff_t)packet.uvOffset * float.sizeof;
        auto deformOffsetBytes = cast(ptrdiff_t)packet.deformOffset * float.sizeof;

        auto vertexStrideBytes = cast(ptrdiff_t)packet.vertexAtlasStride * float.sizeof;
        auto uvStrideBytes = cast(ptrdiff_t)packet.uvAtlasStride * float.sizeof;
        auto deformStrideBytes = cast(ptrdiff_t)packet.deformAtlasStride * float.sizeof;

        auto vertexLane1Offset = vertexStrideBytes + vertexOffsetBytes;
        auto uvLane1Offset = uvStrideBytes + uvOffsetBytes;
        auto deformLane1Offset = deformStrideBytes + deformOffsetBytes;
        glEnableVertexAttribArray(0);
        glBindBuffer(GL_ARRAY_BUFFER, vertexBuffer);
        glVertexAttribPointer(0, 1, GL_FLOAT, GL_FALSE, 0, cast(void*)vertexOffsetBytes);

        glEnableVertexAttribArray(1);
        glBindBuffer(GL_ARRAY_BUFFER, vertexBuffer);
        glVertexAttribPointer(1, 1, GL_FLOAT, GL_FALSE, 0, cast(void*)vertexLane1Offset);

        glEnableVertexAttribArray(2);
        glBindBuffer(GL_ARRAY_BUFFER, uvBuffer);
        glVertexAttribPointer(2, 1, GL_FLOAT, GL_FALSE, 0, cast(void*)uvOffsetBytes);

        glEnableVertexAttribArray(3);
        glBindBuffer(GL_ARRAY_BUFFER, uvBuffer);
        glVertexAttribPointer(3, 1, GL_FLOAT, GL_FALSE, 0, cast(void*)uvLane1Offset);

        glEnableVertexAttribArray(4);
        glBindBuffer(GL_ARRAY_BUFFER, deformBuffer);
        glVertexAttribPointer(4, 1, GL_FLOAT, GL_FALSE, 0, cast(void*)deformOffsetBytes);

        glEnableVertexAttribArray(5);
        glBindBuffer(GL_ARRAY_BUFFER, deformBuffer);
        glVertexAttribPointer(5, 1, GL_FLOAT, GL_FALSE, 0, cast(void*)deformLane1Offset);

        drawDrawableElements(packet.indexBuffer, indexCount);
        glDisableVertexAttribArray(0);
        glDisableVertexAttribArray(1);
        glDisableVertexAttribArray(2);
        glDisableVertexAttribArray(3);
        glDisableVertexAttribArray(4);
        glDisableVertexAttribArray(5);

        if (advanced) {
            blendModeBarrier(packet.blendingMode);
        }
    }

    void renderStage(ref const(NjgPartDrawPacket) packet, bool advanced) {
        auto ibo = getOrCreateIbo(packet.indices, packet.indexCount);
        auto indexCount = cast(uint)packet.indexCount;

        if (!ibo || indexCount == 0 || packet.vertexCount == 0) return;
        if (packet.vertexAtlasStride == 0 || packet.uvAtlasStride == 0 || packet.deformAtlasStride == 0) return;

        auto vertexBuffer = sharedVertexBufferHandle();
        auto uvBuffer = sharedUvBufferHandle();
        auto deformBuffer = sharedDeformBufferHandle();
        if (vertexBuffer == 0 || uvBuffer == 0 || deformBuffer == 0) return;

        auto vertexOffsetBytes = cast(ptrdiff_t)packet.vertexOffset * float.sizeof;
        auto uvOffsetBytes = cast(ptrdiff_t)packet.uvOffset * float.sizeof;
        auto deformOffsetBytes = cast(ptrdiff_t)packet.deformOffset * float.sizeof;

        auto vertexStrideBytes = cast(ptrdiff_t)packet.vertexAtlasStride * float.sizeof;
        auto uvStrideBytes = cast(ptrdiff_t)packet.uvAtlasStride * float.sizeof;
        auto deformStrideBytes = cast(ptrdiff_t)packet.deformAtlasStride * float.sizeof;

        auto vertexLane1Offset = vertexStrideBytes + vertexOffsetBytes;
        auto uvLane1Offset = uvStrideBytes + uvOffsetBytes;
        auto deformLane1Offset = deformStrideBytes + deformOffsetBytes;
        glEnableVertexAttribArray(0);
        glBindBuffer(GL_ARRAY_BUFFER, vertexBuffer);
        glVertexAttribPointer(0, 1, GL_FLOAT, GL_FALSE, 0, cast(void*)vertexOffsetBytes);

        glEnableVertexAttribArray(1);
        glBindBuffer(GL_ARRAY_BUFFER, vertexBuffer);
        glVertexAttribPointer(1, 1, GL_FLOAT, GL_FALSE, 0, cast(void*)vertexLane1Offset);

        glEnableVertexAttribArray(2);
        glBindBuffer(GL_ARRAY_BUFFER, uvBuffer);
        glVertexAttribPointer(2, 1, GL_FLOAT, GL_FALSE, 0, cast(void*)uvOffsetBytes);

        glEnableVertexAttribArray(3);
        glBindBuffer(GL_ARRAY_BUFFER, uvBuffer);
        glVertexAttribPointer(3, 1, GL_FLOAT, GL_FALSE, 0, cast(void*)uvLane1Offset);

        glEnableVertexAttribArray(4);
        glBindBuffer(GL_ARRAY_BUFFER, deformBuffer);
        glVertexAttribPointer(4, 1, GL_FLOAT, GL_FALSE, 0, cast(void*)deformOffsetBytes);

        glEnableVertexAttribArray(5);
        glBindBuffer(GL_ARRAY_BUFFER, deformBuffer);
        glVertexAttribPointer(5, 1, GL_FLOAT, GL_FALSE, 0, cast(void*)deformLane1Offset);

        drawDrawableElements(ibo, indexCount);
        glDisableVertexAttribArray(0);
        glDisableVertexAttribArray(1);
        glDisableVertexAttribArray(2);
        glDisableVertexAttribArray(3);
        glDisableVertexAttribArray(4);
        glDisableVertexAttribArray(5);

        if (advanced) {
            blendModeBarrier(cast(BlendMode)packet.blendingMode);
        }
    }

    size_t textureNativeHandle(GLTextureHandle texture) {
        auto handle = texture;
        return handle.id;
    }

    DynamicCompositePass createDynamicCompositePass(ref const(NjgDynamicCompositePass) packet, Texture[size_t] texturesByHandle) {
        auto pass = new DynamicCompositePass;
        auto surface = new DynamicCompositeSurface;
        surface.textureCount = min(packet.textureCount, packet.textures.length);
        foreach (i; 0 .. surface.textureCount) {
            surface.textureHandles[i] = packet.textures[i];
            if (auto tex = packet.textures[i] in texturesByHandle) {
                surface.textures[i] = *tex;
            } else {
                surface.textures[i] = null;
            }
        }
        surface.stencilHandle = packet.stencil;
        if (auto stencil = packet.stencil in texturesByHandle) {
            surface.stencil = *stencil;
        } else {
            surface.stencil = null;
        }
        pass.surface = surface;
        pass.scale = *cast(vec2*)&packet.scale;
        pass.rotationZ = packet.rotationZ;
        pass.origBuffer = packet.origBuffer;
        pass.origViewport[] = packet.origViewport;
        pass.autoScaled = packet.autoScaled;
        return pass;
    }
}

// ==== Types mirrored from the Unity DLL ABI ====
alias RendererHandle = void*;
alias PuppetHandle = void*;
enum NjgResult : int {
    Ok = 0,
    InvalidArgument = 1,
    Failure = 2,
}

enum NjgRenderCommandKind : uint {
    DrawPart,
    DrawMask, // align with RenderCommandKind; queue may not emit but keeps ABI in sync
    BeginDynamicComposite,
    EndDynamicComposite,
    BeginMask,
    ApplyMask,
    BeginMaskContent,
    EndMask,
    BeginComposite,
    DrawCompositeQuad,
    EndComposite,
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
    vec3 clampedTint;
    vec3 clampedScreen;
    float opacity;
    float emissionStrength;
    float maskThreshold;
    int blendingMode;
    bool useMultistageBlend;
    bool hasEmissionOrBumpmap;
    size_t[3] textureHandles;
    size_t textureCount;
    vec2 origin;
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
    vec2 origin;
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
    vec2 scale;
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

struct OpenGLBackendInit {
    SDL_Window* window;
    SDL_GLContext glContext;
    int drawableW;
    int drawableH;
    UnityResourceCallbacks callbacks;
}

__gshared Texture[size_t] gTextures; // Unity handle -> nlshim Texture
__gshared size_t gNextHandle = 1;
__gshared bool gBackendInitialized;
__gshared RenderResourceHandle[DynamicCompositeFramebufferKey] gDynamicFramebufferCache;
// SDL preview window for texture bytes has been removed to avoid interference.

private struct DynamicCompositeFramebufferKey {
    size_t[3] textures;
    size_t textureCount;
    size_t stencil;

    bool opEquals(const typeof(this) rhs) const {
        return textureCount == rhs.textureCount &&
            stencil == rhs.stencil &&
            textures == rhs.textures;
    }

    size_t toHash() const @safe nothrow {
        size_t h = 1469598103934665603UL;
        static foreach (i; 0 .. 3) {
            h = (h ^ textures[i]) * 1099511628211UL;
        }
        h = (h ^ textureCount) * 1099511628211UL;
        h = (h ^ stencil) * 1099511628211UL;
        return h;
    }
}

private DynamicCompositeFramebufferKey makeDynamicFramebufferKey(const size_t[3] textures,
                                                                 size_t textureCount,
                                                                 size_t stencil) {
    DynamicCompositeFramebufferKey key;
    key.textures = textures;
    key.textureCount = textureCount;
    key.stencil = stencil;
    return key;
}

private bool dynamicFramebufferKeyUsesHandle(ref const(DynamicCompositeFramebufferKey) key, size_t handle) {
    if (handle == 0) return false;
    if (key.stencil == handle) return true;
    foreach (i; 0 .. key.textureCount) {
        if (key.textures[i] == handle) return true;
    }
    return false;
}

private RenderResourceHandle acquireDynamicFramebuffer(const size_t[3] textures,
                                                       size_t textureCount,
                                                       size_t stencil) {
    auto key = makeDynamicFramebufferKey(textures, textureCount, stencil);
    if (auto cached = key in gDynamicFramebufferCache) {
        return *cached;
    }

    GLuint fbo = 0;
    glGenFramebuffers(1, &fbo);
    auto handle = cast(RenderResourceHandle)fbo;
    gDynamicFramebufferCache[key] = handle;
    return handle;
}

private void releaseDynamicFramebuffersForTextureHandle(size_t handle) {
    if (handle == 0 || gDynamicFramebufferCache.length == 0) return;

    DynamicCompositeFramebufferKey[] stale;
    foreach (key, fboHandle; gDynamicFramebufferCache) {
        if (dynamicFramebufferKeyUsesHandle(key, handle)) {
            if (fboHandle != 0) {
                auto fbo = cast(GLuint)fboHandle;
                glDeleteFramebuffers(1, &fbo);
            }
            stale ~= key;
        }
    }

    foreach (key; stale) {
        gDynamicFramebufferCache.remove(key);
    }
}

string sdlError() {
    auto err = SDL_GetError();
    return err is null ? "" : fromStringz(err).idup;
}

/// Initialize SDL + OpenGL context and return backend + window + drawable size.
OpenGLBackendInit initOpenGLBackend(int width, int height, bool isTest) {
    auto support = loadSDL();
    if (support == SDLSupport.noLibrary || support == SDLSupport.badLibrary) {
        // Common Homebrew install path on macOS.
        support = loadSDL("/opt/homebrew/lib/libSDL2-2.0.0.dylib");
    }
    enforce(support >= SDLSupport.sdl206, "Failed to load SDL2 or version too old (loaded="~support.to!string~")");
    enforce(SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS) == 0, "SDL_Init failed: "~sdlError());

    // Request GL 3.3 core context.
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 2);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);
    SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
    SDL_GL_SetAttribute(SDL_GL_STENCIL_SIZE, 8);
    SDL_GL_SetAttribute(SDL_GL_ALPHA_SIZE, 8);

    auto window = SDL_CreateWindow("nijiv",
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        width, height,
        SDL_WINDOW_OPENGL | SDL_WINDOW_RESIZABLE | SDL_WINDOW_ALLOW_HIGHDPI | SDL_WINDOW_SHOWN);
    enforce(window !is null, "SDL_CreateWindow failed: "~sdlError());

    auto glContext = SDL_GL_CreateContext(window);
    enforce(glContext !is null, "SDL_GL_CreateContext failed: "~sdlError());
    SDL_GL_MakeCurrent(window, glContext);
    version (OSX) {
        configureMacOpenGLSurfaceOpacity(glContext);
    }
    auto glSupport = loadOpenGL();
    enforce(glSupport >= GLSupport.gl32, "Failed to load OpenGL bindings (support="~glSupport.to!string~")");
    SDL_GL_SetSwapInterval(1);
    // Ensure a known active texture unit before any texture API calls.
    glActiveTexture(GL_TEXTURE0);

    int drawableW = width;
    int drawableH = height;
    SDL_GL_GetDrawableSize(window, &drawableW, &drawableH);

    // Attach RenderBackend so nlshim Texture can allocate handles.
    inSetRenderBackend(new RenderBackend());
    // Keep viewport state in sync with actual drawable size.
    currentRenderBackend().setViewport(drawableW, drawableH);
    if (!gBackendInitialized) {
        gBackendInitialized = true;
        // Initialize nlshim OpenGL resources to back the queue callbacks.
        auto backend = currentRenderBackend();
        backend.initializeRenderer();
        backend.initializePartBackendResources();
        backend.initializeMaskBackend();
    }
    // Keep viewport in sync with actual drawable size.
    currentRenderBackend().resizeViewportTargets(drawableW, drawableH);

    UnityResourceCallbacks cbs;
    cbs.userData = window;
    cbs.createTexture = (int w, int h, int channels, int mipLevels, int format, bool renderTarget, bool stencil, void* userData) {
        size_t handle = gNextHandle++;
        // Disable mipmaps (min filter is linear-only) to ensure level 0 is displayed.
        auto tex = new Texture(w, h, channels, stencil, false);
        gTextures[handle] = tex;
        return handle;
    };
    cbs.updateTexture = (size_t handle, const(ubyte)* data, size_t dataLen, int w, int h, int channels, void* userData) {
        auto tex = handle in gTextures;
        if (tex is null || *tex is null) {
            return;
        }
        size_t expected = cast(size_t)w * cast(size_t)h * cast(size_t)channels;
        if (data is null || expected == 0 || dataLen < expected) {
            return;
        }
        // Clamp/pad to exactly level0 size so GL upload always gets width*height*channels bytes.
        auto need = expected;
        ubyte[] slice;
        if (dataLen >= need) {
            slice = data[0 .. need].dup;
        } else {
            slice = new ubyte[need];
            slice[0 .. dataLen] = data[0 .. dataLen];
        }
        (*tex).setData(slice, channels);
    };
    cbs.releaseTexture = (size_t handle, void* userData) {
        // Drop all cached dynamic-composite FBOs that reference this texture handle.
        releaseDynamicFramebuffersForTextureHandle(handle);
        if (auto tex = handle in gTextures) {
            if (*tex !is null) (*tex).dispose();
            gTextures.remove(handle);
        }
    };

    return OpenGLBackendInit(window, glContext, drawableW, drawableH, cbs);
}

// ==== Rendering pipeline ====
void renderCommands(const OpenGLBackendInit* gl,
                    const SharedBufferSnapshot* snapshot,
                    const CommandQueueView* view)
{
    if (gl is null) return;
    auto backend = currentRenderBackend();
    auto debugTextureBackend = currentDebugTextureBackend();

    // Backend/VAO/part resources are initialized once at startup (initOpenGLBackend).
    // Per-frame we only need to ensure the currently active FBO attachments stay bound.
    backend.rebindActiveTargets();

    // Unity provides SoA buffers including atlasStride (lane0 -> lane1).
    // Offsets/strides are already in command packets, so upload slices as-is.
    auto uploadSoA = (GLuint target, const NjgBufferSlice slice) {
        if (target == 0 || slice.data is null || slice.length == 0) return;
        glBindBuffer(GL_ARRAY_BUFFER, target);
        glBufferData(GL_ARRAY_BUFFER, slice.length * float.sizeof, cast(const(void)*)slice.data, GL_DYNAMIC_DRAW);
    };

    uploadSoA(backend.sharedVertexBufferHandle(), snapshot.vertices);
    uploadSoA(backend.sharedUvBufferHandle(), snapshot.uvs);
    uploadSoA(backend.sharedDeformBufferHandle(), snapshot.deform);
    backend.beginScene();
    // Core profile requires a VAO. Bind the shared VAO used by nlshim attributes.
    backend.bindDrawableVao();
    // Bind the part shader up front to avoid prog=0 issues.
    backend.bindPartShader();
    auto cmds = view.commands[0 .. view.count];
    // Keep backend stateless; the queue already tracks dynamic-composite depth.
    int[] dynDrawStack;
    DynamicCompositePass[] dynPassStack;
    size_t drawCount;
    foreach (cmd; cmds) {
        switch (cmd.kind) {
            case NjgRenderCommandKind.DrawPart: {
                drawCount++;
                backend.drawPartPacket(cmd.partPacket, gTextures);
                break;
            }
            case NjgRenderCommandKind.DrawMask: {
                // Not expected from current queue; keep placeholder for ABI completeness.
                break;
            }
            case NjgRenderCommandKind.BeginMask: {
                backend.beginMask(cmd.usesStencil);
                break;
            }
            case NjgRenderCommandKind.ApplyMask: {
                backend.applyMask(cmd.maskApplyPacket, gTextures);
                break;
            }
            case NjgRenderCommandKind.BeginMaskContent:
                backend.beginMaskContent();
                break;
            case NjgRenderCommandKind.EndMask:
                backend.endMask();
                break;
            case NjgRenderCommandKind.BeginDynamicComposite: {
                dynDrawStack ~= cast(int)drawCount;
                auto pass = backend.createDynamicCompositePass(cmd.dynamicPass, gTextures);
                dynPassStack ~= pass;
                backend.beginDynamicComposite(pass);
                break;
            }
            case NjgRenderCommandKind.EndDynamicComposite: {
                DynamicCompositePass pass;
                if (dynPassStack.length) {
                    pass = dynPassStack[$-1];
                    dynPassStack.length = dynPassStack.length - 1;
                } else {
                    pass = backend.createDynamicCompositePass(cmd.dynamicPass, gTextures);
                }
                backend.endDynamicComposite(pass);
                if (dynDrawStack.length) {
                    dynDrawStack.length = dynDrawStack.length - 1;
                }
                break;
            }
            default:
                break;
        }
    }
    backend.postProcessScene();
    backend.presentSceneToBackbuffer(gl.drawableW, gl.drawableH);
    // NOTE: Disabled per request. This debug overlay rewrites final pixels,
    // which interferes with transparent-window verification.
    // GLuint[] thumbTextureIds;
    // thumbTextureIds.reserve(gTextures.length);
    // foreach (_handle, tex; gTextures) {
    //     if (tex !is null) {
    //         thumbTextureIds ~= cast(GLuint)tex.getTextureId();
    //     }
    // }
    // debugTextureBackend.renderThumbnailGrid(gl.drawableW, gl.drawableH, thumbTextureIds);
    // Avoid leaking GL state into the next frame.
    glUseProgram(0);
    glBindVertexArray(0);
    glFlush();
    backend.endScene();
}
