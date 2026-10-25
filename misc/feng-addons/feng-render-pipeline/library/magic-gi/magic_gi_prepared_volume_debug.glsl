#[compute]
#version 450
#extension GL_GOOGLE_include_directive : require
// Whole-volume SH2 diagnostic: 96-byte UBO and four packed RGBA response fields.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(set = 0, binding = 0) uniform sampler2D depth_buffer;
layout(set = 0, binding = 1) uniform sampler2D normal_buffer;
layout(set = 0, binding = 2) uniform sampler2D albedo_buffer;
layout(set = 0, binding = 3) uniform sampler2D orm_buffer;
layout(rgba16f, set = 0, binding = 4) uniform writeonly image2D gi_output;
layout(set = 0, binding = 5, std140) uniform Frame {
	mat4 inverse_projection;
	mat4 world_to_grid;
	mat4 view_to_world;
	vec4 grid;
	vec4 control;
	vec4 lighting_sh[7];
	vec4 sky_sh[7];
} frame;
layout(set = 0, binding = 6) uniform sampler2D diffuse_ao_buffer;
layout(set = 1, binding = 62) uniform sampler linear_sampler;
#define FRP_MAGIC_GI_DYNAMIC_VOLUME_LINEAR_SAMPLER linear_sampler
#define MAGIC_GI_PREINTERPOLATED_ONLY
#define MAGIC_GI_PREPARED_SH2_ONLY
#include "magic_gi_dynamic_volume_sample.glslinc"
layout(push_constant, std430) uniform Push {
	ivec2 size;
	int mode;
	float pre_exposure;
} pc;

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(pixel, pc.size))) return;
	float depth = texelFetch(depth_buffer, pixel, 0).r;
	vec2 uv = (vec2(pixel) + 0.5) / vec2(pc.size);
	vec4 view_position = frame.inverse_projection * vec4(uv * 2.0 - 1.0, depth, 1.0);
	if (depth <= 0.0 || abs(view_position.w) < 1e-8) {
		imageStore(gi_output, pixel, vec4(0.0));
		return;
	}
	vec3 world = (frame.view_to_world * vec4(view_position.xyz / view_position.w, 1.0)).xyz;
	vec3 normal = normalize(mat3(frame.view_to_world) *
		(texelFetch(normal_buffer, pixel, 0).xyz * 2.0 - 1.0));
	vec3 incident; float coverage;
	bool supported = frp_magic_gi_dynamic_volume_sample(world, normal, normal, 0, incident, coverage);
	vec3 color = supported ? max(incident, vec3(0.0)) : vec3(0.0);
	if (pc.mode == 1 || pc.mode == 3) {
		int selected = -1;
		for (int lod = 0; lod < 4 && supported; lod++) {
			vec3 unused_incident; float unused_coverage; float edge;
			if (frp_magic_gi_preinterpolated_sample_lod(world, normal, 0, lod,
					unused_incident, unused_coverage, edge)) { selected = lod; break; }
		}
		vec3 palette[4] = vec3[](vec3(0.1, 0.85, 0.2), vec3(1.0, 0.5, 0.05),
			vec3(0.15, 0.4, 1.0), vec3(0.75, 0.2, 0.9));
		color = selected >= 0 ? palette[selected] : vec3(0.0);
		if (pc.mode == 3 && selected >= 0) {
			vec4 origin = frp_magic_gi_dynamic_volume_origin_spacing(0, selected);
			vec3 cell = floor((world - origin.xyz) / origin.w);
			color *= mod(cell.x + cell.y + cell.z, 2.0) == 0.0 ? 0.5 : 1.0;
		}
	} else if (pc.mode == 2 || pc.mode == 5) {
		color = supported ? vec3(0.1, 0.85, 0.2) :
			(frp_magic_gi_dynamic_volume_owner_contains(world, 0)
				? vec3(1.0, 0.05, 0.5) : vec3(0.05, 0.2, 0.8));
	} else if (pc.mode == 0) {
		vec4 owner = frp_magic_gi_dynamic_volume_owner_control(0);
		float ao = clamp(texelFetch(orm_buffer, pixel, 0).r, 0.0, 1.0);
		float diffuse_ao = clamp(textureLod(diffuse_ao_buffer, uv, 0.0).r, 0.0, 1.0);
		color *= max(texelFetch(albedo_buffer, pixel, 0).rgb, vec3(0.0)) *
			ao * diffuse_ao * max(owner.x, 0.0) * max(owner.z, 0.0) * max(pc.pre_exposure, 0.0);
	}
	imageStore(gi_output, pixel, vec4(color, supported ? coverage : 0.0));
}
