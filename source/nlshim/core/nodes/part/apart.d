module nlshim.core.nodes.part.apart;
import nlshim.core.nodes.part;
import nlshim.core;
import nlshim.math;

/**
    Parts which contain spritesheet animation
*/
@TypeId("AnimatedPart")
class AnimatedPart : Part {
private:

protected:
    override
    string typeId() { return "AnimatedPart"; }

public:

    /**
        The amount of splits in the texture
    */
    vec2i splits;
}