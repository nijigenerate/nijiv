module opengl.opengl_backend;

import std.exception : enforce;
import std.string : fromStringz;
import std.conv : to;
import std.file : write;
import std.stdio : File, writeln, stdout;

import bindbc.sdl;
import bindbc.opengl;

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

alias NlMaskKind = MaskDrawableKind;

// placeholder types for difference evaluation (merged)
struct DifferenceEvaluationRegion {}
struct DifferenceEvaluationResult {}

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


// ==== nlshim merged (pure copy, no edits) ====
// ---- source/nlshim/core/dbg.d ----


private bool debugInitialized;
private bool hasDebugBuffer;

private RenderBackend backendOrNull() {
    return tryRenderBackend();
}

private RenderBackend backendForDebug() {
    auto backend = backendOrNull();
    if (backend is null) return null;
    if (!debugInitialized) {
        backend.initDebugRenderer();
        debugInitialized = true;
    }
    return backend;
}

public void inInitDebug() {
    backendForDebug();
}

bool inDbgDrawMeshOutlines = false;
bool inDbgDrawMeshVertexPoints = false;
bool inDbgDrawMeshOrientation = false;

void inDbgPointsSize(float size) {
    auto backend = backendForDebug();
    if (backend !is null) {
        backend.setDebugPointSize(size);
    }
}

void inDbgLineWidth(float size) {
    auto backend = backendForDebug();
    if (backend !is null) {
        backend.setDebugLineWidth(size);
    }
}

void inDbgSetBuffer(Vec3Array points) {
    size_t vertexCount = points.length;
    size_t indexCount = vertexCount == 0 ? 0 : vertexCount + 1;
    ushort[] indices = new ushort[indexCount];
    foreach (i; 0 .. vertexCount) {
        indices[i] = cast(ushort)i;
    }
    if (indices.length) {
        indices[$ - 1] = 0;
    }
    inDbgSetBuffer(points, indices);
}

void inDbgSetBuffer(RenderResourceHandle vbo, RenderResourceHandle ibo, int count) {
    auto backend = backendForDebug();
    if (backend is null) return;
    backend.setDebugExternalBuffer(vbo, ibo, count);
    hasDebugBuffer = count > 0;
}

void inDbgSetBuffer(Vec3Array points, ushort[] indices) {
    if (points.length == 0 || indices.length == 0) {
        hasDebugBuffer = false;
        return;
    }
    auto backend = backendForDebug();
    if (backend is null) return;
    backend.uploadDebugBuffer(points, indices);
    hasDebugBuffer = true;
}

void inDbgDrawPoints(vec4 color, mat4 transform = mat4.identity) {
    if (!hasDebugBuffer) return;
    auto backend = backendForDebug();
    if (backend is null) return;
    backend.drawDebugPoints(color, inGetCamera().matrix * transform);
}

void inDbgDrawLines(vec4 color, mat4 transform = mat4.identity) {
    if (!hasDebugBuffer) return;
    auto backend = backendForDebug();
    if (backend is null) return;
    backend.drawDebugLines(color, inGetCamera().matrix * transform);
}

// ---- source/nlshim/core/package.d ----
/*
    nijilive Rendering
    Inochi2D Rendering

    Copyright © 2020, Inochi2D Project
    Copyright © 2024, nijigenerate Project
    Distributed under the 2-Clause BSD License, see LICENSE file.
    
    Authors: Luna Nielsen
*/

version(InDoesRender) {
    version(UseQueueBackend) {
    } else {
        // OpenGL backend is provided by top-level opengl/* modules; avoid importing nlshim copies.
    }
}
//import std.stdio;

/**
    UDA for sub-classable parts of the spec
    eg. Nodes and Automation can be extended by
    adding new subclasses that aren't in the base spec.
*/
struct TypeId { string id; }

/**
    Different modes of interpolation between values.
*/
enum InterpolateMode {

    /**
        Round to nearest
    */
    Nearest,
    
    /**
        Linear interpolation
    */
    Linear,

    /**
        Round to nearest
    */
    Stepped,

    /**
        Cubic interpolation
    */
    Cubic,

    /**
        Interpolation using beziér splines
    */
    Bezier,

    COUNT
}

// ---- source/nlshim/core/render/backends/opengl/blend.d ----


version (InDoesRender) {

import bindbc.opengl;
import bindbc.opengl.context;

private __gshared Shader[BlendMode] blendShaders;

private void ensureBlendShadersInitialized() {
    if (blendShaders.length > 0) return;

    auto advancedBlendShader = new Shader(shaderAsset!("opengl/shaders/opengl/basic/basic.vert","opengl/shaders/opengl/basic/advanced_blend.frag")());
    BlendMode[] advancedModes = [
        BlendMode.Multiply,
        BlendMode.Screen,
        BlendMode.Overlay,
        BlendMode.Darken,
        BlendMode.Lighten,
        BlendMode.ColorDodge,
        BlendMode.ColorBurn,
        BlendMode.HardLight,
        BlendMode.SoftLight,
        BlendMode.Difference,
        BlendMode.Exclusion
    ];
    foreach (mode; advancedModes) {
        blendShaders[mode] = advancedBlendShader;
    }
}

Shader oglGetBlendShader(BlendMode mode) {
    ensureBlendShadersInitialized();
    auto shader = mode in blendShaders;
    return shader ? *shader : null;
}

void oglBlendToBuffer(
    Shader shader,
    BlendMode mode,
    GLuint dstFramebuffer,
    GLuint bgAlbedo, GLuint bgEmissive, GLuint bgBump,
    GLuint fgAlbedo, GLuint fgEmissive, GLuint fgBump
) {
    if (shader is null) return;

    glBindFramebuffer(GL_FRAMEBUFFER, dstFramebuffer);
    glDrawBuffers(3, [GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2].ptr);

    shader.use();
    GLint modeUniform = shader.getUniformLocation("blend_mode");
    if (modeUniform != -1) {
        shader.setUniform(modeUniform, cast(int)mode);
    }

    glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, bgAlbedo);
    glActiveTexture(GL_TEXTURE1); glBindTexture(GL_TEXTURE_2D, bgEmissive);
    glActiveTexture(GL_TEXTURE2); glBindTexture(GL_TEXTURE_2D, bgBump);

    glActiveTexture(GL_TEXTURE3); glBindTexture(GL_TEXTURE_2D, fgAlbedo);
    glActiveTexture(GL_TEXTURE4); glBindTexture(GL_TEXTURE_2D, fgEmissive);
    glActiveTexture(GL_TEXTURE5); glBindTexture(GL_TEXTURE_2D, fgBump);

    shader.setUniform(shader.getUniformLocation("bg_albedo"), 0);
    shader.setUniform(shader.getUniformLocation("bg_emissive"), 1);
    shader.setUniform(shader.getUniformLocation("bg_bump"), 2);
    shader.setUniform(shader.getUniformLocation("fg_albedo"), 3);
    shader.setUniform(shader.getUniformLocation("fg_emissive"), 4);
    shader.setUniform(shader.getUniformLocation("fg_bump"), 5);

    GLint mvpUniform = shader.getUniformLocation("mvp");
    if (mvpUniform != -1) {
        shader.setUniform(mvpUniform, mat4.identity);
    }

    GLint offsetUniform = shader.getUniformLocation("offset");
    if (offsetUniform != -1) {
        shader.setUniform(offsetUniform, vec2(0, 0));
    }

    // VAO not used; handled in shader setup.
    glDrawArrays(GL_TRIANGLES, 0, 6);

    glActiveTexture(GL_TEXTURE5); glBindTexture(GL_TEXTURE_2D, 0);
    glActiveTexture(GL_TEXTURE4); glBindTexture(GL_TEXTURE_2D, 0);
    glActiveTexture(GL_TEXTURE3); glBindTexture(GL_TEXTURE_2D, 0);
    glActiveTexture(GL_TEXTURE2); glBindTexture(GL_TEXTURE_2D, 0);
    glActiveTexture(GL_TEXTURE1); glBindTexture(GL_TEXTURE_2D, 0);
    glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, 0);
}

// Some platforms/bindings lack GL_KHR_blend_equation_advanced; fall back safely.
void oglSetAdvancedBlendCoherent(bool enable) { /* no-op fallback */ }

void oglSetLegacyBlendMode(BlendMode blendingMode) {
    switch (blendingMode) {
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

void oglSetAdvancedBlendEquation(BlendMode blendingMode) {
    // Fallback: use legacy path if advanced equations are unavailable.
    oglSetLegacyBlendMode(blendingMode);
}

void oglIssueBlendBarrier() {
    // no-op when advanced blend barrier is unavailable
}

bool oglSupportsAdvancedBlend() {
    return hasKHRBlendEquationAdvanced;
}

bool oglSupportsAdvancedBlendCoherent() {
    return hasKHRBlendEquationAdvancedCoherent;
}

} else {

alias GLuint = uint;

Shader oglGetBlendShader(BlendMode) { return null; }
void oglBlendToBuffer(Shader, BlendMode, GLuint, GLuint, GLuint, GLuint, GLuint, GLuint, GLuint) {}
void oglSetAdvancedBlendCoherent(bool) {}
void oglSetLegacyBlendMode(BlendMode) {}
void oglSetAdvancedBlendEquation(BlendMode) {}
void oglIssueBlendBarrier() {}
bool oglSupportsAdvancedBlend() { return false; }
bool oglSupportsAdvancedBlendCoherent() { return false; }

}

// ---- source/nlshim/core/render/backends/opengl/buffer_sync.d ----

version (InDoesRender) {

// GL buffer fences are disabled to avoid per-draw glFenceSync spam.
// Keep stubs so call sites compile; they intentionally do nothing.
void waitForBuffer(uint /*buffer*/, string /*label*/) {}
void markBufferInUse(uint /*buffer*/) {}

} else {

void waitForBuffer(uint, string) {}
void markBufferInUse(uint) {}

}

// ---- source/nlshim/core/render/backends/opengl/debug_renderer.d ----


version (InDoesRender) {

import bindbc.opengl;

private Shader lineShader;
private Shader pointShader;
enum ShaderAsset LineShaderSource = shaderAsset!("opengl/shaders/opengl/dbg.vert","opengl/shaders/opengl/dbgline.frag")();
enum ShaderAsset PointShaderSource = shaderAsset!("opengl/shaders/opengl/dbg.vert","opengl/shaders/opengl/dbgpoint.frag")();
private GLuint vao;
private GLuint vbo;
private GLuint ibo;
private GLuint currentVbo;
private int indexCount;
private int lineMvpLocation = -1;
private int lineColorLocation = -1;
private int pointMvpLocation = -1;
private int pointColorLocation = -1;
private __gshared int pointCount;
private __gshared bool bufferIsSoA;

private void ensureInitialized() {
    if (lineShader !is null) return;

    lineShader = new Shader(LineShaderSource);
    pointShader = new Shader(PointShaderSource);

    lineMvpLocation = lineShader.getUniformLocation("mvp");
    lineColorLocation = lineShader.getUniformLocation("color");
    pointMvpLocation = pointShader.getUniformLocation("mvp");
    pointColorLocation = pointShader.getUniformLocation("color");

    glGenVertexArrays(1, &vao);
    glGenBuffers(1, &vbo);
    glGenBuffers(1, &ibo);
    currentVbo = vbo;
    indexCount = 0;
}

package(opengl) void oglInitDebugRenderer() {
    ensureInitialized();
}

package(opengl) void oglSetDebugPointSize(float size) {
    glPointSize(size);
}

package(opengl) void oglSetDebugLineWidth(float size) {
    glLineWidth(size);
}

package(opengl) void oglUploadDebugBuffer(Vec3Array points, ushort[] indices) {
    ensureInitialized();
    if (points.length == 0 || indices.length == 0) {
        indexCount = 0;
        pointCount = 0;
        bufferIsSoA = false;
        return;
    }

    glBindVertexArray(vao);
    glUploadFloatVecArray(vbo, points, GL_DYNAMIC_DRAW, "UploadDebug");
    currentVbo = vbo;
    pointCount = cast(int)points.length;
    bufferIsSoA = true;

    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, ibo);
    glBufferData(GL_ELEMENT_ARRAY_BUFFER, indices.length * ushort.sizeof, indices.ptr, GL_DYNAMIC_DRAW);
    indexCount = cast(int)indices.length;
}

package(opengl) void oglSetDebugExternalBuffer(RenderResourceHandle vertexBuffer, RenderResourceHandle indexBuffer, int count) {
    ensureInitialized();

    auto vertexHandle = cast(GLuint)vertexBuffer;
    auto indexHandle = cast(GLuint)indexBuffer;

    glBindVertexArray(vao);
    glBindBuffer(GL_ARRAY_BUFFER, vertexHandle);
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, indexHandle);
    currentVbo = vertexHandle;
    indexCount = count;
    bufferIsSoA = false;
    pointCount = 0;
}

private void prepareDraw(Shader shader, int mvpLocation, int colorLocation, mat4 mvp, vec4 color) {
    if (shader is null || indexCount <= 0) return;

    shader.use();
    shader.setUniform(mvpLocation, mvp);
    shader.setUniform(colorLocation, color);

    glBindVertexArray(vao);
    if (bufferIsSoA && pointCount > 0) {
        auto laneBytes = cast(ptrdiff_t)pointCount * float.sizeof;
        glEnableVertexAttribArray(0);
        glBindBuffer(GL_ARRAY_BUFFER, currentVbo);
        glVertexAttribPointer(0, 1, GL_FLOAT, GL_FALSE, 0, cast(void*)0);

        glEnableVertexAttribArray(1);
        glBindBuffer(GL_ARRAY_BUFFER, currentVbo);
        glVertexAttribPointer(1, 1, GL_FLOAT, GL_FALSE, 0, cast(void*)laneBytes);

        glEnableVertexAttribArray(2);
        glBindBuffer(GL_ARRAY_BUFFER, currentVbo);
        glVertexAttribPointer(2, 1, GL_FLOAT, GL_FALSE, 0, cast(void*)(laneBytes * 2));
    } else {
        glEnableVertexAttribArray(0);
        glBindBuffer(GL_ARRAY_BUFFER, currentVbo);
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 0, null);
        glDisableVertexAttribArray(1);
        glDisableVertexAttribArray(2);
    }
}

private void finishDraw() {
    glDisableVertexAttribArray(0);
    glDisableVertexAttribArray(1);
    glDisableVertexAttribArray(2);
    glBindVertexArray(0);
}

package(opengl) void oglDrawDebugPoints(vec4 color, mat4 mvp) {
    ensureInitialized();
    if (indexCount <= 0) return;

    glBlendEquation(GL_FUNC_ADD);
    glBlendFuncSeparate(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA, GL_ONE, GL_ONE);

    prepareDraw(pointShader, pointMvpLocation, pointColorLocation, mvp, color);
    glDrawElements(GL_POINTS, indexCount, GL_UNSIGNED_SHORT, null);
    finishDraw();

    glBlendFuncSeparate(GL_ONE, GL_ONE_MINUS_SRC_ALPHA, GL_ONE, GL_ONE);
}

package(opengl) void oglDrawDebugLines(vec4 color, mat4 mvp) {
    ensureInitialized();
    if (indexCount <= 0) return;

    glEnable(GL_LINE_SMOOTH);
    glBlendEquation(GL_FUNC_ADD);
    glBlendFuncSeparate(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA, GL_ONE, GL_ONE);

    prepareDraw(lineShader, lineMvpLocation, lineColorLocation, mvp, color);
    glDrawElements(GL_LINES, indexCount, GL_UNSIGNED_SHORT, null);
    finishDraw();

    glBlendFuncSeparate(GL_ONE, GL_ONE_MINUS_SRC_ALPHA, GL_ONE, GL_ONE);
    glDisable(GL_LINE_SMOOTH);
}

} else {

package(opengl) void oglInitDebugRenderer() {}
package(opengl) void oglSetDebugPointSize(float) {}
package(opengl) void oglSetDebugLineWidth(float) {}
package(opengl) void oglUploadDebugBuffer(Vec3Array, ushort[]) {}
package(opengl) void oglSetDebugExternalBuffer(RenderResourceHandle, RenderResourceHandle, int) {}
package(opengl) void oglDrawDebugPoints(vec4, mat4) {}
package(opengl) void oglDrawDebugLines(vec4, mat4) {}

}





// ---- source/nlshim/core/render/backends/opengl/drawable_buffers.d ----


version (unittest) {
    alias GLuint = uint;

    void oglInitDrawableBackend() {}
    void oglBindDrawableVao() {}
    void oglCreateDrawableBuffers(ref RenderResourceHandle ibo) {
        ibo = 0;
    }
    void oglUploadDrawableIndices(RenderResourceHandle, ushort[]) {}
    void oglUploadSharedVertexBuffer(Vec2Array) {}
    void oglUploadSharedUvBuffer(Vec2Array) {}
    void oglUploadSharedDeformBuffer(Vec2Array) {}
    GLuint oglGetSharedVertexBuffer() { return 0; }
    GLuint oglGetSharedUvBuffer() { return 0; }
    GLuint oglGetSharedDeformBuffer() { return 0; }
    void oglDrawDrawableElements(GLuint, size_t) {}
} else version (InDoesRender):

import bindbc.opengl;

private __gshared GLuint drawableVAO;
private __gshared bool drawableBuffersInitialized = false;
private __gshared GLuint sharedDeformBuffer;
private __gshared GLuint sharedVertexBuffer;
private __gshared GLuint sharedUvBuffer;
private __gshared GLuint sharedIndexBuffer;
private __gshared size_t sharedIndexCapacity;
private __gshared size_t sharedIndexOffset;
private __gshared RenderResourceHandle nextIndexHandle = 1;

private struct IndexRange {
    size_t offset;
    size_t count;
    size_t capacity;
    ushort[] data;
}
private __gshared IndexRange[RenderResourceHandle] sharedIndexRanges;

private void ensureSharedIndexBuffer(size_t bytes) {
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
void oglInitDrawableBackend() {
    if (drawableBuffersInitialized) return;
    drawableBuffersInitialized = true;
    glGenVertexArrays(1, &drawableVAO);
}

void oglBindDrawableVao() {
    oglInitDrawableBackend();
    glBindVertexArray(drawableVAO);
}

void oglCreateDrawableBuffers(ref RenderResourceHandle ibo) {
    oglInitDrawableBackend();
    if (ibo == 0) {
        ibo = nextIndexHandle++;
    }
}

void oglUploadDrawableIndices(RenderResourceHandle ibo, ushort[] indices) {
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

void oglUploadSharedVertexBuffer(Vec2Array vertices) {
    if (vertices.length == 0) {
        return;
    }
    if (sharedVertexBuffer == 0) {
        glGenBuffers(1, &sharedVertexBuffer);
    }
    glUploadFloatVecArray(sharedVertexBuffer, vertices, GL_DYNAMIC_DRAW, "UploadVertices");
}

void oglUploadSharedUvBuffer(Vec2Array uvs) {
    if (uvs.length == 0) {
        return;
    }
    if (sharedUvBuffer == 0) {
        glGenBuffers(1, &sharedUvBuffer);
    }
    glUploadFloatVecArray(sharedUvBuffer, uvs, GL_DYNAMIC_DRAW, "UploadUV");
}

void oglUploadSharedDeformBuffer(Vec2Array deformation) {
    if (deformation.length == 0) {
        return;
    }
    if (sharedDeformBuffer == 0) {
        glGenBuffers(1, &sharedDeformBuffer);
    }
    glUploadFloatVecArray(sharedDeformBuffer, deformation, GL_DYNAMIC_DRAW, "UploadDeform");
}

GLuint oglGetSharedVertexBuffer() {
    if (sharedVertexBuffer == 0) {
        glGenBuffers(1, &sharedVertexBuffer);
    }
    return sharedVertexBuffer;
}

GLuint oglGetSharedUvBuffer() {
    if (sharedUvBuffer == 0) {
        glGenBuffers(1, &sharedUvBuffer);
    }
    return sharedUvBuffer;
}

GLuint oglGetSharedDeformBuffer() {
    if (sharedDeformBuffer == 0) {
        glGenBuffers(1, &sharedDeformBuffer);
    }
    return sharedDeformBuffer;
}

void oglDrawDrawableElements(RenderResourceHandle ibo, size_t indexCount) {
    if (ibo == 0 || indexCount == 0) return;
    auto rangePtr = ibo in sharedIndexRanges;
    if (rangePtr is null || sharedIndexBuffer == 0) return;
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, sharedIndexBuffer);
    auto offset = rangePtr.offset;
    glDrawElements(GL_TRIANGLES, cast(int)indexCount, GL_UNSIGNED_SHORT, cast(void*)offset);
}

// ---- source/nlshim/core/render/backends/opengl/dynamic_composite.d ----

version (InDoesRender) {

import bindbc.opengl;
version (NijiliveRenderProfiler) {
    import std.stdio : writefln;
    import std.format : format;
}
version (NijiliveRenderProfiler) {
    import core.time : MonoTime;

    __gshared ulong gCompositeCpuAccumUsec;
    __gshared ulong gCompositeGpuAccumUsec;

    void resetCompositeAccum() {
        gCompositeCpuAccumUsec = 0;
        gCompositeGpuAccumUsec = 0;
    }

    ulong compositeCpuAccumUsec() { return gCompositeCpuAccumUsec; }
    ulong compositeGpuAccumUsec() { return gCompositeGpuAccumUsec; }
}

private GLuint textureId(Texture texture) {
    if (texture is null) return 0;
    auto handle = texture.backendHandle();
    if (handle is null) return 0;
    return requireGLTexture(handle).id;
}

private {
    void logFboState(string tag) {
        GLint drawFbo;
        GLint readFbo;
        GLint[4] vp;
        GLint[4] dbufs;
        glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &drawFbo);
        glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &readFbo);
        glGetIntegerv(GL_VIEWPORT, vp.ptr);
        foreach (i; 0 .. 4) {
            glGetIntegerv(GL_DRAW_BUFFER0 + i, &dbufs[i]);
        }
        auto status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
        GLint err = glGetError();
        import std.stdio : writefln;
        writefln("[dc-log] %s drawFbo=%s readFbo=%s drawBufs=%s status=0x%x vp=%s err=%s",
            tag, drawFbo, readFbo, dbufs, status, vp, err);
    }

    void logGlErr(string tag) {
        GLint err = glGetError();
        import std.stdio : writefln;
        writefln("[dc-err] %s glError=%s", tag, err);
    }

    version (NijiliveRenderProfiler) {
        GLuint compositeTimeQuery;
        bool compositeTimerInit;
        bool compositeTimerActive;
        MonoTime compositeCpuStart;
        bool compositeCpuActive;

        void ensureCompositeTimer() {
            if (compositeTimerInit) return;
            compositeTimerInit = true;
            glGenQueries(1, &compositeTimeQuery);
        }
    }
}

void oglBeginDynamicComposite(DynamicCompositePass pass) {
    if (pass is null) {
        debug (NijiliveRenderProfiler) writefln("[nijilive] oglBeginDynamicComposite skip: pass=null");
        return;
    }
    auto surface = pass.surface;
    if (surface is null) {
        debug (NijiliveRenderProfiler) writefln("[nijilive] oglBeginDynamicComposite skip: surface=null");
        return;
    }
    if (surface.textureCount == 0) {
        debug (NijiliveRenderProfiler) writefln("[nijilive] oglBeginDynamicComposite skip: textureCount=0");
        return;
    }
    auto tex = surface.textures[0];
    if (tex is null) {
        debug (NijiliveRenderProfiler) writefln("[nijilive] oglBeginDynamicComposite skip: tex[0]=null");
        return;
    }

    if (surface.framebuffer == 0) {
        GLuint newFramebuffer;
        glGenFramebuffers(1, &newFramebuffer);
        surface.framebuffer = cast(RenderResourceHandle)newFramebuffer;
    }


    logFboState("pre-begin");
    // Save current framebuffer/viewport so we can restore later.
    GLint previousFramebuffer;
    GLint previousReadFramebuffer;
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &previousFramebuffer);
    glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &previousReadFramebuffer);
    pass.origBuffer = cast(RenderResourceHandle)previousFramebuffer;
    glGetIntegerv(GL_VIEWPORT, pass.origViewport.ptr);

    glBindFramebuffer(GL_FRAMEBUFFER, cast(GLuint)surface.framebuffer);
    logGlErr("bind offscreen FBO");

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

    inPushViewport(tex.width, tex.height);

    // Camera is managed on the queue side; no mutation here.

    glDrawBuffers(cast(int)bufferCount, drawBuffers.ptr);
    pass.drawBufferCount = cast(int)bufferCount;
    logGlErr("drawBuffers offscreen");
    glViewport(0, 0, tex.width, tex.height);
    glClearColor(0, 0, 0, 0);
    glClear(GL_COLOR_BUFFER_BIT);
    logGlErr("clear offscreen");
    glActiveTexture(GL_TEXTURE0);
    glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
    debug (NijiliveRenderProfiler) {
    auto beginMsg = format(
        "[nijilive] oglBeginDynamicComposite fbo=%s tex0=%s size=%sx%s scale=%s rotZ=%s autoScaled=%s origFbo=%s origViewport=%s,%s,%s,%s cameraPos=%s cameraScale=%s cameraRot=%s",
        surface.framebuffer, textureId(tex), tex.width, tex.height,
        pass.scale, pass.rotationZ, pass.autoScaled,
        pass.origBuffer, pass.origViewport[0], pass.origViewport[1], pass.origViewport[2], pass.origViewport[3],
        camera.position, camera.scale, camera.rotation);
    writefln(beginMsg);
    }

    logFboState("post-begin");
    version (NijiliveRenderProfiler) {
        if (!compositeCpuActive) {
            compositeCpuActive = true;
            compositeCpuStart = MonoTime.currTime;
        }
        ensureCompositeTimer();
        if (!compositeTimerActive && compositeTimeQuery != 0) {
            glBeginQuery(GL_TIME_ELAPSED, compositeTimeQuery);
            compositeTimerActive = true;
        }
    }
}

void oglEndDynamicComposite(DynamicCompositePass pass) {
    if (pass is null) {
        debug (NijiliveRenderProfiler) writefln("[nijilive] oglEndDynamicComposite skip: pass=null");
        return;
    }
    if (pass.surface is null) {
        debug (NijiliveRenderProfiler) writefln("[nijilive] oglEndDynamicComposite skip: surface=null");
        return;
    }

    logFboState("pre-end");
    // Rebind active attachments (respecting any swaps that happened while rendering).
    oglRebindActiveTargets();

    // Restore framebuffer and viewport to the state saved at begin.
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, cast(GLuint)pass.origBuffer);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, cast(GLuint)pass.origBuffer);
    inPopViewport();
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
    logGlErr("restore draw buffers");
    logFboState("post-end");
    debug (NijiliveRenderProfiler) {
    auto endMsg = format(
        "[nijilive] oglEndDynamicComposite restore origFbo=%s viewport=%s,%s,%s,%s autoScaled=%s",
        pass.origBuffer, pass.origViewport[0], pass.origViewport[1], pass.origViewport[2], pass.origViewport[3],
        pass.autoScaled);
    writefln(endMsg);
    }
    version (NijiliveRenderProfiler) {
        if (compositeTimerActive && compositeTimeQuery != 0) {
            glEndQuery(GL_TIME_ELAPSED);
            ulong ns = 0;
            glGetQueryObjectui64v(compositeTimeQuery, GL_QUERY_RESULT, &ns);
            renderProfilerAddSampleUsec("Composite.Offscreen", ns / 1000);
            gCompositeGpuAccumUsec += ns / 1000;
            compositeTimerActive = false;
        }
        if (compositeCpuActive) {
            auto dur = MonoTime.currTime - compositeCpuStart;
            renderProfilerAddSampleUsec("Composite.Offscreen.CPU", dur.total!"usecs");
            gCompositeCpuAccumUsec += dur.total!"usecs";
            compositeCpuActive = false;
        }
    }
    glFlush();

    auto tex = pass.surface.textureCount > 0 ? pass.surface.textures[0] : null;
    if (tex !is null && !pass.autoScaled) {
        tex.genMipmap();
    }
}

void oglDestroyDynamicComposite(DynamicCompositeSurface surface) {
    if (surface is null) return;
    if (surface.framebuffer != 0) {
        auto buffer = cast(GLuint)surface.framebuffer;
        glDeleteFramebuffers(1, &buffer);
        surface.framebuffer = 0;
    }
}

} else {


void oglBeginDynamicComposite(DynamicCompositePass) {}
void oglEndDynamicComposite(DynamicCompositePass) {}
void oglDestroyDynamicComposite(DynamicCompositeSurface) {}

}

// ---- source/nlshim/core/render/backends/opengl/handles.d ----

import std.exception : enforce;

class GLShaderHandle : RenderShaderHandle {
    ShaderProgramHandle shader;
}

class GLTextureHandle : RenderTextureHandle {
    GLId id;
}

GLShaderHandle requireGLShader(RenderShaderHandle handle) {
    auto result = cast(GLShaderHandle)handle;
    enforce(result !is null, "Shader handle is not backed by OpenGL");
    return result;
}

GLTextureHandle requireGLTexture(RenderTextureHandle handle) {
    auto result = cast(GLTextureHandle)handle;
    enforce(result !is null, "Texture handle is not backed by OpenGL");
    return result;
}

// ---- source/nlshim/core/render/backends/opengl/mask.d ----


version (InDoesRender) {

import bindbc.opengl;

private __gshared Shader maskShader;
enum ShaderAsset MaskShaderSource = shaderAsset!("opengl/shaders/opengl/mask.vert","opengl/shaders/opengl/mask.frag")();
private __gshared GLint maskOffsetUniform;
private __gshared GLint maskMvpUniform;
private __gshared bool maskBackendInitialized = false;

private void ensureMaskBackendInitialized() {
    if (maskBackendInitialized) return;
    maskBackendInitialized = true;

    maskShader = new Shader(MaskShaderSource);
    maskOffsetUniform = maskShader.getUniformLocation("offset");
    maskMvpUniform = maskShader.getUniformLocation("mvp");
}

void oglInitMaskBackend() {
    ensureMaskBackendInitialized();
}

/// Prepare stencil for mask rendering.
/// useStencil == true when there is at least one normal mask (write 1 to masked area).
/// useStencil == false when only dodge masks are present (keep stencil at 1 and punch 0 holes).
void oglBeginMask(bool useStencil) {
    glEnable(GL_STENCIL_TEST);
    // Clear stencil to 0 for normal-mask path, 1 for dodge-only path.
    glClearStencil(useStencil ? 0 : 1);
    glClear(GL_STENCIL_BUFFER_BIT);
    // Reset state to a known baseline before ApplyMask sets specific ops/func.
    glStencilMask(0xFF);
    glStencilFunc(GL_ALWAYS, useStencil ? 0 : 1, 0xFF);
    glStencilOp(GL_KEEP, GL_KEEP, GL_KEEP);
}

void oglEndMask() {
    glStencilMask(0xFF);
    glStencilFunc(GL_ALWAYS, 1, 0xFF);
    glDisable(GL_STENCIL_TEST);
}

void oglBeginMaskContent() {
    glStencilFunc(GL_EQUAL, 1, 0xFF);
    glStencilMask(0x00);
}

void oglExecuteMaskPacket(ref MaskDrawPacket packet) {
    ensureMaskBackendInitialized();
    if (packet.indexCount == 0) return;

    incDrawableBindVAO();

    maskShader.use();
    maskShader.setUniform(maskOffsetUniform, packet.origin);
    maskShader.setUniform(maskMvpUniform, packet.mvp);

    if (packet.vertexCount == 0 || packet.vertexAtlasStride == 0 || packet.deformAtlasStride == 0) return;
    auto sharedVbo = oglGetSharedVertexBuffer();
    auto sharedDbo = oglGetSharedDeformBuffer();
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

    oglDrawDrawableElements(packet.indexBuffer, packet.indexCount);
    markBufferInUse(sharedVbo);
    markBufferInUse(sharedDbo);

    glDisableVertexAttribArray(0);
    glDisableVertexAttribArray(1);
    glDisableVertexAttribArray(2);
    glDisableVertexAttribArray(3);
}

void oglExecuteMaskApplyPacket(ref MaskApplyPacket packet) {
    ensureMaskBackendInitialized();
    glColorMask(GL_FALSE, GL_FALSE, GL_FALSE, GL_FALSE);
    glStencilOp(GL_KEEP, GL_KEEP, GL_REPLACE);
    glStencilFunc(GL_ALWAYS, packet.isDodge ? 0 : 1, 0xFF);
    glStencilMask(0xFF);

    final switch (packet.kind) {
        case MaskDrawableKind.Part:
            oglExecutePartPacket(packet.partPacket);
            break;
        case MaskDrawableKind.Mask:
            oglExecuteMaskPacket(packet.maskPacket);
            break;
    }

    glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
}

} else {


void oglBeginMask(bool) {}
void oglEndMask() {}
void oglBeginMaskContent() {}
void oglExecuteMaskPacket(ref MaskDrawPacket) {}
void oglExecuteMaskApplyPacket(ref MaskApplyPacket) {}
void oglInitMaskBackend() {}

}


// ---- source/nlshim/core/render/backends/opengl/package.d ----

version (InDoesRender) {


// queue/backend not used in this binary; avoid pulling queue modules
import inmath.linalg : rect;

class RenderingBackend(BackendEnum backendType : BackendEnum.OpenGL) {
    void initializeRenderer() {
        oglInitRenderer();
        oglInitDrawableBackend();
        oglInitPartBackendResources();
        oglInitMaskBackend();
    }

    void resizeViewportTargets(int width, int height) {
        oglResizeViewport(width, height);
    }

    void dumpViewport(ref ubyte[] data, int width, int height) {
        oglDumpViewport(data, width, height);
    }

    void beginScene() {
        auto profile = profileScope("BeginScene");
        oglBeginScene();
    }

    void endScene() {
        auto profile = profileScope("EndScene");
        oglEndScene();
        renderProfilerFrameCompleted();
    }

    void postProcessScene() {
        auto profile = profileScope("PostProcess");
        oglPostProcessScene();
    }

    void initializeDrawableResources() {
        oglInitDrawableBackend();
    }

    void bindDrawableVao() {
        oglBindDrawableVao();
    }

    void createDrawableBuffers(out RenderResourceHandle ibo) {
        oglCreateDrawableBuffers(ibo);
    }

    void uploadDrawableIndices(RenderResourceHandle ibo, ushort[] indices) {
        oglUploadDrawableIndices(ibo, indices);
    }

    void uploadSharedVertexBuffer(Vec2Array vertices) {
        auto profile = profileScope("UploadVertices");
        oglUploadSharedVertexBuffer(vertices);
    }

    void uploadSharedUvBuffer(Vec2Array uvs) {
        auto profile = profileScope("UploadUV");
        oglUploadSharedUvBuffer(uvs);
    }

    void uploadSharedDeformBuffer(Vec2Array deform) {
        auto profile = profileScope("UploadDeformAtlas");
        oglUploadSharedDeformBuffer(deform);
    }

    void drawDrawableElements(RenderResourceHandle ibo, size_t indexCount) {
        oglDrawDrawableElements(ibo, indexCount);
    }

    bool supportsAdvancedBlend() {
        return oglSupportsAdvancedBlend();
    }

    bool supportsAdvancedBlendCoherent() {
        return oglSupportsAdvancedBlendCoherent();
    }

    void setAdvancedBlendCoherent(bool enabled) {
        oglSetAdvancedBlendCoherent(enabled);
    }

    void setLegacyBlendMode(BlendMode mode) {
        oglSetLegacyBlendMode(mode);
    }

    void setAdvancedBlendEquation(BlendMode mode) {
        oglSetAdvancedBlendEquation(mode);
    }

    void issueBlendBarrier() {
        oglIssueBlendBarrier();
    }

    void initDebugRenderer() {
        oglInitDebugRenderer();
    }

    void setDebugPointSize(float size) {
        oglSetDebugPointSize(size);
    }

    void setDebugLineWidth(float size) {
        oglSetDebugLineWidth(size);
    }

    void uploadDebugBuffer(Vec3Array points, ushort[] indices) {
        oglUploadDebugBuffer(points, indices);
    }

    void setDebugExternalBuffer(RenderResourceHandle vbo, RenderResourceHandle ibo, int count) {
        oglSetDebugExternalBuffer(vbo, ibo, count);
    }

    void drawDebugPoints(vec4 color, mat4 mvp) {
        oglDrawDebugPoints(color, mvp);
    }

    void drawDebugLines(vec4 color, mat4 mvp) {
        oglDrawDebugLines(color, mvp);
    }

    void drawPartPacket(ref PartDrawPacket packet) {
        auto profile = profileScope("DrawPart");
        oglDrawPartPacket(packet);
    }

    void beginDynamicComposite(DynamicCompositePass pass) {
        oglBeginDynamicComposite(pass);
    }

    void endDynamicComposite(DynamicCompositePass pass) {
        oglEndDynamicComposite(pass);
    }

    void destroyDynamicComposite(DynamicCompositeSurface surface) {
        oglDestroyDynamicComposite(surface);
    }

    void beginMask(bool useStencil) {
        auto profile = profileScope("BeginMask");
        oglBeginMask(useStencil);
    }

    void applyMask(ref MaskApplyPacket packet) {
        auto profile = profileScope("ApplyMask");
        oglExecuteMaskApplyPacket(packet);
    }

    void beginMaskContent() {
        auto profile = profileScope("BeginMaskContent");
        oglBeginMaskContent();
    }

    void endMask() {
        auto profile = profileScope("EndMask");
        oglEndMask();
    }

    // drawTexture* helpers removed; viewer uses packet-driven path only.

    RenderResourceHandle framebufferHandle() {
        return cast(RenderResourceHandle)oglGetFramebuffer();
    }

    RenderResourceHandle renderImageHandle() {
        return cast(RenderResourceHandle)oglGetRenderImage();
    }

    RenderResourceHandle mainAlbedoHandle() {
        return cast(RenderResourceHandle)oglGetMainAlbedo();
    }

    RenderResourceHandle mainEmissiveHandle() {
        return cast(RenderResourceHandle)oglGetMainEmissive();
    }

    RenderResourceHandle mainBumpHandle() {
        return cast(RenderResourceHandle)oglGetMainBump();
    }

    RenderResourceHandle blendFramebufferHandle() {
        return cast(RenderResourceHandle)oglGetBlendFramebuffer();
    }

    RenderResourceHandle blendAlbedoHandle() {
        return cast(RenderResourceHandle)oglGetBlendAlbedo();
    }

    RenderResourceHandle blendEmissiveHandle() {
        return cast(RenderResourceHandle)oglGetBlendEmissive();
    }

    RenderResourceHandle blendBumpHandle() {
        return cast(RenderResourceHandle)oglGetBlendBump();
    }

    void addBasicLightingPostProcess() {
        oglAddBasicLightingPostProcess();
    }

    RenderShaderHandle createShader(string vertexSource, string fragmentSource) {
        auto handle = new GLShaderHandle();
        oglCreateShaderProgram(handle.shader, vertexSource, fragmentSource);
        return handle;
    }

    void destroyShader(RenderShaderHandle shader) {
        auto handle = requireGLShader(shader);
        oglDestroyShaderProgram(handle.shader);
        handle.shader = ShaderProgramHandle.init;
    }

    void useShader(RenderShaderHandle shader) {
        auto handle = requireGLShader(shader);
        oglUseShaderProgram(handle.shader);
    }

    int getShaderUniformLocation(RenderShaderHandle shader, string name) {
        auto handle = requireGLShader(shader);
        return oglShaderGetUniformLocation(handle.shader, name);
    }

    void setShaderUniform(RenderShaderHandle shader, int location, bool value) {
        requireGLShader(shader);
        oglSetUniformBool(location, value);
    }

    void setShaderUniform(RenderShaderHandle shader, int location, int value) {
        requireGLShader(shader);
        oglSetUniformInt(location, value);
    }

    void setShaderUniform(RenderShaderHandle shader, int location, float value) {
        requireGLShader(shader);
        oglSetUniformFloat(location, value);
    }

    void setShaderUniform(RenderShaderHandle shader, int location, vec2 value) {
        requireGLShader(shader);
        oglSetUniformVec2(location, value);
    }

    void setShaderUniform(RenderShaderHandle shader, int location, vec3 value) {
        requireGLShader(shader);
        oglSetUniformVec3(location, value);
    }

    void setShaderUniform(RenderShaderHandle shader, int location, vec4 value) {
        requireGLShader(shader);
        oglSetUniformVec4(location, value);
    }

    void setShaderUniform(RenderShaderHandle shader, int location, mat4 value) {
        requireGLShader(shader);
        oglSetUniformMat4(location, value);
    }

    RenderTextureHandle createTextureHandle() {
        auto handle = new GLTextureHandle();
        oglCreateTextureHandle(handle.id);
        return handle;
    }

    void destroyTextureHandle(RenderTextureHandle texture) {
        auto handle = requireGLTexture(texture);
        oglDeleteTextureHandle(handle.id);
        handle.id = 0;
    }

    void bindTextureHandle(RenderTextureHandle texture, uint unit) {
        auto handle = requireGLTexture(texture);
        oglBindTextureHandle(handle.id, unit);
    }

    void uploadTextureData(RenderTextureHandle texture, int width, int height,
                                    int inChannels, int outChannels, bool stencil,
                                    ubyte[] data) {
        auto handle = requireGLTexture(texture);
        oglUploadTextureData(handle.id, width, height, inChannels, outChannels, stencil, data);
    }

    void updateTextureRegion(RenderTextureHandle texture, int x, int y, int width,
                                      int height, int channels, ubyte[] data) {
        auto handle = requireGLTexture(texture);
        oglUpdateTextureRegion(handle.id, x, y, width, height, channels, data);
    }

    void generateTextureMipmap(RenderTextureHandle texture) {
        auto handle = requireGLTexture(texture);
        oglGenerateTextureMipmap(handle.id);
    }

    void applyTextureFiltering(RenderTextureHandle texture, Filtering filtering, bool useMipmaps = true) {
        auto handle = requireGLTexture(texture);
        oglApplyTextureFiltering(handle.id, filtering, useMipmaps);
    }

    void applyTextureWrapping(RenderTextureHandle texture, Wrapping wrapping) {
        auto handle = requireGLTexture(texture);
        oglApplyTextureWrapping(handle.id, wrapping);
    }

    void applyTextureAnisotropy(RenderTextureHandle texture, float value) {
        auto handle = requireGLTexture(texture);
        oglApplyTextureAnisotropy(handle.id, value);
    }

    float maxTextureAnisotropy() {
        return oglMaxTextureAnisotropy();
    }

    void readTextureData(RenderTextureHandle texture, int channels, bool stencil,
                                  ubyte[] buffer) {
        auto handle = requireGLTexture(texture);
        oglReadTextureData(handle.id, channels, stencil, buffer);
    }

    size_t textureNativeHandle(RenderTextureHandle texture) {
        auto handle = requireGLTexture(texture);
        return handle.id;
    }
}

}

// ---- source/nlshim/core/render/backends/opengl/part.d ----

version (InDoesRender) {

import bindbc.opengl;
import std.algorithm : min;
public {
__gshared Texture boundAlbedo;
    __gshared Shader partShader;
    __gshared Shader partShaderStage1;
    __gshared Shader partShaderStage2;
    __gshared Shader partMaskShader;
    __gshared GLint mvp;
    __gshared GLint offset;
    __gshared GLint gopacity;
    __gshared GLint gMultColor;
    __gshared GLint gScreenColor;
    __gshared GLint gEmissionStrength;
    __gshared GLint gs1mvp;
    __gshared GLint gs1offset;
    __gshared GLint gs1opacity;
    __gshared GLint gs1MultColor;
    __gshared GLint gs1ScreenColor;
    __gshared GLint gs2mvp;
    __gshared GLint gs2offset;
    __gshared GLint gs2opacity;
    __gshared GLint gs2EmissionStrength;
    __gshared GLint gs2MultColor;
    __gshared GLint gs2ScreenColor;
    __gshared GLint mmvp;
    __gshared GLint mthreshold;
__gshared bool partBackendInitialized = false;

enum ShaderAsset PartShaderSource = shaderAsset!("opengl/shaders/opengl/basic/basic.vert","opengl/shaders/opengl/basic/basic.frag")();
enum ShaderAsset PartShaderStage1Source = shaderAsset!("opengl/shaders/opengl/basic/basic.vert","opengl/shaders/opengl/basic/basic-stage1.frag")();
enum ShaderAsset PartShaderStage2Source = shaderAsset!("opengl/shaders/opengl/basic/basic.vert","opengl/shaders/opengl/basic/basic-stage2.frag")();
enum ShaderAsset PartMaskShaderSource = shaderAsset!("opengl/shaders/opengl/basic/basic.vert","opengl/shaders/opengl/basic/basic-mask.frag")();
}

void oglInitPartBackendResources() {
    if (partBackendInitialized) return;
    partBackendInitialized = true;

    partShader = new Shader(PartShaderSource);
    partShaderStage1 = new Shader(PartShaderStage1Source);
    partShaderStage2 = new Shader(PartShaderStage2Source);
    partMaskShader = new Shader(PartMaskShaderSource);

    incDrawableBindVAO();

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

void oglDrawPartPacket(ref PartDrawPacket packet) {
    if (!packet.renderable) return;
    oglExecutePartPacket(packet);
}

void oglExecutePartPacket(ref PartDrawPacket packet) {
    auto textures = packet.textures;
    if (textures.length == 0) return;

    incDrawableBindVAO();

    // Bind only when先頭テクスチャが変わった場合（nijiliveと同じキャッシュ方式）
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
            if (nlIsTripleBufferFallbackEnabled()) {
                auto blendShader = oglGetBlendShader(packet.blendingMode);
                if (blendShader) {
                    // Save full GL state that we modify in the fallback path.
                    struct SavedState {
                        GLint drawFbo;
                        GLint readFbo;
                        GLint readBuffer;
                        GLint[4] viewport;
                        GLfloat[4] clearColor;
                        GLint[4] drawBuffers;
                        GLint drawBufferCount;
                        GLint blendSrcRGB;
                        GLint blendDstRGB;
                        GLint blendSrcA;
                        GLint blendDstA;
                        GLint blendEqRGB;
                        GLint blendEqA;
                        GLboolean[4] colorMask;
                        GLboolean depthEnabled;
                        GLboolean stencilEnabled;
                    }
                    SavedState prev;
                    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &prev.drawFbo);
                    glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &prev.readFbo);
                    glGetIntegerv(GL_READ_BUFFER, &prev.readBuffer);
                    glGetIntegerv(GL_VIEWPORT, prev.viewport.ptr);
                    GLint maxDrawBuffers = 0;
                    glGetIntegerv(GL_MAX_DRAW_BUFFERS, &maxDrawBuffers);
                    maxDrawBuffers = min(maxDrawBuffers, cast(int)prev.drawBuffers.length);
                    int bufCount = 0;
                    for (int i = 0; i < maxDrawBuffers; ++i) {
                        GLint buf = 0;
                        glGetIntegerv(GL_DRAW_BUFFER0 + i, &buf);
                        prev.drawBuffers[i] = buf;
                        if (buf != GL_NONE) bufCount = i + 1;
                    }
                    if (bufCount == 0) {
                        prev.drawBufferCount = 3;
                        prev.drawBuffers[0] = GL_COLOR_ATTACHMENT0;
                        prev.drawBuffers[1] = GL_COLOR_ATTACHMENT1;
                        prev.drawBuffers[2] = GL_COLOR_ATTACHMENT2;
                    } else {
                        prev.drawBufferCount = bufCount;
                    }
                    glGetFloatv(GL_COLOR_CLEAR_VALUE, prev.clearColor.ptr);
                    glGetIntegerv(GL_BLEND_SRC_RGB, &prev.blendSrcRGB);
                    glGetIntegerv(GL_BLEND_DST_RGB, &prev.blendDstRGB);
                    glGetIntegerv(GL_BLEND_SRC_ALPHA, &prev.blendSrcA);
                    glGetIntegerv(GL_BLEND_DST_ALPHA, &prev.blendDstA);
                    glGetIntegerv(GL_BLEND_EQUATION_RGB, &prev.blendEqRGB);
                    glGetIntegerv(GL_BLEND_EQUATION_ALPHA, &prev.blendEqA);
                    glGetBooleanv(GL_COLOR_WRITEMASK, prev.colorMask.ptr);
                    prev.depthEnabled = glIsEnabled(GL_DEPTH_TEST);
                    prev.stencilEnabled = glIsEnabled(GL_STENCIL_TEST);

                    bool drawingMainBuffer = prev.drawFbo == oglGetFramebuffer();
                    bool drawingCompositeBuffer = prev.drawFbo == oglGetCompositeFramebuffer();

                    if (!drawingMainBuffer && !drawingCompositeBuffer) {
                        setupShaderStage(packet, 2, matrix, renderMatrix);
                        renderStage(packet, false);
                        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, prev.drawFbo);
                        glBindFramebuffer(GL_READ_FRAMEBUFFER, prev.readFbo);
                        glReadBuffer(prev.readBuffer);
                        glDrawBuffers(prev.drawBufferCount, cast(const(GLenum)*)prev.drawBuffers.ptr);
                        glViewport(prev.viewport[0], prev.viewport[1], prev.viewport[2], prev.viewport[3]);
                        glClearColor(prev.clearColor[0], prev.clearColor[1], prev.clearColor[2], prev.clearColor[3]);
                        glBlendEquationSeparate(prev.blendEqRGB, prev.blendEqA);
                        glBlendFuncSeparate(prev.blendSrcRGB, prev.blendDstRGB, prev.blendSrcA, prev.blendDstA);
                        glColorMask(prev.colorMask[0], prev.colorMask[1], prev.colorMask[2], prev.colorMask[3]);
                        if (prev.depthEnabled) glEnable(GL_DEPTH_TEST); else glDisable(GL_DEPTH_TEST);
                        if (prev.stencilEnabled) glEnable(GL_STENCIL_TEST); else glDisable(GL_STENCIL_TEST);
                        // Ensure downstream draws target standard MRT attachments.
                        glDrawBuffers(3, [GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2].ptr);
                        return;
                    }

                    int viewportWidth, viewportHeight;
                    inGetViewport(viewportWidth, viewportHeight);

                    GLuint blendFramebuffer = oglGetBlendFramebuffer();
                    // Copy current target into blend buffer as a backup.
                    glBindFramebuffer(GL_READ_FRAMEBUFFER, prev.drawFbo);
                    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, blendFramebuffer);
                    foreach(att; 0 .. 3) {
                        GLenum buf = GL_COLOR_ATTACHMENT0 + att;
                        glReadBuffer(buf);
                        glDrawBuffer(buf);
                        glBlitFramebuffer(0, 0, viewportWidth, viewportHeight,
                            0, 0, viewportWidth, viewportHeight,
                            GL_COLOR_BUFFER_BIT, GL_NEAREST);
                    }

                    // Draw the part into the blend buffer.
                    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, blendFramebuffer);
                    glDrawBuffers(3, [GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2].ptr);
                    glViewport(0, 0, viewportWidth, viewportHeight);
                    setupShaderStage(packet, 2, matrix, renderMatrix);
                    renderStage(packet, false);

                    // Copy result back to original target.
                    glBindFramebuffer(GL_READ_FRAMEBUFFER, blendFramebuffer);
                    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, prev.drawFbo);
                    foreach(att; 0 .. 3) {
                        GLenum buf = GL_COLOR_ATTACHMENT0 + att;
                        glReadBuffer(buf);
                        glDrawBuffer(buf);
                        glBlitFramebuffer(0, 0, viewportWidth, viewportHeight,
                            0, 0, viewportWidth, viewportHeight,
                            GL_COLOR_BUFFER_BIT, GL_NEAREST);
                    }

                    // Restore original state after blending.
                    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, prev.drawFbo);
                    glBindFramebuffer(GL_READ_FRAMEBUFFER, prev.readFbo);
                    glReadBuffer(prev.readBuffer);
                    glDrawBuffers(prev.drawBufferCount, cast(const(GLenum)*)prev.drawBuffers.ptr);
                    glViewport(prev.viewport[0], prev.viewport[1], prev.viewport[2], prev.viewport[3]);
                    glClearColor(prev.clearColor[0], prev.clearColor[1], prev.clearColor[2], prev.clearColor[3]);
                    glBlendEquationSeparate(prev.blendEqRGB, prev.blendEqA);
                    glBlendFuncSeparate(prev.blendSrcRGB, prev.blendDstRGB, prev.blendSrcA, prev.blendDstA);
                    glColorMask(prev.colorMask[0], prev.colorMask[1], prev.colorMask[2], prev.colorMask[3]);
                    if (prev.depthEnabled) glEnable(GL_DEPTH_TEST); else glDisable(GL_DEPTH_TEST);
                    if (prev.stencilEnabled) glEnable(GL_STENCIL_TEST); else glDisable(GL_STENCIL_TEST);
                    // Ensure downstream draws target standard MRT attachments.
                    glDrawBuffers(3, [GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2].ptr);
                    boundAlbedo = null; // force texture rebind after fallback path
                    return;
                }
            }

            // Legacy single-pass when fallback is disabled: set blend and draw once.
            setupShaderStage(packet, 2, matrix, renderMatrix);
            renderStage(packet, false);
        }
    }

    glDrawBuffers(3, [GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2].ptr);
    glBlendEquation(GL_FUNC_ADD);
}

private void setupShaderStage(ref PartDrawPacket packet, int stage, mat4 matrix, mat4 renderMatrix) {
    mat4 mvpMatrix = renderMatrix * matrix;

    // Some offscreen FBOs (DynamicComposite) expose only COLOR_ATTACHMENT0.
    // Guard draw buffer selection to the attachments that actually exist on the
    // currently bound draw framebuffer to avoid INVALID_OPERATION (1282) and
    // the “no texture bound to slot” spam seen in RenderDoc.
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
        // Always try attachment0 first; if it is absent, fall back to backbuffer.
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
            inSetBlendMode(packet.blendingMode, false);
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
            inSetBlendMode(packet.blendingMode, true);
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
            inSetBlendMode(packet.blendingMode, true);
            break;
        default:
            return;
    }
}

private void renderStage(ref PartDrawPacket packet, bool advanced) {
    auto ibo = cast(GLuint)packet.indexBuffer;
    auto indexCount = packet.indexCount;

    if (!ibo || indexCount == 0 || packet.vertexCount == 0) return;
    if (packet.vertexAtlasStride == 0 || packet.uvAtlasStride == 0 || packet.deformAtlasStride == 0) return;

    auto vertexBuffer = oglGetSharedVertexBuffer();
    auto uvBuffer = oglGetSharedUvBuffer();
    auto deformBuffer = oglGetSharedDeformBuffer();
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

    // Debug: dump current program/VAO/buffers for early draws to verify state.
    static int dbgCount;
    if (dbgCount < 4) {
        GLint prog = 0, vao = 0, arrBuf = 0, elemBuf = 0;
        glGetIntegerv(GL_CURRENT_PROGRAM, &prog);
        glGetIntegerv(GL_VERTEX_ARRAY_BINDING, &vao);
        glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &arrBuf);
        glGetIntegerv(GL_ELEMENT_ARRAY_BUFFER_BINDING, &elemBuf);
        import std.stdio : writeln;
        auto dumpAttribState = (int idx) {
            GLint enabled = 0, size = 0, type = 0, stride = 0, buf = 0;
            GLvoid* ptr;
            glGetVertexAttribiv(idx, GL_VERTEX_ATTRIB_ARRAY_ENABLED, &enabled);
            glGetVertexAttribiv(idx, GL_VERTEX_ATTRIB_ARRAY_SIZE, &size);
            glGetVertexAttribiv(idx, GL_VERTEX_ATTRIB_ARRAY_TYPE, &type);
            glGetVertexAttribiv(idx, GL_VERTEX_ATTRIB_ARRAY_STRIDE, &stride);
            glGetVertexAttribiv(idx, GL_VERTEX_ATTRIB_ARRAY_BUFFER_BINDING, &buf);
            glGetVertexAttribPointerv(idx, GL_VERTEX_ATTRIB_ARRAY_POINTER, &ptr);
            writeln("[attr", idx, "] en=", enabled, " size=", size,
                    " type=", type, " stride=", stride,
                    " buf=", buf, " ptr=", cast(size_t)ptr);
        };
        writeln("[part] prog=", prog, " vao=", vao, " vBuf=", vertexBuffer, " uvBuf=", uvBuffer,
                " defBuf=", deformBuffer, " arrBuf=", arrBuf, " elemBuf=", elemBuf,
                " vOff=", vertexOffsetBytes, " uvOff=", uvOffsetBytes, " defOff=", deformOffsetBytes);
        dumpAttribState(0);
        dumpAttribState(1);
        dumpAttribState(2);
        dumpAttribState(3);
        dbgCount++;
    }

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

    oglDrawDrawableElements(packet.indexBuffer, indexCount);
    markBufferInUse(vertexBuffer);
    markBufferInUse(uvBuffer);
    markBufferInUse(deformBuffer);

    glDisableVertexAttribArray(0);
    glDisableVertexAttribArray(1);
    glDisableVertexAttribArray(2);
    glDisableVertexAttribArray(3);
    glDisableVertexAttribArray(4);
    glDisableVertexAttribArray(5);

    if (advanced) {
        inBlendModeBarrier(packet.blendingMode);
    }
}

} else {


void oglInitPartBackendResources() {}
void oglDrawPartPacket(ref PartDrawPacket) {}
void oglExecutePartPacket(ref PartDrawPacket) {}

}

// ---- source/nlshim/core/render/backends/opengl/runtime.d ----

import bindbc.opengl;
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

// Internal rendering constants
private {
    GLuint sceneVAO;
    GLuint sceneVBO;

    GLuint fBuffer;
    GLuint fAlbedo;
    GLuint fEmissive;
    GLuint fBump;
    GLuint fStencil;

    GLuint cfBuffer;
    GLuint cfAlbedo;
    GLuint cfEmissive;
    GLuint cfBump;
    GLuint cfStencil;

    GLuint blendFBO;
    GLuint blendAlbedo;
    GLuint blendEmissive;
    GLuint blendBump;
    GLuint blendStencil;

    PostProcessingShader basicSceneShader;
    PostProcessingShader basicSceneLighting;
    PostProcessingShader[] postProcessingStack;
    enum ShaderAsset SceneShaderSource = shaderAsset!("opengl/shaders/opengl/scene.vert","opengl/shaders/opengl/scene.frag")();
    enum ShaderAsset LightingShaderSource = shaderAsset!("opengl/shaders/opengl/scene.vert","opengl/shaders/opengl/lighting.frag")();

    bool isCompositing;
    struct CompositeFrameState {
        GLint framebuffer;
        GLint[4] viewport;
    }
    CompositeFrameState[] compositeScopeStack;

    void renderScene(vec4 area, PostProcessingShader shaderToUse, GLuint albedo, GLuint emissive, GLuint bump) {
        glViewport(0, 0, cast(int)area.z, cast(int)area.w);

        // Bind our vertex array
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

        // Ambient light
        GLint ambientLightUniform = shaderToUse.getUniform("ambientLight");
        if (ambientLightUniform != -1) shaderToUse.shader.setUniform(ambientLightUniform, inSceneAmbientLight);

        // framebuffer size
        GLint fbSizeUniform = shaderToUse.getUniform("fbSize");
        if (fbSizeUniform != -1) shaderToUse.shader.setUniform(fbSizeUniform, vec2(inViewportWidth[$-1], inViewportHeight[$-1]));

        // Bind the texture
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, albedo);
        glActiveTexture(GL_TEXTURE1);
        glBindTexture(GL_TEXTURE_2D, emissive);
        glActiveTexture(GL_TEXTURE2);
        glBindTexture(GL_TEXTURE_2D, bump);

        // Enable points array
        glEnableVertexAttribArray(0); // verts
        glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 4*float.sizeof, null);

        // Enable UVs array
        glEnableVertexAttribArray(1); // uvs
        glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 4*float.sizeof, cast(float*)(2*float.sizeof));

        // Draw
        glDrawArrays(GL_TRIANGLES, 0, 6);

        // Disable the vertex attribs after use
        glDisableVertexAttribArray(0);
        glDisableVertexAttribArray(1);

        glDisable(GL_BLEND);
    }
}

// Things only available internally for nijilive rendering
public {
/**
        Initializes the renderer (OpenGL-specific portion)
    */
    void oglInitRenderer() {

        // Set the viewport and by extension set the textures
        inSetViewport(640, 480);
        version(InDoesRender) inInitDebug();

        version (InDoesRender) {
            
        // Shader for scene
        basicSceneShader = PostProcessingShader(new Shader(SceneShaderSource));
        glGenVertexArrays(1, &sceneVAO);
        glGenBuffers(1, &sceneVBO);

            import std.stdio : writeln;
            writeln("[oglInitRenderer] sceneVAO=", sceneVAO, " sceneVBO=", sceneVBO);

            // Generate the framebuffer we'll be using to render the model and composites
            glGenFramebuffers(1, &fBuffer);
            glGenFramebuffers(1, &cfBuffer);
            glGenFramebuffers(1, &blendFBO);
            
            // Generate the color and stencil-depth textures needed
            // Note: we're not using the depth buffer but OpenGL 3.4 does not support stencil-only buffers
            glGenTextures(1, &fAlbedo);
            glGenTextures(1, &fEmissive);
            glGenTextures(1, &fBump);
            glGenTextures(1, &fStencil);

            writeln("[oglInitRenderer] fAlbedo=", fAlbedo, " fEmissive=", fEmissive, " fBump=", fBump, " fStencil=", fStencil);

            glGenTextures(1, &cfAlbedo);
            glGenTextures(1, &cfEmissive);
            glGenTextures(1, &cfBump);
            glGenTextures(1, &cfStencil);

            writeln("[oglInitRenderer] cfAlbedo=", cfAlbedo, " cfEmissive=", cfEmissive, " cfBump=", cfBump, " cfStencil=", cfStencil);

            glGenTextures(1, &blendAlbedo);
            glGenTextures(1, &blendEmissive);
            glGenTextures(1, &blendBump);
            glGenTextures(1, &blendStencil);

            writeln("[oglInitRenderer] blendAlbedo=", blendAlbedo, " blendEmissive=", blendEmissive, " blendBump=", blendBump, " blendStencil=", blendStencil);

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

            glBindFramebuffer(GL_FRAMEBUFFER, blendFBO);
            glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, blendAlbedo, 0);
            glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT1, GL_TEXTURE_2D, blendEmissive, 0);
            glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT2, GL_TEXTURE_2D, blendBump, 0);
            glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_TEXTURE_2D, blendStencil, 0);

            // go back to default fb
            glBindFramebuffer(GL_FRAMEBUFFER, 0);

        }
    }
}

/**
    Begins rendering to the framebuffer
*/
void oglBeginScene() {
    // Log & flush any pending GL errors before we start the frame.
    GLenum preErr; int errCnt = 0;
    while ((preErr = glGetError()) != GL_NO_ERROR) {
        import std.stdio : writeln;
        if (errCnt == 0) writeln("[glerr][pre-beginScene] err=", preErr);
        errCnt++;
    }

    boundAlbedo = null; // force texture rebind at start of frame
    glBindVertexArray(sceneVAO);
    glEnable(GL_BLEND);
    glEnablei(GL_BLEND, 0);
    glEnablei(GL_BLEND, 1);
    glEnablei(GL_BLEND, 2);
    glDisable(GL_DEPTH_TEST);
    glDisable(GL_CULL_FACE);

    // Make sure to reset our viewport if someone has messed with it
    glViewport(0, 0, inViewportWidth[$-1], inViewportHeight[$-1]);

    // Ensure framebuffer attachments are bound in case external code modified FBO state.
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

    // Bind and clear composite framebuffer
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, cfBuffer);
    immutable(GLenum[3]) cfTargets = [GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2];
    glDrawBuffers(cast(GLsizei)cfTargets.length, cfTargets.ptr);
    glClearColor(0, 0, 0, 0);

    // Bind our framebuffer
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, fBuffer);

    // Debug: check FBO completeness and attachment objects.
    GLenum status = glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER);
    import std.stdio : writeln;
    if (status != GL_FRAMEBUFFER_COMPLETE) writeln("[fbo] incomplete status=", status);

    auto dumpAttachment = (GLenum attachment, string label) {
        GLint obj = 0; GLint type = 0;
        glGetFramebufferAttachmentParameteriv(GL_DRAW_FRAMEBUFFER, attachment, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE, &type);
        glGetFramebufferAttachmentParameteriv(GL_DRAW_FRAMEBUFFER, attachment, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME, &obj);
        writeln("[fbo] ", label, " type=", type, " obj=", obj);
    };
    dumpAttachment(GL_COLOR_ATTACHMENT0, "C0");
    dumpAttachment(GL_COLOR_ATTACHMENT1, "C1");
    dumpAttachment(GL_COLOR_ATTACHMENT2, "C2");
    dumpAttachment(GL_DEPTH_STENCIL_ATTACHMENT, "DS");

    GLenum err = glGetError();
    if (err != GL_NO_ERROR) {
        writeln("[fbo] glGetError after bind=", err);
        // Do not abort; continue so rendering can proceed and we can see effects.
    }

    // First clear buffer 0
    glDrawBuffers(1, [GL_COLOR_ATTACHMENT0].ptr);
    glClearColor(inClearColor.r, inClearColor.g, inClearColor.b, inClearColor.a);
    glClear(GL_COLOR_BUFFER_BIT);

    // Then clear others with black
    glDrawBuffers(2, [GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2].ptr);
    glClearColor(0, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);

    // Everything else is the actual texture used by the meshes at id 0
    glActiveTexture(GL_TEXTURE0);

    // Finally we render to all buffers
    glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
    glDrawBuffers(3, [GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2].ptr);
}

/**
    Begins a composition step
*/
void oglBeginComposite() {

    CompositeFrameState frameState;
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &frameState.framebuffer);
    glGetIntegerv(GL_VIEWPORT, frameState.viewport.ptr);
    compositeScopeStack ~= frameState;
    isCompositing = true;

    immutable(GLenum[3]) attachments = [GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2];
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, cfBuffer);
    glDrawBuffers(cast(GLsizei)attachments.length, attachments.ptr);
    glClearColor(0, 0, 0, 0);
    glClear(GL_COLOR_BUFFER_BIT);

    glActiveTexture(GL_TEXTURE0);
    glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
}

/**
    Ends a composition step, re-binding the internal framebuffer
*/
void oglEndComposite() {
    if (compositeScopeStack.length == 0) return;

    auto frameState = compositeScopeStack[$ - 1];
    compositeScopeStack.length -= 1;

    immutable(GLenum[3]) attachments = [GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2];
    glBindFramebuffer(GL_FRAMEBUFFER, frameState.framebuffer);
    glViewport(frameState.viewport[0], frameState.viewport[1], frameState.viewport[2], frameState.viewport[3]);
    glDrawBuffers(cast(GLsizei)attachments.length, attachments.ptr);

    if (compositeScopeStack.length == 0) {
        glFlush();
        isCompositing = false;
    }
}
/**
    Ends rendering to the framebuffer
*/
void oglEndScene() {
    glBindFramebuffer(GL_FRAMEBUFFER, 0);

    glDisablei(GL_BLEND, 0);
    glDisablei(GL_BLEND, 1);
    glDisablei(GL_BLEND, 2);
    glEnable(GL_DEPTH_TEST);
    glEnable(GL_CULL_FACE);
    glDisable(GL_BLEND);
    glFlush();
    glDrawBuffers(1, [GL_COLOR_ATTACHMENT0].ptr);

//    import std.stdio;
//    writefln("end render");
}

/**
    Runs post processing on the scene
*/
void oglPostProcessScene() {
    if (postProcessingStack.length == 0) return;
    
    bool targetBuffer;

    // These are passed to glSetClearColor for transparent export
    float r, g, b, a;
    inGetClearColor(r, g, b, a);

    // Render area
    vec4 area = vec4(
        0, 0,
        inViewportWidth[$-1], inViewportHeight[$-1]
    );

    // Tell OpenGL the resolution to render at
    float[] data = [
        area.x,         area.y+area.w,          0, 0,
        area.x,         area.y,                 0, 1,
        area.x+area.z,  area.y+area.w,          1, 0,
        
        area.x+area.z,  area.y+area.w,          1, 0,
        area.x,         area.y,                 0, 1,
        area.x+area.z,  area.y,                 1, 1,
    ];
    glBindBuffer(GL_ARRAY_BUFFER, sceneVBO);
    glBufferData(GL_ARRAY_BUFFER, 24*float.sizeof, data.ptr, GL_DYNAMIC_DRAW);


    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, fEmissive);
    glGenerateMipmap(GL_TEXTURE_2D);

    // We want to be able to post process all the attachments
    glBindFramebuffer(GL_FRAMEBUFFER, cfBuffer);
    glDrawBuffers(3, [GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2].ptr);
    glClearColor(r, g, b, a);
    glClear(GL_COLOR_BUFFER_BIT);

    glBindFramebuffer(GL_FRAMEBUFFER, fBuffer);
    glDrawBuffers(3, [GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2].ptr);

    foreach(shader; postProcessingStack) {
        targetBuffer = !targetBuffer;

        if (targetBuffer) {

            // Main buffer -> Composite buffer
            glBindFramebuffer(GL_FRAMEBUFFER, cfBuffer); // dst
            renderScene(area, shader, fAlbedo, fEmissive, fBump); // src
        } else {

            // Composite buffer -> Main buffer 
            glBindFramebuffer(GL_FRAMEBUFFER, fBuffer); // dst
            renderScene(area, shader, cfAlbedo, cfEmissive, cfBump); // src
        }
    }

    if (targetBuffer) {
        glBindFramebuffer(GL_READ_FRAMEBUFFER, cfBuffer);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, fBuffer);
        glBlitFramebuffer(
            0, 0, inViewportWidth[$-1], inViewportHeight[$-1], // src rect
            0, 0, inViewportWidth[$-1], inViewportHeight[$-1], // dst rect
            GL_COLOR_BUFFER_BIT, // blit mask
            GL_LINEAR // blit filter
        );
    }
    
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
}

/**
    Add basic lighting shader to processing stack
*/
void oglAddBasicLightingPostProcess() {
    postProcessingStack ~= PostProcessingShader(new Shader(LightingShaderSource));
}

/**
    Clears the post processing stack
*/
ref PostProcessingShader[] oglGetPostProcessingStack() {
    return postProcessingStack;
}

/**
    Draw scene to area
*/
void oglDrawScene(vec4 area) {
    float[] data = [
        area.x,         area.y+area.w,          0, 0,
        area.x,         area.y,                 0, 1,
        area.x+area.z,  area.y+area.w,          1, 0,
        
        area.x+area.z,  area.y+area.w,          1, 0,
        area.x,         area.y,                 0, 1,
        area.x+area.z,  area.y,                 1, 1,
    ];

    glBindBuffer(GL_ARRAY_BUFFER, sceneVBO);
    glBufferData(GL_ARRAY_BUFFER, 24*float.sizeof, data.ptr, GL_DYNAMIC_DRAW);
    renderScene(area, basicSceneShader, fAlbedo, fEmissive, fBump);
}

void oglPrepareCompositeScene() {
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, cfAlbedo);
    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, cfEmissive);
    glActiveTexture(GL_TEXTURE2);
    glBindTexture(GL_TEXTURE_2D, cfBump);
}

/**
    Gets the nijilive framebuffer 

    DO NOT MODIFY THIS IMAGE!
*/
GLuint oglGetFramebuffer() {
    return fBuffer;
}

/**
    Gets the nijilive framebuffer render image

    DO NOT MODIFY THIS IMAGE!
*/
GLuint oglGetRenderImage() {
    return fAlbedo;
}

/**
    Gets the nijilive composite render image

    DO NOT MODIFY THIS IMAGE!
*/
GLuint oglGetCompositeImage() {
    return cfAlbedo;
}

public GLuint oglGetCompositeFramebuffer() {
    return cfBuffer;
}

public GLuint oglGetBlendFramebuffer() {
    return blendFBO;
}

public GLuint oglGetMainEmissive() {
    return fEmissive;
}

public GLuint oglGetMainBump() {
    return fBump;
}

public GLuint oglGetCompositeEmissive() {
    return cfEmissive;
}

public GLuint oglGetCompositeBump() {
    return cfBump;
}

public GLuint oglGetBlendAlbedo() {
    return blendAlbedo;
}

public GLuint oglGetBlendEmissive() {
    return blendEmissive;
}

public GLuint oglGetBlendBump() {
    return blendBump;
}

// Reattach the currently active main/composite textures to their FBOs.
public void oglRebindActiveTargets() {
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

/**
    Gets the nijilive main albedo render image

    DO NOT MODIFY THIS IMAGE!
*/
GLuint oglGetMainAlbedo() {
    return fAlbedo;
}

/**
    Gets the blend shader for the specified mode
*/
public void oglSwapMainCompositeBuffers() {
    // No-op swap: we avoid ping-pong to keep attachments stable.
}
public
void oglResizeViewport(int width, int height) {
    version(InDoesRender) {
        // Work on texture unit 0 to avoid “no texture bound” errors.
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

        // Blend framebuffer
        glBindTexture(GL_TEXTURE_2D, blendAlbedo);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, null);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        
        glBindTexture(GL_TEXTURE_2D, blendEmissive);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA, GL_FLOAT, null);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        
        glBindTexture(GL_TEXTURE_2D, blendBump);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, null);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        
        glBindTexture(GL_TEXTURE_2D, blendStencil);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_DEPTH24_STENCIL8, width, height, 0, GL_DEPTH_STENCIL, GL_UNSIGNED_INT_24_8, null);

        glBindFramebuffer(GL_FRAMEBUFFER, blendFBO);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, blendAlbedo, 0);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT1, GL_TEXTURE_2D, blendEmissive, 0);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT2, GL_TEXTURE_2D, blendBump, 0);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_TEXTURE_2D, blendStencil, 0);
        
        glBindFramebuffer(GL_FRAMEBUFFER, 0);

        glViewport(0, 0, width, height);
    }
}

/**
    Dumps viewport data to texture stream
*/
public
void oglDumpViewport(ref ubyte[] dumpTo, int width, int height) {
    version(InDoesRender) {
        if (width == 0 || height == 0) return;
        glBindTexture(GL_TEXTURE_2D, fAlbedo);
        glGetTexImage(GL_TEXTURE_2D, 0, GL_RGBA, GL_UNSIGNED_BYTE, dumpTo.ptr);
    }
}

// ---- source/nlshim/core/render/backends/opengl/shader_backend.d ----


version (InDoesRender) {

import bindbc.opengl;
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

void oglCreateShaderProgram(ref ShaderProgramHandle handle, string vertex, string fragment) {
    handle.vert = glCreateShader(GL_VERTEX_SHADER);
    auto vsrc = vertex.toStringz;
    glShaderSource(handle.vert, 1, &vsrc, null);
    glCompileShader(handle.vert);
    checkShader(handle.vert);

    handle.frag = glCreateShader(GL_FRAGMENT_SHADER);
    auto fsrc = fragment.toStringz;
    glShaderSource(handle.frag, 1, &fsrc, null);
    glCompileShader(handle.frag);
    checkShader(handle.frag);

    handle.program = glCreateProgram();
    glAttachShader(handle.program, handle.vert);
    glAttachShader(handle.program, handle.frag);
    glLinkProgram(handle.program);
    checkProgram(handle.program);
}

void oglDestroyShaderProgram(ref ShaderProgramHandle handle) {
    if (handle.program) {
        glDetachShader(handle.program, handle.vert);
        glDetachShader(handle.program, handle.frag);
        glDeleteProgram(handle.program);
    }
    if (handle.vert) glDeleteShader(handle.vert);
    if (handle.frag) glDeleteShader(handle.frag);
    handle = ShaderProgramHandle.init;
}

void oglUseShaderProgram(ref ShaderProgramHandle handle) {
    glUseProgram(handle.program);
}

int oglShaderGetUniformLocation(ref ShaderProgramHandle handle, string name) {
    return glGetUniformLocation(handle.program, name.toStringz);
}

void oglSetUniformBool(int location, bool value) {
    glUniform1i(location, value ? 1 : 0);
}

void oglSetUniformInt(int location, int value) {
    glUniform1i(location, value);
}

void oglSetUniformFloat(int location, float value) {
    glUniform1f(location, value);
}

void oglSetUniformVec2(int location, vec2 value) {
    glUniform2f(location, value.x, value.y);
}

void oglSetUniformVec3(int location, vec3 value) {
    glUniform3f(location, value.x, value.y, value.z);
}

void oglSetUniformVec4(int location, vec4 value) {
    glUniform4f(location, value.x, value.y, value.z, value.w);
}

void oglSetUniformMat4(int location, mat4 value) {
    glUniformMatrix4fv(location, 1, GL_TRUE, value.ptr);
}

} else {

struct ShaderProgramHandle { }

void oglCreateShaderProgram(ref ShaderProgramHandle handle, string vertex, string fragment) { }
void oglDestroyShaderProgram(ref ShaderProgramHandle handle) { }
void oglUseShaderProgram(ref ShaderProgramHandle handle) { }
int oglShaderGetUniformLocation(ref ShaderProgramHandle handle, string name) { return -1; }
void oglSetUniformBool(int, bool) { }
void oglSetUniformInt(int, int) { }
void oglSetUniformFloat(int, float) { }
void oglSetUniformVec2(int, vec2) { }
void oglSetUniformVec3(int, vec3) { }
void oglSetUniformVec4(int, vec4) { }
void oglSetUniformMat4(int, mat4) { }

}

// ---- source/nlshim/core/render/backends/opengl/soa_upload.d ----

version (InDoesRender) {

import bindbc.opengl;
import std.traits : Unqual;

private template VecInfo(Vec) {
    static if (is(Unqual!Vec == veca!(float, N), size_t N)) {
        enum bool isValid = true;
        enum size_t laneCount = N;
    } else {
        enum bool isValid = false;
        enum size_t laneCount = 0;
    }
}

/// Uploads SoA vector data without converting to AoS on the CPU.
void glUploadFloatVecArray(Vec)(GLuint buffer, auto ref Vec data, GLenum usage, string profileLabel = null)
if (VecInfo!Vec.isValid) {
    if (buffer == 0 || data.length == 0) return;
    auto raw = data.rawStorage();
    if (raw.length == 0) return;
    RenderProfileScope profScope = RenderProfileScope.init;
    if (profileLabel.length) {
        profScope = profileScope(profileLabel);
    }
    glBindBuffer(GL_ARRAY_BUFFER, buffer);
    glBufferData(GL_ARRAY_BUFFER, raw.length * float.sizeof, raw.ptr, usage);
}

} else {

void glUploadFloatVecArray(Vec)(uint, auto ref Vec, uint) {}

}

// ---- source/nlshim/core/render/backends/opengl/texture_backend.d ----


mixin template TextureBackendStub() {
    alias GLId = uint;

    void oglCreateTextureHandle(ref GLId id) { id = 0; }
    void oglDeleteTextureHandle(ref GLId id) { id = 0; }
    void oglBindTextureHandle(GLId, uint) { }
    void oglUploadTextureData(GLId, int, int, int, int, bool, ubyte[]) { }
    void oglUpdateTextureRegion(GLId, int, int, int, int, int, ubyte[]) { }
    void oglGenerateTextureMipmap(GLId) { }
    void oglApplyTextureFiltering(GLId, Filtering, bool = true) { }
    void oglApplyTextureWrapping(GLId, Wrapping) { }
    void oglApplyTextureAnisotropy(GLId, float) { }
    float oglMaxTextureAnisotropy() { return 1; }
    void oglReadTextureData(GLId, int, bool, ubyte[]) { }
}

version (unittest) {
    mixin TextureBackendStub;
} else version (InDoesRender) {

import bindbc.opengl;
import std.exception : enforce;

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

void oglCreateTextureHandle(ref GLId id) {
    GLuint handle;
    glGenTextures(1, &handle);
    enforce(handle != 0, "Failed to create texture");
    id = handle;
}

void oglDeleteTextureHandle(ref GLId id) {
    if (id) {
        GLuint handle = id;
        glDeleteTextures(1, &handle);
        id = 0;
    }
}

void oglBindTextureHandle(GLId id, uint unit) {
    glActiveTexture(GL_TEXTURE0 + (unit <= 31 ? unit : 31));
    glBindTexture(GL_TEXTURE_2D, id);
}

void oglUploadTextureData(GLId id, int width, int height, int inChannels, int outChannels, bool stencil, ubyte[] data) {
    glBindTexture(GL_TEXTURE_2D, id);
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

void oglUpdateTextureRegion(GLId id, int x, int y, int width, int height, int channels, ubyte[] data) {
    auto format = channelFormat(channels);
    glBindTexture(GL_TEXTURE_2D, id);
    glTexSubImage2D(GL_TEXTURE_2D, 0, x, y, width, height, format, GL_UNSIGNED_BYTE, data.ptr);
}

void oglGenerateTextureMipmap(GLId id) {
    glBindTexture(GL_TEXTURE_2D, id);
    glGenerateMipmap(GL_TEXTURE_2D);
}

void oglApplyTextureFiltering(GLId id, Filtering filtering, bool useMipmaps = true) {
    glBindTexture(GL_TEXTURE_2D, id);
    bool linear = filtering == Filtering.Linear;
    auto minFilter = useMipmaps
        ? (linear ? GL_LINEAR_MIPMAP_LINEAR : GL_NEAREST_MIPMAP_NEAREST)
        : (linear ? GL_LINEAR : GL_NEAREST);
    auto magFilter = linear ? GL_LINEAR : GL_NEAREST;
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, minFilter);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, magFilter);
}

void oglApplyTextureWrapping(GLId id, Wrapping wrapping) {
    glBindTexture(GL_TEXTURE_2D, id);
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

void oglApplyTextureAnisotropy(GLId id, float value) {
    glBindTexture(GL_TEXTURE_2D, id);
    glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_MAX_ANISOTROPY, value);
}

float oglMaxTextureAnisotropy() {
    float max;
    glGetFloatv(GL_MAX_TEXTURE_MAX_ANISOTROPY, &max);
    return max;
}

void oglReadTextureData(GLId id, int channels, bool stencil, ubyte[] buffer) {
    glBindTexture(GL_TEXTURE_2D, id);
    GLuint format = stencil ? GL_DEPTH_STENCIL : channelFormat(channels);
    glGetTexImage(GL_TEXTURE_2D, 0, format, GL_UNSIGNED_BYTE, buffer.ptr);
}

} else {

mixin TextureBackendStub;

}

// ---- source/nlshim/core/render/backends/package.d ----

import std.exception : enforce;

/// Struct for backend-cached shared GPU state
alias RenderResourceHandle = size_t;

struct RenderGpuState {
    RenderResourceHandle framebuffer;
    RenderResourceHandle[8] drawBuffers;
    ubyte drawBufferCount;
    bool[4] colorMask;
    bool blendEnabled;
}

/// Base type for backend-provided opaque handles.
class RenderBackendHandle { }

/// Handle for shader programs managed by a RenderBackend.
class RenderShaderHandle : RenderBackendHandle { }

/// Handle for texture resources managed by a RenderBackend.
class RenderTextureHandle : RenderBackendHandle { }

enum BackendEnum {
    OpenGL,
    DirectX12,
    Vulkan,
}

version (Windows) {
    version (UseDirectX) {
        version = RenderBackendDirectX12;
    }
}

/*
class RenderingBackend(BackendEnum backendType) if (backendType != BackendEnum.OpenGL){
    private auto backendUnsupported(T = void)(string func) {
        enforce(false, "Rendering backend "~backendType.stringof~" does not implement "~func);
        static if (!is(T == void)) {
            return T.init;
        }
    }

    void initializeRenderer() { backendUnsupported(__FUNCTION__); }
    void resizeViewportTargets(int width, int height) { backendUnsupported(__FUNCTION__); }
    void dumpViewport(ref ubyte[] data, int width, int height) { backendUnsupported(__FUNCTION__); }
    void beginScene() { backendUnsupported(__FUNCTION__); }
    void endScene() { backendUnsupported(__FUNCTION__); }
    void postProcessScene() { backendUnsupported(__FUNCTION__); }

    void initializeDrawableResources() { backendUnsupported(__FUNCTION__); }
    void bindDrawableVao() { backendUnsupported(__FUNCTION__); }
    void createDrawableBuffers(out uint ibo) { backendUnsupported(__FUNCTION__); }
    void uploadDrawableIndices(uint ibo, ushort[] indices) { backendUnsupported(__FUNCTION__); }
    void uploadSharedVertexBuffer(Vec2Array vertices) { backendUnsupported(__FUNCTION__); }
    void uploadSharedUvBuffer(Vec2Array uvs) { backendUnsupported(__FUNCTION__); }
    void uploadSharedDeformBuffer(Vec2Array deform) { backendUnsupported(__FUNCTION__); }
    void drawDrawableElements(uint ibo, size_t indexCount) { backendUnsupported(__FUNCTION__); }

    bool supportsAdvancedBlend() { return backendUnsupported!bool(__FUNCTION__); }
    bool supportsAdvancedBlendCoherent() { return backendUnsupported!bool(__FUNCTION__); }
    void setAdvancedBlendCoherent(bool enabled) { backendUnsupported(__FUNCTION__); }
    void setLegacyBlendMode(BlendMode mode) { backendUnsupported(__FUNCTION__); }
    void setAdvancedBlendEquation(BlendMode mode) { backendUnsupported(__FUNCTION__); }
    void issueBlendBarrier() { backendUnsupported(__FUNCTION__); }
    void initDebugRenderer() { backendUnsupported(__FUNCTION__); }
    void setDebugPointSize(float size) { backendUnsupported(__FUNCTION__); }
    void setDebugLineWidth(float size) { backendUnsupported(__FUNCTION__); }
    void uploadDebugBuffer(Vec3Array points, ushort[] indices) { backendUnsupported(__FUNCTION__); }
    void setDebugExternalBuffer(uint vbo, uint ibo, int count) { backendUnsupported(__FUNCTION__); }
    void drawDebugPoints(vec4 color, mat4 mvp) { backendUnsupported(__FUNCTION__); }
    void drawDebugLines(vec4 color, mat4 mvp) { backendUnsupported(__FUNCTION__); }

    void drawPartPacket(ref PartDrawPacket packet) { backendUnsupported(__FUNCTION__); }
    void drawMaskPacket(ref MaskDrawPacket packet) { backendUnsupported(__FUNCTION__); }
    void beginDynamicComposite(DynamicCompositePass pass) { backendUnsupported(__FUNCTION__); }
    void endDynamicComposite(DynamicCompositePass pass) { backendUnsupported(__FUNCTION__); }
    void destroyDynamicComposite(DynamicCompositeSurface surface) { backendUnsupported(__FUNCTION__); }
    void beginMask(bool useStencil) { backendUnsupported(__FUNCTION__); }
    void applyMask(ref MaskApplyPacket packet) { backendUnsupported(__FUNCTION__); }
    void beginMaskContent() { backendUnsupported(__FUNCTION__); }
    void endMask() { backendUnsupported(__FUNCTION__); }
    void drawTextureAtPart(Texture texture, Part part) { backendUnsupported(__FUNCTION__); }
    void drawTextureAtPosition(Texture texture, vec2 position, float opacity,
                               vec3 color, vec3 screenColor) { backendUnsupported(__FUNCTION__); }
    void drawTextureAtRect(Texture texture, rect area, rect uvs,
                           float opacity, vec3 color, vec3 screenColor,
                           Shader shader = null, Camera cam = null) { backendUnsupported(__FUNCTION__); }
    uint framebufferHandle() { return backendUnsupported!uint(__FUNCTION__); }
    uint renderImageHandle() { return backendUnsupported!uint(__FUNCTION__); }
    uint compositeFramebufferHandle() { return 0; }
    uint compositeImageHandle() { return 0; }
    uint mainAlbedoHandle() { return backendUnsupported!uint(__FUNCTION__); }
    uint mainEmissiveHandle() { return backendUnsupported!uint(__FUNCTION__); }
    uint mainBumpHandle() { return backendUnsupported!uint(__FUNCTION__); }
    uint compositeEmissiveHandle() { return 0; }
    uint compositeBumpHandle() { return 0; }
    uint blendFramebufferHandle() { return backendUnsupported!uint(__FUNCTION__); }
    uint blendAlbedoHandle() { return backendUnsupported!uint(__FUNCTION__); }
    uint blendEmissiveHandle() { return backendUnsupported!uint(__FUNCTION__); }
    uint blendBumpHandle() { return backendUnsupported!uint(__FUNCTION__); }
    void addBasicLightingPostProcess() { backendUnsupported(__FUNCTION__); }
    void setDifferenceAggregationEnabled(bool enabled) { backendUnsupported(__FUNCTION__); }
    bool isDifferenceAggregationEnabled() { return backendUnsupported!bool(__FUNCTION__); }
    void setDifferenceAggregationRegion(DifferenceEvaluationRegion region) { backendUnsupported(__FUNCTION__); }
    DifferenceEvaluationRegion getDifferenceAggregationRegion() { return backendUnsupported!DifferenceEvaluationRegion(__FUNCTION__); }
    bool evaluateDifferenceAggregation(uint texture, int width, int height) { return backendUnsupported!bool(__FUNCTION__); }
    bool fetchDifferenceAggregationResult(out DifferenceEvaluationResult result) { return backendUnsupported!bool(__FUNCTION__); }

    RenderShaderHandle createShader(string vertexSource, string fragmentSource) { return backendUnsupported!RenderShaderHandle(__FUNCTION__); }
    void destroyShader(RenderShaderHandle shader) { backendUnsupported(__FUNCTION__); }
    void useShader(RenderShaderHandle shader) { backendUnsupported(__FUNCTION__); }
    int getShaderUniformLocation(RenderShaderHandle shader, string name) { return backendUnsupported!int(__FUNCTION__); }
    void setShaderUniform(RenderShaderHandle shader, int location, bool value) { backendUnsupported(__FUNCTION__); }
    void setShaderUniform(RenderShaderHandle shader, int location, int value) { backendUnsupported(__FUNCTION__); }
    void setShaderUniform(RenderShaderHandle shader, int location, float value) { backendUnsupported(__FUNCTION__); }
    void setShaderUniform(RenderShaderHandle shader, int location, vec2 value) { backendUnsupported(__FUNCTION__); }
    void setShaderUniform(RenderShaderHandle shader, int location, vec3 value) { backendUnsupported(__FUNCTION__); }
    void setShaderUniform(RenderShaderHandle shader, int location, vec4 value) { backendUnsupported(__FUNCTION__); }
    void setShaderUniform(RenderShaderHandle shader, int location, mat4 value) { backendUnsupported(__FUNCTION__); }

    RenderTextureHandle createTextureHandle() { return backendUnsupported!RenderTextureHandle(__FUNCTION__); }
    void destroyTextureHandle(RenderTextureHandle texture) { backendUnsupported(__FUNCTION__); }
    void bindTextureHandle(RenderTextureHandle texture, uint unit) { backendUnsupported(__FUNCTION__); }
    void uploadTextureData(RenderTextureHandle texture, int width, int height, int inChannels,
                           int outChannels, bool stencil, ubyte[] data) { backendUnsupported(__FUNCTION__); }
    void updateTextureRegion(RenderTextureHandle texture, int x, int y, int width, int height,
                             int channels, ubyte[] data) { backendUnsupported(__FUNCTION__); }
    void generateTextureMipmap(RenderTextureHandle texture) { backendUnsupported(__FUNCTION__); }
    void applyTextureFiltering(RenderTextureHandle texture, Filtering filtering, bool useMipmaps = true) { backendUnsupported(__FUNCTION__); }
    void applyTextureWrapping(RenderTextureHandle texture, Wrapping wrapping) { backendUnsupported(__FUNCTION__); }
    void applyTextureAnisotropy(RenderTextureHandle texture, float value) { backendUnsupported(__FUNCTION__); }
    float maxTextureAnisotropy() { return backendUnsupported!float(__FUNCTION__); }
    void readTextureData(RenderTextureHandle texture, int channels, bool stencil,
                         ubyte[] buffer) { backendUnsupported(__FUNCTION__); }
    size_t textureNativeHandle(RenderTextureHandle texture) { return backendUnsupported!size_t(__FUNCTION__); }
}
*/
version (RenderBackendOpenGL) {
    enum SelectedBackend = BackendEnum.OpenGL;
} else version (RenderBackendDirectX12) {
    enum SelectedBackend = BackendEnum.DirectX12;
} else version (RenderBackendVulkan) {
    enum SelectedBackend = BackendEnum.Vulkan;
} else {
    enum SelectedBackend = BackendEnum.OpenGL;
}

version (UseQueueBackend) {
    enum bool SelectedBackendIsOpenGL = false;
} else {
    enum bool SelectedBackendIsOpenGL = SelectedBackend == BackendEnum.OpenGL;
}

version (InDoesRender) {
    version (UseQueueBackend) {
    } else {
        version (RenderBackendDirectX12) {
        }
    }
}

version (UseQueueBackend) {
} else {
}

version (UseQueueBackend) {
    alias RenderBackend = core.render.backends.queue.RenderingBackend!(BackendEnum.OpenGL);
} else {
    template RenderingBackend(BackendEnum backendType) {
        static if (backendType == BackendEnum.OpenGL) {
            alias RenderingBackend = core.render.backends.opengl.RenderingBackend!(backendType);
        } else static if (backendType == BackendEnum.DirectX12) {
            alias RenderingBackend = core.render.backends.directx12.RenderingBackend!(backendType);
        } else {
            enum msg = "RenderingBackend!("~backendType.stringof~") is not implemented. Available options: BackendEnum.OpenGL, BackendEnum.DirectX12.";
            pragma(msg, msg);
            static assert(backendType == BackendEnum.OpenGL || backendType == BackendEnum.DirectX12, msg);
        }
    }

    alias RenderBackend = RenderingBackend!(BackendEnum.OpenGL);
}

// ---- source/nlshim/core/render/commands.d ----






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

struct CompositeDrawPacket {
    bool valid;
    float opacity;
    vec3 tint;
    vec3 screenTint;
    BlendMode blendingMode;
}

class DynamicCompositeSurface {
    Texture[3] textures;
    size_t textureCount;
    Texture stencil;
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

bool tryMakeMaskApplyPacket(Drawable, bool, out MaskApplyPacket packet) { packet = MaskApplyPacket.init; return false; }

CompositeDrawPacket makeCompositeDrawPacket(Composite) { CompositeDrawPacket packet; packet.valid = false; return packet; }

// ---- source/nlshim/core/render/passes.d ----

/// Render target scope kinds.
enum RenderPassKind {
    Root,
    DynamicComposite,
}

/// Hint describing which render scope should receive emitted commands.
struct RenderScopeHint {
    RenderPassKind kind = RenderPassKind.Root;
    size_t token;
    bool skip;

    static RenderScopeHint root() {
        RenderScopeHint hint;
        hint.kind = RenderPassKind.Root;
        hint.token = 0;
        hint.skip = false;
        return hint;
    }

    static RenderScopeHint forDynamic(size_t token) {
        if (token == 0 || token == size_t.max) return root();
        RenderScopeHint hint;
        hint.kind = RenderPassKind.DynamicComposite;
        hint.token = token;
        hint.skip = false;
        return hint;
    }

    static RenderScopeHint skipHint() {
        RenderScopeHint hint;
        hint.kind = RenderPassKind.Root;
        hint.token = 0;
        hint.skip = true;
        return hint;
    }
}

// ---- source/nlshim/core/render/profiler.d ----

version (NijiliveRenderProfiler) {

import core.time : MonoTime, Duration, seconds, dur;
import std.algorithm : sort;
import std.array : array;
import std.format : format;
import std.stdio : writeln;

private class RenderProfiler {
    long[string] accumUsec;
    size_t[string] callCounts;
    MonoTime lastReport = MonoTime.init;
    size_t frameCount;

    void addSample(string label, Duration sample) {
        accumUsec[label] += sample.total!"usecs";
        callCounts[label] += 1;
    }

    void frameCompleted() {
        frameCount++;
        auto now = MonoTime.currTime;
        if (lastReport == MonoTime.init) {
            lastReport = now;
            return;
        }
        auto elapsed = now - lastReport;
        if (elapsed >= 1.seconds) {
            report(elapsed);
            accumUsec = typeof(accumUsec).init;
            callCounts = typeof(callCounts).init;
            frameCount = 0;
            lastReport = now;
        }
    }

private:
    void report(Duration interval) {
        double secondsElapsed = interval.total!"usecs" / 1_000_000.0;
            writeln(format!"[RenderProfiler] %.3fs window (%s frames)"(
                secondsElapsed, frameCount));
        auto entries = accumUsec.byKeyValue.array;
        sort!((a, b) => a.value > b.value)(entries);
        foreach (entry; entries) {
            double totalMs = entry.value / 1000.0;
            auto count = entry.key in callCounts ? callCounts[entry.key] : 0;
            double avgMs = count ? totalMs / cast(double)count : totalMs;
            double perFrameMs = frameCount ? totalMs / cast(double)frameCount : totalMs;
            writeln(format!"  %-18s total=%8.3f ms  avg=%6.3f ms  perFrame=%6.3f ms  calls=%6s"(
                entry.key, totalMs, avgMs, perFrameMs, count));
        }
        if (entries.length == 0) {
            writeln("  (no instrumented passes recorded)");
        }
    }
}

private RenderProfiler profiler() {
    static __gshared RenderProfiler instance;
    if (instance is null) {
        instance = new RenderProfiler();
    }
    return instance;
}

struct RenderProfileScope {
    private string label;
    private MonoTime start;
    private bool active;

    this(string label) {
        this.label = label;
        start = MonoTime.currTime;
        active = true;
    }

    void stop() {
        if (!active || label.length == 0) return;
        auto duration = MonoTime.currTime - start;
        profiler().addSample(label, duration);
        active = false;
    }

    ~this() {
        stop();
    }
}

RenderProfileScope profileScope(string label) {
    return RenderProfileScope(label);
}

/// Add a sampled duration in microseconds (e.g., GPU timer results).
void renderProfilerAddSampleUsec(string label, ulong usec) {
    profiler().addSample(label, dur!"usecs"(usec));
}

void renderProfilerFrameCompleted() {
    profiler().frameCompleted();
}

} else {

struct RenderProfileScope {
    this(string) {}
    void stop() {}
}

RenderProfileScope profileScope(string label) {
    return RenderProfileScope(label);
}

void renderProfilerAddSampleUsec(string, ulong) {}

void renderProfilerFrameCompleted() {}

}

// ---- source/nlshim/core/render/shared_deform_buffer.d ----

import std.algorithm : min;


private struct SharedVecAtlas {
    private struct Binding {
        Vec2Array* target;
        size_t* offsetSink;
        size_t length;
        size_t offset;
    }

    Vec2Array storage;
    Binding[] bindings;
    size_t[Vec2Array*] lookup;
    bool dirty;

    void registerArray(ref Vec2Array target, size_t* offsetSink) {
        auto ptr = &target;
        if (auto found = ptr in lookup) {
            auto idx = *found;
            bindings[idx].offsetSink = offsetSink;
            return;
        }
        auto idx = bindings.length;
        lookup[ptr] = idx;
        bindings ~= Binding(ptr, offsetSink, target.length, 0);
        rebuild();
    }

    void unregisterArray(ref Vec2Array target) {
        auto ptr = &target;
        if (auto found = ptr in lookup) {
            auto idx = *found;
            auto last = bindings.length - 1;
            lookup.remove(ptr);
            if (idx != last) {
                bindings[idx] = bindings[last];
                lookup[bindings[idx].target] = idx;
            }
            bindings.length = last;
            rebuild();
        }
    }

    void resizeArray(ref Vec2Array target, size_t newLength) {
        auto ptr = &target;
        if (auto found = ptr in lookup) {
            auto idx = *found;
            if (bindings[idx].length == newLength) {
                return;
            }
            bindings[idx].length = newLength;
            rebuild();
        }
    }

    size_t stride() const {
        return storage.length;
    }

    ref Vec2Array data() {
        return storage;
    }

    bool isDirty() const {
        return dirty;
    }

    void markDirty() {
        dirty = true;
    }

    void markUploaded() {
        dirty = false;
    }

private:
    void rebuild() {
        size_t total = 0;
        foreach (binding; bindings) {
            total += binding.length;
        }

        Vec2Array newStorage;
        if (total) {
            newStorage.length = total;
            size_t offset = 0;
            foreach (ref binding; bindings) {
                auto len = binding.length;
                if (len) {
                    auto dstX = newStorage.lane(0)[offset .. offset + len];
                    auto dstY = newStorage.lane(1)[offset .. offset + len];
                    auto src = *binding.target;
                    auto copyLen = min(len, src.length);
                    if (copyLen) {
                        dstX[0 .. copyLen] = src.lane(0)[0 .. copyLen];
                        dstY[0 .. copyLen] = src.lane(1)[0 .. copyLen];
                    }
                    if (copyLen < len) {
                        dstX[copyLen .. len] = 0;
                        dstY[copyLen .. len] = 0;
                    }
                } else {
                    (*binding.target).clear();
                }
                binding.offset = offset;
                offset += len;
            }
        } else {
            foreach (ref binding; bindings) {
                binding.offset = 0;
                (*binding.target).clear();
            }
        }

        storage = newStorage;
        foreach (ref binding; bindings) {
            if (binding.length) {
                (*binding.target).bindExternalStorage(storage, binding.offset, binding.length);
            } else {
                (*binding.target).clear();
            }
            if (binding.offsetSink !is null) {
                *binding.offsetSink = binding.offset;
            }
        }
        dirty = true;
    }
}

private __gshared {
    SharedVecAtlas deformAtlas;
    SharedVecAtlas vertexAtlas;
    SharedVecAtlas uvAtlas;
}

public void sharedDeformRegister(ref Vec2Array target, size_t* offsetSink) {
    deformAtlas.registerArray(target, offsetSink);
}

public void sharedDeformUnregister(ref Vec2Array target) {
    deformAtlas.unregisterArray(target);
}

public void sharedDeformResize(ref Vec2Array target, size_t newLength) {
    deformAtlas.resizeArray(target, newLength);
}

public size_t sharedDeformAtlasStride() {
    return deformAtlas.stride();
}

public ref Vec2Array sharedDeformBufferData() {
    return deformAtlas.data();
}

public bool sharedDeformBufferDirty() {
    return deformAtlas.isDirty();
}

public void sharedDeformMarkDirty() {
    deformAtlas.markDirty();
}

public void sharedDeformMarkUploaded() {
    deformAtlas.markUploaded();
}

public void sharedVertexRegister(ref Vec2Array target, size_t* offsetSink) {
    vertexAtlas.registerArray(target, offsetSink);
}

public void sharedVertexUnregister(ref Vec2Array target) {
    vertexAtlas.unregisterArray(target);
}

public void sharedVertexResize(ref Vec2Array target, size_t newLength) {
    vertexAtlas.resizeArray(target, newLength);
}

public size_t sharedVertexAtlasStride() {
    return vertexAtlas.stride();
}

public ref Vec2Array sharedVertexBufferData() {
    return vertexAtlas.data();
}

public bool sharedVertexBufferDirty() {
    return vertexAtlas.isDirty();
}

public void sharedVertexMarkDirty() {
    vertexAtlas.markDirty();
}

public void sharedVertexMarkUploaded() {
    vertexAtlas.markUploaded();
}

public void sharedUvRegister(ref Vec2Array target, size_t* offsetSink) {
    uvAtlas.registerArray(target, offsetSink);
}

public void sharedUvUnregister(ref Vec2Array target) {
    uvAtlas.unregisterArray(target);
}

public void sharedUvResize(ref Vec2Array target, size_t newLength) {
    uvAtlas.resizeArray(target, newLength);
}

public size_t sharedUvAtlasStride() {
    return uvAtlas.stride();
}

public ref Vec2Array sharedUvBufferData() {
    return uvAtlas.data();
}

public bool sharedUvBufferDirty() {
    return uvAtlas.isDirty();
}

public void sharedUvMarkDirty() {
    uvAtlas.markDirty();
}

public void sharedUvMarkUploaded() {
    uvAtlas.markUploaded();
}

// ---- source/nlshim/core/render/support.d ----

import inmath.linalg : Vector;
alias Vec2Array = veca!(float, 2);
alias Vec3Array = veca!(float, 3);
alias Vec4Array = veca!(float, 4);

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

private bool inAdvancedBlending;
private bool inAdvancedBlendingCoherent;
version(OSX)
    enum bool inDefaultTripleBufferFallback = true;
else
    enum bool inDefaultTripleBufferFallback = false;
private bool inForceTripleBufferFallback = inDefaultTripleBufferFallback;
private bool inAdvancedBlendingAvailable;
private bool inAdvancedBlendingCoherentAvailable;

private auto blendBackend() { return currentRenderBackend(); }

version (InDoesRender) {
    void setAdvancedBlendCoherent(bool enabled) { blendBackend().setAdvancedBlendCoherent(enabled); }
    void setLegacyBlendMode(BlendMode blendingMode) { blendBackend().setLegacyBlendMode(blendingMode); }
    void setAdvancedBlendEquation(BlendMode blendingMode) { blendBackend().setAdvancedBlendEquation(blendingMode); }
    void issueBlendBarrier() { blendBackend().issueBlendBarrier(); }
    bool hasAdvancedBlendSupport() { return blendBackend().supportsAdvancedBlend(); }
    bool hasAdvancedBlendCoherentSupport() { return blendBackend().supportsAdvancedBlendCoherent(); }
} else {
    void setAdvancedBlendCoherent(bool) { }
    void setLegacyBlendMode(BlendMode) { }
    void setAdvancedBlendEquation(BlendMode) { }
    void issueBlendBarrier() { }
    bool hasAdvancedBlendSupport() { return false; }
    bool hasAdvancedBlendCoherentSupport() { return false; }
}

private void inApplyBlendingCapabilities() {
    bool desiredAdvanced = inAdvancedBlendingAvailable && !inForceTripleBufferFallback;
    bool desiredCoherent = inAdvancedBlendingCoherentAvailable && !inForceTripleBufferFallback;

    if (desiredCoherent != inAdvancedBlendingCoherent) {
        setAdvancedBlendCoherent(desiredCoherent);
    }

    inAdvancedBlending = desiredAdvanced;
    inAdvancedBlendingCoherent = desiredCoherent;
}

private void inSetBlendModeLegacy(BlendMode blendingMode) {
    setLegacyBlendMode(blendingMode);
}

public bool inUseMultistageBlending(BlendMode blendingMode) {
    if (inForceTripleBufferFallback) return false;
    switch(blendingMode) {
        case BlendMode.Normal,
             BlendMode.LinearDodge,
             BlendMode.AddGlow,
             BlendMode.Subtract,
             BlendMode.Inverse,
             BlendMode.DestinationIn,
             BlendMode.ClipToLower,
             BlendMode.SliceFromLower:
                 return false;
        default: return inAdvancedBlending;
    }
}

public void nlApplyBlendingCapabilities() {
    inApplyBlendingCapabilities();
}

public void inInitBlending() {
    inForceTripleBufferFallback = inDefaultTripleBufferFallback;
    inAdvancedBlendingAvailable = hasAdvancedBlendSupport();
    inAdvancedBlendingCoherentAvailable = hasAdvancedBlendCoherentSupport();
    inApplyBlendingCapabilities();
}

public void nlSetTripleBufferFallback(bool enable) {
    if (inForceTripleBufferFallback == enable) return;
    inForceTripleBufferFallback = enable;
    inApplyBlendingCapabilities();
}

public bool nlIsTripleBufferFallbackEnabled() {
    return inForceTripleBufferFallback;
}

public bool inIsAdvancedBlendMode(BlendMode mode) {
    if (!inAdvancedBlending) return false;
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

public void inSetBlendMode(BlendMode blendingMode, bool legacyOnly=false) {
    if (!inAdvancedBlending || legacyOnly) inSetBlendModeLegacy(blendingMode);
    else setAdvancedBlendEquation(blendingMode);
}

public void inBlendModeBarrier(BlendMode mode) {
    if (inAdvancedBlending && !inAdvancedBlendingCoherent && inIsAdvancedBlendMode(mode))
        issueBlendBarrier();
}

// ===== Drawable helpers =====


public void incDrawableBindVAO() {
    version (InDoesRender) {
        currentRenderBackend().bindDrawableVao();
    }
}

private bool doGenerateBounds = false;
public void inSetUpdateBounds(bool state) { doGenerateBounds = state; }
public bool inGetUpdateBounds() { return doGenerateBounds; }

// Minimal placeholders to satisfy type references after core/nodes removal.
class Drawable {}
class Part : Drawable {}
class Mask : Drawable {}
class Projectable : Drawable {}
class Composite : Projectable {}

// ---- source/nlshim/core/runtime_state.d ----

import fghj : deserializeValue;
import std.exception : enforce;
import core.stdc.string : memcpy;

public int[] inViewportWidth;
public int[] inViewportHeight;
public vec4 inClearColor = vec4(0, 0, 0, 0);
public Camera[] inCamera;
vec3 inSceneAmbientLight = vec3(1, 1, 1);

private __gshared RenderBackend cachedRenderBackend;

private void ensureRenderBackend() {
    if (cachedRenderBackend is null) {
        cachedRenderBackend = new RenderBackend();
    }
}

public void inSetRenderBackend(RenderBackend backend) {
    cachedRenderBackend = backend;
}

/// Push a new default camera onto the stack.
void inPushCamera() {
    inPushCamera(new Camera);
}

/// Push a provided camera instance onto the stack.
void inPushCamera(Camera camera) {
    inCamera ~= camera;
}

/// Pop the most recent camera if we have more than one.
void inPopCamera() {
    if (inCamera.length > 1) {
        inCamera.length = inCamera.length - 1;
    }
}

/// Current camera accessor (ensures at least one camera exists).
Camera inGetCamera() {
    if (inCamera.length == 0) {
        inPushCamera(new Camera);
    }
    return inCamera[$-1];
}

/// Set the current camera, falling back to push if the stack is empty.
void inSetCamera(Camera camera) {
    if (inCamera.length == 0) {
        inPushCamera(camera);
    } else {
        inCamera[$-1] = camera;
    }
}

version(unittest)
void inEnsureCameraStackForTests() {
    if (inCamera.length == 0) {
        inCamera ~= new Camera;
    }
}

/// Push viewport dimensions and sync camera stack.
void inPushViewport(int width, int height) {
    inViewportWidth ~= width;
    inViewportHeight ~= height;
    inPushCamera();
    import std.stdio : writeln;
    writeln("[vp] push width=", width, " height=", height,
            " camDepth=", inCamera.length);
}

/// Pop viewport if we have more than one entry.
void inPopViewport() {
    if (inViewportWidth.length > 1) {
        inViewportWidth.length = inViewportWidth.length - 1;
        inViewportHeight.length = inViewportHeight.length - 1;
        inPopCamera();
    }
    import std.stdio : writeln;
    writeln("[vp] pop  camDepth=", inCamera.length);
}

/**
    Sets the viewport dimensions (logical state + backend notification)
*/
void inSetViewport(int width, int height) {
    if (inViewportWidth.length == 0) {
        inPushViewport(width, height);
    } else {
        if (width == inViewportWidth[$-1] && height == inViewportHeight[$-1]) {
            requireRenderBackend().resizeViewportTargets(width, height);
            return;
        }
        inViewportWidth[$-1] = width;
        inViewportHeight[$-1] = height;
    }
    requireRenderBackend().resizeViewportTargets(width, height);
}

/**
    Gets the current viewport dimensions.
*/
void inGetViewport(out int width, out int height) {
    if (inViewportWidth.length == 0) {
        width = 0;
        height = 0;
        return;
    }
    width = inViewportWidth[$-1];
    height = inViewportHeight[$-1];
}

version(unittest)
void inEnsureViewportForTests(int width = 640, int height = 480) {
    if (inViewportWidth.length == 0) {
        inPushViewport(width, height);
    }
}

/// Compute viewport data size (RGBA per pixel).
size_t inViewportDataLength() {
    return inViewportWidth[$-1] * inViewportHeight[$-1] * 4;
}

/// Dump current viewport pixels (common path, backend-provided grab).
void inDumpViewport(ref ubyte[] dumpTo) {
    auto width = inViewportWidth.length ? inViewportWidth[$-1] : 0;
    auto height = inViewportHeight.length ? inViewportHeight[$-1] : 0;
    auto required = width * height * 4;
    enforce(dumpTo.length >= required, "Invalid data destination length for inDumpViewport");

    requireRenderBackend().dumpViewport(dumpTo, width, height);

    if (width == 0 || height == 0) return;
    ubyte[] tmpLine = new ubyte[width * 4];
    size_t ri = 0;
    foreach_reverse(i; height/2 .. height) {
        size_t lineSize = width * 4;
        size_t oldLineStart = lineSize * ri;
        size_t newLineStart = lineSize * i;

        memcpy(tmpLine.ptr, dumpTo.ptr + oldLineStart, lineSize);
        memcpy(dumpTo.ptr + oldLineStart, dumpTo.ptr + newLineStart, lineSize);
        memcpy(dumpTo.ptr + newLineStart, tmpLine.ptr, lineSize);

        ri++;
    }
}

/// Clear color setter.
void inSetClearColor(float r, float g, float b, float a) {
    inClearColor = vec4(r, g, b, a);
}

/// Clear color getter.
void inGetClearColor(out float r, out float g, out float b, out float a) {
    r = inClearColor.r;
    g = inClearColor.g;
    b = inClearColor.b;
    a = inClearColor.a;
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

version(InDoesRender) {

    private RenderBackend renderBackendOrNull() {
        return tryRenderBackend();
    }

    private RenderResourceHandle handleOrZero(RenderResourceHandle value) {
        return value;
    }

    RenderResourceHandle inGetRenderImage() {
        auto backend = renderBackendOrNull();
        return backend is null ? 0 : handleOrZero(backend.renderImageHandle());
    }

    RenderResourceHandle inGetFramebuffer() {
        auto backend = renderBackendOrNull();
        return backend is null ? 0 : handleOrZero(backend.framebufferHandle());
    }

    RenderResourceHandle inGetCompositeImage() { return 0; }

    RenderResourceHandle inGetCompositeFramebuffer() { return 0; }

    RenderResourceHandle inGetMainAlbedo() {
        auto backend = renderBackendOrNull();
        return backend is null ? 0 : handleOrZero(backend.mainAlbedoHandle());
    }

    RenderResourceHandle inGetMainEmissive() {
        auto backend = renderBackendOrNull();
        return backend is null ? 0 : handleOrZero(backend.mainEmissiveHandle());
    }

    RenderResourceHandle inGetMainBump() {
        auto backend = renderBackendOrNull();
        return backend is null ? 0 : handleOrZero(backend.mainBumpHandle());
    }

    RenderResourceHandle inGetCompositeEmissive() { return 0; }

    RenderResourceHandle inGetCompositeBump() { return 0; }

    RenderResourceHandle inGetBlendFramebuffer() {
        auto backend = renderBackendOrNull();
        return backend is null ? 0 : handleOrZero(backend.blendFramebufferHandle());
    }

    RenderResourceHandle inGetBlendAlbedo() {
        auto backend = renderBackendOrNull();
        return backend is null ? 0 : handleOrZero(backend.blendAlbedoHandle());
    }

    RenderResourceHandle inGetBlendEmissive() {
        auto backend = renderBackendOrNull();
        return backend is null ? 0 : handleOrZero(backend.blendEmissiveHandle());
    }

    RenderResourceHandle inGetBlendBump() {
        auto backend = renderBackendOrNull();
        return backend is null ? 0 : handleOrZero(backend.blendBumpHandle());
    }
} else {
    RenderResourceHandle inGetRenderImage() { return 0; }
    RenderResourceHandle inGetFramebuffer() { return 0; }
    RenderResourceHandle inGetCompositeImage() { return 0; }
    RenderResourceHandle inGetCompositeFramebuffer() { return 0; }
    RenderResourceHandle inGetMainAlbedo() { return 0; }
    RenderResourceHandle inGetMainEmissive() { return 0; }
    RenderResourceHandle inGetMainBump() { return 0; }
    RenderResourceHandle inGetCompositeEmissive() { return 0; }
    RenderResourceHandle inGetCompositeBump() { return 0; }
    RenderResourceHandle inGetBlendFramebuffer() { return 0; }
    RenderResourceHandle inGetBlendAlbedo() { return 0; }
    RenderResourceHandle inGetBlendEmissive() { return 0; }
    RenderResourceHandle inGetBlendBump() { return 0; }
}

void inBeginScene() {
    auto backend = tryRenderBackend();
    if (backend !is null) backend.beginScene();
}

void inEndScene() {
    auto backend = tryRenderBackend();
    if (backend !is null) backend.endScene();
}

void inPostProcessScene() {
    auto backend = tryRenderBackend();
    if (backend !is null) backend.postProcessScene();
}

void inPostProcessingAddBasicLighting() {
    auto backend = tryRenderBackend();
    if (backend !is null) backend.addBasicLightingPostProcess();
}

public
void initRendererCommon() {
    inPushViewport(0, 0);

    inInitBlending();


    inSetClearColor(0, 0, 0, 0);
}

public
void initRenderer() {
    initRendererCommon();
    requireRenderBackend().initializeRenderer();
}

void inSetDifferenceAggregationEnabled(bool enabled) {
    // diff aggregation not supported in this build
}

bool inIsDifferenceAggregationEnabled() {
    return false;
}

void inSetDifferenceAggregationRegion(int x, int y, int width, int height) {
    // no-op
}

DifferenceEvaluationRegion inGetDifferenceAggregationRegion() {
    return DifferenceEvaluationRegion.init;
}

bool inEvaluateDifferenceAggregation(RenderResourceHandle texture, int viewportWidth, int viewportHeight) {
    return false;
}

bool inFetchDifferenceAggregationResult(out DifferenceEvaluationResult result) {
    result = DifferenceEvaluationResult.init;
    return false;
}

// ---- source/nlshim/core/shader.d ----
/*
    Copyright © 2020, Inochi2D Project
    Copyright © 2024, nijigenerate Project
    Distributed under the 2-Clause BSD License, see LICENSE file.
    
    Authors: Luna Nielsen
*/
version (InDoesRender) {
}

struct ShaderStageSource {
    string vertex;
    string fragment;
}

struct ShaderAsset {
    ShaderStageSource opengl;
    ShaderStageSource directx;
    ShaderStageSource vulkan;

    ShaderStageSource sourceForCurrentBackend() const {
        static if (SelectedBackend == BackendEnum.OpenGL) {
            assert(opengl.vertex.length && opengl.fragment.length,
                "OpenGL shader source is not provided.");
            return opengl;
        } else {
            static assert(SelectedBackend == BackendEnum.OpenGL,
                "Selected backend is not supported yet.");
        }
    }

    static ShaderAsset fromOpenGLSource(string vertexSource, string fragmentSource) {
        ShaderAsset asset;
        asset.opengl = ShaderStageSource(vertexSource, fragmentSource);
        return asset;
    }
}

auto shaderAsset(string vertexPath, string fragmentPath)()
{
    enum ShaderAsset asset = ShaderAsset(
        ShaderStageSource(import(vertexPath), import(fragmentPath)),
        ShaderStageSource.init,
        ShaderStageSource.init,
    );
    return asset;
}

/**
    A shader
*/
class Shader {
private:
    RenderShaderHandle handle;

public:

    /**
        Destructor
    */
    ~this() {
        version (InDoesRender) {
            if (handle is null) return;
            auto backend = tryRenderBackend();
            if (backend !is null) {
                backend.destroyShader(handle);
            }
            handle = null;
        }
    }

    /**
        Creates a new shader object from source definitions
    */
    this(ShaderAsset sources) {
        version (InDoesRender) {
            auto variant = sources.sourceForCurrentBackend();
            handle = currentRenderBackend().createShader(variant.vertex, variant.fragment);
        }
    }

    /**
        Creates a new shader object from literal source strings (OpenGL fallback)
    */
    this(string vertex, string fragment) {
        this(ShaderAsset.fromOpenGLSource(vertex, fragment));
    }

    /**
        Use the shader
    */
    void use() {
        version (InDoesRender) {
            if (handle is null) return;
            currentRenderBackend().useShader(handle);
        }
    }

    int getUniformLocation(string name) {
        version (InDoesRender) {
            if (handle is null) return -1;
            return currentRenderBackend().getShaderUniformLocation(handle, name);
        }
        return -1;
    }

    void setUniform(int uniform, bool value) {
        version (InDoesRender) {
            if (handle is null) return;
            currentRenderBackend().setShaderUniform(handle, uniform, value);
        }
    }

    void setUniform(int uniform, int value) {
        version (InDoesRender) {
            if (handle is null) return;
            currentRenderBackend().setShaderUniform(handle, uniform, value);
        }
    }

    void setUniform(int uniform, float value) {
        version (InDoesRender) {
            if (handle is null) return;
            currentRenderBackend().setShaderUniform(handle, uniform, value);
        }
    }

    void setUniform(int uniform, vec2 value) {
        version (InDoesRender) {
            if (handle is null) return;
            currentRenderBackend().setShaderUniform(handle, uniform, value);
        }
    }

    void setUniform(int uniform, vec3 value) {
        version (InDoesRender) {
            if (handle is null) return;
            currentRenderBackend().setShaderUniform(handle, uniform, value);
        }
    }

    void setUniform(int uniform, vec4 value) {
        version (InDoesRender) {
            if (handle is null) return;
            currentRenderBackend().setShaderUniform(handle, uniform, value);
        }
    }

    void setUniform(int uniform, mat4 value) {
        version (InDoesRender) {
            if (handle is null) return;
            currentRenderBackend().setShaderUniform(handle, uniform, value);
        }
    }
}

// ---- source/nlshim/core/texture.d ----
/*
    Copyright © 2020, Inochi2D Project
    Copyright © 2024, nijigenerate Project
    Distributed under the 2-Clause BSD License, see LICENSE file.
    
    Authors: Luna Nielsen
*/

version (UseQueueBackend) {
    extern(C) __gshared void function(size_t handle) ngReleaseExternalHandle; // module-level hook for Unity external texture release
}
import std.exception;
import std.format;
import imagefmt;
import std.algorithm : clamp;
version (InDoesRender) {
}

/**
    A texture which is not bound to an OpenGL context
    Used for texture atlassing
*/
struct ShallowTexture {
public:
    /**
        8-bit RGBA color data
    */
    ubyte[] data;

    /**
        Width of texture
    */
    int width;

    /**
        Height of texture
    */
    int height;

    /**
        Amount of color channels
    */
    int channels;

    /**
        Amount of channels to conver to when passed to OpenGL
    */
    int convChannels;

    /**
        Loads a shallow texture from image file
        Supported file types:
        * PNG 8-bit
        * BMP 8-bit
        * TGA 8-bit non-palleted
        * JPEG baseline
    */
    this(string file, int channels = 0) {
        import std.file : read;

        // Ensure we keep this ref alive until we're done with it
        ubyte[] fData = cast(ubyte[])read(file);

        // Load image from disk, as <channels> 8-bit
        IFImage image = read_image(fData, 0, 8);
        enforce( image.e == 0, "%s: %s".format(IF_ERROR[image.e], file));
        scope(exit) image.free();

        // Copy data from IFImage to this ShallowTexture
        this.data = new ubyte[image.buf8.length];
        this.data[] = image.buf8;

        // Set the width/height data
        this.width = image.w;
        this.height = image.h;
        this.channels = image.c;
        this.convChannels = channels == 0 ? image.c : channels;
    }

    /**
        Loads a shallow texture from image buffer
        Supported file types:
        * PNG 8-bit
        * BMP 8-bit
        * TGA 8-bit non-palleted
        * JPEG baseline

        By setting channels to a specific value you can force a specific color mode
    */
    this(ubyte[] buffer, int channels = 0) {

        // Load image from disk, as <channels> 8-bit
        IFImage image = read_image(buffer, 0, 8);
        enforce( image.e == 0, "%s".format(IF_ERROR[image.e]));
        scope(exit) image.free();

        // Copy data from IFImage to this ShallowTexture
        this.data = new ubyte[image.buf8.length];
        this.data[] = image.buf8;

        // Set the width/height data
        this.width = image.w;
        this.height = image.h;
        this.channels = image.c;
        this.convChannels = channels == 0 ? image.c : channels;
    }
    
    /**
        Loads uncompressed texture from memory
    */
    this(ubyte[] buffer, int w, int h, int channels = 4) {
        this.data = buffer;

        // Set the width/height data
        this.width = w;
        this.height = h;
        this.channels = channels;
        this.convChannels = channels;
    }
    
    /**
        Loads uncompressed texture from memory
    */
    this(ubyte[] buffer, int w, int h, int channels = 4, int convChannels = 4) {
        this.data = buffer;

        // Set the width/height data
        this.width = w;
        this.height = h;
        this.channels = channels;
        this.convChannels = convChannels;
    }

    /**
        Saves image
    */
    void save(string file) {
        import std.file : write;
        import core.stdc.stdlib : free;
        int e;
        ubyte[] sData = write_image_mem(IF_PNG, this.width, this.height, this.data, channels, e);
        enforce(!e, "%s".format(IF_ERROR[e]));

        write(file, sData);

        // Make sure we free the buffer
        free(sData.ptr);
    }
}

/**
    A texture, only format supported is unsigned 8 bit RGBA
*/
class Texture {
private:
    RenderTextureHandle handle;
    int width_;
    int height_;
    int channels_;
    bool stencil_;
    bool useMipmaps_ = true;
    size_t externalHandle = 0;

    uint uuid;

    ubyte[] lockedData = null;
    bool locked = false;
    bool modified = false;

public:

    /**
        Loads texture from image file
        Supported file types:
        * PNG 8-bit
        * BMP 8-bit
        * TGA 8-bit non-palleted
        * JPEG baseline
    */
    this(string file, int channels = 0, bool useMipmaps = true) {
        import std.file : read;

        // Ensure we keep this ref alive until we're done with it
        ubyte[] fData = cast(ubyte[])read(file);

        // Load image from disk, as RGBA 8-bit
        IFImage image = read_image(fData, 0, 8);
        enforce( image.e == 0, "%s: %s".format(IF_ERROR[image.e], file));
        scope(exit) image.free();

        // Load in image data to OpenGL
        this(image.buf8, image.w, image.h, image.c, channels == 0 ? image.c : channels, false, useMipmaps);
        uuid = 0;
    }

    /**
        Creates a texture from a ShallowTexture
    */
    this(ShallowTexture shallow, bool useMipmaps = true) {
        this(shallow.data, shallow.width, shallow.height, shallow.channels, shallow.convChannels, false, useMipmaps);
    }

    /**
        Creates a new empty texture
    */
    this(int width, int height, int channels = 4, bool stencil = false, bool useMipmaps = true) {

        // Create an empty texture array with no data
        ubyte[] empty = stencil? null: new ubyte[width_*height_*channels];

        // Pass it on to the other texturing
        this(empty, width, height, channels, channels, stencil, useMipmaps);
    }

    /**
        Creates a new texture from specified data
    */
    this(ubyte[] data, int width, int height, int inChannels = 4, int outChannels = 4, bool stencil = false, bool useMipmaps = true) {
        this.width_ = width;
        this.height_ = height;
        this.channels_ = outChannels;
        this.stencil_ = stencil;
        this.useMipmaps_ = useMipmaps;

        version (InDoesRender) {
            auto backend = currentRenderBackend();
            handle = backend.createTextureHandle();
            this.setData(data, inChannels);

            this.setFiltering(Filtering.Linear);
            this.setWrapping(Wrapping.Clamp);
            this.setAnisotropy(incGetMaxAnisotropy()/2.0f);
        }
        uuid = 0;
    }

    ~this() {
        dispose();
    }

    /**
        Width of texture
    */
    int width() {
        return width_;
    }

    /**
        Height of texture
    */
    int height() {
        return height_;
    }

    /**
        Gets the channel count
    */
    int channels() {
        return channels_;
    }

    /**
        Returns a legacy color mode value matching the previous OpenGL enums.
    */
    @property int colorMode() const {
        return legacyColorModeFromChannels(channels_);
    }

    /**
        Center of texture
    */
    vec2i center() {
        return vec2i(width_/2, height_/2);
    }

    /**
        Gets the size of the texture
    */
    vec2i size() {
        return vec2i(width_, height_);
    }

    /**
        Returns runtime UUID for texture
    */
    uint getRuntimeUUID() {
        return uuid;
    }

    /**
        Set the filtering mode used for the texture
    */
    void setFiltering(Filtering filtering) {
        version (InDoesRender) {
            if (handle is null) return;
            currentRenderBackend().applyTextureFiltering(handle, filtering, useMipmaps_);
        }
    }

    void setAnisotropy(float value) {
        version (InDoesRender) {
            if (handle is null) return;
            currentRenderBackend().applyTextureAnisotropy(handle, clamp(value, 1, incGetMaxAnisotropy()));
        }
    }

    /**
        Set the wrapping mode used for the texture
    */
    void setWrapping(Wrapping wrapping) {
        version (InDoesRender) {
            if (handle is null) return;
            currentRenderBackend().applyTextureWrapping(handle, wrapping);
        }
    }

    /**
        Sets the data of the texture
    */
    void setData(ubyte[] data, int inChannels = -1) {
        int actualChannels = inChannels == -1 ? channels_ : inChannels;
        if (locked) {
            lockedData = data;
            modified = true;
        } else {
            version (InDoesRender) {
                if (handle is null) return;
                currentRenderBackend().uploadTextureData(handle, width_, height_, actualChannels, channels_, stencil_, data);
                this.genMipmap();
            }
        }
    }

    /**
        Generate mipmaps
    */
    void genMipmap() {
        version (InDoesRender) {
            if (!stencil_ && handle !is null && useMipmaps_) {
                currentRenderBackend().generateTextureMipmap(handle);
            }
        }
    }

    /**
        Sets a region of a texture to new data
    */
    void setDataRegion(ubyte[] data, int x, int y, int width, int height, int channels = -1) {
        auto actualChannels = channels == -1 ? this.channels_ : channels;

        // Make sure we don't try to change the texture in an out of bounds area.
        enforce( x >= 0 && x+width <= this.width_, "x offset is out of bounds (xoffset=%s, xbound=%s)".format(x+width, this.width_));
        enforce( y >= 0 && y+height <= this.height_, "y offset is out of bounds (yoffset=%s, ybound=%s)".format(y+height, this.height_));

        version (InDoesRender) {
            if (handle is null) return;
            currentRenderBackend().updateTextureRegion(handle, x, y, width, height, actualChannels, data);
        }

        this.genMipmap();
    }

    /**
        Bind this texture
        
        Notes
        - In release mode the unit value is clamped to 31 (The max OpenGL texture unit value)
        - In debug mode unit values over 31 will assert.
    */
    void bind(uint unit = 0) {
        assert(unit <= 31u, "Outside maximum texture unit value");
        version (InDoesRender) {
            if (handle is null) return;
            currentRenderBackend().bindTextureHandle(handle, unit);
        }
    }

    /**
        Gets this texture's native GPU handle (legacy compatibility with OpenGL ID users)
    */
    uint getTextureId() {
        version (InDoesRender) {
            if (handle is null) return 0;
            auto backend = tryRenderBackend();
            if (backend is null) return 0;
            return cast(uint)backend.textureNativeHandle(handle);
        }
        return 0;
    }

    /**
        Saves the texture to file
    */
    void save(string file) {
        write_image(file, width, height, getTextureData(true), channels_);
    }

    /**
        Gets the texture data for the texture
    */
    ubyte[] getTextureData(bool unmultiply=false) {
        if (locked) {
            return lockedData;
        } else {
            ubyte[] buf = new ubyte[width*height*channels_];
            version (InDoesRender) {
                if (handle is null) return buf;
                currentRenderBackend().readTextureData(handle, channels_, stencil_, buf);
            }
            if (unmultiply && channels == 4) {
                inTexUnPremuliply(buf);
            }
            return buf;
        }
    }

    /**
        Disposes texture from GL
    */
    void dispose() {
        version (InDoesRender) {
            if (handle is null) return;
            auto backend = tryRenderBackend();
            if (backend !is null) backend.destroyTextureHandle(handle);
            handle = null;
        }
        version (UseQueueBackend) {
            if (externalHandle && ngReleaseExternalHandle !is null) {
                ngReleaseExternalHandle(externalHandle);
            }
            externalHandle = 0;
        }
    }

    RenderTextureHandle backendHandle() {
        return handle;
    }

    /// Unity/queue backend: allow external handle injection.
    version (UseQueueBackend) {
        void setExternalHandle(size_t h) {
            externalHandle = h;
        }

        size_t getExternalHandle() const {
            return externalHandle;
        }
    }

    Texture dup() {
        auto result = new Texture(width_, height_, channels_, stencil_);
        result.setData(getTextureData(), channels_);
        return result;
    }

    void lock() {
        if (!locked) {
            lockedData = getTextureData();
            modified = false;
            locked = true;
        }
    }

    void unlock() {
        if (locked) {
            locked = false;
            if (modified)
                setData(lockedData, channels_);
            modified = false;
            lockedData = null;
        }
    }
}
private enum int LegacyGLRed = 0x1903;
private enum int LegacyGLRg = 0x8227;
private enum int LegacyGLRgb = 0x1907;
private enum int LegacyGLRgba = 0x1908;

private int legacyColorModeFromChannels(int channels) {
    switch (channels) {
        case 1: return LegacyGLRed;
        case 2: return LegacyGLRg;
        case 3: return LegacyGLRgb;
        default: return LegacyGLRgba;
    }
}

private {
    Texture[] textureBindings;
    bool started = false;
}

/**
    Gets the maximum level of anisotropy
*/
float incGetMaxAnisotropy() {
    version (InDoesRender) {
        auto backend = tryRenderBackend();
        if (backend !is null) {
            return backend.maxTextureAnisotropy();
        }
    }
    return 1;
}

/**
    Begins a texture loading pass
*/
void inBeginTextureLoading() {
    enforce(!started, "Texture loading pass already started!");
    started = true;
}

/**
    Returns a texture from the internal texture list
*/
Texture inGetTextureFromId(uint id) {
    enforce(started, "Texture loading pass not started!");
    return textureBindings[cast(size_t)id];
}

/**
    Gets the latest texture from the internal texture list
*/
Texture inGetLatestTexture() {
    return textureBindings[$-1];
}

/**
    Adds binary texture
*/
void inAddTextureBinary(ShallowTexture data) {
    textureBindings ~= new Texture(data);
}

/**
    Ends a texture loading pass
*/
void inEndTextureLoading(bool checkErrors=true)() {
    static if (checkErrors) enforce(started, "Texture loading pass not started!");
    started = false;
    textureBindings.length = 0;
}

void inTexPremultiply(ref ubyte[] data, int channels = 4) {
    if (channels < 4) return;

    foreach(i; 0..data.length/channels) {

        size_t offsetPixel = (i*channels);
        data[offsetPixel+0] = cast(ubyte)((cast(int)data[offsetPixel+0] * cast(int)data[offsetPixel+3])/255);
        data[offsetPixel+1] = cast(ubyte)((cast(int)data[offsetPixel+1] * cast(int)data[offsetPixel+3])/255);
        data[offsetPixel+2] = cast(ubyte)((cast(int)data[offsetPixel+2] * cast(int)data[offsetPixel+3])/255);
    }
}

void inTexUnPremuliply(ref ubyte[] data) {
    foreach(i; 0..data.length/4) {
        if (data[((i*4)+3)] == 0) continue;

        data[((i*4)+0)] = cast(ubyte)(cast(int)data[((i*4)+0)] * 255 / cast(int)data[((i*4)+3)]);
        data[((i*4)+1)] = cast(ubyte)(cast(int)data[((i*4)+1)] * 255 / cast(int)data[((i*4)+3)]);
        data[((i*4)+2)] = cast(ubyte)(cast(int)data[((i*4)+2)] * 255 / cast(int)data[((i*4)+3)]);
    }
}

// ---- source/nlshim/core/texture_types.d ----

enum Filtering {
    Linear,
    Point,
}

enum Wrapping {
    Clamp,
    Repeat,
    Mirror,
}

// ---- source/nlshim/math/camera.d ----
/*
    nijilive Camera
    previously Inochi2D Camera

    Copyright © 2020, Inochi2D Project
    Copyright © 2024, nijigenerate Project
    Distributed under the 2-Clause BSD License, see LICENSE file.
    
    Authors: Luna Nielsen
*/
import std.math : isFinite;

/**
    An orthographic camera
*/
class Camera {
private:
    mat4 projection;

public:

    /**
        Position of camera
    */
    vec2 position = vec2(0, 0);

    /**
        Rotation of the camera
    */
    float rotation = 0f;

    /**
        Size of the camera
    */
    vec2 scale = vec2(1, 1);

    vec2 getRealSize() {
        int width, height;
        inGetViewport(width, height);

        return vec2(cast(float)width/scale.x, cast(float)height/scale.y);
    }

    vec2 getCenterOffset() {
        vec2 realSize = getRealSize();
        return realSize/2;
    }

    /**
        Matrix for this camera

        width = width of camera area
        height = height of camera area
    */
    mat4 matrix() {
        if(!position.isFinite) position = vec2(0);
        if(!scale.isFinite) scale = vec2(1);
        if(!rotation.isFinite) rotation = 0;

        vec2 realSize = getRealSize();
        if(!realSize.isFinite) return mat4.identity;
        
        vec2 origin = vec2(realSize.x/2, realSize.y/2);
        vec3 pos = vec3(position.x, position.y, -(ushort.max/2));

        return 
            mat4.orthographic(0f, realSize.x, realSize.y, 0, 0, ushort.max) * 
            mat4.translation(origin.x, origin.y, 0) *
            mat4.zRotation(rotation) *
            mat4.translation(pos);
    }
}

// ---- source/nlshim/math/package.d ----
/*
    nijilive Math helpers
    previously Inochi2D Math helpers

    Copyright © 2020, Inochi2D Project
    Copyright © 2024, nijigenerate Project
    Distributed under the 2-Clause BSD License, see LICENSE file.
    
    Authors: Luna Nielsen
*/
import inmath.util;
public import inmath.linalg;
public import inmath.math;
public import std.math : isNaN;
public import inmath.interpolate;

// transform removed

// Unsigned short vectors

/**
    Smoothly dampens from a position to a target
*/
V dampen(V)(V pos, V target, double delta, double speed = 1) if(isVector!V) {
    return (pos - target) * pow(0.001, delta*speed) + target;
}

/**
    Smoothly dampens from a position to a target
*/
float dampen(float pos, float target, double delta, double speed = 1) {
    return (pos - target) * pow(0.001, delta*speed) + target;
}

/**
    Gets whether a point is within an axis aligned rectangle
*/
bool contains(vec4 a, vec2 b) {
    return  b.x >= a.x && 
            b.y >= a.y &&
            b.x <= a.x+a.z &&
            b.y <= a.y+a.w;
}

/**
    Checks if 2 lines segments are intersecting
*/
bool areLineSegmentsIntersecting(vec2 p1, vec2 p2, vec2 p3, vec2 p4) {
    float epsilon = 0.00001f;
    float demoninator = (p4.y - p3.y) * (p2.x - p1.x) - (p4.x - p3.x) * (p2.y - p1.y);
    if (demoninator == 0) return false;

    float uA = ((p4.x - p3.x) * (p1.y - p3.y) - (p4.y - p3.y) * (p1.x - p3.x)) / demoninator;
    float uB = ((p2.x - p1.x) * (p1.y - p3.y) - (p2.y - p1.y) * (p1.x - p3.x)) / demoninator;
    return (uA > 0+epsilon && uA < 1-epsilon && uB > 0+epsilon && uB < 1-epsilon);
}

// ---- source/nlshim/math/simd.d ----

import core.simd;

alias FloatSimd = __vector(float[4]);
enum size_t simdWidth = FloatSimd.sizeof / float.sizeof;
enum size_t floatSimdAlignment = FloatSimd.alignof ? FloatSimd.alignof : FloatSimd.sizeof;
enum size_t floatSimdMask = floatSimdAlignment - 1;

union SimdRepr {
    FloatSimd vec;
    float[simdWidth] scalars;
}

FloatSimd splatSimd(float value) @trusted {
    SimdRepr repr;
    repr.scalars[] = value;
    return repr.vec;
}

FloatSimd loadVec(const float[] data, size_t index) @trusted {
    auto ptr = data.ptr + index;
    if (((cast(size_t)ptr) & floatSimdMask) == 0) {
        return *cast(FloatSimd*)ptr;
    }
    SimdRepr repr;
    repr.scalars[] = data[index .. index + simdWidth];
    return repr.vec;
}

void storeVec(float[] data, size_t index, FloatSimd value) @trusted {
    auto ptr = data.ptr + index;
    if (((cast(size_t)ptr) & floatSimdMask) == 0) {
        *cast(FloatSimd*)ptr = value;
        return;
    }
    SimdRepr repr;
    repr.vec = value;
    data[index .. index + simdWidth] = repr.scalars[];
}

// ---- source/nlshim/math/veca.d ----

import std.math : approxEqual;
import std.traits : isFloatingPoint, isIntegral, Unqual;
import inmath.linalg : Vector;
import core.memory : GC;
import core.simd;

enum simdAlignment = 16;

/// Struct-of-arrays storage for vector data of size `N`.
struct veca(T, size_t N)
if (N > 0) {
    alias Element = Vector!(T, N);
package(opengl) T[][N] lanes;
private:
    T[] backing;
    size_t logicalLength;
    size_t laneStride;
    size_t laneBase;
    size_t viewCapacity;
    bool ownsStorage = true;

    void rebindLanes() @trusted {
        foreach (laneIdx; 0 .. N) {
            if (logicalLength == 0 || backing.length == 0) {
                lanes[laneIdx] = null;
            } else {
                auto stride = laneStride ? laneStride : logicalLength;
                auto start = laneIdx * stride + laneBase;
                lanes[laneIdx] = backing[start .. start + logicalLength];
            }
        }
    }

    T[] snap(size_t totalElements) @trusted {
        enum size_t mask = simdAlignment - 1;
        auto bytes = totalElements * T.sizeof + mask;
        auto rawMem = cast(ubyte*)GC.malloc(bytes, GC.BlkAttr.NO_SCAN);
        assert(rawMem !is null, "Failed to allocate veca backing buffer");
        auto alignedAddr = (cast(size_t)rawMem + mask) & ~mask;
        auto result = cast(T*)alignedAddr;
        // We intentionally skip zero-initialization to avoid an O(n) fill;
        // callers are expected to overwrite the storage before reading.
        return result[0 .. totalElements];
    }

    void allocateBacking(size_t len) @trusted {
        if (len == 0) {
            backing.length = 0;
            logicalLength = 0;
            laneStride = 0;
            laneBase = 0;
            viewCapacity = 0;
            ownsStorage = true;
            rebindLanes();
            return;
        }
        auto oldBacking = backing;
        auto oldStride = laneStride ? laneStride : logicalLength;
        auto oldBase = laneBase;
        auto oldLength = logicalLength;

        const size_t totalElements = len * N;
        auto newBacking = snap(totalElements);
        size_t copyLen = 0;
        static if (N) {
            if (oldLength && len) {
                copyLen = oldLength < len ? oldLength : len;
            }
        }
        if (copyLen && oldBacking.length) {
            foreach (laneIdx; 0 .. N) {
                auto dstStart = laneIdx * len;
                auto srcStart = laneIdx * oldStride + oldBase;
                newBacking[dstStart .. dstStart + copyLen] =
                    oldBacking[srcStart .. srcStart + copyLen];
            }
        }
        backing = newBacking;
        logicalLength = len;
        laneStride = len;
        laneBase = 0;
        viewCapacity = len;
        ownsStorage = true;
        rebindLanes();
    }
public:

    this(size_t length) {
        ensureLength(length);
    }

    this(Element[] values) {
        assign(values);
    }

    this(Element value) {
        ensureLength(1);
        this[0] = value;
    }

    /// Number of logical vectors stored.
    @property size_t length() const {
        return logicalLength;
    }

    /// Update logical vector count (behaves like dynamic array length).
    @property void length(size_t newLength) {
        ensureLength(newLength);
    }

    @property size_t opDollar() const {
        return length;
    }

    /// Ensure every component lane has the given length.
    void ensureLength(size_t len) {
        if (logicalLength == len) {
            return;
        }
        if (ownsStorage) {
            allocateBacking(len);
        } else {
            assert(len <= viewCapacity, "veca view length exceeds capacity");
            logicalLength = len;
            rebindLanes();
        }
    }

    /// Append a new vector value to the storage.
    void append(Element value) {
        ensureLength(length + 1);
        this[length - 1] = value;
    }

    /// Read/write accessors that expose a view over the underlying SoA slot.
    vecv!(T, N) opIndex(size_t idx) @trusted {
        assert(idx < length, "veca index out of range");
        return vecv!(T, N)(lanes, idx);
    }

    vecvConst!(T, N) opIndex(size_t idx) const @trusted {
        assert(idx < length, "veca index out of range");
        auto ptr = cast(const(T[][N])*)&this.lanes;
        return vecvConst!(T, N)(ptr, idx);
    }

    /// Assign from a dense AoS array.
    void assign(const Element[] source) {
        length = source.length;
        foreach (i, vec; source) {
            this[i] = vec;
        }
    }

    ref veca opAssign(veca rhs) {
        auto len = rhs.length;
        ensureLength(len);
        if (len == 0) {
            return this;
        }
        foreach (laneIdx; 0 .. N) {
            auto dst = lanes[laneIdx][0 .. len];
            auto src = rhs.lanes[laneIdx][0 .. len];
            if (dst.ptr is src.ptr) {
                continue;
            }
            auto copyBytes = len * T.sizeof;
            () @trusted {
                import core.stdc.string : memmove;
                memmove(dst.ptr, src.ptr, copyBytes);
            }();
        }
        return this;
    }

    /// Element-wise arithmetic implemented through SIMD or slices.
    void opOpAssign(string op)(const veca!(T, N) rhs)
    if (op == "+" || op == "-" || op == "*" || op == "/") {
        assert(length == rhs.length, "Mismatched vector lengths");
        foreach (i; 0 .. N) {
            static if (isSIMDCompatible!T) {
                auto dstLane = lanes[i];
                auto srcLane = rhs.lanes[i];
                if (canApplySIMD(dstLane, srcLane)) {
                    applySIMD!(op)(dstLane, srcLane);
                    continue;
                }
            }
            auto dstSlice = lanes[i];
            auto srcSlice = rhs.lanes[i];
            static if (op == "+")
                dstSlice[] += srcSlice[];
            else static if (op == "-")
                dstSlice[] -= srcSlice[];
            else static if (op == "*")
                dstSlice[] *= srcSlice[];
            else
                dstSlice[] /= srcSlice[];
        }
    }

    /// Apply a constant vector across all elements.
    void opOpAssign(string op)(Vector!(T, N) rhs)
    if (op == "+" || op == "-" || op == "*" || op == "/") {
        foreach (laneIdx; 0 .. N) {
            auto lane = lanes[laneIdx];
            auto scalar = rhs.vector[laneIdx];
            static if (op == "+")
                lane[] += scalar;
            else static if (op == "-")
                lane[] -= scalar;
            else static if (op == "*")
                lane[] *= scalar;
            else
                lane[] /= scalar;
        }
    }

    /// Apply a scalar across all components.
    void opOpAssign(string op, U)(U rhs)
    if ((op == "+" || op == "-" || op == "*" || op == "/") && is(typeof(cast(T) rhs))) {
        auto scalar = cast(T)rhs;
        foreach (laneIdx; 0 .. N) {
            auto lane = lanes[laneIdx];
            static if (op == "+")
                lane[] += scalar;
            else static if (op == "-")
                lane[] -= scalar;
            else static if (op == "*")
                lane[] *= scalar;
            else
                lane[] /= scalar;
        }
    }

    /// Create a dense AoS `Vector` array copy.
    Element[] toArray() const {
        auto result = new Element[length];
        foreach (i; 0 .. length)
            result[i] = this[i].toVector();
        return result;
    }

    /// Write the SoA data into a provided AoS buffer.
    void toArrayInto(ref Element[] target) const {
        target.length = length;
        foreach (i; 0 .. length)
            target[i] = this[i].toVector();
    }

    /// Duplicate the SoA buffer.
    veca dup() const {
        veca copy;
        copy.ensureLength(logicalLength);
        foreach (laneIdx; 0 .. N) {
            if (logicalLength == 0) break;
            copy.lanes[laneIdx][] = lanes[laneIdx][];
        }
        return copy;
    }

    /// Clear all stored vectors.
    void clear() {
        logicalLength = 0;
        if (ownsStorage) {
            backing.length = 0;
        } else {
            backing = null;
        }
        laneStride = 0;
        laneBase = 0;
        viewCapacity = 0;
        rebindLanes();
    }

    /// Append element(s) using array-like syntax.
    void opOpAssign(string op, U)(auto ref U value)
    if (op == "~") {
        static if (is(Unqual!U == veca!(T, N)))
            appendArray(value);
        else static if (is(U == vecv!(T, N)) || is(U == vecvConst!(T, N)))
            append(value.toVector());
        else static if (is(U == Element))
            append(value);
        else static if (is(U : const(Element)[]))
            appendAoS(value);
        else static assert(0, "Unsupported append type for veca");
    }

    auto opBinary(string op)(const veca rhs) const
    if (op == "~") {
        auto copy = dup();
        copy ~= rhs;
        return copy;
    }

    auto opBinary(string op)(Element rhs) const
    if (op == "~") {
        auto copy = dup();
        copy ~= rhs;
        return copy;
    }

    auto opBinaryRight(string op)(Element lhs) const
    if (op == "~") {
        veca result;
        result ~= lhs;
        result ~= this;
        return result;
    }

    veca opSlice() const {
        return dup();
    }

    /// Direct access to a component lane.
    inout(T)[] lane(size_t component) inout {
        assert(component < N, "veca lane index out of range");
        return lanes[component];
    }

package(opengl) inout(T)[] rawStorage() inout {
        assert(laneBase == 0 && (laneStride == logicalLength || laneStride == 0),
               "rawStorage is only available for owned contiguous buffers");
        return backing;
    }

package(opengl) void bindExternalStorage(ref veca storage, size_t offset, size_t length) {
        if (length == 0 || storage.backing.length == 0) {
            ownsStorage = false;
            backing = null;
            logicalLength = 0;
            viewCapacity = 0;
            laneStride = storage.logicalLength;
            laneBase = offset;
            rebindLanes();
            return;
        }
        ownsStorage = false;
        backing = storage.backing;
        laneStride = storage.logicalLength;
        laneBase = offset;
        logicalLength = length;
        viewCapacity = length;
        rebindLanes();
    }

    void opSliceAssign(veca rhs) {
        ensureLength(rhs.length);
        foreach (laneIdx; 0 .. N) {
            lanes[laneIdx][] = rhs.lanes[laneIdx][];
        }
    }

    void opSliceAssign(const Element[] values) {
        assign(values);
    }

    void opSliceAssign(Element value) {
        foreach (laneIdx; 0 .. N) {
            lanes[laneIdx][] = value.vector[laneIdx];
        }
    }

    vecv!(T, N) front() {
        return this[0];
    }

    vecv!(T, N) back() {
        return this[length - 1];
    }

    vecvConst!(T, N) front() const {
        return this[0];
    }

    vecvConst!(T, N) back() const {
        return this[length - 1];
    }

    @property bool empty() const {
        return length == 0;
    }

    int opApply(int delegate(vecv!(T, N)) dg) {
        foreach (i; 0 .. length) {
            auto view = vecv!(T, N)(lanes, i);
            auto res = dg(view);
            if (res) return res;
        }
        return 0;
    }

    int opApply(int delegate(size_t, vecv!(T, N)) dg) {
        foreach (i; 0 .. length) {
            auto view = vecv!(T, N)(lanes, i);
            auto res = dg(i, view);
            if (res) return res;
        }
        return 0;
    }

    int opApply(int delegate(vecvConst!(T, N)) dg) const {
        auto ptr = cast(const(T[][N])*)&this.lanes;
        foreach (i; 0 .. length) {
            auto view = vecvConst!(T, N)(ptr, i);
            auto res = dg(view);
            if (res) return res;
        }
        return 0;
    }

    int opApply(int delegate(size_t, vecvConst!(T, N)) dg) const {
        auto ptr = cast(const(T[][N])*)&this.lanes;
        foreach (i; 0 .. length) {
            auto view = vecvConst!(T, N)(ptr, i);
            auto res = dg(i, view);
            if (res) return res;
        }
        return 0;
    }

private:
    void appendArray(in veca rhs) {
        auto oldLen = length;
        ensureLength(oldLen + rhs.length);
        foreach (i; 0 .. N) {
            lanes[i][oldLen .. oldLen + rhs.length] = rhs.lanes[i][];
        }
    }

    void appendAoS(const Element[] values) {
        auto oldLen = length;
        ensureLength(oldLen + values.length);
        foreach (idx, vec; values) {
            this[oldLen + idx] = vec;
        }
    }
}

/// Mutable view into a single element of `veca`.
struct vecv(T, size_t N) {
    alias VectorType = Vector!(T, N);
    private T[][N]* lanes;
    private size_t index;

    this(ref T[][N] storage, size_t idx) @trusted {
        lanes = &storage;
        index = idx;
    }

    this(ref T[][N] storage, size_t idx, Vector!(T, N) initial) {
        this(storage, idx);
        opAssign(initial);
    }

    ref T component(size_t lane) {
        assert(lanes !is null, "vecv is not bound to storage");
        return (*lanes)[lane][index];
    }

    Vector!(T, N) toVector() const {
        Vector!(T, N) result;
        foreach (i; 0 .. N)
            result.vector[i] = (*lanes)[i][index];
        return result;
    }

    alias toVector this;

    void opAssign(Vector!(T, N) value) {
        foreach (i; 0 .. N)
            (*lanes)[i][index] = value.vector[i];
    }

    void opAssign(vecv rhs) {
        foreach (i; 0 .. N)
            (*lanes)[i][index] = rhs.component(i);
    }

    Vector!(T, N) opCast(TT : Vector!(T, N))() const {
        return toVector();
    }

    void opOpAssign(string op)(Vector!(T, N) rhs)
    if (op == "+" || op == "-" || op == "*" || op == "/") {
        auto lhs = toVector();
        mixin("lhs " ~ op ~ "= rhs;");
        opAssign(lhs);
    }

    auto opBinary(string op)(Vector!(T, N) rhs) const
    if (op == "+" || op == "-" || op == "*" || op == "/") {
        auto lhs = toVector();
        mixin("lhs = lhs " ~ op ~ " rhs;");
        return lhs;
    }

    auto opBinaryRight(string op)(Vector!(T, N) lhs) const
    if (op == "+" || op == "-" || op == "*" || op == "/") {
        auto rhs = toVector();
        mixin("lhs = lhs " ~ op ~ " rhs;");
        return lhs;
    }

    static if (N > 0) @property ref T x() { return component(0); }
    static if (N > 1) @property ref T y() { return component(1); }
    static if (N > 2) @property ref T z() { return component(2); }
    static if (N > 3) @property ref T w() { return component(3); }
}

/// Const view variant.
struct vecvConst(T, size_t N) {
    alias VectorType = Vector!(T, N);
    private const(T[][N])* lanes;
    private size_t index;

    this(ref T[][N] storage, size_t idx) @trusted {
        this(&storage, idx);
    }

    this(ref const(T[][N]) storage, size_t idx) {
        this(&storage, idx);
    }

    this(const(T[][N])* storage, size_t idx) {
        lanes = storage;
        index = idx;
    }

    const(T) component(size_t lane) const {
        assert(lanes !is null, "vecvConst is not bound to storage");
        return (*lanes)[lane][index];
    }

    Vector!(T, N) toVector() const {
        Vector!(T, N) result;
        foreach (i; 0 .. N)
            result.vector[i] = (*lanes)[i][index];
        return result;
    }

    alias toVector this;

    static if (N > 0) @property const(T) x() const { return component(0); }
    static if (N > 1) @property const(T) y() const { return component(1); }
    static if (N > 2) @property const(T) z() const { return component(2); }
    static if (N > 3) @property const(T) w() const { return component(3); }
}


alias vec2v = vecv!(float, 2);
alias vec3v = vecv!(float, 3);
alias vec4v = vecv!(float, 4);

alias vec2vConst = vecvConst!(float, 2);
alias vec3vConst = vecvConst!(float, 3);
alias vec4vConst = vecvConst!(float, 4);

template VecArray(T, size_t N) {
    alias VecArray = veca!(T, N);
}

veca!(T, N) vecaFromVectors(T, size_t N)(const Vector!(T, N)[] data) {
    return veca!(T, N)(data.dup);
}

Vector!(T, N)[] toVectorArray(T, size_t N)(const veca!(T, N) storage) {
    return storage.toArray();
}

private bool isSIMDCompatible(T)() {
    static if (isFloatingPoint!T || (isIntegral!T && (T.sizeof == 2 || T.sizeof == 4 || T.sizeof == 8)))
        return true;
    else
        return false;
}

private bool canApplySIMD(T)(const T[] dst, const T[] src) {
    if (dst.length != src.length) {
        return false;
    }
    if (dst.length == 0) {
        return true;
    }
    enum mask = simdAlignment - 1;
    auto dstPtr = cast(size_t)dst.ptr;
    auto srcPtr = cast(size_t)src.ptr;
    return ((dstPtr | srcPtr) & mask) == 0;
}

private @trusted void applySIMD(string op, T)(ref T[] dst, const T[] src)
if (isSIMDCompatible!T) {
    enum width = 16 / T.sizeof;
    alias VectorType = __vector(T[width]);

    size_t i = 0;
    for (; i + width <= dst.length; i += width) {
        auto a = *cast(VectorType*)(dst.ptr + i);
        auto b = *cast(VectorType*)(src.ptr + i);
        static if (op == "+")
            a += b;
        else static if (op == "-")
            a -= b;
        else static if (op == "*")
            a *= b;
        else
            a /= b;
        *cast(VectorType*)(dst.ptr + i) = a;
    }
    for (; i < dst.length; ++i) {
        static if (op == "+")
            dst[i] += src[i];
        else static if (op == "-")
            dst[i] -= src[i];
        else static if (op == "*")
            dst[i] *= src[i];
        else
            dst[i] /= src[i];
    }
}

unittest {
    alias Vec = veca!(float, 3);
    Vec storage;
    storage.ensureLength(2);
    storage[0] = Vector!(float, 3)(1, 2, 3);
    storage[1] = Vector!(float, 3)(4, 5, 6);

    auto copy = storage.toArray();
    assert(copy.length == 2);
    assert(copy[0][0] == 1 && copy[1][2] == 6);

    auto view = storage[0];
    view.x += 2;
    view.y = 10;
    storage += storage;
    assert(approxEqual(storage[0].x, (1 + 2) * 2));
    assert(approxEqual(storage[1].z, 12));

    Vector!(float, 3) vec = storage[0];
    assert(vec[0] == storage[0].x);
    vec[1] = 2;
    storage[0] = vec;
    assert(approxEqual(storage[0].y, 2));

    storage ~= Vector!(float, 3)(7, 8, 9);
    auto concatenated = storage ~ Vector!(float, 3)(0, 0, 0);
    assert(concatenated.length == storage.length + 1);

    float sumBefore;
    foreach (ref elem; storage) {
        sumBefore += elem.x;
        elem.x += 1;
    }
    assert(sumBefore > 0);

    auto dupe = storage.dup;
    assert(dupe.length == storage.length);

    auto rebuilt = vecaFromVectors!(float, 3)(storage.toArray());
    assert(rebuilt.length == storage.length);

    Vec2Array arr2;
    arr2 ~= Vector!(float, 2)(1, 1);
    arr2 ~= Vector!(float, 2)(2, 2);
    assert(arr2.length == 2);
}

// ---- source/nlshim/math/veca_ops.d ----

import std.algorithm : min;

private void simdLinearCombination(bool accumulate)(
    float[] dst,
    const float[] lhs,
    const float[] rhs,
    float lhsCoeff,
    float rhsCoeff,
    float bias) {
    assert(dst.length == lhs.length && lhs.length == rhs.length);
    auto len = dst.length;
    auto lhsVec = splatSimd(lhsCoeff);
    auto rhsVec = splatSimd(rhsCoeff);
    auto biasVec = splatSimd(bias);
    size_t i = 0;
    for (; i + simdWidth <= len; i += simdWidth) {
        auto l = loadVec(lhs, i);
        auto r = loadVec(rhs, i);
        auto value = lhsVec * l + rhsVec * r + biasVec;
        static if (accumulate) {
            value += loadVec(dst, i);
        }
        storeVec(dst, i, value);
    }
    for (; i < len; ++i) {
        auto scalar = lhsCoeff * lhs[i] + rhsCoeff * rhs[i] + bias;
        static if (accumulate)
            dst[i] += scalar;
        else
            dst[i] = scalar;
    }
}

private void simdBlendAxes(
    float[] dst,
    const float[] base,
    const float[] scaleA,
    const float[] dirA,
    const float[] scaleB,
    const float[] dirB) {
    assert(dst.length == base.length);
    assert(base.length == scaleA.length);
    assert(scaleA.length == dirA.length);
    assert(scaleB.length == dirB.length);
    size_t len = dst.length;
    size_t i = 0;
    for (; i + simdWidth <= len; i += simdWidth) {
        auto baseVec = loadVec(base, i);
        auto termA = loadVec(scaleA, i) * loadVec(dirA, i);
        auto termB = loadVec(scaleB, i) * loadVec(dirB, i);
        storeVec(dst, i, baseVec + termA + termB);
    }
    for (; i < len; ++i) {
        dst[i] = base[i] + scaleA[i] * dirA[i] + scaleB[i] * dirB[i];
    }
}

private void projectAxesSimd(
    float[] outAxisA,
    float[] outAxisB,
    const float[] centerX,
    const float[] centerY,
    const float[] referenceX,
    const float[] referenceY,
    const float[] axisAX,
    const float[] axisAY,
    const float[] axisBX,
    const float[] axisBY) {
    assert(outAxisA.length == outAxisB.length);
    auto len = outAxisA.length;
    size_t i = 0;
    for (; i + simdWidth <= len; i += simdWidth) {
        auto cx = loadVec(centerX, i);
        auto cy = loadVec(centerY, i);
        auto rx = loadVec(referenceX, i);
        auto ry = loadVec(referenceY, i);
        auto diffX = cx - rx;
        auto diffY = cy - ry;
        auto axisARes = diffX * loadVec(axisAX, i) + diffY * loadVec(axisAY, i);
        auto axisBRes = diffX * loadVec(axisBX, i) + diffY * loadVec(axisBY, i);
        storeVec(outAxisA, i, axisARes);
        storeVec(outAxisB, i, axisBRes);
    }
    for (; i < len; ++i) {
        auto diffX = centerX[i] - referenceX[i];
        auto diffY = centerY[i] - referenceY[i];
        outAxisA[i] = diffX * axisAX[i] + diffY * axisAY[i];
        outAxisB[i] = diffX * axisBX[i] + diffY * axisBY[i];
    }
}

private void rotateAxesSimd(
    float[] dstX,
    float[] dstY,
    const float[] srcX,
    const float[] srcY) {
    assert(dstX.length == dstY.length);
    assert(srcX.length == srcY.length);
    auto len = dstX.length;
    size_t i = 0;
    for (; i + simdWidth <= len; i += simdWidth) {
        auto sx = loadVec(srcX, i);
        auto sy = loadVec(srcY, i);
        storeVec(dstX, i, -sy);
        storeVec(dstY, i, sx);
    }
    for (; i < len; ++i) {
        dstX[i] = -srcY[i];
        dstY[i] = srcX[i];
    }
}

package(opengl) void projectVec2OntoAxes(
    const Vec2Array center,
    const Vec2Array reference,
    const Vec2Array axisA,
    const Vec2Array axisB,
    float[] outAxisA,
    float[] outAxisB) {
    auto len = center.length;
    if (len == 0) return;
    assert(reference.length == len);
    assert(axisA.length == len);
    assert(axisB.length == len);
    assert(outAxisA.length >= len);
    assert(outAxisB.length >= len);
    auto centerX = center.lane(0)[0 .. len];
    auto centerY = center.lane(1)[0 .. len];
    auto refX = reference.lane(0)[0 .. len];
    auto refY = reference.lane(1)[0 .. len];
    auto axisAX = axisA.lane(0)[0 .. len];
    auto axisAY = axisA.lane(1)[0 .. len];
    auto axisBX = axisB.lane(0)[0 .. len];
    auto axisBY = axisB.lane(1)[0 .. len];
    projectAxesSimd(
        outAxisA[0 .. len],
        outAxisB[0 .. len],
        centerX,
        centerY,
        refX,
        refY,
        axisAX,
        axisAY,
        axisBX,
        axisBY);
}

package(opengl) void composeVec2FromAxes(
    ref Vec2Array dest,
    const Vec2Array base,
    const float[] axisA,
    const Vec2Array dirA,
    const float[] axisB,
    const Vec2Array dirB) {
    auto len = base.length;
    if (len == 0) {
        dest.length = 0;
        return;
    }
    dest.length = len;
    assert(dirA.length == len);
    assert(dirB.length == len);
    assert(axisA.length >= len);
    assert(axisB.length >= len);
    auto dstX = dest.lane(0)[0 .. len];
    auto dstY = dest.lane(1)[0 .. len];
    auto baseX = base.lane(0)[0 .. len];
    auto baseY = base.lane(1)[0 .. len];
    auto dirAX = dirA.lane(0)[0 .. len];
    auto dirAY = dirA.lane(1)[0 .. len];
    auto dirBX = dirB.lane(0)[0 .. len];
    auto dirBY = dirB.lane(1)[0 .. len];
    simdBlendAxes(dstX, baseX, axisA[0 .. len], dirAX, axisB[0 .. len], dirBX);
    simdBlendAxes(dstY, baseY, axisA[0 .. len], dirAY, axisB[0 .. len], dirBY);
}

package(opengl) void rotateVec2TangentsToNormals(
    ref Vec2Array normals,
    const Vec2Array tangents) {
    auto len = tangents.length;
    normals.length = len;
    if (len == 0) return;
    auto dstX = normals.lane(0)[0 .. len];
    auto dstY = normals.lane(1)[0 .. len];
    auto srcX = tangents.lane(0)[0 .. len];
    auto srcY = tangents.lane(1)[0 .. len];
    rotateAxesSimd(dstX, dstY, srcX, srcY);
}

/// Writes `matrix * src` into `dest`, applying the translational part.
void transformAssign(ref Vec2Array dest, const Vec2Array src, const mat4 matrix) {
    dest.length = src.length;
    auto len = src.length;
    if (len == 0) return;

    const float m00 = matrix[0][0];
    const float m01 = matrix[0][1];
    const float m03 = matrix[0][3];
    const float m10 = matrix[1][0];
    const float m11 = matrix[1][1];
    const float m13 = matrix[1][3];

    auto srcX = src.lane(0)[0 .. len];
    auto srcY = src.lane(1)[0 .. len];
    auto dstX = dest.lane(0)[0 .. len];
    auto dstY = dest.lane(1)[0 .. len];

    simdLinearCombination!false(dstX, srcX, srcY, m00, m01, m03);
    simdLinearCombination!false(dstY, srcX, srcY, m10, m11, m13);
}

/// Adds the linear part of `matrix * src` into `dest` (no translation).
void transformAdd(ref Vec2Array dest, const Vec2Array src, const mat4 matrix, size_t count = size_t.max) {
    if (dest.length == 0 || src.length == 0) return;
    auto len = min(count, min(dest.length, src.length));
    if (len == 0) return;

    const float m00 = matrix[0][0];
    const float m01 = matrix[0][1];
    const float m10 = matrix[1][0];
    const float m11 = matrix[1][1];

    auto srcX = src.lane(0)[0 .. len];
    auto srcY = src.lane(1)[0 .. len];
    auto dstX = dest.lane(0)[0 .. len];
    auto dstY = dest.lane(1)[0 .. len];

    simdLinearCombination!true(dstX, srcX, srcY, m00, m01, 0);
    simdLinearCombination!true(dstY, srcX, srcY, m10, m11, 0);
}

// ---- source/nlshim/ver.d ----
// AUTOGENERATED BY GITVER, DO NOT MODIFY

/**
	nijilive Version, autogenerated with gitver
*/
enum IN_VERSION = "v1.0.0-alpha1-40-g4f5ac7f";

// trans rights
