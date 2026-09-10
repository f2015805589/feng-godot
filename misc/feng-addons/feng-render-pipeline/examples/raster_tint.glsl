#[vertex]
#version 450

void main() {
	vec2 uv = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2);
	gl_Position = vec4(uv * 2.0 - 1.0, 0.0, 1.0);
}

#[fragment]
#version 450

layout(set = 0, binding = 0) uniform sampler2D src_image;
layout(push_constant, std430) uniform Parameters {
	vec4 tint;
} params;
layout(location = 0) out vec4 frag_color;

void main() {
	vec2 uv = gl_FragCoord.xy / vec2(textureSize(src_image, 0));
	vec4 color = texture(src_image, uv);
	frag_color = vec4(color.rgb * params.tint.rgb, color.a);
}
