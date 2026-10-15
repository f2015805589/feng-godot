#[compute]
#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D depth_buffer;
layout(set = 0, binding = 2) uniform sampler2D orm_buffer;
layout(rgba16f, set = 0, binding = 3) uniform writeonly image2D gi_output;
layout(set = 0, binding = 4) uniform sampler2D sky_light_diffuse_buffer;
layout(set = 0, binding = 5, std140) uniform PendingPageParams {
	mat4 inverse_projection;
	mat4 view_to_world;
	vec4 core_min_enabled;
	vec4 core_max_strength;
	ivec4 dispatch_rect; // xy = pixel offset, zw = dispatched rectangle size.
	mat4 owner_world_to_local;
	vec4 owner_size_enabled;
} page;

void main() {
	ivec2 local_pixel = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(local_pixel, page.dispatch_rect.zw))) { return; }
	ivec2 pixel = local_pixel + page.dispatch_rect.xy;
	ivec2 extent = imageSize(color_image);
	if (any(greaterThanEqual(pixel, extent))) { return; }
	float depth = texelFetch(depth_buffer, pixel, 0).r;
	if (depth <= 0.0) { return; }
	uint packed_metadata = uint(round(clamp(texelFetch(orm_buffer, pixel, 0).a, 0.0, 1.0) * 255.0));
	if ((packed_metadata & 0x0Fu) == 0u) { return; }
	vec2 uv = (vec2(pixel) + vec2(0.5)) / vec2(extent);
	vec4 clip = vec4(uv * 2.0 - 1.0, depth, 1.0);
	vec4 view_h = page.inverse_projection * clip;
	if (abs(view_h.w) < 1e-7) { return; }
	vec3 view_position = view_h.xyz / view_h.w;
	vec3 world = (page.view_to_world * vec4(view_position, 1.0)).xyz;
	if (page.core_min_enabled.w < 0.5 || any(lessThan(world, page.core_min_enabled.xyz))
			|| any(greaterThanEqual(world, page.core_max_strength.xyz))) {
		return;
	}
	if (page.owner_size_enabled.w > 0.5) {
		vec3 owner_local = (page.owner_world_to_local * vec4(world, 1.0)).xyz;
		if (any(greaterThan(abs(owner_local), page.owner_size_enabled.xyz * 0.5))) { return; }
	}
	float ownership = clamp(page.core_max_strength.w, 0.0, 1.0);
	imageStore(gi_output, pixel, vec4(0.0, 0.0, 0.0, ownership));
	vec4 scene_color = imageLoad(color_image, pixel);
	if (ownership > 0.0) {
		scene_color.rgb -= texelFetch(sky_light_diffuse_buffer, pixel, 0).rgb * ownership;
	}
	imageStore(color_image, pixel, vec4(scene_color.rgb, scene_color.a));
}
