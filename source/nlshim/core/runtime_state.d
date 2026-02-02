module nlshim.core.runtime_state;

import fghj : deserializeValue;
import std.exception : enforce;
import core.stdc.string : memcpy;
import nlshim.math : vec3, vec4;
import nlshim.math.camera : Camera;
import nlshim.core.render.support : inInitBlending;
import nlshim.core.render.backends : RenderBackend, RenderResourceHandle,
    DifferenceEvaluationRegion, DifferenceEvaluationResult;

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
}

/// Pop viewport if we have more than one entry.
void inPopViewport() {
    if (inViewportWidth.length > 1) {
        inViewportWidth.length = inViewportWidth.length - 1;
        inViewportHeight.length = inViewportHeight.length - 1;
        inPopCamera();
    }
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
