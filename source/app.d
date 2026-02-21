module app;

import core.time : MonoTime, Duration, seconds;
import std.conv : to;
import std.exception : enforce;
import std.file : exists, getcwd;
import std.path : buildPath, dirName;
import std.stdio : writeln, writefln, stderr;
import std.string : fromStringz, toStringz, endsWith, toLower;
import std.math : exp;
import std.algorithm : clamp;

version (Windows) {
    import core.sys.windows.windows : HMODULE, GetLastError, GetProcAddress;
    import core.sys.windows.windows : HWND, BOOL, DWORD, LONG, HRGN, HRESULT;
    pragma(lib, "dwmapi");

    struct DWM_BLURBEHIND {
        DWORD dwFlags;
        BOOL fEnable;
        HRGN hRgnBlur;
        BOOL fTransitionOnMaximized;
    }

    struct MARGINS {
        LONG cxLeftWidth;
        LONG cxRightWidth;
        LONG cyTopHeight;
        LONG cyBottomHeight;
    }

    enum DWM_BB_ENABLE = 0x00000001;
    extern (Windows) HRESULT DwmExtendFrameIntoClientArea(HWND hWnd, const(MARGINS)* pMarInset);
    extern (Windows) HRESULT DwmEnableBlurBehindWindow(HWND hWnd, const(DWM_BLURBEHIND)* pBlurBehind);
} else version (Posix) {
    import core.sys.posix.dlfcn : dlsym, dlerror;
}

import bindbc.sdl;

version (EnableVulkanBackend) {
    import gfx = vulkan_backend;
    enum backendName = "vulkan";
    alias BackendInit = gfx.VulkanBackendInit;
} else version (EnableDirectXBackend) {
    import gfx = directx.directx_backend;
    enum backendName = "directx";
    alias BackendInit = gfx.DirectXBackendInit;
} else {
    import bindbc.opengl;
    import gfx = opengl.opengl_backend;
    import opengl.opengl_backend : currentRenderBackend, inClearColor, useColorKeyTransparency;
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

string dynamicLookupError() {
    version (Windows) {
        return "GetProcAddress failed (GetLastError=" ~ to!string(GetLastError()) ~ ")";
    } else version (Posix) {
        auto err = dlerror();
        return err is null ? "dlsym failed" : fromStringz(err).idup;
    } else {
        return "symbol lookup failed";
    }
}

T loadSymbol(T)(void* lib, string name) {
    version (Windows) {
        auto sym = cast(T)GetProcAddress(cast(HMODULE)lib, name.toStringz);
        enforce(sym !is null,
            "Failed to load symbol "~name~
            " from libnijilive-unity: " ~ dynamicLookupError());
        return sym;
    } else version (Posix) {
        auto sym = cast(T)dlsym(lib, name.toStringz);
        enforce(sym !is null,
            "Failed to load symbol "~name~" from libnijilive-unity: " ~ dynamicLookupError());
        return sym;
    } else {
        static assert(false, "Unsupported platform for dynamic symbol loading");
    }
}

T loadOptionalSymbol(T)(void* lib, string name) {
    version (Windows) {
        auto sym = cast(T)GetProcAddress(cast(HMODULE)lib, name.toStringz);
        if (sym is null) {
            writeln("Optional symbol missing: ", name, " (", dynamicLookupError(), ")");
        }
        return sym;
    } else version (Posix) {
        auto sym = cast(T)dlsym(lib, name.toStringz);
        if (sym is null) {
            writeln("Optional symbol missing: ", name, " (", dynamicLookupError(), ")");
        }
        return sym;
    } else {
        static assert(false, "Unsupported platform for dynamic symbol loading");
    }
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
    api.setLogCallback = loadOptionalSymbol!FnSetLogCallback(lib, "njgSetLogCallback");
    api.getSharedBuffers = loadSymbol!FnGetSharedBuffers(lib, "njgGetSharedBuffers");
    api.setPuppetScale = loadOptionalSymbol!FnSetPuppetScale(lib, "njgSetPuppetScale");
    // Explicit runtime init/term provided by DLL.
    api.rtInit = loadOptionalSymbol!FnRtInit(lib, "njgRuntimeInit");
    api.rtTerm = loadOptionalSymbol!FnRtTerm(lib, "njgRuntimeTerm");
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

bool isEnvEnabled(string name) {
    import core.stdc.stdlib : getenv;
    auto p = getenv(name.toStringz);
    if (p is null) return false;
    auto v = fromStringz(p).idup;
    return v == "1" || v == "true" || v == "TRUE";
}

enum ToggleOption {
    Unspecified,
    Enabled,
    Disabled,
}

struct CliOptions {
    bool isTest = false;
    int framesFlag = -1;
    string unityDllFlavor;
    ToggleOption transparentWindow = ToggleOption.Unspecified;
    ToggleOption transparentRetry = ToggleOption.Unspecified;
    ToggleOption transparentDebug = ToggleOption.Unspecified;
    string queueDumpPath;
    string[] positional;
}

private __gshared bool gTransparentDebugLog = false;

private void transparentDebug(string message) {
    if (!gTransparentDebugLog) return;
    stderr.writeln(message);
    stderr.flush();
}

version (Windows) {
    private enum WindowsTransparencyMode {
        ColorKey,
        Dwm,
    }

    private WindowsTransparencyMode windowsTransparencyMode() {
        version (EnableVulkanBackend) {
            // Vulkan + layered colorkey is unstable on Windows (often stays visible as magenta/black).
            return WindowsTransparencyMode.Dwm;
        } else {
            return WindowsTransparencyMode.ColorKey;
        }
    }
}

private bool tryParseEnvBool(string name, out bool value) {
    import core.stdc.stdlib : getenv;
    auto p = getenv(name.toStringz);
    if (p is null) return false;
    auto v = fromStringz(p).idup.toLower();
    if (v == "1" || v == "true" || v == "yes" || v == "on") {
        value = true;
        return true;
    }
    if (v == "0" || v == "false" || v == "no" || v == "off") {
        value = false;
        return true;
    }
    return false;
}

private bool resolveToggle(ToggleOption cliValue, string envName, bool defaultValue) {
    final switch (cliValue) {
        case ToggleOption.Enabled:
            return true;
        case ToggleOption.Disabled:
            return false;
        case ToggleOption.Unspecified:
            bool envValue;
            if (tryParseEnvBool(envName, envValue)) {
                return envValue;
            }
            return defaultValue;
    }
}

private CliOptions parseCliOptions(string[] args) {
    CliOptions out_;
    for (size_t i = 1; i < args.length; ++i) {
        auto arg = args[i];
        if (arg == "--test") {
            out_.isTest = true;
            continue;
        }
        if (arg == "--frames") {
            if (i + 1 < args.length) {
                import std.ascii : isDigit;
                import std.algorithm : all;
                auto maybe = args[i + 1];
                if (maybe.all!isDigit) {
                    out_.framesFlag = maybe.to!int;
                }
                ++i;
            }
            continue;
        }
        if (arg == "--unity-dll") {
            if (i + 1 < args.length) {
                auto flavor = args[i + 1].toLower();
                if (flavor == "nijilive" || flavor == "nicxlive") {
                    out_.unityDllFlavor = flavor;
                }
                ++i;
            }
            continue;
        }
        if (arg == "--transparent-window") {
            out_.transparentWindow = ToggleOption.Enabled;
            continue;
        }
        if (arg == "--no-transparent-window") {
            out_.transparentWindow = ToggleOption.Disabled;
            continue;
        }
        if (arg == "--transparent-window-retry") {
            out_.transparentRetry = ToggleOption.Enabled;
            continue;
        }
        if (arg == "--no-transparent-window-retry") {
            out_.transparentRetry = ToggleOption.Disabled;
            continue;
        }
        if (arg == "--transparent-debug") {
            out_.transparentDebug = ToggleOption.Enabled;
            continue;
        }
        if (arg == "--no-transparent-debug") {
            out_.transparentDebug = ToggleOption.Disabled;
            continue;
        }
        if (arg == "--queue-dump") {
            if (i + 1 < args.length) {
                out_.queueDumpPath = args[i + 1];
                ++i;
            }
            continue;
        }
        out_.positional ~= arg;
    }
    return out_;
}

private string commandKindName(gfx.NjgRenderCommandKind kind) {
    switch (kind) {
        case gfx.NjgRenderCommandKind.DrawPart: return "DrawPart";
        case gfx.NjgRenderCommandKind.BeginDynamicComposite: return "BeginDynamicComposite";
        case gfx.NjgRenderCommandKind.EndDynamicComposite: return "EndDynamicComposite";
        case gfx.NjgRenderCommandKind.BeginMask: return "BeginMask";
        case gfx.NjgRenderCommandKind.ApplyMask: return "ApplyMask";
        case gfx.NjgRenderCommandKind.BeginMaskContent: return "BeginMaskContent";
        case gfx.NjgRenderCommandKind.EndMask: return "EndMask";
        default: return "Unknown(" ~ to!string(cast(uint)kind) ~ ")";
    }
}

private ulong hashFloatSlice(const(float)* ptr, size_t len) {
    ulong h = 1469598103934665603UL;
    if (ptr is null) return h;
    foreach (i; 0 .. len) {
        auto bits = *cast(const(uint)*)(&ptr[i]);
        h ^= cast(ulong)bits;
        h *= 1099511628211UL;
    }
    return h;
}

private void dumpQueueFrame(string path, string dllFlavor, int frameIndex,
                            const gfx.SharedBufferSnapshot* snapshot,
                            const gfx.CommandQueueView* view) {
    import std.format : format;
    import std.stdio : File;

    if (path.length == 0 || snapshot is null || view is null) return;
    if (frameIndex == 0) {
        File(path, "w").close();
    }

    const auto vhash = hashFloatSlice(snapshot.vertices.data, snapshot.vertices.length);
    const auto uhash = hashFloatSlice(snapshot.uvs.data, snapshot.uvs.length);
    const auto dhash = hashFloatSlice(snapshot.deform.data, snapshot.deform.length);
    ulong mhDraw = 1469598103934665603UL;
    ulong mhMask = 1469598103934665603UL;

    string dumpText;
    dumpText ~= format("DLL_FLAVOR %s\n", dllFlavor);
    dumpText ~= format("FRAME %s count=%s vertices=%s uvs=%s deform=%s\n",
        frameIndex, view.count, snapshot.vertexCount, snapshot.uvCount, snapshot.deformCount);
    dumpText ~= format("HASH v=%s u=%s d=%s\n", vhash, uhash, dhash);

    auto cmds = view.commands[0 .. view.count];
    foreach (i, cmd; cmds) {
        dumpText ~= format("CMD %s kind=%s", i, commandKindName(cmd.kind));
        if (cmd.kind == gfx.NjgRenderCommandKind.DrawPart) {
            const auto p = cmd.partPacket;
            mhDraw ^= hashFloatSlice(p.modelMatrix.ptr, 16);
            mhDraw *= 1099511628211UL;
            mhDraw ^= hashFloatSlice(p.renderMatrix.ptr, 16);
            mhDraw *= 1099511628211UL;
            dumpText ~= format(" vo=%s uo=%s do=%s idx=%s vtx=%s",
                p.vertexOffset, p.uvOffset, p.deformOffset, p.indexCount, p.vertexCount);
            if (p.vertexCount > 0 &&
                p.vertexOffset < snapshot.vertices.length &&
                p.uvOffset < snapshot.uvs.length &&
                p.deformOffset < snapshot.deform.length) {
                const float vx = snapshot.vertices.data[p.vertexOffset];
                const float vy = (p.vertexOffset + snapshot.vertexCount) < snapshot.vertices.length
                    ? snapshot.vertices.data[p.vertexOffset + snapshot.vertexCount] : 0.0f;
                const float ux = snapshot.uvs.data[p.uvOffset];
                const float uy = (p.uvOffset + snapshot.uvCount) < snapshot.uvs.length
                    ? snapshot.uvs.data[p.uvOffset + snapshot.uvCount] : 0.0f;
                const float dx = snapshot.deform.data[p.deformOffset];
                const float dy = (p.deformOffset + snapshot.deformCount) < snapshot.deform.length
                    ? snapshot.deform.data[p.deformOffset + snapshot.deformCount] : 0.0f;
                dumpText ~= format(" sample v0=(%s,%s) uv0=(%s,%s) d0=(%s,%s)", vx, vy, ux, uy, dx, dy);
            }
        } else if (cmd.kind == gfx.NjgRenderCommandKind.ApplyMask) {
            const auto m = cmd.maskApplyPacket;
            if (m.kind == gfx.MaskDrawableKind.Part) {
                mhMask ^= hashFloatSlice(m.partPacket.modelMatrix.ptr, 16);
                mhMask *= 1099511628211UL;
                mhMask ^= hashFloatSlice(m.partPacket.renderMatrix.ptr, 16);
                mhMask *= 1099511628211UL;
            }
        }
        dumpText ~= "\n";
    }
    dumpText ~= format("HASH_MAT draw=%s mask=%s\n", mhDraw, mhMask);
    dumpText ~= "\n";
    auto f = File(path, "a");
    f.write(dumpText);
    f.close();
}

void configureTransparentWindow(SDL_Window* window) {
    if (window is null) {
        transparentDebug("[transparent] skipped: window is null");
        return;
    }

    version (Windows) {
        import bindbc.sdl.bind.sdlsyswm : SDL_SysWMinfo, SDL_GetWindowWMInfo;
        import bindbc.sdl.bind.sdlversion : SDL_VERSION;
        import core.sys.windows.windows : HWND, BOOL, BYTE, DWORD, LONG_PTR, HRGN, HRESULT,
            GWL_EXSTYLE, WS_EX_LAYERED, LWA_ALPHA, LWA_COLORKEY,
            GetWindowLongPtrW, SetWindowLongPtrW, SetLayeredWindowAttributes;
        auto mode = windowsTransparencyMode();
        bool defaultDwmBlurBehind = false;
        version (EnableVulkanBackend) {
            defaultDwmBlurBehind = true;
        }
        bool useDwmBlurBehind = (mode == WindowsTransparencyMode.Dwm) &&
            resolveToggle(ToggleOption.Unspecified, "NJIV_WINDOWS_BLUR_BEHIND", defaultDwmBlurBehind);

        SDL_SysWMinfo info = SDL_SysWMinfo.init;
        SDL_VERSION(&info.version_);
        if (SDL_GetWindowWMInfo(window, &info) == SDL_TRUE &&
            info.subsystem == SDL_SYSWM_TYPE.SDL_SYSWM_WINDOWS) {
            auto hwnd = cast(HWND)info.info.win.window;
            if (mode == WindowsTransparencyMode.ColorKey) {
                auto exStyle = cast(LONG_PTR)GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
                auto nextStyle = exStyle | WS_EX_LAYERED;
                if (nextStyle != exStyle) {
                    SetWindowLongPtrW(hwnd, GWL_EXSTYLE, nextStyle);
                }
                // RGB(255, 0, 255) becomes fully transparent. Use full-intensity key to avoid
                // colorspace/quantization mismatches (notably Vulkan + sRGB swapchains).
                DWORD colorKey = (cast(DWORD)255 << 16) | cast(DWORD)255;
                SetLayeredWindowAttributes(hwnd, colorKey, cast(BYTE)255, LWA_COLORKEY);
                transparentDebug("[transparent] windows: applied layered colorkey mode");
            } else {
                // DWM mode: avoid layered colorkey path, let compositor use swapchain alpha.
                auto exStyle = cast(LONG_PTR)GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
                auto nextStyle = exStyle & ~cast(LONG_PTR)WS_EX_LAYERED;
                if (nextStyle != exStyle) {
                    SetWindowLongPtrW(hwnd, GWL_EXSTYLE, nextStyle);
                }
                // Extend frame over the whole client area so backbuffer alpha can be composed.
                MARGINS margins = MARGINS.init;
                margins.cxLeftWidth = -1;
                margins.cxRightWidth = -1;
                margins.cyTopHeight = -1;
                margins.cyBottomHeight = -1;
                DwmExtendFrameIntoClientArea(hwnd, &margins);
            }

            if (mode == WindowsTransparencyMode.Dwm && useDwmBlurBehind) {
                DWM_BLURBEHIND bb = DWM_BLURBEHIND.init;
                bb.dwFlags = DWM_BB_ENABLE;
                bb.fEnable = 1;
                DwmEnableBlurBehindWindow(hwnd, &bb);
                transparentDebug("[transparent] windows: applied layered + dwm blur-behind");
            } else if (mode == WindowsTransparencyMode.Dwm) {
                transparentDebug("[transparent] windows: applied layered alpha-only (no DWM blur)");
            }
        }
    } else version (OSX) {
        import bindbc.sdl.bind.sdlsyswm : SDL_SysWMinfo, SDL_GetWindowWMInfo;
        import bindbc.sdl.bind.sdlversion : SDL_VERSION;
        import core.sys.posix.dlfcn : dlopen, dlsym, RTLD_NOW, RTLD_LOCAL;

        alias ObjcId = void*;
        alias ObjcSel = void*;
        alias ObjcBool = byte;
        alias ObjcGetClassFn = extern(C) ObjcId function(const(char)*);
        alias ObjcRegisterSelFn = extern(C) ObjcSel function(const(char)*);
        alias MsgSendIdFn = extern(C) ObjcId function(ObjcId, ObjcSel);
        alias MsgSendBoolFn = extern(C) void function(ObjcId, ObjcSel, ObjcBool);
        alias MsgSendObjFn = extern(C) void function(ObjcId, ObjcSel, ObjcId);
        alias MsgSendULongFn = extern(C) ulong function(ObjcId, ObjcSel);
        alias MsgSendIndexObjFn = extern(C) ObjcId function(ObjcId, ObjcSel, ulong);
        alias MsgSendBoolSelFn = extern(C) ObjcBool function(ObjcId, ObjcSel, ObjcSel);
        alias MsgSendSetValuesFn = extern(C) void function(ObjcId, ObjcSel, const(int)*, int);

        auto objcHandle = dlopen("/usr/lib/libobjc.A.dylib".toStringz, RTLD_NOW | RTLD_LOCAL);
        if (objcHandle is null) {
            transparentDebug("[transparent] macOS: failed to open /usr/lib/libobjc.A.dylib");
            return;
        }

        auto objcGetClass = cast(ObjcGetClassFn)dlsym(objcHandle, "objc_getClass".toStringz);
        auto selRegisterName = cast(ObjcRegisterSelFn)dlsym(objcHandle, "sel_registerName".toStringz);
        auto objcMsgSendRaw = dlsym(objcHandle, "objc_msgSend".toStringz);
        if (objcGetClass is null || selRegisterName is null || objcMsgSendRaw is null) {
            transparentDebug("[transparent] macOS: objc runtime symbols not found");
            return;
        }

        auto msgSendId = cast(MsgSendIdFn)objcMsgSendRaw;
        auto msgSendBool = cast(MsgSendBoolFn)objcMsgSendRaw;
        auto msgSendObj = cast(MsgSendObjFn)objcMsgSendRaw;
        auto msgSendULong = cast(MsgSendULongFn)objcMsgSendRaw;
        auto msgSendIndexObj = cast(MsgSendIndexObjFn)objcMsgSendRaw;
        auto msgSendBoolSel = cast(MsgSendBoolSelFn)objcMsgSendRaw;
        auto msgSendSetValues = cast(MsgSendSetValuesFn)objcMsgSendRaw;

        SDL_SysWMinfo info = SDL_SysWMinfo.init;
        SDL_VERSION(&info.version_);
        if (SDL_GetWindowWMInfo(window, &info) != SDL_TRUE ||
            info.subsystem != SDL_SYSWM_TYPE.SDL_SYSWM_COCOA) {
            transparentDebug("[transparent] macOS: SDL_GetWindowWMInfo failed or non-COCOA subsystem=" ~ (cast(int)info.subsystem).to!string);
            return;
        }

        auto nsWindow = cast(ObjcId)info.info.cocoa.window;
        if (nsWindow is null) {
            transparentDebug("[transparent] macOS: nsWindow is null");
            return;
        }

        auto nsColorClass = objcGetClass("NSColor".toStringz);
        if (nsColorClass is null) {
            transparentDebug("[transparent] macOS: NSColor class not found");
            return;
        }

        auto selClearColor = selRegisterName("clearColor".toStringz);
        auto selCGColor = selRegisterName("CGColor".toStringz);
        auto selContentView = selRegisterName("contentView".toStringz);
        auto selSubviews = selRegisterName("subviews".toStringz);
        auto selCount = selRegisterName("count".toStringz);
        auto selObjectAtIndex = selRegisterName("objectAtIndex:".toStringz);
        auto selLayer = selRegisterName("layer".toStringz);
        auto selSublayers = selRegisterName("sublayers".toStringz);
        auto selSetWantsLayer = selRegisterName("setWantsLayer:".toStringz);
        auto selSetOpaque = selRegisterName("setOpaque:".toStringz);
        auto selSetBackgroundColor = selRegisterName("setBackgroundColor:".toStringz);
        auto selSetHasShadow = selRegisterName("setHasShadow:".toStringz);
        auto selOpenGLContext = selRegisterName("openGLContext".toStringz);
        auto selSetValuesForParameter = selRegisterName("setValues:forParameter:".toStringz);
        auto selRespondsToSelector = selRegisterName("respondsToSelector:".toStringz);
        if (selClearColor is null || selCGColor is null ||
            selContentView is null || selSubviews is null || selCount is null || selObjectAtIndex is null ||
            selLayer is null || selSublayers is null ||
            selSetWantsLayer is null || selSetOpaque is null ||
            selSetBackgroundColor is null || selSetHasShadow is null ||
            selOpenGLContext is null || selSetValuesForParameter is null || selRespondsToSelector is null) {
            transparentDebug("[transparent] macOS: selector lookup failed");
            return;
        }

        auto clearColor = msgSendId(nsColorClass, selClearColor);
        if (clearColor is null) {
            transparentDebug("[transparent] macOS: [NSColor clearColor] returned null");
            return;
        }
        auto clearCg = msgSendId(clearColor, selCGColor);

        msgSendBool(nsWindow, selSetOpaque, cast(ObjcBool)0);
        msgSendObj(nsWindow, selSetBackgroundColor, clearColor);
        // Shadow darkens transparent edge pixels; disable by default.
        msgSendBool(nsWindow, selSetHasShadow, cast(ObjcBool)0);

        size_t touchedViews = 0;
        size_t touchedLayers = 0;

        void applyLayerTreeTransparency(ObjcId layer) {
            if (layer is null) return;
            touchedLayers++;
            msgSendBool(layer, selSetOpaque, cast(ObjcBool)0);
            if (clearCg !is null) {
                msgSendObj(layer, selSetBackgroundColor, clearCg);
            }
            auto sublayers = msgSendId(layer, selSublayers);
            if (sublayers is null) return;
            auto subCount = msgSendULong(sublayers, selCount);
            foreach (i; 0 .. subCount) {
                auto sublayer = msgSendIndexObj(sublayers, selObjectAtIndex, cast(ulong)i);
                applyLayerTreeTransparency(sublayer);
            }
        }

        auto applyViewTransparency = (ObjcId view) {
            if (view is null) return;
            touchedViews++;
            msgSendBool(view, selSetWantsLayer, cast(ObjcBool)1);
            msgSendBool(view, selSetOpaque, cast(ObjcBool)0);
            auto layer = msgSendId(view, selLayer);
            applyLayerTreeTransparency(layer);
        };

        auto contentView = msgSendId(nsWindow, selContentView);
        applyViewTransparency(contentView);
        if (contentView !is null) {
            auto subviews = msgSendId(contentView, selSubviews);
            if (subviews !is null) {
                auto subCount = msgSendULong(subviews, selCount);
                foreach (i; 0 .. subCount) {
                    auto subview = msgSendIndexObj(subviews, selObjectAtIndex, cast(ulong)i);
                    applyViewTransparency(subview);
                }
            }
        }

        // OpenGL path only: request non-opaque context surface explicitly when available.
        version (EnableVulkanBackend) {
        } else {
            if (contentView !is null) {
                auto hasOpenGLContext = msgSendBoolSel(contentView, selRespondsToSelector, selOpenGLContext);
                if (hasOpenGLContext != 0) {
                    auto glctx = msgSendId(contentView, selOpenGLContext);
                    if (glctx !is null) {
                        enum NSOpenGLCPSurfaceOpacity = 236;
                        int zero = 0;
                        msgSendSetValues(glctx, selSetValuesForParameter, &zero, NSOpenGLCPSurfaceOpacity);
                    }
                }
            }
        }

        transparentDebug("[transparent] macOS: applied non-opaque settings views=" ~ touchedViews.to!string ~ " layers=" ~ touchedLayers.to!string);
    } else version (linux) {
        import bindbc.sdl.bind.sdlsyswm : SDL_SysWMinfo, SDL_GetWindowWMInfo;
        import bindbc.sdl.bind.sdlversion : SDL_VERSION;
        import core.stdc.stdint : uint32_t;
        import core.sys.posix.dlfcn : dlopen, dlsym, RTLD_NOW, RTLD_LOCAL;

        alias XDisplay = void;
        alias XWindow = ulong;
        alias XAtom = ulong;
        alias XBool = int;

        alias XInternAtomFn = XAtom function(XDisplay* display, const(char)* atom_name, XBool only_if_exists);
        alias XChangePropertyFn = int function(XDisplay* display,
                                               XWindow w,
                                               XAtom property,
                                               XAtom type,
                                               int format,
                                               int mode,
                                               const(ubyte)* data,
                                               int nelements);
        alias XFlushFn = int function(XDisplay* display);

        enum PropModeReplace = 0;

        SDL_SysWMinfo info = SDL_SysWMinfo.init;
        SDL_VERSION(&info.version_);
        if (SDL_GetWindowWMInfo(window, &info) != SDL_TRUE ||
            info.subsystem != SDL_SYSWM_TYPE.SDL_SYSWM_X11) {
            return;
        }

        auto x11 = dlopen("libX11.so.6".toStringz, RTLD_NOW | RTLD_LOCAL);
        if (x11 is null) return;

        auto xInternAtom = cast(XInternAtomFn)dlsym(x11, "XInternAtom".toStringz);
        auto xChangeProperty = cast(XChangePropertyFn)dlsym(x11, "XChangeProperty".toStringz);
        auto xFlush = cast(XFlushFn)dlsym(x11, "XFlush".toStringz);
        if (xInternAtom is null || xChangeProperty is null || xFlush is null) return;

        auto display = cast(XDisplay*)info.info.x11.display;
        auto xwindow = cast(XWindow)info.info.x11.window;
        if (display is null || xwindow == 0) return;

        auto atomCardinal = xInternAtom(display, "CARDINAL".toStringz, 0);
        if (atomCardinal == 0) return;

        // Explicitly keep compositor path enabled so alpha visuals are respected.
        auto atomBypass = xInternAtom(display, "_NET_WM_BYPASS_COMPOSITOR".toStringz, 0);
        if (atomBypass != 0) {
            uint32_t bypass = 0;
            xChangeProperty(display,
                            xwindow,
                            atomBypass,
                            atomCardinal,
                            32,
                            PropModeReplace,
                            cast(const(ubyte)*)&bypass,
                            1);
        }

        // Keep whole-window opacity at 1.0; per-pixel alpha still comes from rendering.
        auto atomOpacity = xInternAtom(display, "_NET_WM_WINDOW_OPACITY".toStringz, 0);
        if (atomOpacity != 0) {
            uint32_t opacity = uint32_t.max;
            xChangeProperty(display,
                            xwindow,
                            atomOpacity,
                            atomCardinal,
                            32,
                            PropModeReplace,
                            cast(const(ubyte)*)&opacity,
                            1);
        }

        xFlush(display);
        transparentDebug("[transparent] linux-x11: applied compositor/opacity window properties");
    }
}

void main(string[] args) {
    auto cli = parseCliOptions(args);
    bool isTest = cli.isTest;
    string[] positional = cli.positional;
    int framesFlag = cli.framesFlag;
    import core.stdc.stdlib : getenv;
    import std.string : fromStringz;
    import std.conv : to;
    // Defaults for test mode
    int testMaxFrames = 5;
    auto testTimeout = 5.seconds;
    if (positional.length < 1) {
        writeln("Usage: nijiv <puppet.inp|puppet.inx> [width height] [--test] [--frames N] [--unity-dll nijilive|nicxlive] [--queue-dump PATH] [--transparent-window|--no-transparent-window] [--transparent-window-retry|--no-transparent-window-retry] [--transparent-debug]");
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
    gTransparentDebugLog = resolveToggle(cli.transparentDebug, "NJIV_TRANSPARENT_DEBUG", false);
    bool transparentWindowEnabled = resolveToggle(cli.transparentWindow, "NJIV_TRANSPARENT_WINDOW", true);
    bool transparentWindowRetry = resolveToggle(cli.transparentRetry, "NJIV_TRANSPARENT_WINDOW_RETRY", true);
    version (Windows) {
        version (EnableDirectXBackend) {
        } else {
            version (EnableVulkanBackend) {
                if (windowsTransparencyMode() == WindowsTransparencyMode.ColorKey) {
                    // Match Windows colorkey (RGB 255,0,255) so background pixels become fully transparent.
                    gfx.inClearColor = typeof(gfx.inClearColor)(1.0f, 0.0f, 1.0f, 1.0f);
                } else {
                    // DWM composition path expects transparent background in swapchain.
                    gfx.inClearColor = typeof(gfx.inClearColor)(0.0f, 0.0f, 0.0f, 0.0f);
                }
            } else {
                // OpenGL colorkey path: keep offscreen transparent; convert to colorkey only at present pass.
                inClearColor = typeof(inClearColor)(0.0f, 0.0f, 0.0f, 0.0f);
                useColorKeyTransparency = (windowsTransparencyMode() == WindowsTransparencyMode.ColorKey);
            }
        }
    }

    writefln("nijiv (%s DLL) start: file=%s, size=%sx%s (test=%s frames=%s timeout=%s)",
        backendName, puppetPath, width, height, isTest, testMaxFrames, testTimeout);
    version (Windows) {
        auto mode = windowsTransparencyMode();
        writefln("Windows transparency mode: %s", mode == WindowsTransparencyMode.ColorKey ? "colorkey" : "dwm");
    }
    transparentDebug("[transparent] option enabled=" ~ transparentWindowEnabled.to!string ~ " retry=" ~ transparentWindowRetry.to!string);

    BackendInit backendInit = void;
    version (EnableVulkanBackend) {
        backendInit = gfx.initVulkanBackend(width, height, isTest);
        scope (exit) {
            if (backendInit.backend !is null) backendInit.backend.dispose();
            if (backendInit.window !is null) SDL_DestroyWindow(backendInit.window);
            SDL_Quit();
        }
        SDL_Vulkan_GetDrawableSize(backendInit.window, &backendInit.drawableW, &backendInit.drawableH);
    } else version (EnableDirectXBackend) {
        backendInit = gfx.initDirectXBackend(width, height, isTest);
        scope (exit) {
            if (backendInit.backend !is null) backendInit.backend.dispose();
            if (backendInit.window !is null) SDL_DestroyWindow(backendInit.window);
            SDL_Quit();
        }
        SDL_GetWindowSize(backendInit.window, &backendInit.drawableW, &backendInit.drawableH);
    } else {
        backendInit = gfx.initOpenGLBackend(width, height, isTest);
        scope (exit) {
            if (backendInit.glContext !is null) SDL_GL_DeleteContext(backendInit.glContext);
            if (backendInit.window !is null) SDL_DestroyWindow(backendInit.window);
            SDL_Quit();
        }
        SDL_GL_GetDrawableSize(backendInit.window, &backendInit.drawableW, &backendInit.drawableH);
    }

    bool canApplyTransparentWindow = transparentWindowEnabled;
    version (Windows) {
        version (EnableVulkanBackend) {
            if (transparentWindowEnabled && !backendInit.backend.supportsPerPixelTransparency()) {
                writeln("[transparent] windows+vulkan: swapchain composite alpha is OPAQUE; skip transparent window setup.");
                canApplyTransparentWindow = false;
            }
        }
    }
    if (canApplyTransparentWindow) {
        configureTransparentWindow(backendInit.window);
    }
    bool transparencyRetryPending = canApplyTransparentWindow && transparentWindowRetry;

    // Resolve Unity-facing DLL flavor.
    string unityFlavor = cli.unityDllFlavor;
    if (unityFlavor.length == 0) {
        if (auto p = getenv("NJIV_UNITY_DLL")) {
            auto envFlavor = fromStringz(p).idup.toLower();
            if (envFlavor == "nijilive" || envFlavor == "nicxlive") {
                unityFlavor = envFlavor;
            }
        }
    }
    if (unityFlavor.length == 0) {
        unityFlavor = "nicxlive";
    }

    // Load the Unity-facing DLL from nearby build outputs.
    string exeDir = getcwd();
    string[] libNames;
    if (unityFlavor == "nicxlive") {
        version (Windows) {
            libNames = ["nicxlive.dll"];
        } else version (linux) {
            libNames = ["libnicxlive.so", "nicxlive.so"];
        } else version (OSX) {
            libNames = ["libnicxlive.dylib", "nicxlive.dylib"];
        } else {
            libNames = ["libnicxlive"];
        }
    } else {
        libNames = unityLibraryNames();
    }
    string[] libCandidates;
    foreach (name; libNames) {
        libCandidates ~= buildPath(exeDir, name);
        if (unityFlavor == "nicxlive") {
            libCandidates ~= buildPath(exeDir, "..", "nicxlive", "build", "Debug", name);
            libCandidates ~= buildPath(exeDir, "..", "..", "nicxlive", "build", "Debug", name);
            libCandidates ~= buildPath("..", "nicxlive", "build", "Debug", name);
        } else {
            libCandidates ~= buildPath(exeDir, "..", "nijilive", name);
            libCandidates ~= buildPath(exeDir, "..", "..", "nijilive", name);
            libCandidates ~= buildPath("..", "nijilive", name);
        }
    }
    string libPath;
    foreach (c; libCandidates) {
        if (exists(c)) {
            libPath = c;
            break;
        }
    }
    enforce(libPath.length > 0, "Could not find unity library for flavor=" ~ unityFlavor ~ " (searched: "~libCandidates.to!string~")");
    writefln("[unity] flavor=%s path=%s", unityFlavor, libPath);
    auto api = loadUnityApi(libPath);
    // Do not unload the shared runtime-bound DLL during process lifetime.
    if (api.rtInit !is null) api.rtInit();
    if (api.setLogCallback !is null) {
        api.setLogCallback(&logCallback, null);
    }

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
    } else version (EnableDirectXBackend) {
        backendInit.backend.setViewport(backendInit.drawableW, backendInit.drawableH);
    } else {
        currentRenderBackend().setViewport(backendInit.drawableW, backendInit.drawableH);
    }
    float puppetScale = 0.12f;

    // Apply initial scale (default 0.25) so that the view starts zoomed out.
    if (api.setPuppetScale !is null) {
        auto initScaleRes = api.setPuppetScale(puppet, puppetScale, puppetScale);
        if (initScaleRes != gfx.NjgResult.Ok) {
            writeln("njgSetPuppetScale initial apply failed: ", initScaleRes);
        }
    }

    bool autoWheel = isEnvEnabled("NJIV_AUTO_WHEEL");
    int autoWheelInterval = 3;
    if (auto p = getenv("NJIV_AUTO_WHEEL_INTERVAL")) {
        try {
            autoWheelInterval = to!int(fromStringz(p));
        } catch (Exception) {}
    }
    if (autoWheelInterval <= 0) autoWheelInterval = 3;
    int autoWheelPhaseTicks = 18;
    if (auto p = getenv("NJIV_AUTO_WHEEL_PHASE_TICKS")) {
        try {
            autoWheelPhaseTicks = to!int(fromStringz(p));
        } catch (Exception) {}
    }
    if (autoWheelPhaseTicks <= 0) autoWheelPhaseTicks = 18;
    int autoWheelY = 1;
    int autoWheelPhaseCount = 0;
    if (autoWheel) {
        writefln("Auto wheel enabled: interval=%s phaseTicks=%s startY=%s",
            autoWheelInterval, autoWheelPhaseTicks, autoWheelY);
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
                        } else version (EnableDirectXBackend) {
                            SDL_GetWindowSize(backendInit.window, &backendInit.drawableW, &backendInit.drawableH);
                            frameCfg.viewportWidth = backendInit.drawableW;
                            frameCfg.viewportHeight = backendInit.drawableH;
                            backendInit.backend.setViewport(backendInit.drawableW, backendInit.drawableH);
                        } else {
                            SDL_GL_GetDrawableSize(backendInit.window, &backendInit.drawableW, &backendInit.drawableH);
                            frameCfg.viewportWidth = backendInit.drawableW;
                            frameCfg.viewportHeight = backendInit.drawableH;
                            currentRenderBackend().setViewport(backendInit.drawableW, backendInit.drawableH);
                        }
                        if (canApplyTransparentWindow) {
                            // SDL may recreate native view/layer objects on resize.
                            // Re-apply transparency settings to keep alpha compositing active.
                            configureTransparentWindow(backendInit.window);
                        }
                    }
                    break;
                case SDL_MOUSEWHEEL:
                    // Scroll up to zoom in, down to zoom out. Use exponential step.
                    {
                        float step = 0.1f; // ~10% per notch
                        float factor = cast(float)exp(step * -ev.wheel.y);
                        puppetScale = clamp(puppetScale * factor, 0.1f, 10.0f);
                        if (api.setPuppetScale !is null) {
                            auto res = api.setPuppetScale(puppet, puppetScale, puppetScale);
                            if (res != gfx.NjgResult.Ok) {
                                writeln("njgSetPuppetScale failed: ", res);
                            }
                        }
                    }
                    break;
                default:
                    break;
            }
        }
        if (!running) {
            break;
        }

        if (autoWheel && api.setPuppetScale !is null && frameCount > 0 &&
            (frameCount % autoWheelInterval) == 0) {
            int wheelY = autoWheelY;
            autoWheelPhaseCount++;
            if (autoWheelPhaseCount >= autoWheelPhaseTicks) {
                autoWheelPhaseCount = 0;
                autoWheelY = -autoWheelY;
            }
            // Match SDL_MOUSEWHEEL handling path exactly.
            float step = 0.1f;
            float factor = cast(float)exp(step * -wheelY);
            puppetScale = clamp(puppetScale * factor, 0.1f, 10.0f);
            auto res = api.setPuppetScale(puppet, puppetScale, puppetScale);
            writefln("Auto wheel frame=%s -> wheelY=%s scale=%s res=%s",
                frameCount, wheelY, puppetScale, res);
        }

        MonoTime now = MonoTime.currTime;
        Duration delta = now - prev;
        prev = now;
        double deltaSec = delta.total!"nsecs" / 1_000_000_000.0;

        enforce(api.beginFrame(renderer, &frameCfg) == gfx.NjgResult.Ok, "njgBeginFrame failed");
        enforce(api.tickPuppet(puppet, deltaSec) == gfx.NjgResult.Ok, "njgTickPuppet failed");

        gfx.CommandQueueView view;
        enforce(api.emitCommands(renderer, &view) == gfx.NjgResult.Ok, "njgEmitCommands failed");
        gfx.SharedBufferSnapshot snapshot;
        enforce(api.getSharedBuffers(renderer, &snapshot) == gfx.NjgResult.Ok, "njgGetSharedBuffers failed");
        dumpQueueFrame(cli.queueDumpPath, unityFlavor, frameCount, &snapshot, &view);

        gfx.renderCommands(&backendInit, &snapshot, &view);

        // Some SDL backends create/replace native subviews lazily after first render.
        // Re-apply transparency once to catch late-created view/layer objects.
        if (transparencyRetryPending) {
            configureTransparentWindow(backendInit.window);
            transparencyRetryPending = false;
        }

        if (isEnvEnabled("NJIV_SKIP_FLUSH")) {
        } else {
            api.flushCommands(renderer);
        }
        version (EnableVulkanBackend) {
        } else version (EnableDirectXBackend) {
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

    version (EnableDirectXBackend) {
        gfx.shutdownDirectXBackend(backendInit);
    }

    api.unloadPuppet(renderer, puppet);
    api.destroyRenderer(renderer);
    // Keep DLL runtime alive until process exit to avoid shutdown-order crashes.

    version (EnableDirectXBackend) {
        import core.stdc.stdlib : _Exit;
        _Exit(0);
    } else version (EnableVulkanBackend) {
        import core.stdc.stdlib : _Exit;
        _Exit(0);
    }
}
