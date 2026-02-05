module opengl.opengl_backend;

import std.exception : enforce;
import std.string : fromStringz;
import std.conv : to;
import std.file : write;
import std.stdio : File, writeln, stdout;

import bindbc.sdl;
import bindbc.opengl;
import nlshim.core.render.support : BlendMode;
import nlshim.core.render.support : vec2, vec3, mat4;
import nlshim.core.render.backends.opengl.handles : GLTextureHandle;
import nlshim.core.render.backends : RenderResourceHandle, RenderTextureHandle, BackendEnum, RenderBackend;

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
}
enum MaskDrawableKind : uint { Part, Mask }

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

struct vec2 { float x; float y; }
struct vec3 { float x; float y; float z; }
struct vec4 { float x; float y; float z; float w; }

import nlshim.core.texture : Texture;
import nlshim.core.render.support : Vec2Array;
import nlshim.core.render.backends.opengl.handles : GLTextureHandle;
import nlshim.core.render.backends.opengl.runtime : oglInitRenderer, oglResizeViewport, oglBeginScene, oglEndScene, oglPostProcessScene, oglGetFramebuffer, oglRebindActiveTargets;
import nlshim.core.render.backends.opengl.drawable_buffers :
    oglInitDrawableBackend,
    oglBindDrawableVao,
    oglCreateDrawableBuffers,
    oglUploadDrawableIndices,
    oglUploadSharedVertexBuffer,
    oglUploadSharedUvBuffer,
    oglUploadSharedDeformBuffer,
    oglGetSharedVertexBuffer,
    oglGetSharedUvBuffer,
    oglGetSharedDeformBuffer;
import nlshim.core.render.backends.opengl.part : oglInitPartBackendResources, oglExecutePartPacket;
import nlshim.core.render.backends.opengl.mask :
    oglInitMaskBackend,
    oglExecuteMaskPacket,
    oglExecuteMaskApplyPacket,
    oglBeginMask,
    oglEndMask,
    oglBeginMaskContent;
import nlshim.core.render.backends.opengl.dynamic_composite :
    oglBeginDynamicComposite,
    oglEndDynamicComposite;
import nlshim.core.render.support : incDrawableBindVAO, nlSetTripleBufferFallback;
import NlCmds = nlshim.core.render.commands;
alias PartDrawPacket = NlCmds.PartDrawPacket;
alias MaskDrawPacket = NlCmds.MaskDrawPacket;
alias MaskApplyPacket = NlCmds.MaskApplyPacket;
alias DynamicCompositePass = NlCmds.DynamicCompositePass;
alias DynamicCompositeSurface = NlCmds.DynamicCompositeSurface;
alias NlMaskKind = NlCmds.MaskDrawableKind;
import nlshim.core.runtime_state : inSetRenderBackend, inSetViewport;
import nlshim.core.render.support : mat4;
import nlshim.core.render.backends.opengl.part : partShader, gopacity, gMultColor, gScreenColor, mvp, offset;

__gshared Texture[size_t] gTextures; // Unity handle -> nlshim Texture
__gshared size_t gNextHandle = 1;
__gshared bool gBackendInitialized;
// SDL preview window for texture bytes has been removed to avoid interference.

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

    auto window = SDL_CreateWindow("nijiv",
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        width, height,
        SDL_WINDOW_OPENGL | SDL_WINDOW_RESIZABLE | SDL_WINDOW_ALLOW_HIGHDPI | SDL_WINDOW_SHOWN);
    enforce(window !is null, "SDL_CreateWindow failed: "~sdlError());

    auto glContext = SDL_GL_CreateContext(window);
    enforce(glContext !is null, "SDL_GL_CreateContext failed: "~sdlError());
    SDL_GL_MakeCurrent(window, glContext);
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
    // Keep nlshim viewport state in sync with actual drawable size.
    inSetViewport(drawableW, drawableH);
    if (!gBackendInitialized) {
        gBackendInitialized = true;
        // Initialize nlshim OpenGL resources to back the queue callbacks.
        oglInitRenderer();
        oglInitDrawableBackend();
        oglInitPartBackendResources();
        oglInitMaskBackend();
    }
    // Keep viewport in sync with actual drawable size.
    oglResizeViewport(drawableW, drawableH);

    UnityResourceCallbacks cbs;
    cbs.userData = window;
    cbs.createTexture = (int w, int h, int channels, int mipLevels, int format, bool renderTarget, bool stencil, void* userData) {
        size_t handle = gNextHandle++;
        // Mipmapsは使わず（最小フィルタはLinearのみ）確実にレベル0を表示する
        auto tex = new Texture(w, h, channels, stencil, false);
        gTextures[handle] = tex;
        import std.stdio : writeln;
        writeln("[opengl_backend] createTexture handle=", handle, " size=", w, "x", h, " ch=", channels, " stencil=", stencil);
        return handle;
    };
    cbs.updateTexture = (size_t handle, const(ubyte)* data, size_t dataLen, int w, int h, int channels, void* userData) {
        import std.stdio : writeln;
        auto tex = handle in gTextures;
        if (tex is null || *tex is null) {
            writeln("[opengl_backend] updateTexture handle=", handle, " (missing texture) dataLen=", dataLen);
            return;
        }
        size_t expected = cast(size_t)w * cast(size_t)h * cast(size_t)channels;
        if (data is null || expected == 0 || dataLen < expected) {
            writeln("[opengl_backend] updateTexture handle=", handle, " INVALID len=", dataLen, " expected>=", expected, " size=", w, "x", h, " ch=", channels);
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
        // Quick sanity: min/max to detect all-zero uploads.
        ubyte minv = 255;
        ubyte maxv = 0;
        foreach (b; slice) { if (b < minv) minv = b; if (b > maxv) maxv = b; }
        (*tex).setData(slice.dup, channels);
        writeln("[opengl_backend] updateTexture handle=", handle,
                " dataLen=", dataLen, " used=", expected,
                " size=", w, "x", h, " ch=", channels,
                " min=", minv, " max=", maxv);

    };
    cbs.releaseTexture = (size_t handle, void* userData) {
        if (auto tex = handle in gTextures) {
            if (*tex !is null) (*tex).dispose();
            gTextures.remove(handle);
        }
    };

    return OpenGLBackendInit(window, glContext, drawableW, drawableH, cbs);
}

// ==== Rendering pipeline ====
__gshared GLuint gProgram;
__gshared GLuint gVao;
__gshared GLuint gVboPos;
__gshared GLuint gVboUv;
__gshared GLuint gEbo;
__gshared GLint gMvpLoc = -1;
__gshared GLint gTintLoc = -1;
__gshared GLint gScreenLoc = -1;
__gshared GLint gOpacityLoc = -1;

// Shared vertex/uv/deform buffers uploaded per frame.
__gshared GLuint gSharedVertexVbo;
__gshared GLuint gSharedUvVbo;
__gshared GLuint gSharedDeformVbo;
// Debug thumbnail rendering buffers.
__gshared GLuint gDbgQuadVbo;
__gshared GLuint gDbgQuadUvVbo;
__gshared GLuint gDbgQuadEbo;
__gshared GLuint gThumbFbo;
__gshared GLuint gThumbColor;
__gshared GLuint gDebugTestTex;
__gshared GLuint gThumbProg;
__gshared GLint gThumbMvpLoc = -1;
__gshared GLuint gThumbVao;
__gshared GLuint gThumbQuadVbo;
__gshared GLuint gThumbQuadEbo;
struct IboKey {
    size_t ptr;
    size_t count;
    bool opEquals(ref const IboKey other) const nothrow @safe {
        return ptr == other.ptr && count == other.count;
    }
    size_t toHash() const nothrow @safe {
        // simple pointer/count mix; sufficient for stable indices buffers
        return (ptr ^ (count + 0x9e3779b97f4a7c15UL + (ptr << 6) + (ptr >> 2)));
    }
}
__gshared RenderResourceHandle[IboKey] gIboCache;

/// Lookup Texture created via callbacks.
Texture toTex(size_t h) {
    auto tex = h in gTextures;
    return tex is null ? null : *tex;
}

RenderResourceHandle getOrCreateIbo(const(ushort)* indices, size_t count) {
    if (indices is null || count == 0) return RenderResourceHandle.init;
    IboKey key = IboKey(cast(size_t)indices, count);
    if (auto existing = key in gIboCache) {
        return *existing;
    }
    RenderResourceHandle ibo;
    oglCreateDrawableBuffers(ibo);
    auto idxSlice = indices[0 .. count];
    oglUploadDrawableIndices(ibo, idxSlice.dup);
    gIboCache[key] = ibo;
    return ibo;
}

void ensureSharedBuffers() {
    if (gSharedVertexVbo == 0) glGenBuffers(1, &gSharedVertexVbo);
    if (gSharedUvVbo == 0) glGenBuffers(1, &gSharedUvVbo);
    if (gSharedDeformVbo == 0) glGenBuffers(1, &gSharedDeformVbo);
}

void ensureDebugBuffers() {
    if (gDbgQuadVbo == 0) glGenBuffers(1, &gDbgQuadVbo);
    if (gDbgQuadUvVbo == 0) glGenBuffers(1, &gDbgQuadUvVbo);
    if (gDbgQuadEbo == 0) glGenBuffers(1, &gDbgQuadEbo);
}

void ensureThumbVao() {
    if (gThumbVao == 0) {
        glGenVertexArrays(1, &gThumbVao);
    }
    if (gThumbQuadVbo == 0) glGenBuffers(1, &gThumbQuadVbo);
    if (gThumbQuadEbo == 0) glGenBuffers(1, &gThumbQuadEbo);
}

void ensureThumbTarget() {
    const int thumbSize = 48;
    if (gThumbColor == 0) {
        glGenTextures(1, &gThumbColor);
        glBindTexture(GL_TEXTURE_2D, gThumbColor);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, thumbSize, thumbSize, 0, GL_RGBA, GL_UNSIGNED_BYTE, null);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    }
    if (gThumbFbo == 0) {
        glGenFramebuffers(1, &gThumbFbo);
        glBindFramebuffer(GL_FRAMEBUFFER, gThumbFbo);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, gThumbColor, 0);
        auto status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
        enforce(status == GL_FRAMEBUFFER_COMPLETE, "thumb FBO incomplete: "~status.to!string);
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
    }
}

/// Draw gDebugTestTex as a fullscreen quad using client arrays (no VBO/VAO reliance).
private void drawFullscreenTest(int w, int h, GLuint texId = 0) {
    ensureThumbProgram();
    ensureThumbVao();
    ensureDebugTestTex();
    glUseProgram(gThumbProg);
    // Clip-space fullscreen triangle (no matrix dependency)
    if (gThumbMvpLoc >= 0) {
        // identity
        float[16] m = [1,0,0,0,
                       0,1,0,0,
                       0,0,1,0,
                       0,0,0,1];
        glUniformMatrix4fv(gThumbMvpLoc, 1, GL_FALSE, m.ptr);
    }
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, texId != 0 ? texId : gDebugTestTex);

    // pos(x,y), uv
    // 3 vertices * 4 floats (x,y,u,v)
    float[12] verts = [
        -1, -1,  0, 0,
         3, -1,  2, 0,
        -1,  3,  0, 2
    ];
    glBindVertexArray(gThumbVao);
    glBindBuffer(GL_ARRAY_BUFFER, gThumbQuadVbo);
    glBufferData(GL_ARRAY_BUFFER, verts.length * float.sizeof, verts.ptr, GL_STATIC_DRAW);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, cast(int)(4 * float.sizeof), cast(void*)0);
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, cast(int)(4 * float.sizeof), cast(void*)(2 * float.sizeof));
    glDisableVertexAttribArray(2);
    glDisableVertexAttribArray(3);
    glDisableVertexAttribArray(4);
    glDisableVertexAttribArray(5);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    glBindVertexArray(0);
}

/// Draw a texture as a rectangle in screen pixel coordinates (uses same simple shader).
private void drawTile(GLuint texId, float x, float y, float size, int screenW, int screenH) {
    if (texId == 0) return;
    ensureThumbProgram();
    ensureThumbVao();
    // 保守的にターゲットとビューポートを設定し直す
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glViewport(0, 0, screenW, screenH);
    glUseProgram(gThumbProg);
    // 直接クリップ座標に変換して恒等行列を渡す
    float left = (x / cast(float)screenW) * 2f - 1f;
    float right = ((x + size) / cast(float)screenW) * 2f - 1f;
    float top = (y / cast(float)screenH) * 2f - 1f;
    float bottom = ((y + size) / cast(float)screenH) * 2f - 1f;
    if (gThumbMvpLoc >= 0) {
        float[16] ident = [1,0,0,0,
                           0,1,0,0,
                           0,0,1,0,
                           0,0,0,1];
        glUniformMatrix4fv(gThumbMvpLoc, 1, GL_FALSE, ident.ptr);
    }
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, texId);

    // Two triangles (6 vertices) to avoid strip-related surprises.
    float[24] verts = [
        // tri 1
        left,  top,    0, 0,
        right, top,    1, 0,
        left,  bottom, 0, 1,
        // tri 2
        right, top,    1, 0,
        right, bottom, 1, 1,
        left,  bottom, 0, 1
    ];
    glBindVertexArray(gThumbVao);
    glBindBuffer(GL_ARRAY_BUFFER, gThumbQuadVbo);
    glBufferData(GL_ARRAY_BUFFER, verts.length * float.sizeof, verts.ptr, GL_STREAM_DRAW);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, cast(int)(4 * float.sizeof), cast(void*)0);
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, cast(int)(4 * float.sizeof), cast(void*)(2 * float.sizeof));
    glDisableVertexAttribArray(2);
    glDisableVertexAttribArray(3);
    glDisableVertexAttribArray(4);
    glDisableVertexAttribArray(5);
    glDrawArrays(GL_TRIANGLES, 0, 6);
    glBindVertexArray(0);
}

/// Convenience: draw the debug checkerboard at (x,y) with 48x48 size on the screen.
private void drawTestTile(float x, float y, int screenW, int screenH) {
    ensureDebugTestTex();
    drawTile(gDebugTestTex, x, y, 48, screenW, screenH);
}

/// Minimal helper: read a GL texture, downscale on CPU to 48x48, write PPM (no external libs).
void saveTextureThumbnail(GLuint texId, string path, int target = 48) {
    if (texId == 0) return;
    glBindTexture(GL_TEXTURE_2D, texId);
    GLint w = 0, h = 0;
    glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_WIDTH, &w);
    glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_HEIGHT, &h);
    if (w <= 0 || h <= 0) return;
    auto full = new ubyte[w * h * 4];
    glGetTexImage(GL_TEXTURE_2D, 0, GL_RGBA, GL_UNSIGNED_BYTE, full.ptr);
    auto outBuf = new ubyte[target * target * 3];
    foreach (ty; 0 .. target) {
        foreach (tx; 0 .. target) {
            size_t sx = cast(size_t)(tx * w / target);
            size_t sy = cast(size_t)(ty * h / target);
            auto si = (sy * w + sx) * 4;
            auto di = (ty * target + tx) * 3;
            outBuf[di + 0] = full[si + 0];
            outBuf[di + 1] = full[si + 1];
            outBuf[di + 2] = full[si + 2];
        }
    }
    // Write PPM (binary P6)
    import std.format : format;
    auto headerStr = format("P6\n%d %d\n255\n", target, target);
    auto header = cast(ubyte[])headerStr;
    ubyte[] data;
    data.length = header.length + outBuf.length;
    data[0 .. header.length] = header[];
    data[header.length .. $] = outBuf[];
    write(path, data);
}

void ensureDebugTestTex() {
    if (gDebugTestTex != 0) return;
    const int sz = 48;
    ubyte[sz*sz*4] pixels;
    foreach (y; 0 .. sz) foreach (x; 0 .. sz) {
        bool on = ((x / 6) ^ (y / 6)) & 1;
        auto idx = (y * sz + x) * 4;
        pixels[idx + 0] = on ? 255 : 30;
        pixels[idx + 1] = on ? 128 : 30;
        pixels[idx + 2] = on ? 64 : 30;
        pixels[idx + 3] = 255;
    }
    glGenTextures(1, &gDebugTestTex);
    glBindTexture(GL_TEXTURE_2D, gDebugTestTex);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, sz, sz, 0, GL_RGBA, GL_UNSIGNED_BYTE, pixels.ptr);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
}

void ensureThumbProgram() {
    if (gThumbProg != 0) return;
    enum string vsSrc = q{
        #version 330 core
        uniform mat4 mvp;
        layout(location = 0) in vec2 inPos;
        layout(location = 1) in vec2 inUv;
        out vec2 vUv;
        void main() {
            gl_Position = mvp * vec4(inPos, 0.0, 1.0);
            vUv = inUv;
        }
    };
    enum string fsSrc = q{
        #version 330 core
        in vec2 vUv;
        layout(location = 0) out vec4 outColor;
        uniform sampler2D albedo;
        void main() {
            outColor = texture(albedo, vUv);
        }
    };
    auto compile = (GLenum kind, string src) {
        GLuint s = glCreateShader(kind);
        const(char)* p = src.ptr;
        glShaderSource(s, 1, &p, null);
        glCompileShader(s);
        GLint ok = 0;
        glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
        enforce(ok == GL_TRUE, "thumb shader compile failed");
        return s;
    };
    GLuint vs = compile(GL_VERTEX_SHADER, vsSrc);
    GLuint fs = compile(GL_FRAGMENT_SHADER, fsSrc);
    gThumbProg = glCreateProgram();
    glAttachShader(gThumbProg, vs);
    glAttachShader(gThumbProg, fs);
    glLinkProgram(gThumbProg);
    GLint linked = 0;
    glGetProgramiv(gThumbProg, GL_LINK_STATUS, &linked);
    enforce(linked == GL_TRUE, "thumb shader link failed");
    glDeleteShader(vs);
    glDeleteShader(fs);
    glUseProgram(gThumbProg);
    GLint albedoLoc = glGetUniformLocation(gThumbProg, "albedo");
    if (albedoLoc >= 0) glUniform1i(albedoLoc, 0);
    gThumbMvpLoc = glGetUniformLocation(gThumbProg, "mvp");
    glUseProgram(0);
}

bool sliceHasRoom(NjgBufferSlice slice, size_t offset, size_t stride, size_t count) {
    if (slice.data is null || slice.length == 0) return false;
    auto lane0End = offset + count;
    auto lane1End = offset + stride + count;
    return lane0End <= slice.length && lane1End <= slice.length;
}

/// Debug: draw a texture as a 48x48 thumbnail at pixel (x,y) on the default framebuffer.
void debugDrawThumbnail(Texture tex, float x, float y, float size, int screenW, int screenH) {
    if (tex is null) return;
    ensureThumbProgram();
    ensureThumbVao();
    glUseProgram(gThumbProg);
    glBindVertexArray(gThumbVao);
    glActiveTexture(GL_TEXTURE0);
    tex.bind();
    auto ortho = mat4.orthographic(0f, cast(float)screenW, cast(float)screenH, 0f, -1f, 1f);
    if (gThumbMvpLoc >= 0) glUniformMatrix4fv(gThumbMvpLoc, 1, GL_FALSE, ortho.ptr);

    float left = x;
    float right = x + size;
    float top = y;
    float bottom = y + size;

    float[16] verts = [
        left,  top,    0, 0,
        right, top,    1, 0,
        left,  bottom, 0, 1,
        right, bottom, 1, 1
    ];
    glBindBuffer(GL_ARRAY_BUFFER, gThumbQuadVbo);
    glBufferData(GL_ARRAY_BUFFER, verts.length * float.sizeof, verts.ptr, GL_STREAM_DRAW);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, cast(int)(4 * float.sizeof), cast(void*)0);
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, cast(int)(4 * float.sizeof), cast(void*)(2 * float.sizeof));
    glDisableVertexAttribArray(2);
    glDisableVertexAttribArray(3);
    glDisableVertexAttribArray(4);
    glDisableVertexAttribArray(5);

    static immutable ushort[6] idx = [0,1,2, 2,1,3];
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, gThumbQuadEbo);
    glBufferData(GL_ELEMENT_ARRAY_BUFFER, idx.length * ushort.sizeof, idx.ptr, GL_STATIC_DRAW);
    glDrawElements(GL_TRIANGLES, idx.length, GL_UNSIGNED_SHORT, null);

    glBindVertexArray(0);
}

/// Draw a thumbnail using a raw GL texture id (used after rendering into a thumb FBO).
void debugDrawThumbnailId(GLuint texId, float x, float y, float size, int screenW, int screenH) {
    if (texId == 0) return;
    ensureThumbProgram();
    ensureThumbVao();
    glBindVertexArray(gThumbVao);
    auto ortho = mat4.orthographic(0f, cast(float)screenW, cast(float)screenH, 0f, -1f, 1f);
    glUseProgram(gThumbProg);
    if (gThumbMvpLoc >= 0) glUniformMatrix4fv(gThumbMvpLoc, 1, GL_FALSE, ortho.ptr);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, texId);

    float left = x;
    float right = x + size;
    float top = y;
    float bottom = y + size;

    float[16] verts = [
        left,  top,    0, 0,
        right, top,    1, 0,
        left,  bottom, 0, 1,
        right, bottom, 1, 1
    ];
    glBindBuffer(GL_ARRAY_BUFFER, gThumbQuadVbo);
    glBufferData(GL_ARRAY_BUFFER, verts.length * float.sizeof, verts.ptr, GL_STREAM_DRAW);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, cast(int)(4 * float.sizeof), cast(void*)0);
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, cast(int)(4 * float.sizeof), cast(void*)(2 * float.sizeof));
    glDisableVertexAttribArray(2);
    glDisableVertexAttribArray(3);
    glDisableVertexAttribArray(4);
    glDisableVertexAttribArray(5);

    static immutable ushort[6] idx = [0,1,2, 2,1,3];
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, gThumbQuadEbo);
    glBufferData(GL_ELEMENT_ARRAY_BUFFER, idx.length * ushort.sizeof, idx.ptr, GL_STATIC_DRAW);
    glDrawElements(GL_TRIANGLES, idx.length, GL_UNSIGNED_SHORT, null);

    glBindVertexArray(0);
}


void setBlendMode(int mode) {
    GLenum src = GL_ONE;
    GLenum dst = GL_ONE_MINUS_SRC_ALPHA;
    GLenum op = GL_FUNC_ADD;
    switch (mode) {
        case 1: // Multiply
            src = GL_DST_COLOR;
            dst = GL_ONE_MINUS_SRC_ALPHA;
            break;
        case 2: // Screen
            src = GL_ONE;
            dst = GL_ONE_MINUS_SRC_COLOR;
            break;
        case 7: // Add
            src = GL_ONE;
            dst = GL_ONE;
            break;
        case 14: // Subtract
            src = GL_ONE;
            dst = GL_ONE;
            op = GL_FUNC_REVERSE_SUBTRACT;
            break;
        default:
            break;
    }
    glEnable(GL_BLEND);
    glBlendFunc(src, dst);
    glBlendEquation(op);
}

// Bridge: convert DLL packets to backend PartDrawPacket/MaskDrawPacket and call ogl*.
void renderCommands(const OpenGLBackendInit* gl,
                    const SharedBufferSnapshot* snapshot,
                    const CommandQueueView* view)
{
    if (gl is null) return;
    import std.stdio : writeln;
    // 先頭数件について、実際に参照するオフセット周辺のバッファ内容をダンプする。
    auto logPacketLayout = () {
        string path = "/Users/seagetch/src/nijigenerate/nijiv/test_layout.log";
        File f;
        try {
            f = File(path, "a");
        } catch (Exception e) {
            writeln("[renderCommands] failed to open ", path, ": ", e.msg);
        }
        writeln("---- frame ----"); // stdout で確認
        if (f.isOpen) f.writeln("---- frame ----");
        size_t logged;
        enum sampleN = 6;
        auto dumpBuf = (GLuint target, size_t start, string label) {
            if (target == 0) return;
            float[sampleN] tmp;
            glBindBuffer(GL_ARRAY_BUFFER, target);
            glGetBufferSubData(GL_ARRAY_BUFFER, cast(ptrdiff_t)(start * float.sizeof), tmp.length * float.sizeof, tmp.ptr);
            writeln("  ", label, " @", start, " -> ", tmp);
            if (f.isOpen) f.writeln("  ", label, " @", start, " -> ", tmp);
        };
        foreach (cmd; view.commands[0 .. view.count]) {
            if (logged >= 8) break;
            switch (cmd.kind) {
                case NjgRenderCommandKind.DrawPart:
                    writeln("DrawPart idxCount=", cmd.partPacket.indexCount,
                            " vtxCount=", cmd.partPacket.vertexCount,
                            " vStride=", cmd.partPacket.vertexAtlasStride,
                            " uvStride=", cmd.partPacket.uvAtlasStride,
                            " defStride=", cmd.partPacket.deformAtlasStride,
                            " vOff=", cmd.partPacket.vertexOffset,
                            " uvOff=", cmd.partPacket.uvOffset,
                            " defOff=", cmd.partPacket.deformOffset,
                            " blend=", cast(int)cmd.partPacket.blendingMode,
                            " multi=", cmd.partPacket.useMultistageBlend);
                    if (f.isOpen) f.writeln("DrawPart idxCount=", cmd.partPacket.indexCount,
                                             " vtxCount=", cmd.partPacket.vertexCount,
                                             " vStride=", cmd.partPacket.vertexAtlasStride,
                                             " uvStride=", cmd.partPacket.uvAtlasStride,
                                             " defStride=", cmd.partPacket.deformAtlasStride,
                                             " vOff=", cmd.partPacket.vertexOffset,
                                             " uvOff=", cmd.partPacket.uvOffset,
                                             " defOff=", cmd.partPacket.deformOffset,
                                             " blend=", cast(int)cmd.partPacket.blendingMode,
                                             " multi=", cmd.partPacket.useMultistageBlend);
                    // 実データを少量抜き出す（lane0/lane1 の先頭部分）
                    dumpBuf(oglGetSharedVertexBuffer(), cmd.partPacket.vertexOffset, "vLane0");
                    dumpBuf(oglGetSharedVertexBuffer(), cmd.partPacket.vertexAtlasStride + cmd.partPacket.vertexOffset, "vLane1");
                    dumpBuf(oglGetSharedUvBuffer(), cmd.partPacket.uvOffset, "uvLane0");
                    dumpBuf(oglGetSharedUvBuffer(), cmd.partPacket.uvAtlasStride + cmd.partPacket.uvOffset, "uvLane1");
                    dumpBuf(oglGetSharedDeformBuffer(), cmd.partPacket.deformOffset, "defLane0");
                    dumpBuf(oglGetSharedDeformBuffer(), cmd.partPacket.deformAtlasStride + cmd.partPacket.deformOffset, "defLane1");
                    logged++;
                    break;
                case NjgRenderCommandKind.ApplyMask:
                    writeln("ApplyMask part idxCount=", cmd.maskApplyPacket.partPacket.indexCount,
                            " vtxCount=", cmd.maskApplyPacket.partPacket.vertexCount,
                            " vStride=", cmd.maskApplyPacket.partPacket.vertexAtlasStride,
                            " uvStride=", cmd.maskApplyPacket.partPacket.uvAtlasStride,
                            " defStride=", cmd.maskApplyPacket.partPacket.deformAtlasStride,
                            " vOff=", cmd.maskApplyPacket.partPacket.vertexOffset,
                            " uvOff=", cmd.maskApplyPacket.partPacket.uvOffset,
                            " defOff=", cmd.maskApplyPacket.partPacket.deformOffset);
                    if (f.isOpen) f.writeln("ApplyMask part idxCount=", cmd.maskApplyPacket.partPacket.indexCount,
                                             " vtxCount=", cmd.maskApplyPacket.partPacket.vertexCount,
                                             " vStride=", cmd.maskApplyPacket.partPacket.vertexAtlasStride,
                                             " uvStride=", cmd.maskApplyPacket.partPacket.uvAtlasStride,
                                             " defStride=", cmd.maskApplyPacket.partPacket.deformAtlasStride,
                                             " vOff=", cmd.maskApplyPacket.partPacket.vertexOffset,
                                             " uvOff=", cmd.maskApplyPacket.partPacket.uvOffset,
                                             " defOff=", cmd.maskApplyPacket.partPacket.deformOffset);
                    logged++;
                    break;
                case NjgRenderCommandKind.BeginDynamicComposite,
                     NjgRenderCommandKind.EndDynamicComposite,
                     NjgRenderCommandKind.BeginMask,
                     NjgRenderCommandKind.BeginMaskContent,
                     NjgRenderCommandKind.EndMask:
                    break;
                default:
                    break;
            }
        }
        if (f.isOpen) f.close();
        stdout.flush();
    };

    // Backend/VAO/part resources are initialized once at startup (initOpenGLBackend).
    // Per-frame we only need to ensure the currently active FBO attachments stay bound.
    oglRebindActiveTargets();
    // Disable triple-buffer fallback so legacy glBlendFunc path (ClipToLower 等) is used.
    nlSetTripleBufferFallback(false);
    writeln("[renderCommands] normal path");

    // Unity 側は atlasStride を含んだ SoA（lane0→lane1）になっている。
    // オフセット/ストライドはコマンドパケットに入っているので、そのまま丸ごと転送する。
    auto uploadSoA = (GLuint target, const NjgBufferSlice slice) {
        if (target == 0 || slice.data is null || slice.length == 0) return;
        glBindBuffer(GL_ARRAY_BUFFER, target);
        glBufferData(GL_ARRAY_BUFFER, slice.length * float.sizeof, cast(const(void)*)slice.data, GL_DYNAMIC_DRAW);
    };

    uploadSoA(oglGetSharedVertexBuffer(), snapshot.vertices);
    uploadSoA(oglGetSharedUvBuffer(), snapshot.uvs);
    uploadSoA(oglGetSharedDeformBuffer(), snapshot.deform);

    // パケットレイアウトをファイルに記録
    logPacketLayout();

    oglBeginScene();
    // Core profileはVAO必須。nlshim側の属性設定を活かすため共通VAOをバインド。
    oglBindDrawableVao();
    // 念のため最初にパート用シェーダをバインドしておく（prog=0防止）。
    partShader.use();
    debug {
        import std.stdio : writefln;
        GLint vao=0, prog=0;
        glGetIntegerv(GL_VERTEX_ARRAY_BINDING, &vao);
        glGetIntegerv(GL_CURRENT_PROGRAM, &prog);
        writefln("[vao-debug] vao=%s prog=%s", vao, prog);
    }
    auto cmds = view.commands[0 .. view.count];
    // Keep backend stateless; the queue already tracks dynamic-composite depth.
    int dynDepth;
    int[] dynDrawStack;
    bool[] dynLogged;
    DynamicCompositePass[] dynPassStack;
    writeln("[renderCommands] commands this frame=", cmds.length);
    size_t drawCount, beginMaskCount, applyMaskCount, beginMaskContentCount, endMaskCount, beginDynCount, endDynCount;
    foreach (cmd; cmds) {
        switch (cmd.kind) {
            case NjgRenderCommandKind.DrawPart: {
                drawCount++;
                PartDrawPacket p;
                p.renderable = true;
                p.isMask = cmd.partPacket.isMask;
                p.modelMatrix = *cast(mat4*)&cmd.partPacket.modelMatrix;
                p.renderMatrix = *cast(mat4*)&cmd.partPacket.renderMatrix;
                p.origin = *cast(vec2*)&cmd.partPacket.origin;
                p.vertexOffset = cmd.partPacket.vertexOffset;
                p.vertexAtlasStride = cmd.partPacket.vertexAtlasStride;
                p.uvOffset = cmd.partPacket.uvOffset;
                p.uvAtlasStride = cmd.partPacket.uvAtlasStride;
                p.deformOffset = cmd.partPacket.deformOffset;
                p.deformAtlasStride = cmd.partPacket.deformAtlasStride;
                p.indexCount = cast(uint)cmd.partPacket.indexCount;
                p.vertexCount = cast(uint)cmd.partPacket.vertexCount;
                p.textures.length = cmd.partPacket.textureCount;
                foreach(i; 0 .. cmd.partPacket.textureCount) p.textures[i] = toTex(cmd.partPacket.textureHandles[i]);
                p.opacity = cmd.partPacket.opacity;
                p.clampedTint = *cast(vec3*)&cmd.partPacket.clampedTint;
                p.clampedScreen = *cast(vec3*)&cmd.partPacket.clampedScreen;
                p.maskThreshold = cmd.partPacket.maskThreshold;
                p.blendingMode = cast(BlendMode)cmd.partPacket.blendingMode;
                p.useMultistageBlend = cmd.partPacket.useMultistageBlend;
                p.hasEmissionOrBumpmap = cmd.partPacket.hasEmissionOrBumpmap;
                p.indexBuffer = getOrCreateIbo(cmd.partPacket.indices, cmd.partPacket.indexCount);
                oglExecutePartPacket(p);
                debug {
                    import std.stdio : writefln;
                    if (dynDrawStack.length > 0 && dynLogged.length && !dynLogged[$-1]) {
                        dynLogged[$-1] = true;
                        auto rm = p.renderMatrix;
                        auto mm = p.modelMatrix;
                        writefln("[renderCommands] drawPart inDyn rmRow0=(%.3f,%.3f,%.3f,%.3f) mmRow0=(%.3f,%.3f,%.3f,%.3f)",
                            rm[0][0], rm[0][1], rm[0][2], rm[0][3],
                            mm[0][0], mm[0][1], mm[0][2], mm[0][3]);
                    }
                    GLint[4] aEn;
                    GLint[4] aStride;
                    GLint[4] aBuf;
                    foreach(i; 0 .. 4){
                        glGetVertexAttribiv(i, GL_VERTEX_ATTRIB_ARRAY_ENABLED, &aEn[i]);
                        glGetVertexAttribiv(i, GL_VERTEX_ATTRIB_ARRAY_STRIDE, &aStride[i]);
                        glGetVertexAttribiv(i, GL_VERTEX_ATTRIB_ARRAY_BUFFER_BINDING, &aBuf[i]);
                    }
                    writefln("[attr-debug] en=%s stride=%s buf=%s vOff=%s uvOff=%s defOff=%s",
                        aEn, aStride, aBuf, p.vertexOffset, p.uvOffset, p.deformOffset);
                }
                break;
            }
            case NjgRenderCommandKind.DrawMask: {
                // Not expected from current queue; keep placeholder for ABI completeness.
                break;
            }
            case NjgRenderCommandKind.BeginMask: {
                beginMaskCount++;
                oglBeginMask(cmd.usesStencil);
                break;
            }
            case NjgRenderCommandKind.ApplyMask: {
                applyMaskCount++;
                MaskApplyPacket mp;
                PartDrawPacket p;
                auto src = cmd.maskApplyPacket.partPacket;
                p.renderable = true;
                p.isMask = src.isMask;
                p.modelMatrix = *cast(mat4*)&src.modelMatrix;
                p.renderMatrix = *cast(mat4*)&src.renderMatrix;
                p.origin = *cast(vec2*)&src.origin;
                p.vertexOffset = src.vertexOffset;
                p.vertexAtlasStride = src.vertexAtlasStride;
                p.uvOffset = src.uvOffset;
                p.uvAtlasStride = src.uvAtlasStride;
                p.deformOffset = src.deformOffset;
                p.deformAtlasStride = src.deformAtlasStride;
                p.indexCount = cast(uint)src.indexCount;
                p.vertexCount = cast(uint)src.vertexCount;
                p.textures.length = src.textureCount;
                foreach(i; 0 .. src.textureCount) p.textures[i] = toTex(src.textureHandles[i]);
                p.opacity = src.opacity;
                p.clampedTint = *cast(vec3*)&src.clampedTint;
                p.clampedScreen = *cast(vec3*)&src.clampedScreen;
                p.maskThreshold = src.maskThreshold;
                p.blendingMode = cast(BlendMode)src.blendingMode;
                p.useMultistageBlend = src.useMultistageBlend;
                p.hasEmissionOrBumpmap = src.hasEmissionOrBumpmap;
                p.indexBuffer = getOrCreateIbo(src.indices, src.indexCount);
                mp.partPacket = p;

                MaskDrawPacket m;
                auto ms = cmd.maskApplyPacket.maskPacket;
                m.modelMatrix = *cast(mat4*)&ms.modelMatrix;
                m.mvp = *cast(mat4*)&ms.mvp;
                m.origin = *cast(vec2*)&ms.origin;
                m.vertexOffset = ms.vertexOffset;
                m.vertexAtlasStride = ms.vertexAtlasStride;
                m.deformOffset = ms.deformOffset;
                m.deformAtlasStride = ms.deformAtlasStride;
                m.indexCount = cast(uint)ms.indexCount;
                m.vertexCount = cast(uint)ms.vertexCount;
                m.indexBuffer = getOrCreateIbo(ms.indices, ms.indexCount);

                mp.maskPacket = m;
                mp.kind = cast(NlMaskKind)cmd.maskApplyPacket.kind;
                mp.isDodge = cmd.maskApplyPacket.isDodge;
                oglExecuteMaskApplyPacket(mp);
                break;
            }
            case NjgRenderCommandKind.BeginMaskContent:
                beginMaskContentCount++;
                oglBeginMaskContent();
                break;
            case NjgRenderCommandKind.EndMask:
                endMaskCount++;
                oglEndMask();
                break;
            case NjgRenderCommandKind.BeginDynamicComposite: {
                beginDynCount++;
                dynDrawStack ~= cast(int)drawCount;
                dynDepth = cast(int)dynDrawStack.length;
                dynLogged ~= false;
                writeln("[renderCommands] beginDyn texCount=", cmd.dynamicPass.textureCount,
                        " tex0=", cmd.dynamicPass.textureCount>0 ? cmd.dynamicPass.textures[0] : 0,
                        " stencil=", cmd.dynamicPass.stencil,
                        " scale=(", cmd.dynamicPass.scale.x, ",", cmd.dynamicPass.scale.y, ")",
                        " rotZ=", cmd.dynamicPass.rotationZ,
                        " autoScaled=", cmd.dynamicPass.autoScaled,
                        " drawCount=", drawCount);
                auto pass = new DynamicCompositePass;
                auto surf = new DynamicCompositeSurface;
                surf.textureCount = cmd.dynamicPass.textureCount;
                foreach(i; 0 .. surf.textureCount) {
                    surf.textures[i] = toTex(cmd.dynamicPass.textures[i]);
                }
                surf.stencil = toTex(cmd.dynamicPass.stencil);
                pass.surface = surf;
                pass.scale = *cast(vec2*)&cmd.dynamicPass.scale;
                pass.rotationZ = cmd.dynamicPass.rotationZ;
                pass.origBuffer = cmd.dynamicPass.origBuffer;
                pass.origViewport[] = cmd.dynamicPass.origViewport;
                pass.autoScaled = cmd.dynamicPass.autoScaled;
                pass.drawBufferCount = cmd.dynamicPass.drawBufferCount;
                pass.hasStencil = cmd.dynamicPass.hasStencil;
                dynPassStack ~= pass;
                oglBeginDynamicComposite(pass);
                break;
            }
            case NjgRenderCommandKind.EndDynamicComposite: {
                endDynCount++;
                writeln("[renderCommands] endDyn");
                DynamicCompositePass pass;
                if (dynPassStack.length) {
                    pass = dynPassStack[$-1];
                    dynPassStack.length = dynPassStack.length - 1;
                } else {
                    // Fallback: reconstruct (should not happen)
                    pass = new DynamicCompositePass;
                    auto surf = new DynamicCompositeSurface;
                    surf.textureCount = cmd.dynamicPass.textureCount;
                    foreach(i; 0 .. surf.textureCount) {
                        surf.textures[i] = toTex(cmd.dynamicPass.textures[i]);
                    }
                    surf.stencil = toTex(cmd.dynamicPass.stencil);
                    pass.surface = surf;
                    pass.scale = *cast(vec2*)&cmd.dynamicPass.scale;
                    pass.rotationZ = cmd.dynamicPass.rotationZ;
                    pass.origBuffer = cmd.dynamicPass.origBuffer;
                    pass.origViewport[] = cmd.dynamicPass.origViewport;
                    pass.autoScaled = cmd.dynamicPass.autoScaled;
                    pass.drawBufferCount = cmd.dynamicPass.drawBufferCount;
                    pass.hasStencil = cmd.dynamicPass.hasStencil;
                }
                oglEndDynamicComposite(pass);
                if (dynDrawStack.length) {
                    auto before = dynDrawStack[$-1];
                    dynDrawStack.length = dynDrawStack.length - 1;
                    dynDepth = cast(int)dynDrawStack.length;
                    dynLogged.length = dynLogged.length - 1;
                    writeln("[renderCommands] endDyn drawsAdded=", cast(int)drawCount - before);
                }
                break;
            }
            default:
                writeln("[renderCommands] unknown cmd kind=", cast(uint)cmd.kind);
                break;
        }
    }
    writeln("[renderCommands] counts draw=", drawCount,
            " beginMask=", beginMaskCount,
            " applyMask=", applyMaskCount,
            " beginMaskContent=", beginMaskContentCount,
            " endMask=", endMaskCount,
            " beginDyn=", beginDynCount,
            " endDyn=", endDynCount);
    oglPostProcessScene();
    // After nlshim rendering, blit scene to backbuffer.
    auto srcFbo = oglGetFramebuffer();
    glBindFramebuffer(GL_READ_FRAMEBUFFER, srcFbo);
    glReadBuffer(GL_COLOR_ATTACHMENT0);
    // Debug: sample source FBO center before blit
    ubyte[4] srcSample;
    glReadPixels(gl.drawableW/2, gl.drawableH/2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, srcSample.ptr);

    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0);
    glDrawBuffer(GL_BACK);
    glViewport(0, 0, gl.drawableW, gl.drawableH);
    GLint fbBind = 0;
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &fbBind);
    import std.stdio : writeln;
    writeln("[blit] READ=", srcFbo, " DRAW=", fbBind);
    glBlitFramebuffer(0, 0, gl.drawableW, gl.drawableH,
                      0, 0, gl.drawableW, gl.drawableH,
                      GL_COLOR_BUFFER_BIT, GL_LINEAR);

    // Debug: sample backbuffer center & sidebar average after blit.
    ubyte[4] dstSample;
    glReadPixels(gl.drawableW/2, gl.drawableH/2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, dstSample.ptr);
    enum sidebarW = 64;
    ubyte[] buf = new ubyte[sidebarW * gl.drawableH * 4];
    glReadPixels(0, 0, sidebarW, gl.drawableH, GL_RGBA, GL_UNSIGNED_BYTE, buf.ptr);
    ulong sum = 0;
    foreach(b; buf) sum += b;
    writeln("[fb-sample] src rgba=", srcSample[0], ",", srcSample[1], ",", srcSample[2], ",", srcSample[3],
            " dst rgba=", dstSample[0], ",", dstSample[1], ",", dstSample[2], ",", dstSample[3],
            " sidebarAvg=", cast(double)sum / buf.length);
    // Thumbnail grid (debug). Renders 48x48 tiles for all textures in gTextures at left sidebar.
    {
        GLint prevFbo = 0, prevProgram = 0, prevVao = 0, prevDrawBuf = 0;
        GLboolean prevDepth = 0, prevStencil = 0, prevCull = 0, prevScissor = 0;
        GLint[4] prevViewport;
        glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &prevFbo);
        glGetIntegerv(GL_CURRENT_PROGRAM, &prevProgram);
        glGetIntegerv(GL_VERTEX_ARRAY_BINDING, &prevVao);
        glGetIntegerv(GL_DRAW_BUFFER, &prevDrawBuf);
        glGetIntegerv(GL_VIEWPORT, prevViewport.ptr);
        prevDepth = glIsEnabled(GL_DEPTH_TEST);
        prevStencil = glIsEnabled(GL_STENCIL_TEST);
        prevCull = glIsEnabled(GL_CULL_FACE);
        prevScissor = glIsEnabled(GL_SCISSOR_TEST);

        writeln("[renderCommands] thumbnail grid");
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        glDisable(GL_DEPTH_TEST);
        glDisable(GL_STENCIL_TEST);
        glDisable(GL_CULL_FACE);
        glViewport(0, 0, gl.drawableW, gl.drawableH);
        glDrawBuffer(GL_BACK);

        glEnable(GL_SCISSOR_TEST);
        const float tile = 48;
        const float pad = 2;
        float sidebarWidthPx = (tile + pad) * 8; // room for a few columns
        glScissor(0, 0, cast(int)sidebarWidthPx, gl.drawableH);
        glClearColor(0.18f, 0.18f, 0.18f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        glDisable(GL_SCISSOR_TEST);

        ensureDebugTestTex();
        float tx = pad;
        float ty = pad;
        // First tile: debug checkerboard
        drawTile(gDebugTestTex, tx, ty, tile, gl.drawableW, gl.drawableH);
        ty += tile + pad;
        foreach (handle, tex; gTextures) {
            if (tex !is null) {
                drawTile(tex.getTextureId(), tx, ty, tile, gl.drawableW, gl.drawableH);
                ty += tile + pad;
                if (ty + tile > gl.drawableH - pad) {
                    ty = pad;
                    tx += tile + pad;
                }
            }
        }
        GLenum err = glGetError();
        if (err != GL_NO_ERROR) writeln("[renderCommands] thumb glGetError=", err);

        // Restore previous GL state.
        if (prevDepth) glEnable(GL_DEPTH_TEST); else glDisable(GL_DEPTH_TEST);
        if (prevStencil) glEnable(GL_STENCIL_TEST); else glDisable(GL_STENCIL_TEST);
        if (prevCull) glEnable(GL_CULL_FACE); else glDisable(GL_CULL_FACE);
        if (prevScissor) glEnable(GL_SCISSOR_TEST); else glDisable(GL_SCISSOR_TEST);
        glBindFramebuffer(GL_FRAMEBUFFER, prevFbo);
        glViewport(prevViewport[0], prevViewport[1], prevViewport[2], prevViewport[3]);
        glDrawBuffer(prevDrawBuf);
        glUseProgram(prevProgram);
        glBindVertexArray(prevVao);
    }
    // 次フレームへのリークを避ける
    glUseProgram(0);
    glBindVertexArray(0);
    glFlush();
    oglEndScene();
}
