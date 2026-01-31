/*
    nijilive Rendering
    Inochi2D Rendering

    Copyright © 2020, Inochi2D Project
    Copyright © 2024, nijigenerate Project
    Distributed under the 2-Clause BSD License, see LICENSE file.
    
    Authors: Luna Nielsen
*/
module nlshim.core;

public import nlshim.core.shader;
public import nlshim.core.texture;
public import nlshim.core.resource;
public import nlshim.core.nodes;
public import nlshim.core.nodes.common : BlendMode;
public import nlshim.core.puppet;
public import nlshim.core.meshdata;
public import nlshim.core.param;
public import nlshim.core.automation;
public import nlshim.core.animation;
public import nlshim.core.diff_collect : DifferenceEvaluationRegion, DifferenceEvaluationResult;
public import nlshim.core.texture_types;
public import nlshim.core.runtime_state;
public import nlshim.integration;
version(InDoesRender) {
    version(UseQueueBackend) {
    } else {
        // OpenGL backend is provided by top-level opengl/* modules; avoid importing nlshim copies.
    }
}
//import std.stdio;

/**
    UDA for sub-classable parts of the spec
    eg. Nodes and Automation can be extended by
    adding new subclasses that aren't in the base spec.
*/
struct TypeId { string id; }

/**
    Different modes of interpolation between values.
*/
enum InterpolateMode {

    /**
        Round to nearest
    */
    Nearest,
    
    /**
        Linear interpolation
    */
    Linear,

    /**
        Round to nearest
    */
    Stepped,

    /**
        Cubic interpolation
    */
    Cubic,

    /**
        Interpolation using beziér splines
    */
    Bezier,

    COUNT
}
