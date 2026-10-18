#[compute]
#version 450
// Publish immutable geometry support with the consumer's normal-error margin.
layout(local_size_x = 64) in;
layout(rgba32f, set = 0, binding = 0) uniform readonly image3D cache_image;
layout(rgba32i, set = 0, binding = 1) uniform readonly iimage3D cache_tags;
layout(r32ui, set = 0, binding = 2) uniform uimage3D support_image;
layout(set = 0, binding = 3, std430) readonly buffer Jobs { ivec4 cells[]; } jobs;
layout(set = 0, binding = 4, std430) readonly buffer VisibilityNodes { vec4 nodes[]; } visibility_bvh;
layout(set = 0, binding = 5, std430) readonly buffer VisibilityTriangles { vec4 triangles[]; } visibility_geometry;
layout(push_constant, std430) uniform FillParameters {
	int jobs; int resolution; int epoch; float base_spacing;
} config;
#include "magic_gi_clv_layout.glslinc"
#include "magic_gi_visibility.glslinc"

bool finite3(vec3 v) { return !any(isnan(v)) && !any(isinf(v)); }

ivec3 cache_slot(ivec3 logical, int level) {
	return ((logical % config.resolution) + config.resolution) % config.resolution
			+ ivec3(0, 0, level * config.resolution);
}

void main() {
	uint index = gl_GlobalInvocationID.x;
	if (index >= uint(config.jobs * 8)) { return; }
	ivec4 job = jobs.cells[index / 8u];
	uint corner = index % 8u;
	ivec3 base = job.xyz - ivec3(int(corner & 1u), int((corner >> 1u) & 1u), int(corner >> 2u));
	ivec3 slot = cache_slot(base, job.w);
	ivec4 owner = imageLoad(cache_tags, slot);
	// An out-of-window parent may alias a different logical cell. Do not revoke
	// that unrelated cell; consumers also check the complete logical bounds.
	if (any(notEqual(owner.xyz, base)) || owner.w == 0) { return; }
	bool current_support = owner.w == config.epoch;
	for (int z = 0; z < 2 && current_support; z++) for (int y = 0; y < 2 && current_support; y++)
	for (int x = 0; x < 2; x++) {
		ivec3 logical = base + ivec3(x, y, z);
		ivec4 tag = imageLoad(cache_tags, cache_slot(logical, job.w));
		if (any(notEqual(tag.xyz, logical)) || tag.w != owner.w) { current_support = false; break; }
	}
	if (!current_support) { imageAtomicExchange(support_image, slot, 0u); return; }
	// Geometry and the support decisions are immutable within a cell epoch.
	// Bit 7 records a completed decision, including a deliberately rejected box.
	if ((imageAtomicOr(support_image, slot, 0u) & 128u) != 0u) { return; }
	float step_size = config.base_spacing * float(1 << job.w);
	uint mask = 128u;
	for (int axis = 0; axis < CLV_FACE_SLOT_COUNT; axis++) {
		int metadata_column = clv_face_column(axis, CLV_FACE_METADATA_COLUMN);
		int anchor_column = clv_face_column(axis, CLV_FACE_ANCHOR_COLUMN);
		vec4 reference = imageLoad(cache_image, slot + ivec3(metadata_column * config.resolution, 0, 0));
		vec4 reference_anchor = imageLoad(cache_image, slot + ivec3(anchor_column * config.resolution, 0, 0));
		if (!(reference.w > 0.0) || !(abs(reference_anchor.w) >= 1.0)
				|| !finite3(reference.xyz) || !finite3(reference_anchor.xyz)) { continue; }
		bool valid = true;
		for (int z = 0; z < 2 && valid; z++) for (int y = 0; y < 2 && valid; y++)
		for (int x = 0; x < 2; x++) {
			ivec3 logical = base + ivec3(x, y, z);
			ivec3 neighbor = cache_slot(logical, job.w);
			ivec4 tag = imageLoad(cache_tags, neighbor);
			vec4 metadata = imageLoad(cache_image, neighbor + ivec3(metadata_column * config.resolution, 0, 0));
			vec4 anchor = imageLoad(cache_image, neighbor + ivec3(anchor_column * config.resolution, 0, 0));
			vec3 delta = metadata.xyz - reference.xyz;
			float magnitude = max(step_size, max(max(abs(anchor.x), abs(anchor.y)), abs(anchor.z)));
			float tolerance = max(1e-5, step_size * 1e-4) + max(1e-5, magnitude * 1.9073486328125e-6);
			valid = all(equal(tag.xyz, logical)) && tag.w == owner.w
					&& metadata.w == reference.w && abs(anchor.w) >= 1.0
					&& finite3(metadata.xyz) && finite3(anchor.xyz)
					&& dot(delta, delta) <= 1e-10
					&& abs(dot(anchor.xyz - reference_anchor.xyz, reference.xyz)) <= tolerance;
			if (!valid) { break; }
		}
		if (valid) {
			vec3 first_corner = (vec3(base) + 0.5) * step_size;
			vec3 last_corner = first_corner + step_size;
			vec3 offset = reference.xyz * (0.75 * step_size);
			vec3 lower = min(first_corner, first_corner - offset);
			vec3 upper = max(last_corner, last_corner - offset);
			float magnitude = max(step_size, max(max(abs(first_corner.x), abs(first_corner.y)), abs(first_corner.z)));
			float margin = max(1e-5, magnitude * 1.9073486328125e-6);
			float tolerance = max(1e-5, step_size * 1e-4) + margin;
			valid = clv_surface_bounds_certificate_clear((lower + upper) * 0.5,
					(upper - lower) * 0.5 + vec3(margin + step_size * CLV_DIFFUSE_NORMAL_ERROR),
					reference_anchor.xyz, reference.xyz, int(reference.w), tolerance, margin);
		}
		if (valid) { mask |= 1u << uint(axis); }
	}
	// Several changed corners can address the same parent. Their inputs are
	// read-only during this dispatch, so they atomically publish the same mask.
	imageAtomicExchange(support_image, slot, mask);
}
