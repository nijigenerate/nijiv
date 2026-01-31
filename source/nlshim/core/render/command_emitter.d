module nlshim.core.render.command_emitter;

import nlshim.core.nodes.part : Part;
import nlshim.core.nodes.drawable : Drawable;
import nlshim.core.nodes.composite.projectable : Projectable;
import nlshim.core.render.commands : DynamicCompositePass;
version (UseQueueBackend) {
    import nlshim.core.render.backends : RenderGpuState, BackendEnum;
    import nlshim.core.render.backends.queue : RenderingBackend;
    alias RenderBackend = RenderingBackend!(BackendEnum.OpenGL);
} else {
    import nlshim.core.render.backends : RenderBackend, RenderGpuState;
}

interface RenderCommandEmitter {
    void beginFrame(RenderBackend backend, ref RenderGpuState state);
    void drawPart(Part part, bool isMask);
    void beginDynamicComposite(Projectable composite, DynamicCompositePass passData);
    void endDynamicComposite(Projectable composite, DynamicCompositePass passData);
    void beginMask(bool useStencil);
    void applyMask(Drawable drawable, bool isDodge);
    void beginMaskContent();
    void endMask();
    void endFrame(RenderBackend backend, ref RenderGpuState state);
}
