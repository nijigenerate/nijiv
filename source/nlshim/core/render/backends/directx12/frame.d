module nlshim.core.render.backends.directx12.frame;

version (RenderBackendDirectX12) {

version (InDoesRender) {

import nlshim.core.render.backends : RenderGpuState;

private __gshared void delegate(RenderGpuState*) beginHook;
private __gshared void delegate(RenderGpuState*) endHook;

public void registerDirectXFrameHooks(
    void delegate(RenderGpuState*) beginFrame,
    void delegate(RenderGpuState*) endFrame) {
    beginHook = beginFrame;
    endHook = endFrame;
}

/// Entry invoked by the render queue before playback begins.
void dxBeginFrame(RenderGpuState* state) {
    if (beginHook !is null) {
        beginHook(state);
    }
}

/// Entry invoked when the render queue has finished issuing commands.
void dxEndFrame(RenderGpuState* state) {
    if (endHook !is null) {
        endHook(state);
    }
}

}

}
