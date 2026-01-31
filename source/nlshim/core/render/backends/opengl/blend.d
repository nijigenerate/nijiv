module nlshim.core.render.backends.opengl.blend;

import nlshim.core.nodes.common : BlendMode;

version (InDoesRender) {

import bindbc.opengl;
import bindbc.opengl.context;
import nlshim.core.shader : Shader, shaderAsset;
import nlshim.math : mat4, vec2;

private __gshared Shader[BlendMode] blendShaders;

private void ensureBlendShadersInitialized() {
    if (blendShaders.length > 0) return;

    auto advancedBlendShader = new Shader(shaderAsset!("opengl/basic/basic.vert","opengl/basic/advanced_blend.frag")());
    BlendMode[] advancedModes = [
        BlendMode.Multiply,
        BlendMode.Screen,
        BlendMode.Overlay,
        BlendMode.Darken,
        BlendMode.Lighten,
        BlendMode.ColorDodge,
        BlendMode.ColorBurn,
        BlendMode.HardLight,
        BlendMode.SoftLight,
        BlendMode.Difference,
        BlendMode.Exclusion
    ];
    foreach (mode; advancedModes) {
        blendShaders[mode] = advancedBlendShader;
    }
}

Shader oglGetBlendShader(BlendMode mode) {
    ensureBlendShadersInitialized();
    auto shader = mode in blendShaders;
    return shader ? *shader : null;
}

void oglBlendToBuffer(
    Shader shader,
    BlendMode mode,
    GLuint dstFramebuffer,
    GLuint bgAlbedo, GLuint bgEmissive, GLuint bgBump,
    GLuint fgAlbedo, GLuint fgEmissive, GLuint fgBump
) {
    if (shader is null) return;

    glBindFramebuffer(GL_FRAMEBUFFER, dstFramebuffer);
    glDrawBuffers(3, [GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2].ptr);

    shader.use();
    GLint modeUniform = shader.getUniformLocation("blend_mode");
    if (modeUniform != -1) {
        shader.setUniform(modeUniform, cast(int)mode);
    }

    glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, bgAlbedo);
    glActiveTexture(GL_TEXTURE1); glBindTexture(GL_TEXTURE_2D, bgEmissive);
    glActiveTexture(GL_TEXTURE2); glBindTexture(GL_TEXTURE_2D, bgBump);

    glActiveTexture(GL_TEXTURE3); glBindTexture(GL_TEXTURE_2D, fgAlbedo);
    glActiveTexture(GL_TEXTURE4); glBindTexture(GL_TEXTURE_2D, fgEmissive);
    glActiveTexture(GL_TEXTURE5); glBindTexture(GL_TEXTURE_2D, fgBump);

    shader.setUniform(shader.getUniformLocation("bg_albedo"), 0);
    shader.setUniform(shader.getUniformLocation("bg_emissive"), 1);
    shader.setUniform(shader.getUniformLocation("bg_bump"), 2);
    shader.setUniform(shader.getUniformLocation("fg_albedo"), 3);
    shader.setUniform(shader.getUniformLocation("fg_emissive"), 4);
    shader.setUniform(shader.getUniformLocation("fg_bump"), 5);

    GLint mvpUniform = shader.getUniformLocation("mvp");
    if (mvpUniform != -1) {
        shader.setUniform(mvpUniform, mat4.identity);
    }

    GLint offsetUniform = shader.getUniformLocation("offset");
    if (offsetUniform != -1) {
        shader.setUniform(offsetUniform, vec2(0, 0));
    }

    // VAO not used; handled in shader setup.
    glDrawArrays(GL_TRIANGLES, 0, 6);

    glActiveTexture(GL_TEXTURE5); glBindTexture(GL_TEXTURE_2D, 0);
    glActiveTexture(GL_TEXTURE4); glBindTexture(GL_TEXTURE_2D, 0);
    glActiveTexture(GL_TEXTURE3); glBindTexture(GL_TEXTURE_2D, 0);
    glActiveTexture(GL_TEXTURE2); glBindTexture(GL_TEXTURE_2D, 0);
    glActiveTexture(GL_TEXTURE1); glBindTexture(GL_TEXTURE_2D, 0);
    glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, 0);
}

// Some platforms/bindings lack GL_KHR_blend_equation_advanced; fall back safely.
void oglSetAdvancedBlendCoherent(bool enable) { /* no-op fallback */ }

void oglSetLegacyBlendMode(BlendMode blendingMode) {
    switch (blendingMode) {
        case BlendMode.Normal:
            glBlendEquation(GL_FUNC_ADD);
            glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
            break;
        case BlendMode.Multiply:
            glBlendEquation(GL_FUNC_ADD);
            glBlendFunc(GL_DST_COLOR, GL_ONE_MINUS_SRC_ALPHA);
            break;
        case BlendMode.Screen:
            glBlendEquation(GL_FUNC_ADD);
            glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_COLOR);
            break;
        case BlendMode.Lighten:
            glBlendEquation(GL_MAX);
            glBlendFunc(GL_ONE, GL_ONE);
            break;
        case BlendMode.ColorDodge:
            glBlendEquation(GL_FUNC_ADD);
            glBlendFunc(GL_DST_COLOR, GL_ONE);
            break;
        case BlendMode.LinearDodge:
            glBlendEquation(GL_FUNC_ADD);
            glBlendFuncSeparate(GL_ONE, GL_ONE_MINUS_SRC_COLOR, GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
            break;
        case BlendMode.AddGlow:
            glBlendEquation(GL_FUNC_ADD);
            glBlendFuncSeparate(GL_ONE, GL_ONE, GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
            break;
        case BlendMode.Subtract:
            glBlendEquationSeparate(GL_FUNC_REVERSE_SUBTRACT, GL_FUNC_ADD);
            glBlendFunc(GL_ONE_MINUS_DST_COLOR, GL_ONE);
            break;
        case BlendMode.Exclusion:
            glBlendEquation(GL_FUNC_ADD);
            glBlendFuncSeparate(GL_ONE_MINUS_DST_COLOR, GL_ONE_MINUS_SRC_COLOR, GL_ONE, GL_ONE);
            break;
        case BlendMode.Inverse:
            glBlendEquation(GL_FUNC_ADD);
            glBlendFunc(GL_ONE_MINUS_DST_COLOR, GL_ONE_MINUS_SRC_ALPHA);
            break;
        case BlendMode.DestinationIn:
            glBlendEquation(GL_FUNC_ADD);
            glBlendFunc(GL_ZERO, GL_SRC_ALPHA);
            break;
        case BlendMode.ClipToLower:
            glBlendEquation(GL_FUNC_ADD);
            glBlendFunc(GL_DST_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
            break;
        case BlendMode.SliceFromLower:
            glBlendEquation(GL_FUNC_ADD);
            glBlendFunc(GL_ZERO, GL_ONE_MINUS_SRC_ALPHA);
            break;
        default:
            glBlendEquation(GL_FUNC_ADD);
            glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
            break;
    }
}

void oglSetAdvancedBlendEquation(BlendMode blendingMode) {
    // Fallback: use legacy path if advanced equations are unavailable.
    oglSetLegacyBlendMode(blendingMode);
}

void oglIssueBlendBarrier() {
    // no-op when advanced blend barrier is unavailable
}

bool oglSupportsAdvancedBlend() {
    return hasKHRBlendEquationAdvanced;
}

bool oglSupportsAdvancedBlendCoherent() {
    return hasKHRBlendEquationAdvancedCoherent;
}

} else {

import nlshim.core.nodes.common : BlendMode;
import nlshim.core.shader : Shader;
alias GLuint = uint;

Shader oglGetBlendShader(BlendMode) { return null; }
void oglBlendToBuffer(Shader, BlendMode, GLuint, GLuint, GLuint, GLuint, GLuint, GLuint, GLuint) {}
void oglSetAdvancedBlendCoherent(bool) {}
void oglSetLegacyBlendMode(BlendMode) {}
void oglSetAdvancedBlendEquation(BlendMode) {}
void oglIssueBlendBarrier() {}
bool oglSupportsAdvancedBlend() { return false; }
bool oglSupportsAdvancedBlendCoherent() { return false; }

}
