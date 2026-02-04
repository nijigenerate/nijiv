module nlshim.core.render.backends.opengl.dynamic_composite;

version (InDoesRender) {

import bindbc.opengl;
import nlshim.core.render.commands : DynamicCompositePass, DynamicCompositeSurface;
import nlshim.core.runtime_state : inPushViewport, inPopViewport, inGetCamera, inSetCamera;
import nlshim.core.render.backends.opengl.runtime : oglRebindActiveTargets;
import nlshim.core.render.support : mat4, vec2, vec3, vec4;
import nlshim.core.texture : Texture;
import nlshim.core.render.backends.opengl.handles : requireGLTexture;
import nlshim.core.render.backends : RenderResourceHandle;
version (NijiliveRenderProfiler) {
    import std.stdio : writefln;
    import std.format : format;
}
version (NijiliveRenderProfiler) {
    import nlshim.core.render.profiler : renderProfilerAddSampleUsec;
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
    // Save current framebuffer/viewport so we can restore.
    GLint previousFramebuffer;
    GLint previousReadFramebuffer;
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &previousFramebuffer);
    glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &previousReadFramebuffer);
    pass.origBuffer = cast(RenderResourceHandle)previousFramebuffer;
    glGetIntegerv(GL_VIEWPORT, pass.origViewport.ptr);
    // Save draw buffer count (fallback to 3 when unknown).
    GLint maxDrawBuffers = 0;
    glGetIntegerv(GL_MAX_COLOR_ATTACHMENTS, &maxDrawBuffers);
    GLint[8] drawBufs;
    glGetIntegerv(GL_DRAW_BUFFER0, &drawBufs[0]); // read only first
    pass.drawBufferCount = surface.textureCount > 0 ? cast(int)surface.textureCount : 1;

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
    } else {
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT, GL_TEXTURE_2D, 0, 0);
    }

    inPushViewport(tex.width, tex.height);

    // Adjust camera so offscreen composite renders upright into the target texture.
    auto camera = inGetCamera();
    camera.scale = vec2(1, -1);

    float invScaleX = pass.scale.x == 0 ? 0 : 1 / pass.scale.x;
    float invScaleY = pass.scale.y == 0 ? 0 : 1 / pass.scale.y;
    auto scaling = mat4.identity.scaling(invScaleX, invScaleY, 1);
    auto rotation = mat4.identity.rotateZ(-pass.rotationZ);
    auto offsetMatrix = scaling * rotation;
    camera.position = (offsetMatrix * -vec4(0, 0, 0, 1)).xy;
    inSetCamera(camera);

    glDrawBuffers(cast(int)bufferCount, drawBuffers.ptr);
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

    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, cast(GLuint)pass.origBuffer);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, cast(GLuint)pass.origBuffer);
    inPopViewport();
    glViewport(pass.origViewport[0], pass.origViewport[1],
        pass.origViewport[2], pass.origViewport[3]);
    if (pass.origBuffer != 0) {
        int count = pass.drawBufferCount > 0 ? pass.drawBufferCount : 3;
        GLuint[3] bufs = [GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2];
        glDrawBuffers(count, bufs.ptr);
    } else {
        // Backbuffer: ensure both draw/read buffers restored.
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

import nlshim.core.render.commands : DynamicCompositePass, DynamicCompositeSurface;

void oglBeginDynamicComposite(DynamicCompositePass) {}
void oglEndDynamicComposite(DynamicCompositePass) {}
void oglDestroyDynamicComposite(DynamicCompositeSurface) {}

}
