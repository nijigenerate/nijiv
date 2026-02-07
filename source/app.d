module app;

import core.sys.posix.dlfcn : dlopen, dlsym, dlclose, RTLD_NOW, RTLD_LOCAL, dlerror;
import core.time : MonoTime, Duration, seconds;
import std.conv : to;
import std.exception : enforce;
import std.file : exists, getcwd;
import std.path : buildPath, dirName;
import std.stdio : writeln, writefln;
import std.string : fromStringz, toStringz, endsWith;
import std.math : exp;
import std.algorithm : clamp;

import bindbc.sdl;

version (EnableVulkanBackend) {
    import gfx = vulkan_backend;
    enum backendName = "vulkan";
    alias BackendInit = gfx.VulkanBackendInit;
} else {
    import bindbc.opengl;
    import gfx = opengl.opengl_backend;
    import opengl.opengl_backend : currentRenderBackend;
    enum backendName = "opengl";
    alias BackendInit = gfx.OpenGLBackendInit;
}
import core.runtime : Runtime;
enum MaskDrawableKind : uint { Part, Mask }

extern(C) alias NjgLogFn = void function(const(char)* message, size_t length, void* userData);

alias FnCreateRenderer = extern(C) gfx.NjgResult function(const gfx.UnityRendererConfig*, const gfx.UnityResourceCallbacks*, gfx.RendererHandle*);
alias FnDestroyRenderer = extern(C) void function(gfx.RendererHandle);
alias FnLoadPuppet = extern(C) gfx.NjgResult function(gfx.RendererHandle, const char*, gfx.PuppetHandle*);
alias FnUnloadPuppet = extern(C) gfx.NjgResult function(gfx.RendererHandle, gfx.PuppetHandle);
alias FnBeginFrame = extern(C) gfx.NjgResult function(gfx.RendererHandle, const gfx.FrameConfig*);
alias FnTickPuppet = extern(C) gfx.NjgResult function(gfx.PuppetHandle, double);
alias FnEmitCommands = extern(C) gfx.NjgResult function(gfx.RendererHandle, gfx.CommandQueueView*);
alias FnFlushCommandBuffer = extern(C) void function(gfx.RendererHandle);
alias FnSetLogCallback = extern(C) void function(NjgLogFn, void*);
alias FnRtInit = extern(C) void function();
alias FnRtTerm = extern(C) void function();
alias FnGetSharedBuffers = extern(C) gfx.NjgResult function(gfx.RendererHandle, gfx.SharedBufferSnapshot*);
alias FnSetPuppetScale = extern(C) gfx.NjgResult function(gfx.PuppetHandle, float, float);

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

string[] unityLibraryNames() {
    version (Windows) {
        return ["nijilive-unity.dll", "libnijilive-unity.dll"];
    } else version (linux) {
        return ["libnijilive-unity.so", "nijilive-unity.so"];
    } else version (OSX) {
        return ["libnijilive-unity.dylib", "nijilive-unity.dylib"];
    } else {
        return ["libnijilive-unity"];
    }
}

string resolvePuppetPath(string rawPath) {
    if (exists(rawPath)) return rawPath;

    string[] candidates;
    // Common typo: .inxd (directory-like typo) for .inx
    if (rawPath.endsWith(".inxd")) {
        candidates ~= rawPath[0 .. $ - 1]; // -> .inx
    }
    // Also try sibling package formats with same stem.
    if (rawPath.endsWith(".inx") || rawPath.endsWith(".inxd") || rawPath.endsWith(".inp")) {
        auto dot = rawPath.length - 1;
        while (dot > 0 && rawPath[dot] != '.') dot--;
        if (dot > 0) {
            auto stem = rawPath[0 .. dot];
            candidates ~= stem ~ ".inx";
            candidates ~= stem ~ ".inp";
        }
    }

    foreach (c; candidates) {
        if (exists(c)) return c;
    }
    enforce(false, "Puppet file not found: " ~ rawPath ~ " (tried: " ~ candidates.to!string ~ ")");
    return rawPath;
}

void main(string[] args) {
    bool isTest = false;
    string[] positional;
    int framesFlag = -1;
    import core.stdc.stdlib : getenv;
    import std.string : fromStringz;
    import std.conv : to;
    // Defaults for test mode
    int testMaxFrames = 5;
    auto testTimeout = 5.seconds;
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
    string puppetPath = resolvePuppetPath(positional[0]);
    import std.algorithm : all;
    import std.ascii : isDigit;
    bool hasWidth = positional.length > 1 && positional[1].all!isDigit;
    bool hasHeight = positional.length > 2 && positional[2].all!isDigit;
    int width = hasWidth ? positional[1].to!int : 1280;
    int height = hasHeight ? positional[2].to!int : 720;
    // Env overrides for capture/debug
    if (auto p = getenv("NJIV_TEST_FRAMES")) {
        try testMaxFrames = to!int(fromStringz(p)); catch (Exception) {}
    }
    if (framesFlag > 0) testMaxFrames = framesFlag;
    if (auto p = getenv("NJIV_TEST_TIMEOUT_MS")) {
        import core.time : msecs;
        try testTimeout = msecs(to!int(fromStringz(p))); catch (Exception) {}
    }

    writefln("nijiv (%s DLL) start: file=%s, size=%sx%s (test=%s frames=%s timeout=%s)",
        backendName, puppetPath, width, height, isTest, testMaxFrames, testTimeout);

    BackendInit backendInit = void;
    version (EnableVulkanBackend) {
        backendInit = gfx.initVulkanBackend(width, height, isTest);
        scope (exit) {
            if (backendInit.backend !is null) backendInit.backend.dispose();
            if (backendInit.window !is null) SDL_DestroyWindow(backendInit.window);
            SDL_Quit();
        }
        SDL_Vulkan_GetDrawableSize(backendInit.window, &backendInit.drawableW, &backendInit.drawableH);
    } else {
        backendInit = gfx.initOpenGLBackend(width, height, isTest);
        scope (exit) {
            if (backendInit.glContext !is null) SDL_GL_DeleteContext(backendInit.glContext);
            if (backendInit.window !is null) SDL_DestroyWindow(backendInit.window);
            SDL_Quit();
        }
        SDL_GL_GetDrawableSize(backendInit.window, &backendInit.drawableW, &backendInit.drawableH);
    }

    // Load the Unity-facing DLL from a nearby nijilive build.
    string exeDir = getcwd();
    auto libNames = unityLibraryNames();
    string[] libCandidates;
    foreach (name; libNames) {
        libCandidates ~= buildPath(exeDir, name);
        libCandidates ~= buildPath(exeDir, "..", "nijilive", name);
        libCandidates ~= buildPath(exeDir, "..", "..", "nijilive", name);
        libCandidates ~= buildPath("..", "nijilive", name);
    }
    string libPath;
    foreach (c; libCandidates) {
        if (exists(c)) {
            libPath = c;
            break;
        }
    }
    enforce(libPath.length > 0, "Could not find nijilive unity library (searched: "~libCandidates.to!string~")");
    auto api = loadUnityApi(libPath);
    // Do not unload the shared runtime-bound DLL during process lifetime.
    if (api.rtInit !is null) api.rtInit();
    scope (exit) if (api.rtTerm !is null) api.rtTerm();
    api.setLogCallback(&logCallback, null);

    gfx.UnityRendererConfig rendererCfg;
    rendererCfg.viewportWidth = backendInit.drawableW;
    rendererCfg.viewportHeight = backendInit.drawableH;
    gfx.RendererHandle renderer;
    auto createRendererRes = api.createRenderer(&rendererCfg, &backendInit.callbacks, &renderer);
    enforce(createRendererRes == gfx.NjgResult.Ok,
        "njgCreateRenderer failed: " ~ createRendererRes.to!string);

    gfx.PuppetHandle puppet;
    auto loadPuppetRes = api.loadPuppet(renderer, puppetPath.toStringz, &puppet);
    enforce(loadPuppetRes == gfx.NjgResult.Ok,
        "njgLoadPuppet failed: " ~ loadPuppetRes.to!string ~ " path=" ~ puppetPath);
    gfx.FrameConfig frameCfg;
    frameCfg.viewportWidth = backendInit.drawableW;
    frameCfg.viewportHeight = backendInit.drawableH;
    version (EnableVulkanBackend) {
        backendInit.backend.setViewport(backendInit.drawableW, backendInit.drawableH);
    } else {
        currentRenderBackend().setViewport(backendInit.drawableW, backendInit.drawableH);
    }
    float puppetScale = 0.12f;

    // Apply initial scale (default 0.25) so that the view starts zoomed out.
    auto initScaleRes = api.setPuppetScale(puppet, puppetScale, puppetScale);
    if (initScaleRes != gfx.NjgResult.Ok) {
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
                        version (EnableVulkanBackend) {
                            SDL_Vulkan_GetDrawableSize(backendInit.window, &backendInit.drawableW, &backendInit.drawableH);
                            frameCfg.viewportWidth = backendInit.drawableW;
                            frameCfg.viewportHeight = backendInit.drawableH;
                            backendInit.backend.setViewport(backendInit.drawableW, backendInit.drawableH);
                        } else {
                            SDL_GL_GetDrawableSize(backendInit.window, &backendInit.drawableW, &backendInit.drawableH);
                            frameCfg.viewportWidth = backendInit.drawableW;
                            frameCfg.viewportHeight = backendInit.drawableH;
                            currentRenderBackend().setViewport(backendInit.drawableW, backendInit.drawableH);
                        }
                    }
                    break;
                case SDL_MOUSEWHEEL:
                    // Scroll up to zoom in, down to zoom out. Use exponential step.
                    {
                        float step = 0.1f; // ~10% per notch
                        float factor = cast(float)exp(step * -ev.wheel.y);
                        puppetScale = clamp(puppetScale * factor, 0.1f, 10.0f);
                        auto res = api.setPuppetScale(puppet, puppetScale, puppetScale);
                        if (res != gfx.NjgResult.Ok) {
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

        enforce(api.beginFrame(renderer, &frameCfg) == gfx.NjgResult.Ok, "njgBeginFrame failed");
        enforce(api.tickPuppet(puppet, deltaSec) == gfx.NjgResult.Ok, "njgTickPuppet failed");

        gfx.CommandQueueView view;
        enforce(api.emitCommands(renderer, &view) == gfx.NjgResult.Ok, "njgEmitCommands failed");
        if (view.count && frameCount % 60 == 0) {
            writefln("Frame %s: queued commands=%s", frameCount, view.count);
        }

        gfx.SharedBufferSnapshot snapshot;
        enforce(api.getSharedBuffers(renderer, &snapshot) == gfx.NjgResult.Ok, "njgGetSharedBuffers failed");

        gfx.renderCommands(&backendInit, &snapshot, &view);

        api.flushCommands(renderer);
        version (EnableVulkanBackend) {
        } else {
            SDL_GL_SwapWindow(backendInit.window);
        }

        frameCount++;
        if (isTest && frameCount >= testMaxFrames) {
            writefln("Exit after %s frames (test)", frameCount);
            break;
        }
        auto elapsed = now - startTime;
        if (isTest && elapsed > testTimeout) {
            writefln("Exit: elapsed %s > test-timeout %s", elapsed.total!"seconds", testTimeout.total!"seconds");
            break;
        }
    }

    api.unloadPuppet(renderer, puppet);
    api.destroyRenderer(renderer);
}
