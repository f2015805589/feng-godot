// Test overlay for the Post Process / Tonemap pass (misc/scripts/tests/frp_post.gd).
//
// It writes a flat colour chosen by the shader keyword POST_AFTER_TONEMAP:
//
//   * before tone mapping the overlay writes HDR red into the frame's colour buffer,
//     which the tone mapper then maps to screen, so the presented pixel is a *toned*
//     red;
//   * after tone mapping the overlay writes LDR green into its own texture, which the
//     pass presents unchanged, so the presented pixel is exactly green.
//
// The two colours are the extremes of the 0..1 range, so neither depends on the colour
// space the destination happens to use.

#[vertex]
#version 450

void main() {
	vec2 uv = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2);
	gl_Position = vec4(uv * 2.0 - 1.0, 0.0, 1.0);
}

#[fragment]
#version 450

layout(constant_id = 0) const bool POST_AFTER_TONEMAP = false;

// FengShaderPass always supplies its parameters as a push constant, so the shader has
// to declare the block even though this overlay does not use it.
layout(push_constant, std430) uniform Parameters {
	vec4 params;
} push;

layout(location = 0) out vec4 frag_color;

void main() {
	frag_color = POST_AFTER_TONEMAP ? vec4(0.0, 1.0, 0.0, 1.0) : vec4(1.0, 0.0, 0.0, 1.0);
}
