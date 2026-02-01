module app;

import core.sys.posix.dlfcn : dlopen, dlsym, dlclose, RTLD_NOW, RTLD_LOCAL, dlerror;
import core.time : MonoTime, Duration, seconds;
import std.conv : to;
import std.exception : enforce;
import std.file : exists, getcwd;
import std.path : buildPath, dirName;
import std.stdio : writeln, writefln;
import std.string : fromStringz, toStringz;
import std.math : exp;
import std.algorithm : clamp;

import bindbc.opengl;
import bindbc.sdl;

import ogl = opengl.opengl_backend;
import opengl.opengl_backend : NjgResult, UnityRendererConfig, UnityResourceCallbacks, RendererHandle, PuppetHandle, FrameConfig, CommandQueueView, SharedBufferSnapshot;
import opengl.opengl_backend : initOpenGLBackend, OpenGLBackendInit;
import nlshim.core.render.backends.opengl.runtime : oglResizeViewport;
import core.runtime : Runtime;
import nlshim.core.nodes.drawable : inSetUpdateBounds;
import nlshim.core.runtime_state : inSetViewport;
enum MaskDrawableKind : uint { Part, Mask }

extern(C) alias NjgLogFn = void function(const(char)* message, size_t length, void* userData);

alias FnCreateRenderer = extern(C) NjgResult function(const UnityRendererConfig*, const UnityResourceCallbacks*, RendererHandle*);
alias FnDestroyRenderer = extern(C) void function(RendererHandle);
alias FnLoadPuppet = extern(C) NjgResult function(RendererHandle, const char*, PuppetHandle*);
alias FnUnloadPuppet = extern(C) NjgResult function(RendererHandle, PuppetHandle);
alias FnBeginFrame = extern(C) NjgResult function(RendererHandle, const FrameConfig*);
alias FnTickPuppet = extern(C) NjgResult function(PuppetHandle, double);
alias FnEmitCommands = extern(C) NjgResult function(RendererHandle, CommandQueueView*);
alias FnFlushCommandBuffer = extern(C) void function(RendererHandle);
alias FnSetLogCallback = extern(C) void function(NjgLogFn, void*);
alias FnRtInit = extern(C) void function();
alias FnRtTerm = extern(C) void function();
alias FnGetSharedBuffers = extern(C) NjgResult function(RendererHandle, SharedBufferSnapshot*);
alias FnSetPuppetScale = extern(C) NjgResult function(PuppetHandle, float, float);

struct UnityApi {
    void* lib;
    FnCreateRenderer createRenderer;
    FnDestroyRenderer destroyRenderer;
    FnLoadPuppet loadPuppet;
    FnUnloadPuppet unloadPuppet;
    FnBeginFrame beginFrame;
    FnTickPuppet tickPuppet;
    FnEmitCommands emitCommands;
    FnFlushCommandBuffer flushCommands;
    FnSetLogCallback setLogCallback;
    FnGetSharedBuffers getSharedBuffers;
    FnRtInit rtInit;
    FnRtTerm rtTerm;
    FnSetPuppetScale setPuppetScale;
}

string dlErrorString() {
    auto err = dlerror();
    return err is null ? "" : fromStringz(err).idup;
}

T loadSymbol(T)(void* lib, string name) {
    auto sym = cast(T)dlsym(lib, name.toStringz);
    enforce(sym !is null, "Failed to load symbol "~name~" from libnijilive-unity: "~dlErrorString());
    return sym;
}

UnityApi loadUnityApi(string libPath) {
    // Load via druntime to share the runtime instance with the DLL.
    auto lib = Runtime.loadLibrary(libPath);
    enforce(lib !is null, "Failed to load libnijilive-unity via Runtime.loadLibrary: "~libPath);
    UnityApi api;
    api.lib = lib;
    api.createRenderer = loadSymbol!FnCreateRenderer(lib, "njgCreateRenderer");
    api.destroyRenderer = loadSymbol!FnDestroyRenderer(lib, "njgDestroyRenderer");
    api.loadPuppet = loadSymbol!FnLoadPuppet(lib, "njgLoadPuppet");
    api.unloadPuppet = loadSymbol!FnUnloadPuppet(lib, "njgUnloadPuppet");
    api.beginFrame = loadSymbol!FnBeginFrame(lib, "njgBeginFrame");
    api.tickPuppet = loadSymbol!FnTickPuppet(lib, "njgTickPuppet");
    api.emitCommands = loadSymbol!FnEmitCommands(lib, "njgEmitCommands");
    api.flushCommands = loadSymbol!FnFlushCommandBuffer(lib, "njgFlushCommandBuffer");
    api.setLogCallback = loadSymbol!FnSetLogCallback(lib, "njgSetLogCallback");
    api.getSharedBuffers = loadSymbol!FnGetSharedBuffers(lib, "njgGetSharedBuffers");
    api.setPuppetScale = loadSymbol!FnSetPuppetScale(lib, "njgSetPuppetScale");
    // Explicit runtime init/term provided by DLL.
    api.rtInit = loadSymbol!FnRtInit(lib, "njgRuntimeInit");
    api.rtTerm = loadSymbol!FnRtTerm(lib, "njgRuntimeTerm");
    return api;
}

extern(C) void logCallback(const(char)* msg, size_t len, void* userData) {
    if (msg is null || len == 0) return;
    writeln("[nijilive-unity] "~msg[0 .. len].idup);
}

void main(string[] args) {
    bool isTest = false;
    string[] positional;
    int framesFlag = -1;
    for (size_t i = 1; i < args.length; ++i) {
        auto arg = args[i];
        if (arg == "--test") {
            isTest = true;
            continue;
        }
        if (arg == "--frames") {
            if (i + 1 < args.length) {
                import std.ascii : isDigit;
                import std.algorithm : all;
                auto maybe = args[i + 1];
                if (maybe.all!isDigit) {
                    framesFlag = maybe.to!int;
                }
                ++i; // skip value
            }
            continue;
        }
        positional ~= arg;
    }
    if (positional.length < 1) {
        writeln("Usage: nijiv <puppet.inp|puppet.inx> [width height] [--test]");
        return;
    }
    string puppetPath = positional[0];
    import std.algorithm : all;
    import std.ascii : isDigit;
    bool hasWidth = positional.length > 1 && positional[1].all!isDigit;
    bool hasHeight = positional.length > 2 && positional[2].all!isDigit;
    int width = hasWidth ? positional[1].to!int : 1280;
    int height = hasHeight ? positional[2].to!int : 720;
    writefln("nijiv (Unity DLL) start: file=%s, size=%sx%s (test=%s)", puppetPath, width, height, isTest);

    auto glInit = initOpenGLBackend(width, height, isTest);
    scope (exit) {
        if (glInit.glContext !is null) SDL_GL_DeleteContext(glInit.glContext);
        if (glInit.window !is null) SDL_DestroyWindow(glInit.window);
        SDL_Quit();
    }
    // Ensure drawable size reflects the actual GL framebuffer (handles HiDPI).
    SDL_GL_GetDrawableSize(glInit.window, &glInit.drawableW, &glInit.drawableH);

    // Load the Unity-facing DLL from a nearby nijilive build.
    string exeDir = getcwd();
    string[] libCandidates = [
        buildPath(exeDir, "libnijilive-unity.dylib"),
        buildPath(exeDir, "..", "nijilive", "libnijilive-unity.dylib"),
        buildPath(exeDir, "..", "..", "nijilive", "libnijilive-unity.dylib"),
        buildPath("..", "nijilive", "libnijilive-unity.dylib"),
    ];
    string libPath;
    foreach (c; libCandidates) {
        if (exists(c)) {
            libPath = c;
            break;
        }
    }
    enforce(libPath.length > 0, "Could not find libnijilive-unity.dylib (searched: "~libCandidates.to!string~")");
    auto api = loadUnityApi(libPath);
    // Do not unload the shared runtime-bound DLL during process lifetime.
    if (api.rtInit !is null) api.rtInit();
    scope (exit) if (api.rtTerm !is null) api.rtTerm();
    api.setLogCallback(&logCallback, null);
    // Queue backend needs bounds generation enabled; otherwise bounds stay NaN and offscreen targets fail.
    inSetUpdateBounds(true);

    UnityRendererConfig rendererCfg;
    rendererCfg.viewportWidth = glInit.drawableW;
    rendererCfg.viewportHeight = glInit.drawableH;
    RendererHandle renderer;
    enforce(api.createRenderer(&rendererCfg, &glInit.callbacks, &renderer) == NjgResult.Ok,
        "njgCreateRenderer failed");

    PuppetHandle puppet;
    enforce(api.loadPuppet(renderer, puppetPath.toStringz, &puppet) == NjgResult.Ok,
        "njgLoadPuppet failed");
    FrameConfig frameCfg;
    frameCfg.viewportWidth = glInit.drawableW;
    frameCfg.viewportHeight = glInit.drawableH;
    inSetViewport(glInit.drawableW, glInit.drawableH);
    oglResizeViewport(glInit.drawableW, glInit.drawableH);
    float puppetScale = 0.25f;

    // Apply initial scale (default 0.25) so that the view starts zoomed out.
    auto initScaleRes = api.setPuppetScale(puppet, puppetScale, puppetScale);
    if (initScaleRes != NjgResult.Ok) {
        writeln("njgSetPuppetScale initial apply failed: ", initScaleRes);
    }

    bool running = true;
    int frameCount = 0;
    MonoTime startTime = MonoTime.currTime;
    MonoTime prev = startTime;
    SDL_Event ev;

    while (running) {
        while (SDL_PollEvent(&ev) != 0) {
            switch (cast(uint)ev.type) {
                case SDL_QUIT:
                    running = false;
                    break;
                case SDL_KEYDOWN:
                    if (ev.key.keysym.scancode == SDL_SCANCODE_ESCAPE) running = false;
                    break;
                case SDL_WINDOWEVENT:
                    if (ev.window.event == SDL_WINDOWEVENT_SIZE_CHANGED ||
                        ev.window.event == SDL_WINDOWEVENT_RESIZED) {
                        SDL_GL_GetDrawableSize(glInit.window, &glInit.drawableW, &glInit.drawableH);
                        frameCfg.viewportWidth = glInit.drawableW;
                        frameCfg.viewportHeight = glInit.drawableH;
                        inSetViewport(glInit.drawableW, glInit.drawableH);
                        oglResizeViewport(glInit.drawableW, glInit.drawableH);
                    }
                    break;
                case SDL_MOUSEWHEEL:
                    // Scroll up to zoom in, down to zoom out. Use exponential step.
                    {
                        float step = 0.1f; // ~10% per notch
                        float factor = cast(float)exp(step * ev.wheel.y);
                        puppetScale = clamp(puppetScale * factor, 0.1f, 10.0f);
                        auto res = api.setPuppetScale(puppet, puppetScale, puppetScale);
                        if (res != NjgResult.Ok) {
                            writeln("njgSetPuppetScale failed: ", res);
                        }
                    }
                    break;
                default:
                    break;
            }
        }

        MonoTime now = MonoTime.currTime;
        Duration delta = now - prev;
        prev = now;
        double deltaSec = delta.total!"nsecs" / 1_000_000_000.0;

        enforce(api.beginFrame(renderer, &frameCfg) == NjgResult.Ok, "njgBeginFrame failed");
        enforce(api.tickPuppet(puppet, deltaSec) == NjgResult.Ok, "njgTickPuppet failed");

        CommandQueueView view;
        enforce(api.emitCommands(renderer, &view) == NjgResult.Ok, "njgEmitCommands failed");
        if (view.count && frameCount % 60 == 0) {
            writefln("Frame %s: queued commands=%s", frameCount, view.count);
        }

        SharedBufferSnapshot snapshot;
        enforce(api.getSharedBuffers(renderer, &snapshot) == NjgResult.Ok, "njgGetSharedBuffers failed");

        ogl.renderCommands(&glInit, &snapshot, &view);

        api.flushCommands(renderer);
        SDL_GL_SwapWindow(glInit.window);

        frameCount++;
        if (isTest && frameCount >= 5) {
            writefln("Exit after %s frames (test)", frameCount);
            break;
        }
        auto elapsed = now - startTime;
        if (isTest && elapsed > 5.seconds) {
            writefln("Exit: elapsed %s > 5s test-timeout", elapsed.total!"seconds");
            break;
        }
    }

    api.unloadPuppet(renderer, puppet);
    api.destroyRenderer(renderer);
}
