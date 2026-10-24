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
layout(set = 0, binding = 6, std430) readonly buffer Stencils { uint words[]; } clv_stencils;
layout(push_constant, std430) uniform FillParameters {
	int jobs; int resolution; int epoch; float base_spacing;
} config;
#include "magic_gi_clv_layout.glslinc"
#include "magic_gi_visibility.glslinc"

const int CLV_STENCIL_WORDS = 52;
const uint CLV_STENCIL_TRANSFER_VALID_BIT = 0x80000000u;

bool finite3(vec3 v) { return !any(isnan(v)) && !any(isinf(v)); }

uint stencil_base(ivec3 slot, int axis) {
	uint cell = uint((slot.z * config.resolution + slot.y) * config.resolution + slot.x);
	return (cell * uint(CLV_FACE_SLOT_COUNT) + uint(axis)) * uint(CLV_STENCIL_WORDS);
}

bool transfer_payload_valid(ivec3 slot, int axis) {
	uint base = stencil_base(slot, axis);
	if (base + 4u > uint(clv_stencils.words.length())) { return false; }
	uint count = clv_stencils.words[base];
	uint proxy_and_flags = clv_stencils.words[base + 1u];
	float candidate = uintBitsToFloat(clv_stencils.words[base + 2u]);
	float visible = uintBitsToFloat(clv_stencils.words[base + 3u]);
	return count > 0u && (proxy_and_flags & CLV_STENCIL_TRANSFER_VALID_BIT) != 0u
			&& !isnan(candidate) && !isinf(candidate)
			&& !isnan(visible) && !isinf(visible) && visible > 1e-10;
}

// Fold exactly the patch-id portion of the old approximate predicate. Unknown
// alpha values keep the slow path; only a definite old patch-gate rejection
// is allowed to clear the candidate bit.
void approx_patch_accumulate(vec4 secondary, vec4 primary, vec4 moments,
		bool hardware_filter,
		inout bool candidate_valid, inout bool have_patch,
		inout bool uncertain_alpha, inout float reference_patch) {
	float guide_alpha = moments.w;
	if (!hardware_filter) {
		guide_alpha = min(min(secondary.a, primary.a), moments.w);
	}
	if (isnan(guide_alpha) || isinf(guide_alpha)) {
		uncertain_alpha = true;
		return;
	}
	if (guide_alpha == 0.0) { return; }
	if (!(guide_alpha > 0.0)) {
		// Negative alpha is not produced by CLV, but other positive corners can
		// still satisfy the old weighted predicate. Keep the slow path.
		uncertain_alpha = true;
		return;
	}
	float patch_id = moments.x;
	if (isnan(patch_id) || isinf(patch_id) || !(patch_id > 0.0)
			|| floor(patch_id) != patch_id) {
		candidate_valid = false;
		return;
	}
	if (!have_patch) {
		reference_patch = patch_id;
		have_patch = true;
	} else if (patch_id != reference_patch) {
		candidate_valid = false;
	}
}

ivec3 cache_slot(ivec3 logical, int level) {
	return ((logical % config.resolution) + config.resolution) % config.resolution
			+ ivec3(0, 0, level * config.resolution);
}

// This is a necessary-condition prefilter for the old per-pixel patch test,
// not a receiver-domain certificate. A zero guide is ignored exactly as it is
// by clv_approx_fetch_neighborhood().
bool approx_patch_may_match(ivec3 base, int level, int axis) {
	ivec3 physical_base = cache_slot(base, level);
	physical_base.z -= level * config.resolution;
	bool hardware_filter = all(lessThan(physical_base,
			ivec3(config.resolution - 1)));
	int diffuse_column = clv_face_column(axis, CLV_FACE_DIFFUSE_COLUMN);
	int moments_column = clv_face_column(axis,
			CLV_FACE_APPROX_PATCH_PLANE_MOMENTS_COLUMN);
	bool candidate_valid = true;
	bool have_patch = false;
	bool uncertain_alpha = false;
	float reference_patch = 0.0;
	for (int z = 0; z < 2; z++) for (int y = 0; y < 2; y++)
	for (int x = 0; x < 2; x++) {
		ivec3 logical = base + ivec3(x, y, z);
		ivec3 corner_slot = cache_slot(logical, level);
		vec4 secondary = imageLoad(cache_image,
				corner_slot + ivec3(diffuse_column * config.resolution, 0, 0));
		vec4 primary = imageLoad(cache_image,
				corner_slot + ivec3((diffuse_column + 1) * config.resolution, 0, 0));
		vec4 moments = imageLoad(cache_image,
				corner_slot + ivec3(moments_column * config.resolution, 0, 0));
		approx_patch_accumulate(secondary, primary, moments, hardware_filter,
				candidate_valid, have_patch, uncertain_alpha, reference_patch);
	}
	return candidate_valid && (have_patch || uncertain_alpha);
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
	// The ready bit means the complete 2x2x2 tag neighborhood was checked,
	// including a deliberately rejected geometry-box certificate.
	if ((imageAtomicOr(support_image, slot, 0u) & CLV_SUPPORT_NEIGHBOR_TAGS_READY) != 0u) { return; }
	float step_size = config.base_spacing * float(1 << job.w);
	uint mask = CLV_SUPPORT_NEIGHBOR_TAGS_READY;
	int triangle_count = visibility_geometry.triangles.length() / 3;
	for (int axis = 0; axis < CLV_FACE_SLOT_COUNT; axis++) {
		uint approx_possible_bit = axis == 0 ? CLV_SUPPORT_APPROX_POSSIBLE_X
				: axis == 1 ? CLV_SUPPORT_APPROX_POSSIBLE_Y
				: CLV_SUPPORT_APPROX_POSSIBLE_Z;
		int metadata_column = clv_face_column(axis, CLV_FACE_METADATA_COLUMN);
		int anchor_column = clv_face_column(axis, CLV_FACE_ANCHOR_COLUMN);
		ivec3 physical_base = cache_slot(base, job.w);
		physical_base.z -= job.w * config.resolution;
		bool hardware_filter = all(lessThan(physical_base,
				ivec3(config.resolution - 1)));
		vec4 reference = imageLoad(cache_image,
				slot + ivec3(metadata_column * config.resolution, 0, 0));
		vec4 reference_anchor = imageLoad(cache_image,
				slot + ivec3(anchor_column * config.resolution, 0, 0));
		float reference_normal_length_squared = dot(reference.xyz, reference.xyz);
		bool base_reference_valid = reference.w > 0.0
				&& abs(reference_anchor.w) >= 1.0
				&& finite3(reference.xyz) && finite3(reference_anchor.xyz)
				&& reference_normal_length_squared > 1e-12
				&& !isnan(reference_normal_length_squared)
				&& !isinf(reference_normal_length_squared);
		// The candidate scan must also run when the base surface anchor is empty:
		// an interior receiver near the other side can still have enough valid
		// guide coverage for the legacy approximate path.
		if (!base_reference_valid) {
			if (approx_patch_may_match(base, job.w, axis)) { mask |= approx_possible_bit; }
			continue;
		}
		vec3 reference_normal = reference.xyz * inversesqrt(reference_normal_length_squared);
		float domain_center_magnitude = max(step_size,
				max(max(abs((float(base.x) + 1.0) * step_size),
						abs((float(base.y) + 1.0) * step_size)),
						abs((float(base.z) + 1.0) * step_size)));
		float domain_margin = max(1e-5, domain_center_magnitude * 1.9073486328125e-6);
		float plane_tolerance = max(1e-5, step_size * 1e-4) + domain_margin;
		bool strict_corners_valid = true;
		bool flat_corners_valid = true;
		bool curved_corners_valid = true;
		bool transfer_valid = true;
		bool diffuse_guides_valid = true;
		bool approx_candidate_valid = true;
		bool approx_have_patch = false;
		bool approx_uncertain_alpha = false;
		float approx_reference_patch = 0.0;
		// Track all eight stored receiver anchors. The BVH proof must cover the
		// complete receiver-to-anchor segments, not only receiver query points.
		vec3 anchor_bounds_lower = vec3(1e30);
		vec3 anchor_bounds_upper = vec3(-1e30);
		for (int z = 0; z < 2; z++) for (int y = 0; y < 2; y++)
		for (int x = 0; x < 2; x++) {
			ivec3 logical = base + ivec3(x, y, z);
			ivec3 neighbor = cache_slot(logical, job.w);
			ivec4 tag = imageLoad(cache_tags, neighbor);
			vec4 metadata = imageLoad(cache_image,
					neighbor + ivec3(metadata_column * config.resolution, 0, 0));
			vec4 anchor = imageLoad(cache_image,
					neighbor + ivec3(anchor_column * config.resolution, 0, 0));
			if (finite3(anchor.xyz)) {
				anchor_bounds_lower = min(anchor_bounds_lower, anchor.xyz);
				anchor_bounds_upper = max(anchor_bounds_upper, anchor.xyz);
			}
			bool tag_valid = all(equal(tag.xyz, logical)) && tag.w == owner.w;
			bool metadata_valid = finite3(metadata.xyz) && !isnan(metadata.w) && !isinf(metadata.w)
					&& metadata.w == reference.w;
			float anchor_id = abs(anchor.w);
			bool anchor_valid = finite3(anchor.xyz) && !isnan(anchor.w) && !isinf(anchor.w)
					&& anchor_id >= 1.0 && floor(anchor_id) == anchor_id
					&& anchor_id <= float(triangle_count);
			bool common_corner_valid = tag_valid && metadata_valid && anchor_valid;
			float anchor_delta = common_corner_valid
					? dot(anchor.xyz - reference_anchor.xyz, reference_normal) : 1e30;
			vec3 strict_normal_delta = metadata.xyz - reference.xyz;
			float strict_magnitude = max(step_size,
					max(max(abs(anchor.x), abs(anchor.y)), abs(anchor.z)));
			float strict_tolerance = max(1e-5, step_size * 1e-4)
					+ max(1e-5, strict_magnitude * 1.9073486328125e-6);
			strict_corners_valid = strict_corners_valid
					&& all(equal(tag.xyz, logical)) && tag.w == owner.w
					&& metadata.w == reference.w && abs(anchor.w) >= 1.0
					&& finite3(metadata.xyz) && finite3(anchor.xyz)
					&& dot(strict_normal_delta, strict_normal_delta) <= 1e-10
					&& abs(dot(anchor.xyz - reference_anchor.xyz, reference.xyz))
						<= strict_tolerance;

			// The flat certificate is independent of the legacy strict bit. It
			// accepts a smooth planar parent when the real diffuse guides, transfer
			// payloads and exact receiver-domain BVH query prove the same patch.
			float metadata_normal_length_squared = dot(metadata.xyz, metadata.xyz);
			vec3 metadata_normal = common_corner_valid
					&& metadata_normal_length_squared > 1e-12
					? metadata.xyz * inversesqrt(metadata_normal_length_squared) : vec3(0.0);
			float flat_normal_delta_squared = dot(metadata_normal - reference_normal,
					metadata_normal - reference_normal);
			flat_corners_valid = flat_corners_valid && common_corner_valid
					&& metadata_normal_length_squared > 1e-12
					&& flat_normal_delta_squared <= CLV_DIFFUSE_NORMAL_ERROR_SQUARED
					&& abs(anchor_delta) <= plane_tolerance;
			curved_corners_valid = curved_corners_valid && common_corner_valid
					&& metadata_normal_length_squared > 1e-12
					&& dot(metadata_normal, reference_normal)
						> CLV_CURVED_SH_SAME_FACING_DOT_MIN;
			bool corner_transfer_valid = tag_valid && transfer_payload_valid(neighbor, axis);
			transfer_valid = transfer_valid && corner_transfer_valid;

			int triangle = anchor_valid ? int(anchor_id) - 1 : 0;
			float triangle_patch = anchor_valid
					? visibility_geometry.triangles[triangle * 3 + 2].w : -1.0;
			vec3 edge1 = anchor_valid
					? visibility_geometry.triangles[triangle * 3 + 1].xyz : vec3(0.0);
			vec3 edge2 = anchor_valid
					? visibility_geometry.triangles[triangle * 3 + 2].xyz : vec3(0.0);
			vec3 triangle_normal = cross(edge2, edge1);
			float triangle_normal_length_squared = dot(triangle_normal, triangle_normal);
			bool triangle_matches = anchor_valid && !isnan(triangle_patch)
					&& !isinf(triangle_patch) && triangle_patch == metadata.w
					&& finite3(triangle_normal) && triangle_normal_length_squared > 1e-12
					&& !isnan(triangle_normal_length_squared)
					&& !isinf(triangle_normal_length_squared);
			if (triangle_matches) {
				triangle_normal *= inversesqrt(triangle_normal_length_squared);
				flat_corners_valid = flat_corners_valid
						&& dot(triangle_normal, reference_normal) >= 0.9999;
				curved_corners_valid = curved_corners_valid
						&& dot(triangle_normal, reference_normal)
							> CLV_CURVED_SH_SAME_FACING_DOT_MIN;
			} else {
				flat_corners_valid = false;
				curved_corners_valid = false;
			}

			int diffuse_column = clv_face_column(axis, CLV_FACE_DIFFUSE_COLUMN);
			vec4 secondary = imageLoad(cache_image,
					neighbor + ivec3(diffuse_column * config.resolution, 0, 0));
			vec4 primary = imageLoad(cache_image,
					neighbor + ivec3((diffuse_column + 1) * config.resolution, 0, 0));
			vec4 geometry = imageLoad(cache_image,
					neighbor + ivec3(clv_face_column(axis,
							CLV_FACE_APPROX_GEOMETRY_COLUMN) * config.resolution, 0, 0));
			vec4 moments = imageLoad(cache_image,
					neighbor + ivec3(clv_face_column(axis,
							CLV_FACE_APPROX_PATCH_PLANE_MOMENTS_COLUMN) * config.resolution, 0, 0));
			approx_patch_accumulate(secondary, primary, moments, hardware_filter,
					approx_candidate_valid, approx_have_patch,
					approx_uncertain_alpha, approx_reference_patch);
			float guide_weight = min(min(secondary.a, primary.a), moments.w);
			vec3 guide_normal = guide_weight >= CLV_DOMAIN_MIN_GUIDE_ALPHA
					? geometry.xyz / guide_weight : vec3(0.0);
			float guide_normal_length_squared = dot(guide_normal, guide_normal);
			vec3 guide_unit_normal = guide_normal_length_squared > 1e-12
					? guide_normal * inversesqrt(guide_normal_length_squared) : vec3(0.0);
			float cell_center_projection = dot(anchor.xyz
					- (vec3(logical) + 0.5) * step_size, reference_normal);
			float guide_plane_offset = guide_weight > 0.0 ? geometry.w / guide_weight : 1e30;
			bool guide_valid = all(not(isnan(secondary))) && all(not(isinf(secondary)))
					&& all(not(isnan(primary))) && all(not(isinf(primary)))
					&& all(not(isnan(geometry))) && all(not(isinf(geometry)))
					&& all(not(isnan(moments))) && all(not(isinf(moments)))
					&& guide_weight >= CLV_DOMAIN_MIN_GUIDE_ALPHA
					&& moments.x == metadata.w && guide_normal_length_squared > 1e-12
					&& !isnan(guide_normal_length_squared) && !isinf(guide_normal_length_squared)
					&& abs(guide_plane_offset - cell_center_projection) <= plane_tolerance
					&& dot(guide_unit_normal, reference_normal)
						>= CLV_DIFFUSE_DOMAIN_NORMAL_DOT_MIN;
			diffuse_guides_valid = diffuse_guides_valid && guide_valid;
		}
		if (approx_candidate_valid && (approx_have_patch || approx_uncertain_alpha)) {
			mask |= approx_possible_bit;
		}

		bool strict_valid = strict_corners_valid;
		if (strict_valid) {
			vec3 first_corner = (vec3(base) + 0.5) * step_size;
			vec3 last_corner = first_corner + step_size;
			vec3 offset = reference.xyz * (0.75 * step_size);
			vec3 receiver_lower = min(first_corner, first_corner - offset);
			vec3 receiver_upper = max(last_corner, last_corner - offset);
			vec3 certificate_lower = min(receiver_lower, anchor_bounds_lower);
			vec3 certificate_upper = max(receiver_upper, anchor_bounds_upper);
			vec3 certificate_center = (certificate_lower + certificate_upper) * 0.5;
			vec3 certificate_half_extent = (certificate_upper - certificate_lower) * 0.5;
			float strict_magnitude = max(step_size,
					max(max(max(abs(certificate_lower.x), abs(certificate_upper.x)),
						max(abs(certificate_lower.y), abs(certificate_upper.y))),
						max(abs(certificate_lower.z), abs(certificate_upper.z))));
			float strict_margin = max(1e-5,
					strict_magnitude * 1.9073486328125e-6);
			float strict_tolerance = max(1e-5, step_size * 1e-4) + strict_margin;
			strict_valid = clv_surface_bounds_certificate_clear(certificate_center,
					certificate_half_extent
						+ vec3(strict_margin + step_size * CLV_DIFFUSE_NORMAL_ERROR),
					reference_anchor.xyz, reference.xyz, int(reference.w),
					strict_tolerance, strict_margin);
		}
		if (strict_valid) { mask |= 1u << uint(axis); }

		vec3 domain_center = (vec3(base) + vec3(1.0)) * step_size;
		if (flat_corners_valid && transfer_valid && diffuse_guides_valid) {
			vec3 flat_receiver_half_extent = clv_receiver_domain_half_extent(reference_normal,
					step_size, CLV_DIFFUSE_DOMAIN_NORMAL_DOT_MIN);
			vec3 flat_receiver_lower = domain_center - flat_receiver_half_extent;
			vec3 flat_receiver_upper = domain_center + flat_receiver_half_extent;
			vec3 flat_certificate_lower = min(flat_receiver_lower, anchor_bounds_lower);
			vec3 flat_certificate_upper = max(flat_receiver_upper, anchor_bounds_upper);
			vec3 flat_certificate_center = (flat_certificate_lower + flat_certificate_upper) * 0.5;
			vec3 flat_certificate_half_extent = (flat_certificate_upper - flat_certificate_lower) * 0.5;
			float flat_margin = clv_receiver_domain_margin(flat_certificate_center,
					flat_certificate_half_extent, step_size);
			// The union AABB encloses every receiver point and every corner anchor,
			// hence every segment interpolated by the hardware trilinear query.
			if (clv_surface_bounds_certificate_clear(flat_certificate_center,
					flat_certificate_half_extent, reference_anchor.xyz, reference_normal,
					int(reference.w), plane_tolerance, flat_margin)) {
				mask |= 1u << uint(axis + 3);
			}
		}
		if (transfer_valid && curved_corners_valid) {
			vec3 curved_receiver_half_extent = vec3(1.25 * step_size);
			vec3 curved_receiver_lower = domain_center - curved_receiver_half_extent;
			vec3 curved_receiver_upper = domain_center + curved_receiver_half_extent;
			vec3 curved_certificate_lower = min(curved_receiver_lower, anchor_bounds_lower);
			vec3 curved_certificate_upper = max(curved_receiver_upper, anchor_bounds_upper);
			vec3 curved_certificate_center = (curved_certificate_lower + curved_certificate_upper) * 0.5;
			vec3 curved_certificate_half_extent = (curved_certificate_upper - curved_certificate_lower) * 0.5;
			float curved_margin = clv_receiver_domain_margin(curved_certificate_center,
					curved_certificate_half_extent, step_size);
			if (clv_surface_patch_domain_certificate_clear(curved_certificate_center,
					curved_certificate_half_extent, int(reference.w), reference_normal,
					curved_margin)) {
				mask |= 1u << uint(axis + 8);
			}
		}
	}
	// Several changed corners can address the same parent. Their inputs are
	// read-only during this dispatch, so they atomically publish the same mask.
	imageAtomicExchange(support_image, slot, mask);
}
