module nlshim.core.render.backends.queue;

version (UseQueueBackend) {

version (InDoesRender) {

import nlshim.core.render.command_emitter : RenderCommandEmitter, RenderBackend;
import nlshim.core.render.commands;
import nlshim.core.render.backends : RenderGpuState, RenderResourceHandle,
    RenderTextureHandle, RenderShaderHandle, BackendEnum;
import nlshim.core.nodes.part : Part;
import nlshim.core.nodes.drawable : Drawable;
import nlshim.core.nodes.composite.projectable : Projectable;
import nlshim.core.nodes.common : BlendMode;
import nlshim.core.texture_types : Filtering, Wrapping;
import nlshim.core.texture : Texture;
import nlshim.core.shader : Shader;
import nlshim.math : vec2, vec3, vec4, rect, mat4, Vec2Array, Vec3Array;
import nlshim.core.diff_collect : DifferenceEvaluationRegion, DifferenceEvaluationResult;
import nlshim.math.camera : Camera;
import nlshim.core.runtime_state : inGetViewport;
import std.algorithm : min;
import std.exception : enforce;
import bindbc.opengl;
import nlshim.core.render.backends.opengl.drawable_buffers : oglInitDrawableBackend, oglBindDrawableVao;
import nlshim.core.render.backends.opengl.handles : GLShaderHandle;
import nlshim.core.render.backends.opengl.shader_backend :
    ShaderProgramHandle,
    oglCreateShaderProgram,
    oglDestroyShaderProgram,
    oglUseShaderProgram,
    oglSetUniformBool,
    oglSetUniformInt,
    oglSetUniformFloat,
    oglSetUniformVec2,
    oglSetUniformVec3,
    oglSetUniformVec4,
    oglSetUniformMat4,
    oglShaderGetUniformLocation;

/// Captured command information emitted sequentially.
struct QueuedCommand {
    RenderCommandKind kind;
    union Payload {
        PartDrawPacket partPacket;
        MaskApplyPacket maskApplyPacket;
        DynamicCompositePass dynamicPass;
    }
    Payload payload;
    bool usesStencil;
}

/// CommandEmitter implementation that records commands into an in-memory queue.
final class CommandQueueEmitter : RenderCommandEmitter {
private:
    QueuedCommand[] queueData;
    RenderBackend activeBackend;
    RenderGpuState* statePtr;
    // Defer BeginMask emission until we know ApplyMask is valid.
    bool pendingMask;
    bool pendingMaskUsesStencil;

public:
    void beginFrame(RenderBackend backend, ref RenderGpuState state) {
        activeBackend = backend;
        statePtr = &state;
        state = RenderGpuState.init;
        queueData.length = 0;
    }

    void drawPart(Part part, bool isMask) {
        if (part is null) return;
        auto packet = makePartDrawPacket(part, isMask);
        record(RenderCommandKind.DrawPart, (ref QueuedCommand cmd) {
            cmd.payload.partPacket = packet;
        });
    }

    void beginDynamicComposite(Projectable composite, DynamicCompositePass passData) {
        record(RenderCommandKind.BeginDynamicComposite, (ref QueuedCommand cmd) {
            cmd.payload.dynamicPass = passData;
        });
    }

    void endDynamicComposite(Projectable composite, DynamicCompositePass passData) {
        record(RenderCommandKind.EndDynamicComposite, (ref QueuedCommand cmd) {
            cmd.payload.dynamicPass = passData;
        });
    }

    void beginMask(bool useStencil) {
        // Do not emit yet; wait until ApplyMask succeeds.
        pendingMask = true;
        pendingMaskUsesStencil = useStencil;
    }

    void applyMask(Drawable drawable, bool isDodge) {
        if (drawable is null) return;
        MaskApplyPacket packet;
        if (!tryMakeMaskApplyPacket(drawable, isDodge, packet)) {
            // Invalidate pending mask block if ApplyMask is unusable.
            pendingMask = false;
            return;
        }
        if (pendingMask) {
            record(RenderCommandKind.BeginMask, (ref QueuedCommand cmd) {
                cmd.usesStencil = pendingMaskUsesStencil;
            });
            pendingMask = false;
        }
        record(RenderCommandKind.ApplyMask, (ref QueuedCommand cmd) {
            cmd.payload.maskApplyPacket = packet;
        });
    }

    void beginMaskContent() {
        if (pendingMask) return; // Skip when ApplyMask was invalid.
        record(RenderCommandKind.BeginMaskContent, (ref QueuedCommand) {});
    }

    void endMask() {
        if (pendingMask) {
            pendingMask = false;
            return;
        }
        record(RenderCommandKind.EndMask, (ref QueuedCommand) {});
    }

    void endFrame(RenderBackend backend, ref RenderGpuState state) {
        activeBackend = backend;
        statePtr = &state;
    }

    /// Returns a copy of the recorded commands.
    const(QueuedCommand)[] queuedCommands() const {
        return queueData;
    }

    /// Clears all recorded commands.
    void clearQueue() {
        queueData.length = 0;
    }

private:
    void record(RenderCommandKind kind, scope void delegate(ref QueuedCommand) fill) {
        QueuedCommand cmd;
        cmd.kind = kind;
        fill(cmd);
        queueData ~= cmd;
    }
}

/// Minimal render backend that tracks resource handles without issuing GPU work.
class RenderingBackend(BackendEnum backendType : BackendEnum.OpenGL) {
private:
    size_t framebuffer;
    size_t renderImage;
    size_t compositeFramebuffer;
    size_t compositeImage;
    size_t blendFramebuffer;
    size_t blendAlbedo;
    size_t blendEmissive;
    size_t blendBump;
    class QueueTextureHandle : RenderTextureHandle {
        size_t id;           // logical handle (we align this to native GL id)
        GLuint nativeId = 0; // GL texture id
        int width;
        int height;
        int inChannels;
        int outChannels;
        bool stencil;
        Filtering filtering = Filtering.Linear;
        Wrapping wrapping = Wrapping.Clamp;
        float anisotropy = 1.0f;
        ubyte[] data;
    }

    class QueueShaderHandle : RenderShaderHandle { }

    import core.memory : GC;
    struct IndexBufferData {
        ushort* data;
        size_t length;
    }

    size_t nextTextureId = 1;
    size_t nextIndexHandle = 1;
    IndexBufferData[RenderResourceHandle] indexBuffers;
    bool differenceAggregationEnabled = false;
    DifferenceEvaluationRegion differenceRegion;
    DifferenceEvaluationResult differenceResult;

    QueueTextureHandle requireTexture(RenderTextureHandle handle) {
        auto tex = cast(QueueTextureHandle)handle;
        enforce(tex !is null, "Invalid QueueTextureHandle provided.");
        return tex;
    }

public:
    void initializeRenderer() {}
    void resizeViewportTargets(int, int) {}
    void dumpViewport(ref ubyte[] data, int width, int height) {
        auto required = cast(size_t)width * cast(size_t)height * 4;
        if (data.length < required) return;
        data[0 .. required] = 0;
    }
    void beginScene() {}
    void endScene() {}
    void postProcessScene() {}

    void initializeDrawableResources() {
        // Reuse the OpenGL VAO/VBO setup so vertex attrib pointers are valid.
        oglInitDrawableBackend();
    }
    void bindDrawableVao() {
        // Ensure a VAO is bound before glDrawElements in the OpenGL helpers.
        oglBindDrawableVao();
    }
    void createDrawableBuffers(out RenderResourceHandle ibo) {
        ibo = nextIndexHandle++;
    }
    void uploadDrawableIndices(RenderResourceHandle ibo, ushort[] indices) {
        // Allocate in a non-movable region, then copy
        auto bytes = cast(size_t)indices.length * ushort.sizeof;
        auto ptr = cast(ushort*)GC.malloc(bytes, GC.BlkAttr.NO_SCAN | GC.BlkAttr.NO_MOVE);
        if (indices.length && ptr !is null) {
            ptr[0 .. indices.length] = indices[];
        }
        // Free existing buffer if present
        if (auto existing = ibo in indexBuffers) {
            if (existing.data !is null) GC.free(existing.data);
        }
        indexBuffers[ibo] = IndexBufferData(ptr, indices.length);
        debug (UnityDLLLog) {
            import std.stdio : writefln;
            debug (UnityDLLLog) writefln("[nijilive] uploadDrawableIndices ibo=%s len=%s ptr=%s", ibo, indices.length, cast(size_t)ptr);
        }
    }
    void uploadSharedVertexBuffer(Vec2Array) {}
    void uploadSharedUvBuffer(Vec2Array) {}
    void uploadSharedDeformBuffer(Vec2Array) {}
    void drawDrawableElements(RenderResourceHandle, size_t) {}

    bool supportsAdvancedBlend() { return false; }
    bool supportsAdvancedBlendCoherent() { return false; }
    void setAdvancedBlendCoherent(bool) {}
    void setLegacyBlendMode(BlendMode) {}
    void setAdvancedBlendEquation(BlendMode) {}
    void issueBlendBarrier() {}
    void initDebugRenderer() {}
    void setDebugPointSize(float) {}
    void setDebugLineWidth(float) {}
    void uploadDebugBuffer(Vec3Array, ushort[]) {}
    void setDebugExternalBuffer(size_t, size_t, int) {}
    void drawDebugPoints(vec4, mat4) {}
    void drawDebugLines(vec4, mat4) {}

    void drawPartPacket(ref PartDrawPacket) {}
    void beginDynamicComposite(DynamicCompositePass pass) {
        if (pass is null) return;
        pass.origBuffer = framebuffer;
        int vw, vh;
        inGetViewport(vw, vh);
        pass.origViewport[0] = 0;
        pass.origViewport[1] = 0;
        pass.origViewport[2] = vw;
        pass.origViewport[3] = vh;
    }
    void endDynamicComposite(DynamicCompositePass) {}
    void destroyDynamicComposite(DynamicCompositeSurface) {}
    void beginMask(bool) {}
    void applyMask(ref MaskApplyPacket) {}
    void beginMaskContent() {}
    void endMask() {}
    void drawTextureAtPart(Texture, Part) {}
    void drawTextureAtPosition(Texture, vec2, float, vec3, vec3) {}
    void drawTextureAtRect(Texture, rect, rect, float, vec3, vec3, Shader, Camera) {}

    RenderResourceHandle framebufferHandle() { return framebuffer; }
    RenderResourceHandle renderImageHandle() { return renderImage; }
    RenderResourceHandle compositeFramebufferHandle() { return compositeFramebuffer; }
    RenderResourceHandle compositeImageHandle() { return compositeImage; }
    RenderResourceHandle mainAlbedoHandle() { return renderImage; }
    RenderResourceHandle mainEmissiveHandle() { return renderImage; }
    RenderResourceHandle mainBumpHandle() { return renderImage; }
    RenderResourceHandle compositeEmissiveHandle() { return compositeImage; }
    RenderResourceHandle compositeBumpHandle() { return compositeImage; }
    RenderResourceHandle blendFramebufferHandle() { return blendFramebuffer; }
    RenderResourceHandle blendAlbedoHandle() { return blendAlbedo; }
    RenderResourceHandle blendEmissiveHandle() { return blendEmissive; }
    RenderResourceHandle blendBumpHandle() { return blendBump; }
    void addBasicLightingPostProcess() {}
    void setDifferenceAggregationEnabled(bool enabled) { differenceAggregationEnabled = enabled; }
    bool isDifferenceAggregationEnabled() { return differenceAggregationEnabled; }
    void setDifferenceAggregationRegion(DifferenceEvaluationRegion region) { differenceRegion = region; }
    DifferenceEvaluationRegion getDifferenceAggregationRegion() { return differenceRegion; }
    bool evaluateDifferenceAggregation(size_t, int, int) { return false; }
    bool fetchDifferenceAggregationResult(out DifferenceEvaluationResult result) {
        result = differenceResult;
        return false;
    }

    RenderShaderHandle createShader(string vertexSrc, string fragmentSrc) {
        auto handle = new GLShaderHandle();
        oglCreateShaderProgram(handle.shader, vertexSrc, fragmentSrc);
        return handle;
    }
    void destroyShader(RenderShaderHandle shader) {
        auto h = cast(GLShaderHandle)shader;
        if (h is null) return;
        oglDestroyShaderProgram(h.shader);
    }
    void useShader(RenderShaderHandle shader) {
        auto h = cast(GLShaderHandle)shader;
        if (h is null) return;
        oglUseShaderProgram(h.shader);
    }
    int getShaderUniformLocation(RenderShaderHandle shader, string name) {
        auto h = cast(GLShaderHandle)shader;
        if (h is null) return -1;
        return oglShaderGetUniformLocation(h.shader, name);
    }
    void setShaderUniform(RenderShaderHandle, int location, bool value) {
        oglSetUniformBool(location, value);
    }
    void setShaderUniform(RenderShaderHandle, int location, int value) {
        oglSetUniformInt(location, value);
    }
    void setShaderUniform(RenderShaderHandle, int location, float value) {
        oglSetUniformFloat(location, value);
    }
    void setShaderUniform(RenderShaderHandle, int location, vec2 value) {
        oglSetUniformVec2(location, value);
    }
    void setShaderUniform(RenderShaderHandle, int location, vec3 value) {
        oglSetUniformVec3(location, value);
    }
    void setShaderUniform(RenderShaderHandle, int location, vec4 value) {
        oglSetUniformVec4(location, value);
    }
    void setShaderUniform(RenderShaderHandle, int location, mat4 value) {
        oglSetUniformMat4(location, value);
    }

    RenderTextureHandle createTextureHandle() {
        auto handle = new QueueTextureHandle();
        glGenTextures(1, &handle.nativeId);
        handle.id = nextTextureId++;
        return handle;
    }
    void destroyTextureHandle(RenderTextureHandle texture) {
        if (auto tex = cast(QueueTextureHandle)texture) {
            if (tex.nativeId) {
                GLuint id = tex.nativeId;
                glDeleteTextures(1, &id);
                tex.nativeId = 0;
            }
            tex.data = null;
        }
    }
    void bindTextureHandle(RenderTextureHandle texture, uint unit) {
        auto tex = requireTexture(texture);
        if (tex.nativeId == 0) return;
        glActiveTexture(GL_TEXTURE0 + unit);
        glBindTexture(GL_TEXTURE_2D, tex.nativeId);
    }
    void uploadTextureData(RenderTextureHandle texture, int width, int height, int inChannels,
                           int outChannels, bool stencil, ubyte[] data) {
        auto tex = requireTexture(texture);
        tex.width = width;
        tex.height = height;
        tex.inChannels = inChannels;
        tex.outChannels = outChannels;
        tex.stencil = stencil;
        auto expected = cast(size_t)width * cast(size_t)height * cast(size_t)outChannels;
        tex.data.length = expected;
        if (tex.nativeId == 0) {
            glGenTextures(1, &tex.nativeId);
            tex.id = tex.nativeId;
        }
        glBindTexture(GL_TEXTURE_2D, tex.nativeId);
        // Make sure row alignment doesn't drop tail bytes on odd widths.
        GLint prevAlign = 0;
        glGetIntegerv(GL_UNPACK_ALIGNMENT, &prevAlign);
        glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
        auto format = (outChannels == 4) ? GL_RGBA : (outChannels == 3 ? GL_RGB : (outChannels == 2 ? GL_RG : GL_RED));
        glTexImage2D(GL_TEXTURE_2D, 0, format, width, height, 0, format, GL_UNSIGNED_BYTE,
                     data.length ? data.ptr : null);
        auto minFilter = tex.filtering == Filtering.Point ? GL_NEAREST : GL_LINEAR;
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, minFilter);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, minFilter);
        auto wrap = tex.wrapping == Wrapping.Repeat ? GL_REPEAT : (tex.wrapping == Wrapping.Mirror ? GL_MIRRORED_REPEAT : GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, wrap);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, wrap);
        glPixelStorei(GL_UNPACK_ALIGNMENT, prevAlign);
    }
    void updateTextureRegion(RenderTextureHandle texture, int x, int y, int width, int height,
                             int channels, ubyte[] data) {
        auto tex = requireTexture(texture);
        if (tex.nativeId == 0) return;
        auto format = (tex.outChannels == 4) ? GL_RGBA : (tex.outChannels == 3 ? GL_RGB : (tex.outChannels == 2 ? GL_RG : GL_RED));
        glBindTexture(GL_TEXTURE_2D, tex.nativeId);
        glTexSubImage2D(GL_TEXTURE_2D, 0, x, y, width, height, format, GL_UNSIGNED_BYTE,
                        data.length ? data.ptr : null);
    }
    void generateTextureMipmap(RenderTextureHandle texture) {
        auto tex = requireTexture(texture);
        if (tex.nativeId == 0) return;
        glBindTexture(GL_TEXTURE_2D, tex.nativeId);
        glGenerateMipmap(GL_TEXTURE_2D);
    }
    void applyTextureFiltering(RenderTextureHandle texture, Filtering filtering, bool) {
        auto tex = cast(QueueTextureHandle)texture;
        if (tex is null || tex.nativeId == 0) return;
        tex.filtering = filtering;
        auto minFilter = filtering == Filtering.Point ? GL_NEAREST : GL_LINEAR;
        glBindTexture(GL_TEXTURE_2D, tex.nativeId);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, minFilter);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, minFilter);
    }
    void applyTextureWrapping(RenderTextureHandle texture, Wrapping wrapping) {
        auto tex = cast(QueueTextureHandle)texture;
        if (tex is null || tex.nativeId == 0) return;
        tex.wrapping = wrapping;
        auto wrap = wrapping == Wrapping.Repeat ? GL_REPEAT : (wrapping == Wrapping.Mirror ? GL_MIRRORED_REPEAT : GL_CLAMP_TO_EDGE);
        glBindTexture(GL_TEXTURE_2D, tex.nativeId);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, wrap);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, wrap);
    }
    void applyTextureAnisotropy(RenderTextureHandle texture, float value) {
        auto tex = cast(QueueTextureHandle)texture;
        if (tex is null || tex.nativeId == 0) return;
        tex.anisotropy = value;
        // EXT_max_texture_anisotropy may not be present; ignore if unavailable.
        enum GL_TEXTURE_MAX_ANISOTROPY_EXT = 0x84FE;
        glBindTexture(GL_TEXTURE_2D, tex.nativeId);
        glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_MAX_ANISOTROPY_EXT, value);
    }
    float maxTextureAnisotropy() { return 1.0f; }
    void readTextureData(RenderTextureHandle texture, int, bool, ubyte[] buffer) {
        auto tex = cast(QueueTextureHandle)texture;
        if (tex is null || buffer.length == 0 || tex.nativeId == 0) return;
        auto expected = cast(size_t)tex.width * tex.height * tex.outChannels;
        if (buffer.length < expected) return;
        glBindTexture(GL_TEXTURE_2D, tex.nativeId);
        auto format = (tex.outChannels == 4) ? GL_RGBA : (tex.outChannels == 3 ? GL_RGB : (tex.outChannels == 2 ? GL_RG : GL_RED));
        glGetTexImage(GL_TEXTURE_2D, 0, format, GL_UNSIGNED_BYTE, buffer.ptr);
    }
    size_t textureNativeHandle(RenderTextureHandle texture) {
        auto tex = cast(QueueTextureHandle)texture;
        return tex is null ? 0 : tex.nativeId;
    }

    public const(ushort)[] findIndexBuffer(RenderResourceHandle handle) {
        if (auto found = handle in indexBuffers) {
            if (found.data is null || found.length == 0) return null;
            return found.data[0 .. found.length];
        }
        return null;
    }

    public size_t textureHandleId(RenderTextureHandle texture) {
        auto tex = cast(QueueTextureHandle)texture;
        return tex is null ? 0 : tex.id;
    }

    public void setRenderTargets(size_t renderHandle, size_t compositeHandle, size_t blendHandle = 0) {
        framebuffer = renderHandle;
        renderImage = renderHandle;
        compositeFramebuffer = compositeHandle;
        compositeImage = compositeHandle;
        blendFramebuffer = blendHandle;
        blendAlbedo = blendHandle;
        blendEmissive = blendHandle;
        blendBump = blendHandle;
    }

    public void overrideTextureId(RenderTextureHandle tex, size_t id) {
        auto q = cast(QueueTextureHandle)tex;
        if (q !is null) {
            q.id = id;
        }
    }
}

}

}
