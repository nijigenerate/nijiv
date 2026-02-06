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
/// Lookup Texture created via callbacks.
Texture toTex(size_t h) {
    auto tex = h in gTextures;
    return tex is null ? null : *tex;
}

// Bridge: convert DLL packets to backend PartDrawPacket/MaskDrawPacket and call ogl*.
void renderCommands(const OpenGLBackendInit* gl,
                    const SharedBufferSnapshot* snapshot,
                    const CommandQueueView* view)
{
    if (gl is null) return;
    import std.stdio : writeln;
    auto backend = currentRenderBackend();
    auto debugTextureBackend = currentDebugTextureBackend();
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
                    dumpBuf(backend.sharedVertexBufferHandle(), cmd.partPacket.vertexOffset, "vLane0");
                    dumpBuf(backend.sharedVertexBufferHandle(), cmd.partPacket.vertexAtlasStride + cmd.partPacket.vertexOffset, "vLane1");
                    dumpBuf(backend.sharedUvBufferHandle(), cmd.partPacket.uvOffset, "uvLane0");
                    dumpBuf(backend.sharedUvBufferHandle(), cmd.partPacket.uvAtlasStride + cmd.partPacket.uvOffset, "uvLane1");
                    dumpBuf(backend.sharedDeformBufferHandle(), cmd.partPacket.deformOffset, "defLane0");
                    dumpBuf(backend.sharedDeformBufferHandle(), cmd.partPacket.deformAtlasStride + cmd.partPacket.deformOffset, "defLane1");
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
    backend.rebindActiveTargets();
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

    uploadSoA(backend.sharedVertexBufferHandle(), snapshot.vertices);
    uploadSoA(backend.sharedUvBufferHandle(), snapshot.uvs);
    uploadSoA(backend.sharedDeformBufferHandle(), snapshot.deform);

    // パケットレイアウトをファイルに記録
    logPacketLayout();

    backend.beginScene();
    // Core profileはVAO必須。nlshim側の属性設定を活かすため共通VAOをバインド。
    backend.bindDrawableVao();
    // 念のため最初にパート用シェーダをバインドしておく（prog=0防止）。
    backend.bindPartShader();
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
                p.indexBuffer = backend.getOrCreateIbo(cmd.partPacket.indices, cmd.partPacket.indexCount);
                backend.drawPartPacket(p);
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
                backend.beginMask(cmd.usesStencil);
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
                p.indexBuffer = backend.getOrCreateIbo(src.indices, src.indexCount);
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
                m.indexBuffer = backend.getOrCreateIbo(ms.indices, ms.indexCount);

                mp.maskPacket = m;
                mp.kind = cast(NlMaskKind)cmd.maskApplyPacket.kind;
                mp.isDodge = cmd.maskApplyPacket.isDodge;
                backend.applyMask(mp);
                break;
            }
            case NjgRenderCommandKind.BeginMaskContent:
                beginMaskContentCount++;
                backend.beginMaskContent();
                break;
            case NjgRenderCommandKind.EndMask:
                endMaskCount++;
                backend.endMask();
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
                backend.beginDynamicComposite(pass);
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
                backend.endDynamicComposite(pass);
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
    backend.postProcessScene();
    // After nlshim rendering, blit scene to backbuffer.
    auto srcFbo = cast(GLuint)backend.framebufferHandle();
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

        debugTextureBackend.ensureDebugTestTex();
        float tx = pad;
        float ty = pad;
        // First tile: debug checkerboard
        debugTextureBackend.drawTile(debugTextureBackend.debugTestTextureId(), tx, ty, tile, gl.drawableW, gl.drawableH);
        ty += tile + pad;
        foreach (handle, tex; gTextures) {
            if (tex !is null) {
                debugTextureBackend.drawTile(tex.getTextureId(), tx, ty, tile, gl.drawableW, gl.drawableH);
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
    backend.endScene();
}


// ==== nlshim merged (pure copy, no edits) ====
// ---- source/nlshim/core/package.d ----
/*
    nijilive Rendering
    Inochi2D Rendering

    Copyright © 2020, Inochi2D Project
    Copyright © 2024, nijigenerate Project
    Distributed under the 2-Clause BSD License, see LICENSE file.
    
    Authors: Luna Nielsen
*/

// OpenGL backend is provided by top-level opengl/* modules; avoid importing nlshim copies.

//import std.stdio;

// ---- source/nlshim/core/render/backends/opengl/blend.d ----




import bindbc.opengl;
import bindbc.opengl.context;



// ---- source/nlshim/core/render/backends/opengl/debug_renderer.d ----




import bindbc.opengl;







// ---- source/nlshim/core/render/backends/opengl/drawable_buffers.d ----


import bindbc.opengl;

// ---- source/nlshim/core/render/backends/opengl/dynamic_composite.d ----



import bindbc.opengl;

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

class DebugTextureBackend {
private:
    GLuint debugThumbTex;
    GLuint debugThumbProg;
    GLint debugThumbMvpLoc = -1;
    GLuint debugThumbVao;
    GLuint debugThumbQuadVbo;
    GLuint debugThumbQuadEbo;

    void ensureThumbVao() {
        if (debugThumbVao == 0) {
            glGenVertexArrays(1, &debugThumbVao);
        }
        if (debugThumbQuadVbo == 0) glGenBuffers(1, &debugThumbQuadVbo);
        if (debugThumbQuadEbo == 0) glGenBuffers(1, &debugThumbQuadEbo);
    }

    void ensureThumbProgram() {
        if (debugThumbProg != 0) return;
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
        debugThumbProg = glCreateProgram();
        glAttachShader(debugThumbProg, vs);
        glAttachShader(debugThumbProg, fs);
        glLinkProgram(debugThumbProg);
        GLint linked = 0;
        glGetProgramiv(debugThumbProg, GL_LINK_STATUS, &linked);
        enforce(linked == GL_TRUE, "thumb shader link failed");
        glDeleteShader(vs);
        glDeleteShader(fs);
        glUseProgram(debugThumbProg);
        GLint albedoLoc = glGetUniformLocation(debugThumbProg, "albedo");
        if (albedoLoc >= 0) glUniform1i(albedoLoc, 0);
        debugThumbMvpLoc = glGetUniformLocation(debugThumbProg, "mvp");
        glUseProgram(0);
    }

public:
    void ensureDebugTestTex() {
        if (debugThumbTex != 0) return;
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
        glGenTextures(1, &debugThumbTex);
        glBindTexture(GL_TEXTURE_2D, debugThumbTex);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, sz, sz, 0, GL_RGBA, GL_UNSIGNED_BYTE, pixels.ptr);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    }

    void drawTile(GLuint texId, float x, float y, float size, int screenW, int screenH) {
        if (texId == 0) return;
        ensureThumbProgram();
        ensureThumbVao();
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        glViewport(0, 0, screenW, screenH);
        glUseProgram(debugThumbProg);
        float left = (x / cast(float)screenW) * 2f - 1f;
        float right = ((x + size) / cast(float)screenW) * 2f - 1f;
        float top = (y / cast(float)screenH) * 2f - 1f;
        float bottom = ((y + size) / cast(float)screenH) * 2f - 1f;
        if (debugThumbMvpLoc >= 0) {
            float[16] ident = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];
            glUniformMatrix4fv(debugThumbMvpLoc, 1, GL_FALSE, ident.ptr);
        }
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, texId);
        float[24] verts = [
            left,  top,    0, 0,
            right, top,    1, 0,
            left,  bottom, 0, 1,
            right, top,    1, 0,
            right, bottom, 1, 1,
            left,  bottom, 0, 1
        ];
        glBindVertexArray(debugThumbVao);
        glBindBuffer(GL_ARRAY_BUFFER, debugThumbQuadVbo);
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

    GLuint debugTestTextureId() const {
        return debugThumbTex;
    }
}

private __gshared DebugTextureBackend cachedDebugTextureBackend;

private DebugTextureBackend currentDebugTextureBackend() {
    if (cachedDebugTextureBackend is null) {
        cachedDebugTextureBackend = new DebugTextureBackend();
    }
    return cachedDebugTextureBackend;
}

// ---- source/nlshim/core/render/backends/opengl/mask.d ----




import bindbc.opengl;

// ---- Shader Asset Definitions (centralized) ----
private enum ShaderAsset MaskShaderSource = shaderAsset!("opengl/shaders/opengl/mask.vert","opengl/shaders/opengl/mask.frag")();
private enum ShaderAsset AdvancedBlendShaderSource = shaderAsset!("opengl/shaders/opengl/basic/basic.vert","opengl/shaders/opengl/basic/advanced_blend.frag")();
private enum ShaderAsset PartShaderSource = shaderAsset!("opengl/shaders/opengl/basic/basic.vert","opengl/shaders/opengl/basic/basic.frag")();
private enum ShaderAsset PartShaderStage1Source = shaderAsset!("opengl/shaders/opengl/basic/basic.vert","opengl/shaders/opengl/basic/basic-stage1.frag")();
private enum ShaderAsset PartShaderStage2Source = shaderAsset!("opengl/shaders/opengl/basic/basic.vert","opengl/shaders/opengl/basic/basic-stage2.frag")();
private enum ShaderAsset PartMaskShaderSource = shaderAsset!("opengl/shaders/opengl/basic/basic.vert","opengl/shaders/opengl/basic/basic-mask.frag")();
private enum ShaderAsset LightingShaderSource = shaderAsset!("opengl/shaders/opengl/scene.vert","opengl/shaders/opengl/lighting.frag")();

/// Prepare stencil for mask rendering.
/// useStencil == true when there is at least one normal mask (write 1 to masked area).
/// useStencil == false when only dodge masks are present (keep stencil at 1 and punch 0 holes).



// ---- source/nlshim/core/render/backends/opengl/package.d ----




// queue/backend not used in this binary; avoid pulling queue modules
import inmath.linalg : rect;

class RenderingBackend(BackendEnum backendType : BackendEnum.OpenGL) {
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
        ushort[] data;
    }

    private SharedVecAtlas deformAtlas;
    private SharedVecAtlas vertexAtlas;
    private SharedVecAtlas uvAtlas;

    private Shader[BlendMode] blendShaders;
    private int pointCount;
    private bool bufferIsSoA;

    private GLuint drawableVAO;
    private bool drawableBuffersInitialized = false;
    private GLuint sharedDeformBuffer;
    private GLuint sharedVertexBuffer;
    private GLuint sharedUvBuffer;
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

    private GLuint blendFBO;
    private GLuint blendAlbedo;
    private GLuint blendEmissive;
    private GLuint blendBump;
    private GLuint blendStencil;

    private PostProcessingShader[] postProcessingStack;

    private GLuint debugVao;
    private GLuint debugVbo;
    private GLuint debugIbo;
    private GLuint debugCurrentVbo;
    private int debugIndexCount;

    private bool advancedBlending;
    private bool advancedBlendingCoherent;
    private bool forceTripleBufferFallback;
    private int[] viewportWidthStack;
    private int[] viewportHeightStack;

    private RenderResourceHandle[IboKey] iboCache;

    private void ensureBlendShadersInitialized() {
        if (blendShaders.length > 0) return;

        auto advancedBlendShader = new Shader(AdvancedBlendShaderSource);
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

    private void ensureMaskBackendInitialized() {
        if (maskBackendInitialized) return;
        maskBackendInitialized = true;

        maskShader = new Shader(MaskShaderSource);
        maskOffsetUniform = maskShader.getUniformLocation("offset");
        maskMvpUniform = maskShader.getUniformLocation("mvp");
    }

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

    private void ensureDebugRendererInitialized() {
        if (debugVao != 0) return;
        glGenVertexArrays(1, &debugVao);
        glGenBuffers(1, &debugVbo);
        glGenBuffers(1, &debugIbo);
        debugCurrentVbo = debugVbo;
        debugIndexCount = 0;
    }

    private GLuint textureId(Texture texture) {
        if (texture is null) return 0;
        auto handle = texture.backendHandle();
        if (handle is null) return 0;
        return requireGLTexture(handle).id;
    }

    private void logFboState(string tag) {
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

    private void logGlErr(string tag) {
        GLint err = glGetError();
        import std.stdio : writefln;
        writefln("[dc-err] %s glError=%s", tag, err);
    }

    private void renderScene(vec4 area, PostProcessingShader shaderToUse, GLuint albedo, GLuint emissive, GLuint bump) {
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
        glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 4*float.sizeof, null);

        glEnableVertexAttribArray(1);
        glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 4*float.sizeof, cast(float*)(2*float.sizeof));

        glDrawArrays(GL_TRIANGLES, 0, 6);

        glDisableVertexAttribArray(0);
        glDisableVertexAttribArray(1);

        glDisable(GL_BLEND);
    }

    void bindPartShader() {
        if (partShader !is null) {
            partShader.use();
        }
    }

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

    void getViewport(out int width, out int height) {
        if (viewportWidthStack.length == 0) {
            width = 0;
            height = 0;
            return;
        }
        width = viewportWidthStack[$-1];
        height = viewportHeightStack[$-1];
    }

    void initializeRenderer() {
        // Set a default logical viewport before first explicit size arrives.
        setViewport(640, 480);

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

    void bindDrawableVao() {
        ensureDrawableBackendInitialized();
        glBindVertexArray(drawableVAO);
    }

    void createDrawableBuffers(ref RenderResourceHandle ibo) {
        ensureDrawableBackendInitialized();
        if (ibo == 0) {
            ibo = nextIndexHandle++;
        }
    }

    void uploadDrawableIndices(RenderResourceHandle ibo, ushort[] indices) {
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

    RenderResourceHandle getOrCreateIbo(const(ushort)* indices, size_t count) {
        if (indices is null || count == 0) return RenderResourceHandle.init;
        IboKey key = IboKey(cast(size_t)indices, count);
        if (auto existing = key in iboCache) {
            return *existing;
        }
        RenderResourceHandle ibo;
        createDrawableBuffers(ibo);
        auto idxSlice = indices[0 .. count];
        uploadDrawableIndices(ibo, idxSlice.dup);
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

    bool supportsAdvancedBlend() {
        return hasKHRBlendEquationAdvanced;
    }

    bool supportsAdvancedBlendCoherent() {
        return hasKHRBlendEquationAdvancedCoherent;
    }

    void applyBlendingCapabilities() {
        bool desiredAdvanced = supportsAdvancedBlend() && !forceTripleBufferFallback;
        bool desiredCoherent = supportsAdvancedBlendCoherent() && !forceTripleBufferFallback;
        if (desiredCoherent != advancedBlendingCoherent) {
            setAdvancedBlendCoherent(desiredCoherent);
        }
        advancedBlending = desiredAdvanced;
        advancedBlendingCoherent = desiredCoherent;
    }

    void setTripleBufferFallback(bool enable) {
        if (forceTripleBufferFallback == enable) return;
        forceTripleBufferFallback = enable;
        applyBlendingCapabilities();
    }

    bool tripleBufferFallbackEnabled() const {
        return forceTripleBufferFallback;
    }

    bool advancedBlendEnabled() const {
        return advancedBlending;
    }

    bool advancedBlendCoherentEnabled() const {
        return advancedBlendingCoherent;
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

    private bool isAdvancedBlendMode(BlendMode mode) const {
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

    private void applyBlendMode(BlendMode mode, bool legacyOnly=false) {
        if (!advancedBlending || legacyOnly) setLegacyBlendMode(mode);
        else setAdvancedBlendEquation(mode);
    }

    private void blendModeBarrier(BlendMode mode) {
        if (advancedBlending && !advancedBlendingCoherent && isAdvancedBlendMode(mode))
            issueBlendBarrier();
    }

    void issueBlendBarrier() {
        // no-op when advanced blend barrier is unavailable
    }

    void beginScene() {
        GLenum preErr;
        int errCnt = 0;
        while ((preErr = glGetError()) != GL_NO_ERROR) {
            import std.stdio : writeln;
            if (errCnt == 0) writeln("[glerr][pre-beginScene] err=", preErr);
            errCnt++;
        }

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

        GLenum status = glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER);
        import std.stdio : writeln;
        if (status != GL_FRAMEBUFFER_COMPLETE) writeln("[fbo] incomplete status=", status);

        auto dumpAttachment = (GLenum attachment, string label) {
            GLint obj = 0;
            GLint type = 0;
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
        }

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

    void postProcessScene() {
        if (postProcessingStack.length == 0) return;

        bool targetBuffer;
        float r, g, b, a;
        inGetClearColor(r, g, b, a);

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
        glClearColor(r, g, b, a);
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

    void initDebugRenderer() {
        ensureDebugRendererInitialized();
    }

    void uploadDebugBuffer(Vec3Array points, ushort[] indices) {
        ensureDebugRendererInitialized();
        if (points.length == 0 || indices.length == 0) {
            debugIndexCount = 0;
            pointCount = 0;
            bufferIsSoA = false;
            return;
        }

        glBindVertexArray(debugVao);
        glUploadFloatVecArray(debugVbo, points, GL_DYNAMIC_DRAW, "UploadDebug");
        debugCurrentVbo = debugVbo;
        pointCount = cast(int)points.length;
        bufferIsSoA = true;

        glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, debugIbo);
        glBufferData(GL_ELEMENT_ARRAY_BUFFER, indices.length * ushort.sizeof, indices.ptr, GL_DYNAMIC_DRAW);
        debugIndexCount = cast(int)indices.length;
    }

    void setDebugExternalBuffer(RenderResourceHandle vbo, RenderResourceHandle ibo, int count) {
        ensureDebugRendererInitialized();
        auto vertexHandle = cast(GLuint)vbo;
        auto indexHandle = cast(GLuint)ibo;
        glBindVertexArray(debugVao);
        glBindBuffer(GL_ARRAY_BUFFER, vertexHandle);
        glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, indexHandle);
        debugCurrentVbo = vertexHandle;
        debugIndexCount = count;
        bufferIsSoA = false;
        pointCount = 0;
    }

    // drawTexture* helpers removed; viewer uses packet-driven path only.

    void drawPartPacket(ref PartDrawPacket packet) {
        auto textures = packet.textures;
        if (textures.length == 0) return;

        incDrawableBindVAO();

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
                    auto blendShader = getBlendShader(packet.blendingMode);
                    if (blendShader) {
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

                        bool drawingMainBuffer = prev.drawFbo == fBuffer;
                        bool drawingCompositeBuffer = prev.drawFbo == cfBuffer;

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
                            glDrawBuffers(3, [GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2].ptr);
                            return;
                        }

                        int viewportWidth;
                        int viewportHeight;
                        getViewport(viewportWidth, viewportHeight);

                        GLuint blendFramebuffer = blendFBO;
                        glBindFramebuffer(GL_READ_FRAMEBUFFER, prev.drawFbo);
                        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, blendFramebuffer);
                        foreach (att; 0 .. 3) {
                            GLenum buf = GL_COLOR_ATTACHMENT0 + att;
                            glReadBuffer(buf);
                            glDrawBuffer(buf);
                            glBlitFramebuffer(0, 0, viewportWidth, viewportHeight,
                                0, 0, viewportWidth, viewportHeight,
                                GL_COLOR_BUFFER_BIT, GL_NEAREST);
                        }

                        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, blendFramebuffer);
                        glDrawBuffers(3, [GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2].ptr);
                        glViewport(0, 0, viewportWidth, viewportHeight);
                        setupShaderStage(packet, 2, matrix, renderMatrix);
                        renderStage(packet, false);

                        glBindFramebuffer(GL_READ_FRAMEBUFFER, blendFramebuffer);
                        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, prev.drawFbo);
                        foreach (att; 0 .. 3) {
                            GLenum buf = GL_COLOR_ATTACHMENT0 + att;
                            glReadBuffer(buf);
                            glDrawBuffer(buf);
                            glBlitFramebuffer(0, 0, viewportWidth, viewportHeight,
                                0, 0, viewportWidth, viewportHeight,
                                GL_COLOR_BUFFER_BIT, GL_NEAREST);
                        }

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
                        glDrawBuffers(3, [GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2].ptr);
                        boundAlbedo = null;
                        return;
                    }
                }

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
            GLuint newFramebuffer;
            glGenFramebuffers(1, &newFramebuffer);
            surface.framebuffer = cast(RenderResourceHandle)newFramebuffer;
        }

        logFboState("pre-begin");
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

        pushViewport(tex.width, tex.height);

        glDrawBuffers(cast(int)bufferCount, drawBuffers.ptr);
        pass.drawBufferCount = cast(int)bufferCount;
        logGlErr("drawBuffers offscreen");
        glViewport(0, 0, tex.width, tex.height);
        glClearColor(0, 0, 0, 0);
        glClear(GL_COLOR_BUFFER_BIT);
        logGlErr("clear offscreen");
        glActiveTexture(GL_TEXTURE0);
        glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);

        logFboState("post-begin");
    }

    void endDynamicComposite(DynamicCompositePass pass) {
        if (pass is null) {
            return;
        }
        if (pass.surface is null) {
            return;
        }

        logFboState("pre-end");
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
        logGlErr("restore draw buffers");
        logFboState("post-end");
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

    void useShader(RenderShaderHandle shader) {
        auto handle = requireGLShader(shader);
        glUseProgram(handle.shader.program);
    }

    RenderShaderHandle createShader(string vertexSource, string fragmentSource) {
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

    void destroyShader(RenderShaderHandle shader) {
        auto handle = requireGLShader(shader);
        if (handle.shader.program) {
            glDetachShader(handle.shader.program, handle.shader.vert);
            glDetachShader(handle.shader.program, handle.shader.frag);
            glDeleteProgram(handle.shader.program);
        }
        if (handle.shader.vert) glDeleteShader(handle.shader.vert);
        if (handle.shader.frag) glDeleteShader(handle.shader.frag);
        handle.shader = ShaderProgramHandle.init;
    }

    int getShaderUniformLocation(RenderShaderHandle shader, string name) {
        auto handle = requireGLShader(shader);
        return glGetUniformLocation(handle.shader.program, name.toStringz);
    }

    void setShaderUniform(RenderShaderHandle shader, int location, bool value) {
        requireGLShader(shader);
        glUniform1i(location, value ? 1 : 0);
    }

    void setShaderUniform(RenderShaderHandle shader, int location, int value) {
        requireGLShader(shader);
        glUniform1i(location, value);
    }

    void setShaderUniform(RenderShaderHandle shader, int location, float value) {
        requireGLShader(shader);
        glUniform1f(location, value);
    }

    void setShaderUniform(RenderShaderHandle shader, int location, vec2 value) {
        requireGLShader(shader);
        glUniform2f(location, value.x, value.y);
    }

    void setShaderUniform(RenderShaderHandle shader, int location, vec3 value) {
        requireGLShader(shader);
        glUniform3f(location, value.x, value.y, value.z);
    }

    void setShaderUniform(RenderShaderHandle shader, int location, vec4 value) {
        requireGLShader(shader);
        glUniform4f(location, value.x, value.y, value.z, value.w);
    }

    void setShaderUniform(RenderShaderHandle shader, int location, mat4 value) {
        requireGLShader(shader);
        glUniformMatrix4fv(location, 1, GL_TRUE, value.ptr);
    }

    RenderTextureHandle createTextureHandle() {
        auto handle = new GLTextureHandle();
        GLuint textureId;
        glGenTextures(1, &textureId);
        enforce(textureId != 0, "Failed to create texture");
        handle.id = textureId;
        return handle;
    }

    void destroyTextureHandle(RenderTextureHandle texture) {
        auto handle = requireGLTexture(texture);
        if (handle.id) {
            GLuint textureId = handle.id;
            glDeleteTextures(1, &textureId);
        }
        handle.id = 0;
    }

    void bindTextureHandle(RenderTextureHandle texture, uint unit) {
        auto handle = requireGLTexture(texture);
        glActiveTexture(GL_TEXTURE0 + (unit <= 31 ? unit : 31));
        glBindTexture(GL_TEXTURE_2D, handle.id);
    }

    void uploadTextureData(RenderTextureHandle texture, int width, int height,
                                    int inChannels, int outChannels, bool stencil,
                                    ubyte[] data) {
        auto handle = requireGLTexture(texture);
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

    void generateTextureMipmap(RenderTextureHandle texture) {
        auto handle = requireGLTexture(texture);
        glBindTexture(GL_TEXTURE_2D, handle.id);
        glGenerateMipmap(GL_TEXTURE_2D);
    }

    void applyTextureFiltering(RenderTextureHandle texture, Filtering filtering, bool useMipmaps = true) {
        auto handle = requireGLTexture(texture);
        glBindTexture(GL_TEXTURE_2D, handle.id);
        bool linear = filtering == Filtering.Linear;
        auto minFilter = useMipmaps
            ? (linear ? GL_LINEAR_MIPMAP_LINEAR : GL_NEAREST_MIPMAP_NEAREST)
            : (linear ? GL_LINEAR : GL_NEAREST);
        auto magFilter = linear ? GL_LINEAR : GL_NEAREST;
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, minFilter);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, magFilter);
    }

    void applyTextureWrapping(RenderTextureHandle texture, Wrapping wrapping) {
        auto handle = requireGLTexture(texture);
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

    void applyTextureAnisotropy(RenderTextureHandle texture, float value) {
        auto handle = requireGLTexture(texture);
        glBindTexture(GL_TEXTURE_2D, handle.id);
        glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_MAX_ANISOTROPY, value);
    }

    float maxTextureAnisotropy() {
        float max;
        glGetFloatv(GL_MAX_TEXTURE_MAX_ANISOTROPY, &max);
        return max;
    }

    void readTextureData(RenderTextureHandle texture, int channels, bool stencil,
                                  ubyte[] buffer) {
        auto handle = requireGLTexture(texture);
        glBindTexture(GL_TEXTURE_2D, handle.id);
        GLuint format = stencil ? GL_DEPTH_STENCIL : channelFormat(channels);
        glGetTexImage(GL_TEXTURE_2D, 0, format, GL_UNSIGNED_BYTE, buffer.ptr);
    }

private:
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

    Shader getBlendShader(BlendMode mode) {
        ensureBlendShadersInitialized();
        auto shader = mode in blendShaders;
        return shader ? *shader : null;
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

    size_t textureNativeHandle(RenderTextureHandle texture) {
        auto handle = requireGLTexture(texture);
        return handle.id;
    }
}



// ---- source/nlshim/core/render/backends/opengl/part.d ----



import bindbc.opengl;
import std.algorithm : min;

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

// Things only available internally for nijilive rendering
public {
}

// ---- source/nlshim/core/render/backends/opengl/shader_backend.d ----




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

// ---- source/nlshim/core/render/backends/opengl/soa_upload.d ----



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
    glBindBuffer(GL_ARRAY_BUFFER, buffer);
    glBufferData(GL_ARRAY_BUFFER, raw.length * float.sizeof, raw.ptr, usage);
}



// ---- source/nlshim/core/render/backends/opengl/texture_backend.d ----

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

// ---- source/nlshim/core/render/backends/package.d ----

import std.exception : enforce;

/// Struct for backend-cached shared GPU state
alias RenderResourceHandle = size_t;

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

version (RenderBackendOpenGL) {
    enum SelectedBackend = BackendEnum.OpenGL;
} else version (RenderBackendDirectX12) {
    enum SelectedBackend = BackendEnum.DirectX12;
} else version (RenderBackendVulkan) {
    enum SelectedBackend = BackendEnum.Vulkan;
} else {
    enum SelectedBackend = BackendEnum.OpenGL;
}

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

// ---- source/nlshim/core/render/passes.d ----

/// Render target scope kinds.
enum RenderPassKind {
    Root,
    DynamicComposite,
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
  size_t stride() const {
        return storage.length;
    }

    ref Vec2Array data() {
        return storage;
    }

    bool isDirty() const {
        return dirty;
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

// ---- source/nlshim/core/render/support.d ----

import inmath.linalg : Vector;
alias Vec2Array = veca!(float, 2);
alias Vec3Array = veca!(float, 3);

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

public void nlSetTripleBufferFallback(bool enable) {
    currentRenderBackend().setTripleBufferFallback(enable);
}

public bool nlIsTripleBufferFallbackEnabled() {
    return currentRenderBackend().tripleBufferFallbackEnabled();
}

// ===== Drawable helpers =====


public void incDrawableBindVAO() {
    
        currentRenderBackend().bindDrawableVao();
    
}

private bool doGenerateBounds = false;
public void inSetUpdateBounds(bool state) { doGenerateBounds = state; }

// ---- source/nlshim/core/runtime_state.d ----

import fghj : deserializeValue;
import std.exception : enforce;
import core.stdc.string : memcpy;

public vec4 inClearColor = vec4(0, 0, 0, 0);
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

/// Push viewport dimensions.
void inPushViewport(int width, int height) {
    requireRenderBackend().pushViewport(width, height);
}

/// Pop viewport if we have more than one entry.
void inPopViewport() {
    requireRenderBackend().popViewport();
}

/**
    Sets the viewport dimensions (logical state + backend notification)
*/
void inSetViewport(int width, int height) {
    requireRenderBackend().setViewport(width, height);
}

/**
    Gets the current viewport dimensions.
*/
void inGetViewport(out int width, out int height) {
    requireRenderBackend().getViewport(width, height);
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
// ---- source/nlshim/core/shader.d ----
/*
    Copyright © 2020, Inochi2D Project
    Copyright © 2024, nijigenerate Project
    Distributed under the 2-Clause BSD License, see LICENSE file.
    
    Authors: Luna Nielsen
*/



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
        
            if (handle is null) return;
            auto backend = tryRenderBackend();
            if (backend !is null) {
                backend.destroyShader(handle);
            }
            handle = null;
        
    }

    /**
        Creates a new shader object from source definitions
    */
    this(ShaderAsset sources) {
        
            auto variant = sources.sourceForCurrentBackend();
            handle = currentRenderBackend().createShader(variant.vertex, variant.fragment);
        
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
        
            if (handle is null) return;
            currentRenderBackend().useShader(handle);
        
    }

    int getUniformLocation(string name) {
        
            if (handle is null) return -1;
            return currentRenderBackend().getShaderUniformLocation(handle, name);
        
        return -1;
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

// ---- source/nlshim/core/texture.d ----
/*
    Copyright © 2020, Inochi2D Project
    Copyright © 2024, nijigenerate Project
    Distributed under the 2-Clause BSD License, see LICENSE file.
    
    Authors: Luna Nielsen
*/

import std.exception;
import std.format;
import imagefmt;
import std.algorithm : clamp;



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

        
            auto backend = currentRenderBackend();
            handle = backend.createTextureHandle();
            this.setData(data, inChannels);

            this.setFiltering(Filtering.Linear);
            this.setWrapping(Wrapping.Clamp);
            this.setAnisotropy(incGetMaxAnisotropy()/2.0f);
        
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
        Set the filtering mode used for the texture
    */
    void setFiltering(Filtering filtering) {
        
            if (handle is null) return;
            currentRenderBackend().applyTextureFiltering(handle, filtering, useMipmaps_);
        
    }

    void setAnisotropy(float value) {
        
            if (handle is null) return;
            currentRenderBackend().applyTextureAnisotropy(handle, clamp(value, 1, incGetMaxAnisotropy()));
        
    }

    /**
        Set the wrapping mode used for the texture
    */
    void setWrapping(Wrapping wrapping) {
        
            if (handle is null) return;
            currentRenderBackend().applyTextureWrapping(handle, wrapping);
        
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
            
                if (handle is null) return;
                currentRenderBackend().uploadTextureData(handle, width_, height_, actualChannels, channels_, stencil_, data);
                this.genMipmap();
            
        }
    }

    /**
        Generate mipmaps
    */
    void genMipmap() {
        
            if (!stencil_ && handle !is null && useMipmaps_) {
                currentRenderBackend().generateTextureMipmap(handle);
            }
        
    }

    /**
        Bind this texture
        
        Notes
        - In release mode the unit value is clamped to 31 (The max OpenGL texture unit value)
        - In debug mode unit values over 31 will assert.
    */
    void bind(uint unit = 0) {
        assert(unit <= 31u, "Outside maximum texture unit value");
        
            if (handle is null) return;
            currentRenderBackend().bindTextureHandle(handle, unit);
        
    }

    /**
        Gets this texture's native GPU handle (legacy compatibility with OpenGL ID users)
    */
    uint getTextureId() {
        
            if (handle is null) return 0;
            auto backend = tryRenderBackend();
            if (backend is null) return 0;
            return cast(uint)backend.textureNativeHandle(handle);
        
        return 0;
    }

    /**
        Gets the texture data for the texture
    */
    ubyte[] getTextureData(bool unmultiply=false) {
        if (locked) {
            return lockedData;
        } else {
            ubyte[] buf = new ubyte[width*height*channels_];
            
                if (handle is null) return buf;
                currentRenderBackend().readTextureData(handle, channels_, stencil_, buf);
            
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
        
            if (handle is null) return;
            auto backend = tryRenderBackend();
            if (backend !is null) backend.destroyTextureHandle(handle);
            handle = null;
    }

    RenderTextureHandle backendHandle() {
        return handle;
    }

    Texture dup() {
        auto result = new Texture(width_, height_, channels_, stencil_);
        result.setData(getTextureData(), channels_);
        return result;
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

/**
    Gets the maximum level of anisotropy
*/
float incGetMaxAnisotropy() {
    
        auto backend = tryRenderBackend();
        if (backend !is null) {
            return backend.maxTextureAnisotropy();
        }
    
    return 1;
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

// ---- source/nlshim/math/veca_ops.d ----

import std.algorithm : min;
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

// ---- source/nlshim/ver.d ----
// AUTOGENERATED BY GITVER, DO NOT MODIFY

// trans rights
