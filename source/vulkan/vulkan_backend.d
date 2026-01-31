module vulkan_backend;

version (EnableVulkanBackend) {

import std.exception : enforce;
import std.string : fromStringz, toStringz;
import std.conv : to;
import std.process : environment;
import std.algorithm : canFind;
import std.stdio : writefln;

import bindbc.sdl;
import bindbc.sdl.bind.sdlvulkan;
import bindbc.sdl.dynload : loadedSDLVersion;
import erupted.types;

import nijilive.core.render.backends : BackendEnum;
import nijilive.core.render.backends.vulkan : RenderingBackend;
import nijilive.core.runtime_state : inSetRenderBackend, inSetViewport;
import nijilive : inInit;

struct VulkanBackendInit {
    SDL_Window* window;
    RenderingBackend!(BackendEnum.Vulkan) backend;
    int drawableW;
    int drawableH;
}

string sdlError() {
    auto err = SDL_GetError();
    return err is null ? "" : fromStringz(err).idup;
}

/// Initialize SDL, load Vulkan loader, create window, and return a configured backend + drawable size.
VulkanBackendInit initVulkanBackend(int width, int height, bool isTest) {
    auto support = loadSDL();
    if (support == SDLSupport.noLibrary || support == SDLSupport.badLibrary) {
        // Common Homebrew path on macOS
        support = loadSDL("/opt/homebrew/lib/libSDL2-2.0.0.dylib");
    }
    enforce(support >= SDLSupport.sdl206,
        "Failed to load SDL2 or version too old for Vulkan (loaded="~loadedSDLVersion().to!string~")");
    enforce(SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS) == 0, "SDL_Init failed: "~sdlError());

    string vkLibLoaded;
    string[] vkCandidates;
    auto sdk = environment.get("VULKAN_SDK", null);
    if (sdk.length) {
        vkCandidates ~= sdk ~ "/lib/libvulkan.1.dylib";
        vkCandidates ~= sdk ~ "/lib/libvulkan.dylib";
        vkCandidates ~= sdk ~ "/Frameworks/libvulkan.1.dylib";
    }
    vkCandidates ~= "/Applications/VulkanSDK/macOS/lib/libvulkan.1.dylib";
    vkCandidates ~= "/Applications/VulkanSDK/macOS/lib/libvulkan.dylib";
    vkCandidates ~= "/Applications/VulkanSDK/lib/libvulkan.1.dylib";
    vkCandidates ~= "/opt/homebrew/lib/libvulkan.1.dylib";
    vkCandidates ~= "/usr/local/lib/libvulkan.1.dylib";

    foreach (path; vkCandidates) {
        if (SDL_Vulkan_LoadLibrary(path.toStringz()) == 0) {
            vkLibLoaded = path;
            break;
        }
    }
    if (!vkLibLoaded.length) {
        // Fallback: let SDL try system default if not already loaded
        SDL_Vulkan_UnloadLibrary();
        SDL_Vulkan_LoadLibrary(null);
    }
    writefln("Vulkan loader: %s", vkLibLoaded.length ? vkLibLoaded : "(SDL default)");

    auto window = SDL_CreateWindow("nijiv",
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        width, height,
        SDL_WINDOW_VULKAN | SDL_WINDOW_RESIZABLE | SDL_WINDOW_ALLOW_HIGHDPI | SDL_WINDOW_SHOWN);
    enforce(window !is null, "SDL_CreateWindow failed: "~sdlError());

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
    version(OSX) {
        // MoltenVK portability requires this extension + flag
        if (!extNames.canFind("VK_KHR_portability_enumeration")) {
            extNames ~= "VK_KHR_portability_enumeration";
        }
    }
    writefln("Instance extensions: %s", extNames);

    auto backend = new RenderingBackend!(BackendEnum.Vulkan)();
    backend.setInstanceExtensions(extNames);
    version(OSX) {
        string[] devExts = ["VK_KHR_swapchain", "VK_KHR_portability_subset"];
        backend.setDeviceExtensions(devExts);
    }
    backend.setTestMode(isTest);
    inSetRenderBackend(backend);
    inInit(() => SDL_GetTicks() / 1000.0);

    VkSurfaceKHR surface = VK_NULL_HANDLE;
    enforce(SDL_Vulkan_CreateSurface(window, backend.instanceHandle(), &surface) == SDL_TRUE,
        "SDL_Vulkan_CreateSurface failed");
    backend.setSurface(surface);

    int drawableW = width;
    int drawableH = height;
    SDL_Vulkan_GetDrawableSize(window, &drawableW, &drawableH);
    inSetViewport(drawableW, drawableH);
    return VulkanBackendInit(window, backend, drawableW, drawableH);
}

} // version (EnableVulkanBackend)
