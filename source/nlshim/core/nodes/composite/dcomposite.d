/*
    nijilive DynamicComposite Node

    Copyright © 2020, nijigenerate Project
    Distributed under the 2-Clause BSD License, see LICENSE file.
    
    Authors: Luna Nielsen
*/
module nlshim.core.nodes.composite.dcomposite;

import nlshim.core.nodes;
import nlshim.core; // for TypeId
import nlshim.core.nodes.composite.projectable;
import nlshim.core.meshdata;

public {
    void inInitDComposite() {
        inRegisterNodeType!DynamicComposite;
    }

    alias advanceDynamicCompositeFrame = advanceProjectableFrame;
    alias currentDynamicCompositeFrame = currentProjectableFrame;
}

/**
    DynamicComposite keeps Projectable behavior while remaining a distinct node type.
*/
@TypeId("DynamicComposite")
class DynamicComposite : Projectable {
public:
    this(Node parent = null) {
        super(parent);
    }

    this(MeshData data, uint uuid, Node parent = null) {
        super(data, uuid, parent);
    }

    override
    string typeId() { return "DynamicComposite"; }
}
