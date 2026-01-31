module nlshim.core.render.tests.render_queue;

version(unittest) {

import std.algorithm : equal, filter, map;
import std.array : array;
import std.conv : to;
import std.range : iota;

import nlshim.math : vec2, vec3, mat4;
import nlshim.core;
import nlshim.core : inEnsureCameraStackForTests, inEnsureViewportForTests;
import nlshim.core.nodes;
import nlshim.core.nodes.composite;
import nlshim.core.nodes.mask;
import nlshim.core.nodes.meshgroup;
import nlshim.core.nodes.part;
import nlshim.core.nodes.deformer.grid;
import nlshim.core.nodes.deformer.path;
import nlshim.core.nodes.composite.dcomposite;
import nlshim.core.nodes.composite.projectable : Projectable;
import nlshim.core.nodes.drawable : Drawable;
import nlshim.core.render.graph_builder;
import nlshim.core.render.command_emitter : RenderCommandEmitter;
import nlshim.core.render.commands : RenderCommandKind, MaskApplyPacket, PartDrawPacket,
    MaskDrawPacket, MaskDrawableKind, CompositeDrawPacket, DynamicCompositePass,
    DynamicCompositeSurface, makePartDrawPacket, makeMaskDrawPacket,
    makeCompositeDrawPacket, tryMakeMaskApplyPacket;
import nlshim.core.render.backends : RenderBackend, RenderGpuState;
import nlshim.core.render.scheduler : RenderContext, TaskScheduler;
import nlshim.core.meshdata;
import nlshim.core.texture : Texture;
import nlshim.core.texture_types : Filtering, Wrapping;
import nlshim.core.nodes.part : TextureUsage;
import nlshim.core.nodes.common : MaskBinding, MaskingMode;

final class RecordingEmitter : RenderCommandEmitter {
    struct RecordedCommand {
        RenderCommandKind kind;
        PartDrawPacket partPacket;
        DynamicCompositePass dynamicPass;
        bool maskUsesStencil;
        MaskApplyPacket maskPacket;
    }

    RecordedCommand[] commands;

    void beginFrame(RenderBackend, ref RenderGpuState) {
        commands.length = 0;
    }

    void endFrame(RenderBackend, ref RenderGpuState) {}

    void drawPart(Part part, bool isMask) {
        RecordedCommand cmd;
        cmd.kind = RenderCommandKind.DrawPart;
        cmd.partPacket = makePartDrawPacket(part, isMask);
        commands ~= cmd;
    }

    void beginDynamicComposite(Projectable, DynamicCompositePass passData) {
        RecordedCommand cmd;
        cmd.kind = RenderCommandKind.BeginDynamicComposite;
        cmd.dynamicPass = passData;
        commands ~= cmd;
    }

    void endDynamicComposite(Projectable, DynamicCompositePass passData) {
        RecordedCommand cmd;
        cmd.kind = RenderCommandKind.EndDynamicComposite;
        cmd.dynamicPass = passData;
        commands ~= cmd;
    }

    void beginMask(bool useStencil) {
        RecordedCommand cmd;
        cmd.kind = RenderCommandKind.BeginMask;
        cmd.maskUsesStencil = useStencil;
        commands ~= cmd;
    }

    void applyMask(Drawable drawable, bool isDodge) {
        RecordedCommand cmd;
        cmd.kind = RenderCommandKind.ApplyMask;
        MaskApplyPacket packet;
        if (tryMakeMaskApplyPacket(drawable, isDodge, packet)) {
            cmd.maskPacket = packet;
        }
        commands ~= cmd;
    }

    void beginMaskContent() {
        RecordedCommand cmd;
        cmd.kind = RenderCommandKind.BeginMaskContent;
        commands ~= cmd;
    }

    void endMask() {
        RecordedCommand cmd;
        cmd.kind = RenderCommandKind.EndMask;
        commands ~= cmd;
    }

}

shared static this() {
    inEnsureCameraStackForTests();
    inEnsureViewportForTests();
}

MeshData makeQuadMesh(float size = 1.0f) {
    auto half = size / 2.0f;
    MeshData data;
    data.vertices = [
        vec2(-half, -half),
        vec2( half, -half),
        vec2(-half,  half),
        vec2( half,  half),
    ];
    data.uvs = [
        vec2(0, 0),
        vec2(1, 0),
        vec2(0, 1),
        vec2(1, 1),
    ];
    data.indices = [
        cast(ushort)0, 1, 2,
        cast(ushort)2, 1, 3,
    ];
    data.origin = vec2(0, 0);
    return data;
}

alias RecordedCommand = RecordingEmitter.RecordedCommand;

RecordedCommand[] executeFrame(Puppet puppet) {
    inEnsureCameraStackForTests();
    inEnsureViewportForTests();
    auto graph = new RenderGraphBuilder();
    RenderContext ctx;
    ctx.renderGraph = &graph;
    ctx.renderBackend = null;
    ctx.gpuState = RenderGpuState.init;

    auto scheduler = new TaskScheduler();
    if (auto root = puppet.actualRoot()) {
        scheduler.clearTasks();
        root.registerRenderTasks(scheduler);
        graph.beginFrame();
        scheduler.execute(ctx);
    }

    auto emitter = new RecordingEmitter();
    emitter.beginFrame(null, ctx.gpuState);
    graph.playback(emitter);
    emitter.endFrame(null, ctx.gpuState);
    return emitter.commands.dup;
}

unittest {
    auto puppet = new Puppet();
    puppet.root.name = "Root";

    auto quad = makeQuadMesh();
    Texture[] textures;
    textures.length = TextureUsage.COUNT;

    auto part = new Part(quad, textures, inCreateUUID(), puppet.root);
    part.name = "StandalonePart";

    puppet.rescanNodes();
    auto commands = executeFrame(puppet);
    auto kinds = commands.map!(c => c.kind).array;
    assert(kinds == [RenderCommandKind.DrawPart], "Standalone part should enqueue exactly one DrawPart command.");
}

unittest {
    auto puppet = new Puppet();
    puppet.root.name = "Root";

    auto quad = makeQuadMesh();
    Texture[] textures;
    textures.length = TextureUsage.COUNT;

    auto back = new Part(quad, textures, inCreateUUID(), puppet.root);
    back.name = "Background";
    back.zSort = -0.5f;
    back.opacity = 0.25f;

    auto front = new Part(quad, textures, inCreateUUID(), puppet.root);
    front.name = "Foreground";
    front.zSort = 0.5f;
    front.opacity = 0.75f;

    puppet.rescanNodes();
    auto commands = executeFrame(puppet);
    auto drawOpacities = commands
        .filter!(c => c.kind == RenderCommandKind.DrawPart)
        .map!(c => c.partPacket.opacity)
        .array;
    assert(drawOpacities == [0.75f, 0.25f],
        "Render tasks must be flushed in descending zSort order.");
}

} // version(unittest)

unittest {
    auto puppet = new Puppet();
    puppet.root.name = "Root";

    auto quad = makeQuadMesh();
    Texture[] textures;
    textures.length = TextureUsage.COUNT;

    auto part = new Part(quad, textures, inCreateUUID(), puppet.root);
    part.name = "MaskedPart";

    auto mask = new Mask(quad, inCreateUUID(), part);
    mask.name = "LocalMask";

    MaskBinding binding;
    binding.maskSrcUUID = mask.uuid;
    binding.mode = MaskingMode.Mask;
    binding.maskSrc = mask;
    part.masks = [binding];

    puppet.rescanNodes();
    auto commands = executeFrame(puppet);
    auto kinds = commands.map!(c => c.kind).array;
    assert(kinds == [
        RenderCommandKind.BeginMask,
        RenderCommandKind.ApplyMask,
        RenderCommandKind.BeginMaskContent,
        RenderCommandKind.DrawPart,
        RenderCommandKind.EndMask
    ], "Masked part should emit mask begin/apply/content commands around DrawPart.");

    assert(commands[1].maskPacket.kind == MaskDrawableKind.Mask,
        "ApplyMask should reference Mask drawable when masking.");
}

unittest {
    auto puppet = new Puppet();
    puppet.root.name = "Root";

    auto quad = makeQuadMesh();
    Texture[] textures;
    textures.length = TextureUsage.COUNT;

    auto composite = new Composite(puppet.root);
    composite.name = "Composite";

    auto child = new Part(quad, textures, inCreateUUID(), composite);
    child.name = "ChildPart";

    puppet.rescanNodes();
    auto commands = executeFrame(puppet);
    auto kinds = commands.map!(c => c.kind).array;
    assert(kinds == [
        RenderCommandKind.BeginDynamicComposite,
        RenderCommandKind.DrawPart,
        RenderCommandKind.EndDynamicComposite,
        RenderCommandKind.DrawPart
    ], "Composite should render children into its offscreen target and then draw itself.");
}

unittest {
    auto puppet = new Puppet();
    puppet.root.name = "Root";

    auto quad = makeQuadMesh();
    Texture[] textures;
    textures.length = TextureUsage.COUNT;

    auto composite = new Composite(puppet.root);
    composite.name = "MaskedComposite";

    auto child = new Part(quad, textures, inCreateUUID(), composite);
    child.name = "ChildPart";

    auto maskNode = new Mask(quad, inCreateUUID(), composite);
    maskNode.name = "CompositeMask";

    MaskBinding binding;
    binding.maskSrcUUID = maskNode.uuid;
    binding.mode = MaskingMode.Mask;
    binding.maskSrc = maskNode;
    composite.masks = [binding];

    puppet.rescanNodes();
    auto commands = executeFrame(puppet);
    auto kinds = commands.map!(c => c.kind).array;
    assert(kinds == [
        RenderCommandKind.BeginDynamicComposite,
        RenderCommandKind.DrawPart,
        RenderCommandKind.EndDynamicComposite,
        RenderCommandKind.BeginMask,
        RenderCommandKind.ApplyMask,
        RenderCommandKind.BeginMaskContent,
        RenderCommandKind.DrawPart,
        RenderCommandKind.EndMask
    ], "Composite masks must wrap the transfer step (self draw), not child rendering.");
}

unittest {
    auto puppet = new Puppet();
    puppet.root.name = "Root";

    auto quad = makeQuadMesh();
    Texture[] textures;
    textures.length = TextureUsage.COUNT;

    auto outer = new Composite(puppet.root);
    outer.name = "OuterComposite";

    auto inner = new Composite(outer);
    inner.name = "InnerComposite";

    auto innerPart = new Part(quad, textures, inCreateUUID(), inner);
    innerPart.name = "InnerPart";

    puppet.rescanNodes();
    auto commands = executeFrame(puppet);
    auto kinds = commands.map!(c => c.kind).array;
    assert(kinds == [
        RenderCommandKind.BeginDynamicComposite,      // outer begin
        RenderCommandKind.BeginDynamicComposite,      // inner begin
        RenderCommandKind.DrawPart,                   // inner child
        RenderCommandKind.EndDynamicComposite,        // inner end
        RenderCommandKind.DrawPart,                   // inner self draw
        RenderCommandKind.EndDynamicComposite,        // outer end
        RenderCommandKind.DrawPart                    // outer self draw
    ], "Nested composites should finalize inner scopes before closing the outer scope.");
}

unittest {
    auto puppet = new Puppet();
    puppet.root.name = "Root";

    auto quad = makeQuadMesh();
    Texture[] textures;
    textures.length = TextureUsage.COUNT;

    auto first = new Composite(puppet.root);
    first.name = "FirstComposite";
    auto firstPart = new Part(quad, textures, inCreateUUID(), first);
    firstPart.name = "FirstChild";

    auto second = new Composite(puppet.root);
    second.name = "SecondComposite";
    second.zSort = -0.1f;
    auto secondPart = new Part(quad, textures, inCreateUUID(), second);
    secondPart.name = "SecondChild";

    puppet.rescanNodes();
    auto commands = executeFrame(puppet);
    auto begins = commands
        .filter!(c => c.kind == RenderCommandKind.BeginDynamicComposite)
        .array;
    assert(begins.length == 2,
        "Sibling composites should each emit a BeginDynamicComposite command.");
}

unittest {
    auto puppet = new Puppet();
    puppet.root.name = "Root";

    auto quad = makeQuadMesh();
    Texture[] textures;
    textures.length = TextureUsage.COUNT;

    auto dynamic = new DynamicComposite(false);
    dynamic.name = "Dynamic";
    dynamic.textures = [null, null, null];
    dynamic.invalidate();
    dynamic.parent = puppet.root;

    auto child = new Part(quad, textures, inCreateUUID(), dynamic);
    child.name = "DynamicChild";

    puppet.rescanNodes();
    auto commands = executeFrame(puppet);
    auto kinds = commands.map!(c => c.kind).array;
    assert(kinds == [
        RenderCommandKind.BeginDynamicComposite,
        RenderCommandKind.DrawPart,
        RenderCommandKind.EndDynamicComposite,
        RenderCommandKind.DrawPart
    ], "DynamicComposite should render into its target before emitting its draw command.");
}

unittest {
    auto puppet = new Puppet();
    puppet.root.name = "Root";

    auto quad = makeQuadMesh();
    Texture[] textures;
    textures.length = TextureUsage.COUNT;

    auto meshGroup = new MeshGroup(puppet.root);
    meshGroup.name = "MeshGroup";

    auto grid = new GridDeformer(meshGroup);
    grid.name = "GridDeformer";

    auto path = new PathDeformer(grid);
    path.name = "PathDeformer";
    path.rebuffer([vec2(0, 0), vec2(1, 0)]);

    auto part = new Part(quad, textures, inCreateUUID(), path);
    part.name = "NestedPart";

    puppet.rescanNodes();
    auto commands = executeFrame(puppet);
    auto kinds = commands.map!(c => c.kind).array;
    assert(kinds == [RenderCommandKind.DrawPart],
        "CPU-only deformers should not emit additional GPU commands.");
}
