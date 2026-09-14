// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// Raw strings have a limit of 64k, but MSVC has a limit of 2k in a string literal. This file is split into
// multiple raw strings that are concatenated by the compiler.

R"(shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx, skip_vertex_transform;

/* The terrain depends on this shader to function. Don't change most things in vertex() or 
 * terrain normal calculations in fragment(). You probably only want to customize the 
 * material calculation and PBR application in fragment().
 *
 * Uniforms that begin with _ are private and will not display in the inspector. However, 
 * you can set them via code. You are welcome to create more of your own hidden uniforms.
 *
 * This system only supports albedo, height, normal, roughness. Most textures don't need the other
 * PBR channels. Height can be used as an approximation for AO. For the rare textures do need
 * additional channels, you can add maps for that one texture. e.g. an emissive map for lava.
 *
 */

// Defined Constants
#define COLOR_MAP_DEF vec4(1.0, 1.0, 1.0, 0.5)
#define DIV_255 0.003921568627450 // 1. / 255.
#define DIV_1024 0.0009765625 // 1. / 1024.
#define TAU_16TH -0.392699081698724 // -TAU / 16.

// Inline Functions
#define DECODE_BLEND(control) float(control >>14u & 0xFFu) * DIV_255
#define DECODE_AUTO(control) bool(control & 0x1u)
#define DECODE_BASE(control) int(control >>27u & 0x1Fu)
#define DECODE_OVER(control) int(control >>22u & 0x1Fu)
#define DECODE_ANGLE(control) float(control >>10u & 0xFu) * TAU_16TH
// This math recreates the scale value directly rather than using an 8 float const array.
#define DECODE_SCALE(control) (0.9 - float(((control >>7u & 0x7u) + 3u) % 8u + 1u) * 0.1)
#define DECODE_HOLE(control) bool(control >>2u & 0x1u)

#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
    #define fma(a, b, c) ((a) * (b) + (c))
    #define dFdxCoarse(a) dFdx(a)
    #define dFdyCoarse(a) dFdy(a)
#endif

// Private uniforms
group_uniforms private;
uniform bool _cdlod_enabled = false;
uniform bool _region_grid_enabled = false;
uniform vec3 _target_pos = vec3(0.f);
uniform float _mesh_size = 48.f;
uniform float _subdiv = 1.f;
uniform float _tessellation_level = 0.f;
uniform uint _background_mode = 1u; // NONE = 0, FLAT = 1, NOISE = 2
uniform uint _mouse_layer = 0x80000000u; // Layer 32
uniform float _vertex_spacing = 1.0;
#ifndef TERRAIN_NO_VT
uniform float _avt_coverage_distance = 512.0;
uniform float _avt_base_block_size = 256.0;
uniform float _avt_mip_distance[16];
uniform int _avt_mip_distance_count = 0;
uniform bool _avt_sectors_enabled = false;
uniform bool _avt_coarse_mip_fallback = false;
uniform sampler2D _avt_sector_directory : filter_nearest, repeat_disable;
uniform int _avt_directory_mask = 0;
uniform int _avt_root_level = 1;
#endif
uniform float _vertex_density = 1.0; // = 1./_vertex_spacing
uniform float _region_size = 1024.0;
uniform float _region_texel_size = 0.0009765625; // = 1./region_size
uniform int _region_map_size = 128;
// Chunk -> layer directory. This is a texture, not a uniform int array, so the
// world grid is not capped by the uniform buffer size (32x32 was 4 KB, 64x64 would
// already be 16 KB, 128x128 64 KB). R32F holding slot + 1, 0.0 = no region, so the
// decode below reproduces the old int array values exactly.
uniform highp sampler2D _region_map : filter_nearest, repeat_disable;
//INSERT: MAX_REGIONS_64
//INSERT: MAX_REGIONS_128
//INSERT: MAX_REGIONS_256
//INSERT: MAX_REGIONS_512
//INSERT: MAX_REGIONS_1024
// Surface virtual texture. Off by default: the array path stays authoritative until a
// region's surface source carries more detail than the array can afford to keep
// resident, and enabling this costs an extra indirection lookup per corner.
#ifdef TERRAIN_NO_VT
const bool _surface_vt_enabled = false;
const bool _surface_svt_enabled = false;
const bool _surface_material_enabled = false;
const bool _surface_material_required = false;
#else
uniform bool _surface_vt_enabled = false;
uniform int _surface_vt_region_size = 256;
uniform int _surface_vt_page_size = 256;
uniform int _surface_vt_page_border = 4;
uniform int _surface_vt_pages_per_axis = 4;
uniform int _surface_vt_max_local_mip = 2;
uniform int _surface_vt_indirection_size = 256;
uniform highp sampler2D _surface_vt_indirection : filter_nearest, repeat_disable;
uniform highp sampler2DArray _surface_vt_atlas : repeat_disable;
// Layer -> virtual page block origin inside the indirection, or (-1, -1) when that
// sector has no block. Indexed by the layer slot the chunk directory returns.
uniform vec2 _surface_vt_blocks[MAX_REGIONS];
uniform float _surface_vt_block_sizes[MAX_REGIONS];
uniform bool _surface_material_enabled = false;
uniform bool _surface_material_required = false;
uniform highp sampler2DArray _surface_material_albedo : filter_linear, repeat_disable;
uniform highp sampler2DArray _surface_material_normal : filter_linear, repeat_disable;
uniform highp sampler2DArray _surface_material_params : filter_linear, repeat_disable;
#endif
// Stored surface resolution in texels per region texel. The virtual texture's pages
// are produced from the dense payload, so its page grid and texel lookups are in
// source texels; the region texture array stays at region_size and is untouched.
uniform int _surface_density = 1;
#ifndef TERRAIN_NO_VT
// Far field: a world-space page grid at a coarser texel density. The page coordinate is
// derived from the world position and the grid is centred on the origin, so no per-layer
// block table is needed -- the CPU uses the same `(page + half) >> mip` formula.
uniform bool _surface_svt_enabled = false;
uniform float _surface_svt_page_world = 512.0;
uniform int _surface_svt_page_size = 256;
uniform int _surface_svt_page_border = 4;
uniform int _surface_svt_max_mip = 4;
uniform int _surface_svt_indirection_size = 1024;
// Distance -> level table, in metres: entry m is the largest camera distance sampled at
// world mip m. `_surface_svt_mip_distance_count` 0 keeps the automatic rule (one level
// per doubling of the page's world size). The CPU demand pass resolves a page's level
// with the same table, so the level that was produced is the level sampled here.
uniform int _surface_svt_mip_distance_count = 0;
uniform float _surface_svt_mip_distance[16];
uniform highp sampler2D _surface_svt_indirection : filter_nearest, repeat_disable;
uniform highp sampler2DArray _surface_svt_atlas : repeat_disable;
#endif
uniform float _texture_normal_depth_array[32];
uniform float _texture_ao_strength_array[32];
uniform float _texture_ao_affect_array[32];
uniform float _texture_roughness_mod_array[32];
uniform float _texture_uv_scale_array[32];
uniform vec2 _texture_detile_array[32];
uniform vec4 _texture_color_array[32];
uniform highp sampler2DArray _height_maps : repeat_disable;
uniform highp sampler2DArray _control_maps : repeat_disable;
uniform highp sampler2DArray _surface_maps : repeat_disable;
//INSERT: TEXTURE_SAMPLERS_LINEAR_ANISOTROPIC
//INSERT: TEXTURE_SAMPLERS_LINEAR
//INSERT: TEXTURE_SAMPLERS_NEAREST_ANISOTROPIC
//INSERT: TEXTURE_SAMPLERS_NEAREST
uniform highp sampler2DArray _color_maps : source_color, FILTER_METHOD, repeat_disable;
uniform highp sampler2DArray _texture_array_albedo : source_color, FILTER_METHOD, repeat_enable;
uniform highp sampler2DArray _texture_array_normal : hint_normal, FILTER_METHOD, repeat_enable;
uniform vec3 _texture_slope_params_array[32];
uniform vec3 _light_direction = vec3(0., 0., 0);
uniform vec3 _light_color : source_color = vec3(1.0, 1.0, .735);
group_uniforms;

// Public uniforms
group_uniforms general_uniforms;
//INSERT: FLAT_UNIFORMS
uniform bool flat_terrain_normals = false;
uniform float distant_normal_scale : hint_range(1.0, 10.0, 0.1) = 2.0;
// Legacy 2-texture blend sharpness. Retained so existing materials keep a valid
// parameter; the IdWeight material path uses the per-texture-asset
// slope_blend_sharpness instead.
uniform float blend_sharpness : hint_range(0, 1) = 0.5;
group_uniforms;

//INSERT: AUTO_SHADER_UNIFORMS
//INSERT: DISPLACEMENT_UNIFORMS
//INSERT: MACRO_VARIATION_UNIFORMS

group_uniforms mipmaps;
uniform float bias_distance : hint_range(0.0, 16384.0, 0.1) = 512.0;
uniform float mipmap_bias : hint_range(0.5, 1.5, 0.01) = 1.0;
uniform float depth_blur : hint_range(0.0, 35.0, 0.1) = 0.0;
group_uniforms;

//INSERT: WORLD_NOISE_UNIFORMS

// Varyings & Types

struct material {
	vec4 albedo_height;
	vec4 normal_rough;
	float normal_map_depth;
	float ao;
	float ao_affect;
	float total_weight;
};

varying vec3 v_vertex;
varying float v_vertex_xz_dist;
varying vec3 v_camera_pos;
//INSERT: IDWEIGHT_R16
)"

		R"(
////////////////////////
// Vertex
////////////////////////

// Reads the chunk directory and returns the texture array layer for a chunk, or -1
// when the chunk is outside the world grid, holds no region, or its layer is past
// MAX_REGIONS. Kept identical in meaning to the old `_region_map[...] - 1` lookup.
int get_region_layer(const ivec2 p_chunk) {
	ivec2 pos = p_chunk + (_region_map_size / 2);
	int bounds = int(uint(pos.x | pos.y) < uint(_region_map_size));
	// Clamp before fetching: an out of range texelFetch is undefined, and `bounds`
	// is what actually rejects the sample.
	ivec2 clamped = clamp(pos, ivec2(0), ivec2(_region_map_size - 1));
	int map_val = int(texelFetch(_region_map, clamped, 0).r + 0.5);
	int raw_index = map_val - 1;
	// Real regions limited by max_regions
	int is_region = bounds * int(raw_index >= 0) * int(raw_index < MAX_REGIONS);
	// Editor dummies are negative; keep them != -1 so the shader still sees a region
	int is_dummy = bounds * int(map_val < 0);
	int layer_index = is_region * raw_index
	                + is_dummy * (map_val - 1)
	                - (1 - is_region - is_dummy);
	return layer_index;
}

// Takes in world space XZ (UV) coordinates
// Returns ivec3 with:
// XY: (0 to _region_size - 1) coordinates within a region
// Z: layer index used for texturearrays, -1 if not in a region
ivec3 get_index_coord(const vec2 uv) {
	vec2 r_uv = round(uv);
	ivec2 chunk = ivec2(floor(r_uv * _region_texel_size));
	return ivec3(ivec2(mod(r_uv, _region_size)), get_region_layer(chunk));
}

// Near-field surface id/weight through the virtual texture. Walks the indirection mip
// chain from local mip 0 upward and takes the first resident page, exactly like the
// CPU-side lookup, so a coarse page serves the finer texels it covers. Returns false
// when the sector has no block or no page covers this texel, and the caller falls back
// to the region texture array.
//
// `p_surface_texel` is a texel of the *stored* payload, i.e. on the surface_density
// grid, not a region texel. The page grid mirrors Terrain3DData::produce_surface_pages:
// the sector block is _surface_vt_pages_per_axis pages per axis at local mip 0, so mip
// m has max(1, pages >> m) pages per axis covering region_size * density /
// pages_at_mip source texels each.
#ifndef TERRAIN_NO_VT
bool surface_vt_sample(const int p_layer, const ivec2 p_surface_texel, out uint r_value) {
	if (!_surface_vt_enabled || p_layer < 0 || p_layer >= MAX_REGIONS) {
		return false;
	}
	vec2 block = _surface_vt_blocks[p_layer];
	if (block.x < 0.0) {
		return false;
	}
	// Not `const`: Godot's shader language requires constant expressions there and
	// these depend on uniforms.
	int density = max(1, _surface_density);
	int block_size = max(1, int(_surface_vt_block_sizes[p_layer]));
	int span0 = max(1, _surface_vt_region_size * density / block_size);
	// The chunk's own layer slot already identifies the sector, so the virtual page is
	// the block origin plus the local page coordinate.
	ivec2 virtual_page = ivec2(block) + p_surface_texel / span0;
	float stored = float(_surface_vt_page_size + 2 * _surface_vt_page_border);
	for (int mip = 0; mip <= _surface_vt_max_local_mip; mip++) {
		if ((1 << mip) > block_size) { break; }
		ivec2 coord = virtual_page >> mip;
		int level_size = max(1, _surface_vt_indirection_size >> mip);
		// Page-table lookup must bypass sampler LOD clamps and filtering.
		float slot_f = texelFetch(_surface_vt_indirection, clamp(coord, ivec2(0), ivec2(level_size - 1)), mip).r;
		int slot = int(slot_f + 0.5);
		if (slot == 65535 || slot < 0) {
			continue;
		}
		// Source texel origin of the matched page, relative to the sector.
		int span = span0 << mip;
		ivec2 page_origin = ((coord << mip) - ivec2(block)) * span0;
		ivec2 offset = p_surface_texel - page_origin;
		ivec2 page_texel = clamp(offset * _surface_vt_page_size / span + _surface_vt_page_border,
				ivec2(0), ivec2(int(stored) - 1));
		r_value = uint(texelFetch(_surface_vt_atlas, ivec3(page_texel, slot), 0).r * 65535.0 + 0.5);
		return true;
	}
	return false;
}

// The surface id/weight for one corner: virtual texture first, region texture array as
// the fallback. `p_index` addresses the array layer (region texels, 1 texel/m) and
// `p_surface_texel` addresses the stored payload (the surface_density grid). Both are
// needed because the array deliberately stays at region_size while the payload is
// density times finer.
)"

R"(
// Far field through the sparse virtual texture. `p_world` is world XZ in metres. The
// page grid is world aligned and centred on the origin, so the page is `floor(world /
// page_world)` and the indirection coordinate is `(page + half) >> mip`, which is the
// same formula Terrain3DVirtualTexture::world_page_to_virtual publishes with.
//
// `p_world` carries the terrain height of the fragment so the distance matches the one
// the demand pass measured for the page: a page is produced for a level by its distance
// from the camera, and this is the distance of the fragment inside it.
float surface_svt_distance(vec2 p_world) {
	return length(vec3(p_world.x, v_vertex.y, p_world.y) - v_camera_pos);
}

// The far field's distance -> level rule. Mirrors
// Terrain3D::get_surface_svt_mip_for_distance() exactly: with an explicit table, level m
// covers distances up to entry m; without one, a mip m page covers page_world * 2^m
// metres, so level m serves out to twice that.
int surface_svt_mip_for_distance(float p_distance) {
	if (_surface_svt_mip_distance_count > 0) {
		int last = min(_surface_svt_mip_distance_count - 1, _surface_svt_max_mip);
		int mip = 0;
		while (mip < last && p_distance > _surface_svt_mip_distance[mip]) {
			mip++;
		}
		return min(mip, _surface_svt_max_mip);
	}
	int mip = 0;
	float threshold = max(1.0, _surface_svt_page_world * 2.0);
	while (mip < _surface_svt_max_mip && p_distance > threshold) {
		threshold *= 2.0;
		mip++;
	}
	return mip;
}

// Sampling starts at the level the distance selects and only ever walks coarser, so the
// renderer can never show a level finer than the distance allows: a missing page
// degrades to the next level up (the protected roots guarantee one exists) instead of
// picking whatever finer page happens to still be resident.
bool surface_svt_sample(const vec2 p_world, out uint r_value) {
	if (!_surface_svt_enabled) {
		return false;
	}
	int half = _surface_svt_indirection_size >> 1;
	int stored = _surface_svt_page_size + 2 * _surface_svt_page_border;
	ivec2 page = ivec2(floor(p_world / _surface_svt_page_world));
	if (any(lessThan(page + ivec2(half), ivec2(0))) || any(greaterThanEqual(page + ivec2(half), ivec2(_surface_svt_indirection_size)))) { return false; }
	int start_mip = surface_svt_mip_for_distance(surface_svt_distance(p_world));
	for (int mip = start_mip; mip <= _surface_svt_max_mip; mip++) {
		ivec2 coord = (page + ivec2(half)) >> mip;
		int level_size = max(1, _surface_svt_indirection_size >> mip);
		float slot_f = texelFetch(_surface_svt_indirection, clamp(coord, ivec2(0), ivec2(level_size - 1)), mip).r;
		int slot = int(slot_f + 0.5);
		if (slot == 65535 || slot < 0) {
			continue;
		}
		float mip_world = _surface_svt_page_world * float(1 << mip);
		vec2 page_origin = vec2(page >> mip) * mip_world;
		// Not clamped to [0, 1]: a position just outside the page core belongs to the
		// page's border texels, which the producer filled from the neighbours.
		vec2 offset = (p_world - page_origin) / mip_world;
		ivec2 page_texel = clamp(ivec2(floor(offset * float(_surface_svt_page_size))) +
						_surface_svt_page_border,
				ivec2(0), ivec2(stored - 1));
		r_value = uint(texelFetch(_surface_svt_atlas, ivec3(page_texel, slot), 0).r * 65535.0 + 0.5);
		return true;
	}
	return false;
}

// Both virtual address spaces resolve into the same material arrays. A missing
// or pending selected page displays diagnostics; residency never selects a substitute mip.
bool surface_material_slot(int slot, vec2 offset, int page_size, int border,
		out material r_mat, out vec3 r_normal) {
	if (slot < 0 || slot == 65535) { return false; }
	vec3 coord = vec3((offset * float(page_size) + float(border)) / float(page_size + border * 2), float(slot));
	vec4 params = textureLod(_surface_material_params, coord, 0.0);
	if (params.a < 0.99) { return false; }
	vec4 albedo = textureLod(_surface_material_albedo, coord, 0.0);
	vec4 normal_rough = textureLod(_surface_material_normal, coord, 0.0);
	r_mat = material(albedo, normal_rough, params.x, params.y, params.z, 1.0);
	r_normal = normal_rough.xyz;
	return true;
}

bool surface_svt_material_sample(vec2 world, out material r_mat, out vec3 r_normal) {
	if (_surface_svt_enabled) {
		ivec2 page = ivec2(floor(world / _surface_svt_page_world));
		ivec2 virtual_page = page + ivec2(_surface_svt_indirection_size >> 1);
		if (all(greaterThanEqual(virtual_page, ivec2(0))) && all(lessThan(virtual_page, ivec2(_surface_svt_indirection_size)))) {
			int start_mip = surface_svt_mip_for_distance(surface_svt_distance(world));
			for (int mip = start_mip; mip <= _surface_svt_max_mip; mip++) {
				ivec2 coord = virtual_page >> mip;
				int level_size = max(1, _surface_svt_indirection_size >> mip);
				int slot = int(texelFetch(_surface_svt_indirection, coord, mip).r + 0.5);
				vec2 offset = fract(world / (_surface_svt_page_world * float(1 << mip)));
				if (surface_material_slot(slot, offset, _surface_svt_page_size, _surface_svt_page_border, r_mat, r_normal)) { return true; }
			}
		}
	}
	return false;
}

vec4 avt_directory_texel(int index) {
	int width = textureSize(_avt_sector_directory, 0).x;
	return texelFetch(_avt_sector_directory, ivec2(index % width, index / width), 0);
}

bool avt_find_sector(ivec2 key, int level, out vec4 block) {
	if (_avt_directory_mask == 0) { return false; }
	uint hash = uint(key.x) * 73856093u ^ uint(key.y) * 19349663u ^ uint(level) * 83492791u;
	int index = int(hash & uint(_avt_directory_mask));
	for (int probe = 0; probe <= _avt_directory_mask; ++probe) {
		vec4 entry = avt_directory_texel(index * 2);
		if (entry.w == 0.0) { return false; }
		if (all(equal(ivec2(entry.xy), key)) && int(entry.z) == level) {
			block = avt_directory_texel(index * 2 + 1);
			return true;
		}
		index = (index + 1) & _avt_directory_mask;
	}
	return false;
}

int avt_distance_mip(float distance_to_camera, int top) {
	int mip = 0;
	float edge = 8.0;
	while (mip < top) {
		if (mip < _avt_mip_distance_count) { edge = _avt_mip_distance[mip]; }
		if (distance_to_camera <= edge) { break; }
		mip++; edge *= 2.0;
	}
	return mip;
}

)"

R"(
// Select by pixel footprint across local mips and the world hierarchy.
// Strict by default; optional coarse recovery stays within the AVT hierarchy.
bool avt_resolve(vec2 world, float pixel_world, float minimum_texel, out material result, out vec3 result_normal,
		out float texel_world, out bool last_mip) {
	for (int level = 0; level <= _avt_root_level; ++level) {
		float span = 64.0 * float(1 << level);
		// The first world parent has a fixed world footprint. Its texel size
		// can be less than twice the last local mip for non-power-of-two density
		// (e.g. 768 texels/m); switch at its actual size, not a rounded local LOD.
		if (level == 0 && _avt_base_block_size > 1.0 && pixel_world >= 128.0 / float(_surface_vt_page_size)) { continue; }
		if (level > 0 && level < _avt_root_level && pixel_world >= 2.0 * span / float(_surface_vt_page_size)) { continue; }
		ivec2 sector = ivec2(floor(world / span));
		vec4 entry;
		if (!avt_find_sector(sector, level, entry)) {
			if (_avt_coarse_mip_fallback) { continue; }
			return false;
		}
		float base_texel = span / (entry.w * float(_surface_vt_page_size));
		int top = int(round(log2(entry.z)));
		int start = int(floor(log2(max(1.0, pixel_world / base_texel))));
		start = max(start, int(ceil(log2(max(1.0, minimum_texel / base_texel)))));
		// A world parent is also the clamp for footprints larger than the tree root.
		if (level == _avt_root_level && minimum_texel <= base_texel * float(1 << top)) { start = min(start, top); }
		// Near a negative sector boundary, subtraction can round an interior
		// coordinate up to 1.0. Keep the address in the sector selected above;
		// otherwise its last pixel reads the next indirection block.
		vec2 local = clamp(world / span - vec2(sector), vec2(0.0), vec2(0.99999994));
		ivec2 page = ivec2(entry.xy) + ivec2(floor(local * entry.w));
		for (int mip = max(0, start); mip <= top; ++mip) {
			int slot = int(texelFetch(_surface_vt_indirection, page >> mip, mip).r + 0.5);
			vec2 offset = fract(local * entry.w / float(1 << mip));
			if (!surface_material_slot(slot, offset, _surface_vt_page_size, _surface_vt_page_border, result, result_normal)) {
				if (_avt_coarse_mip_fallback) { continue; }
				return false;
			}
			texel_world = base_texel * float(1 << mip);
			last_mip = level == _avt_root_level && mip == top;

			return true;
		}
	}
	return false;
}

bool avt_filtered_sample(vec2 world, float pixel_world, out material r_mat, out vec3 r_normal) {
	float fine_texel;
	bool last_mip;
	if (!avt_resolve(world, pixel_world, 0.0, r_mat, r_normal, fine_texel, last_mip)) { return false; }
	// Normal mip interpolation only: no arrival or missing-neighbour blending.
	// Clamp the mip range at its actual end, independently of page residency.
	if (last_mip || pixel_world <= fine_texel) { return true; }
	material coarse;
	vec3 coarse_normal;
	float coarse_texel;
	if (!avt_resolve(world, pixel_world, fine_texel * 1.001, coarse, coarse_normal, coarse_texel, last_mip)) { return false; }
	float mip_weight = clamp(log2(max(pixel_world / fine_texel, 1.0)) / log2(coarse_texel / fine_texel), 0.0, 1.0);
	float weight = mip_weight;
	r_mat.albedo_height = mix(r_mat.albedo_height, coarse.albedo_height, weight);
	r_mat.normal_rough = mix(r_mat.normal_rough, coarse.normal_rough, weight);
	r_mat.normal_map_depth = mix(r_mat.normal_map_depth, coarse.normal_map_depth, weight);
	r_mat.ao = mix(r_mat.ao, coarse.ao, weight);
	r_mat.ao_affect = mix(r_mat.ao_affect, coarse.ao_affect, weight);
	r_normal = mix(r_normal, coarse_normal, weight);
	return true;
}

bool surface_material_sample(vec2 world, out material r_mat, out vec3 r_normal) {
	if (!_surface_material_enabled) { return false; }
	if (_surface_vt_enabled && _avt_sectors_enabled) {
		float pixel_world = max(length(dFdx(world)), length(dFdy(world)));
		float reach = max(64.0, _avt_coverage_distance);
		float far_weight = _surface_svt_enabled ? smoothstep(reach * 0.75, reach, distance(world, v_camera_pos.xz)) : 0.0;
		if (far_weight >= 1.0) { return surface_svt_material_sample(world, r_mat, r_normal); }
		bool ready = avt_filtered_sample(world, pixel_world, r_mat, r_normal);
		if (far_weight <= 0.0) { return ready; }
		material far_mat;
		vec3 far_normal;
		if (!ready || !surface_svt_material_sample(world, far_mat, far_normal)) { return false; }
		r_mat.albedo_height = mix(r_mat.albedo_height, far_mat.albedo_height, far_weight);
		r_mat.normal_rough = mix(r_mat.normal_rough, far_mat.normal_rough, far_weight);
		r_mat.normal_map_depth = mix(r_mat.normal_map_depth, far_mat.normal_map_depth, far_weight);
		r_mat.ao = mix(r_mat.ao, far_mat.ao, far_weight);
		r_mat.ao_affect = mix(r_mat.ao_affect, far_mat.ao_affect, far_weight);
		r_normal = mix(r_normal, far_normal, far_weight);
		return true;
	}
	float region_world = _region_size * _vertex_spacing;
	ivec2 region = ivec2(floor(world / region_world));
	int layer = get_region_layer(region);
	if (_surface_vt_enabled && layer >= 0 && layer < MAX_REGIONS) {
		ivec2 block = ivec2(_surface_vt_blocks[layer]);
		int size = max(1, int(_surface_vt_block_sizes[layer]));
		vec2 local = world / region_world - vec2(region);
		ivec2 virtual_page = block + ivec2(floor(local * float(size)));
		if (block.x >= 0) {
			for (int mip = _avt_mip_distance_count > 0 ? avt_distance_mip(surface_svt_distance(world), int(round(log2(float(size))))) : 0; mip <= _surface_vt_max_local_mip; mip++) {
				if ((1 << mip) > size) { break; }
				ivec2 coord = virtual_page >> mip;
				int level_size = max(1, _surface_vt_indirection_size >> mip);
				int slot = int(texelFetch(_surface_vt_indirection, coord, mip).r + 0.5);
				vec2 offset = fract(local * float(max(1, size >> mip)));
				if (surface_material_slot(slot, offset, _surface_vt_page_size, _surface_vt_page_border, r_mat, r_normal)) { return true; }
				return false;
			}
			return false; // This region is assigned to AVT; expose its missing pages.
		}
	}
	return surface_svt_material_sample(world, r_mat, r_normal);
}
#else
bool surface_material_sample(vec2 world, out material r_mat, out vec3 r_normal) {
	return false;
}
#endif

// The surface id/weight for one corner: near field first, then the far field, then the
// region texture array. `p_index` addresses the array layer (region texels, 1 texel/m),
// `p_surface_texel` addresses the stored payload (the surface_density grid) and
// `p_world` is the corner's world XZ, which is what the far field is addressed by. All
// three are needed because the array stays at region_size, the near field is region
// aligned and the far field is world aligned.
uint get_surface_value(const vec2 p_world, const ivec3 p_index, const ivec2 p_surface_texel) {
#ifndef TERRAIN_NO_VT
	if (p_index.z > -1 && _surface_vt_enabled) {
		uint value;
		if (surface_vt_sample(p_index.z, p_surface_texel, value)) {
			return value;
		}
	}
	if (_surface_svt_enabled) {
		uint value;
		if (surface_svt_sample(p_world, value)) {
			return value;
		}
	}
#endif
	return p_index.z >= 0 ? uint(texelFetch(_surface_maps, p_index, 0).r * 65535.0 + 0.5) : 0u;
}

// World XZ of one corner of the surface cell that contains p_uv. At density 1 this is
// the integer metre corner the array and near field have always used.
vec2 surface_corner(const vec2 p_uv, const ivec2 p_offset) {
	float density = float(max(1, _surface_density));
	return (floor(p_uv * density) + vec2(p_offset)) * (_vertex_spacing / density);
}

// Corner texel of the density cell that contains p_uv (world XZ in metres), on the
// stored payload's grid. At density 1 this is the region texel the array fallback and
// the pre-density shader used, bit for bit.
ivec2 get_surface_texel(const vec2 p_uv, const ivec2 p_offset) {
	// Not `const`: these derive from a uniform, which Godot's shader language does not
	// accept in a constant expression.
	float density = float(max(1, _surface_density));
	vec2 size = vec2(_region_size) * density;
	return ivec2(mod(floor(p_uv * density) + vec2(p_offset), size));
}

// Takes in descaled (world_space / region_size) world to region space XZ (UV2) coordinates, returns vec3 with:
// XY: (0. to 1.) coordinates within a region
// Z: layer index used for texturearrays, -1 if not in a region
vec3 get_index_uv(const vec2 uv2) {
	int layer_index = get_region_layer(ivec2(floor(uv2)));
	// Clamp the table index; callers test z > -1 before using the result.
	return vec3(uv2 - _region_locations[max(layer_index, 0)], float(layer_index));
}

float interpolated_height(vec2 pos) {
	const vec2 offsets = vec2(0, 1);
	vec2 index_id = floor(pos);
	ivec3 index[4];
	index[0] = get_index_coord(index_id + offsets.xy);
	index[1] = get_index_coord(index_id + offsets.yy);
	index[2] = get_index_coord(index_id + offsets.yx);
	index[3] = get_index_coord(index_id + offsets.xx);
	float h0 = texelFetch(_height_maps, index[0], 0).r;
	float h1 = texelFetch(_height_maps, index[1], 0).r;
	float h2 = texelFetch(_height_maps, index[2], 0).r;
	float h3 = texelFetch(_height_maps, index[3], 0).r;
	vec2 f = fract(pos);
	vec2 i = 1.0 - f;
	vec4 w = vec4(i.x * f.y, f.x * f.y, f.x * i.y, i.x * i.y);
	float h = h0 * w[0] + h1 * w[1] + h2 * w[2] + h3 * w[3];
	return h;
}

//INSERT: DISPLACEMENT_FUNCTIONS
//INSERT: NONE_FUNCTIONS
//INSERT: FLAT_FUNCTIONS
//INSERT: WORLD_NOISE_FUNCTIONS

void vertex() {
	// Save Camera Position to varying for access in later functions
	v_camera_pos = MAIN_CAM_INV_VIEW_MATRIX[3].xyz;

	// Get vertex of flat plane in world coordinates and set world UV
	v_vertex = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;

	// Distance from target node to vertex on a flat plane
	v_vertex_xz_dist = length(v_vertex.xz - _target_pos.xz);

	// Geomorph vertex across clipmap LODs, set end and start for linear height interpolate
	float scale = MODEL_MATRIX[0][0];
	float vertex_lerp;
	vec2 shift;
	if (_region_grid_enabled) {
		vertex_lerp = _cdlod_enabled ? clamp((length(v_vertex.xz - v_camera_pos.xz) - INSTANCE_CUSTOM.x) * INSTANCE_CUSTOM.y, 0.0, 1.0) : 0.0;
		shift = mod(VERTEX.xz, vec2(2.0));
	} else {
		float inv_scale = 1.0 / scale;
		float max_xz = max(abs(v_vertex.x - _target_pos.x), abs(v_vertex.z - _target_pos.z));
		vertex_lerp = smoothstep(0.0, 1.0, (max_xz * inv_scale - _mesh_size - 4.0) / (_mesh_size - 4.0));
		vec2 vertex_fract = fract(VERTEX.xz * 0.5) * 2.0;
		// For LOD0 morph from a regular grid to an alternating grid to align with LOD1+
		shift = (scale < _vertex_spacing / _subdiv + 1e-6) ? // LOD0 or not
			// Shift from regular to symmetric
			mix(vertex_fract, vec2(vertex_fract.x, -vertex_fract.y),
				round(fract(round(mod(v_vertex.z * inv_scale, 4.0)) *
				round(mod(v_vertex.x * inv_scale, 4.0)) * 0.25))) :
			// Symmetric shift
			vertex_fract * round((fract(v_vertex.xz * 0.25 * inv_scale) - 0.5) * 4.0);
	}
	vec2 start_pos = v_vertex.xz * _vertex_density;
	vec2 end_pos = (v_vertex.xz - shift * scale) * _vertex_density;
	v_vertex.xz -= shift * scale * vertex_lerp;

	// UV coordinates in region space. 0-1 covers 1 region, 1-2 is the next region, etc.
	UV = v_vertex.xz * _vertex_density;

	// UV coordinates in region space + texel offset. Values are 0 to 1 within regions
	UV2 = fma(UV, vec2(_region_texel_size), vec2(0.5 * _region_texel_size));

	// Discard vertices for Holes. 1 lookup
	ivec3 v_region = get_index_coord(start_pos);
	uint control = floatBitsToUint(texelFetch(_control_maps, v_region, 0)).r;
	bool hole = DECODE_HOLE(control);

	vec3 displacement = vec3(0.);
	// Show holes to all cameras except mouse camera (on exactly 1 layer)
	if ( !(CAMERA_VISIBLE_LAYERS == _mouse_layer) && (hole
//INSERT: NONE_CHECK
		)){
		v_vertex.x = 0. / 0.;
	} else {
		// Set final vertex height.
		float h;
		// This branch is static for each of the clipmap segments
		// Interpolated reads only occur where sub-texel values are required.
		if (scale < _vertex_spacing) {
			h = interpolated_height(UV);
		} else {
			ivec3 coord_a = get_index_coord(start_pos);
			ivec3 coord_b = get_index_coord(end_pos);
			h = mix(texelFetch(_height_maps, coord_a, 0).r, texelFetch(_height_maps, coord_b, 0).r, vertex_lerp);
		}

//INSERT: FLAT_VERTEX
//INSERT: WORLD_NOISE_VERTEX
//INSERT: DISPLACEMENT_VERTEX
		v_vertex.y = h;
	}

	// Convert model space to view space w/ skip_vertex_transform render mode
	// Include displacement without modifying v_vertex.
	VERTEX = (VIEW_MATRIX * vec4(v_vertex + displacement, 1.0)).xyz;
	NORMAL = normalize((MODELVIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	BINORMAL = normalize((MODELVIEW_MATRIX * vec4(BINORMAL, 0.0)).xyz);
	TANGENT = normalize((MODELVIEW_MATRIX * vec4(TANGENT, 0.0)).xyz);
}
)"

		R"(
////////////////////////
// Fragment
////////////////////////

float random(in vec2 xy) {
	return fract(sin(dot(xy, vec2(12.9898, 78.233))) * 43758.5453);
}

vec2 rotate_vec2(const vec2 v, const vec2 cs) {
	return vec2(fma(cs.x, v.x,  cs.y * v.y), fma(cs.x, v.y, -cs.y * v.x));
}

// The legacy control-map material path (accumulate_material) was removed when
// the IdWeight surface evaluator replaced the 2-texture-per-texel
// material model. Its dual scaling, auto-shader and control-map angle/scale
// features were tied to that model and are superseded by the per-material
// slope parameters and the R16 surface map. Materials are now sampled
// exclusively by accumulate_idweight_layer() below.

// IdWeight layer sampling. Samples one material layer with world-space
// projection, detiling and normal reconstruction, accumulating into `mat`.
// `projectionAxis` selects the triplanar projection plane (0=ZY, 1=XZ, 2=XY).
void accumulate_idweight_layer(const int id, const float weight, const vec3 base_ddx, const vec3 base_ddy,
		const uint projectionAxis, const vec3 geometricNormalWS,
		inout material mat, inout vec3 blendedNormalWS) {
	float id_scale = _texture_uv_scale_array[id];
	vec3 i_vertex = v_vertex;
	vec2 i_uv = idweight_get_projection_position(i_vertex, projectionAxis) * id_scale;
	vec2 i_dd_uv = idweight_get_projection_position(base_ddx, projectionAxis) * id_scale;
	vec2 i_dd_uv2 = idweight_get_projection_position(base_ddy, projectionAxis) * id_scale;

	// Detiling
	vec2 uv_center = floor(i_uv + 0.5);
	vec2 id_detile = fma(random(uv_center), 2.0, -1.0) * _texture_detile_array[id] * TAU;
	vec2 id_cs_angle = vec2(cos(id_detile.x), sin(id_detile.x));
	vec2 id_uv = rotate_vec2(i_uv - uv_center, id_cs_angle) + uv_center + id_detile.y - 0.5;
	// Rotate derivatives counter to UV rotation for correct anisotropic filtering
	id_cs_angle = vec2(id_cs_angle.x, -id_cs_angle.y);
	i_dd_uv = rotate_vec2(i_dd_uv, id_cs_angle);
	i_dd_uv2 = rotate_vec2(i_dd_uv2, id_cs_angle);

	vec4 alb = textureGrad(_texture_array_albedo, vec3(id_uv, float(id)), i_dd_uv, i_dd_uv2);
	vec4 nrm = textureGrad(_texture_array_normal, vec3(id_uv, float(id)), i_dd_uv, i_dd_uv2);
	alb.rgb *= _texture_color_array[id].rgb;
	nrm.a = clamp(nrm.a + _texture_roughness_mod_array[id], 0., 1.);
	// Decode the Godot Y-up normal map into (nU, nH, nV) with the out-of-plane
	// component re-derived after the material's normal depth is applied.
	vec3 normalPS = idweight_decode_normal(nrm, _texture_normal_depth_array[id]);
	float ao = length(nrm.xyz) * 2.0 - 1.0;
	ao = mix(ao * ao * _texture_ao_strength_array[id] + 1.0 - _texture_ao_strength_array[id], 1.0, alb.a * alb.a);

	// Slope-based normal damp: blend sampled normal toward the geometric normal.
	vec3 layerNormalWS = idweight_projection_normal_to_world(normalPS, projectionAxis, geometricNormalWS);
	float normalDamp = idweight_saturate(_texture_slope_params_array[id].z * 0.001);
	layerNormalWS = normalize(mix(layerNormalWS, normalize(geometricNormalWS), normalDamp));

	mat.albedo_height = fma(alb, vec4(weight), mat.albedo_height);
	mat.normal_rough = fma(nrm, vec4(weight), mat.normal_rough);
	mat.normal_map_depth = fma(_texture_normal_depth_array[id], weight, mat.normal_map_depth);
	mat.ao = fma(ao, weight, mat.ao);
	mat.ao_affect = fma(_texture_ao_affect_array[id], weight, mat.ao_affect);
	mat.total_weight += weight;
	blendedNormalWS += layerNormalWS * weight;
}

// Pair-aware slope evaluation. `slopeDistanceBlend` fades the slope effect
// with camera distance (full inside 180m, disabled beyond 200m). The overlay
// normal is sampled from the overlay material's normal texture and flattened
// toward up by the vertex alignment, then damped by the overlay's
// slope_based_damp before the tangent test.
float idweight_evaluate_slope_overlay_weight(uint packed, uint backgroundId, uint overlayId,
		float slopeDistanceBlend, uint projectionAxis, vec3 geometricNormalWS,
		vec3 base_ddx, vec3 base_ddy) {
	if (overlayId == backgroundId) {
		return 0.0;
	}
	// blendSharpness protection: clamp to [0.1, 1000] then /1000, so legacy 0
	// still produces a valid slope blend and never degrades to linear weight.
	float blendSharpness = idweight_saturate(clamp(_texture_slope_params_array[int(backgroundId)].x, 0.1, 1000.0) * 0.001);
	float slopeBasedDamp = idweight_saturate(_texture_slope_params_array[int(overlayId)].y * 0.001);

	// Sample the overlay normal in the active projection plane.
	float id_scale = _texture_uv_scale_array[int(overlayId)];
	vec2 i_uv = idweight_get_projection_position(v_vertex, projectionAxis) * id_scale;
	vec2 i_dd_uv = idweight_get_projection_position(base_ddx, projectionAxis) * id_scale;
	vec2 i_dd_uv2 = idweight_get_projection_position(base_ddy, projectionAxis) * id_scale;
	vec2 uv_center = floor(i_uv + 0.5);
	vec2 id_detile = fma(random(uv_center), 2.0, -1.0) * _texture_detile_array[int(overlayId)] * TAU;
	vec2 id_cs_angle = vec2(cos(id_detile.x), sin(id_detile.x));
	vec2 id_uv = rotate_vec2(i_uv - uv_center, id_cs_angle) + uv_center + id_detile.y - 0.5;
	id_cs_angle = vec2(id_cs_angle.x, -id_cs_angle.y);
	i_dd_uv = rotate_vec2(i_dd_uv, id_cs_angle);
	i_dd_uv2 = rotate_vec2(i_dd_uv2, id_cs_angle);
	vec4 nrm = textureGrad(_texture_array_normal, vec3(id_uv, float(overlayId)), i_dd_uv, i_dd_uv2);
	vec3 normalPS = idweight_decode_normal(nrm, _texture_normal_depth_array[int(overlayId)]);
	vec3 combinedVerticalNormalWS = idweight_projection_normal_to_world(normalPS, projectionAxis, geometricNormalWS);

	vec3 normalizedGeometricNormalWS = normalize(geometricNormalWS);
	float vertexUp = idweight_saturate(dot(normalizedGeometricNormalWS, vec3(0.0, 1.0, 0.0)));
	vec3 flattenedVerticalNormal = normalize(mix(combinedVerticalNormalWS, vec3(0.0, 1.0, 0.0), vertexUp));
	vec3 slopeNormal = normalize(mix(combinedVerticalNormalWS, flattenedVerticalNormal, slopeBasedDamp));
	return idweight_compute_slope_tangent(slopeNormal, idweight_slope_threshold(packed), blendSharpness);
}

void idweight_add_pair_vertex(uint packed, float barycentric,
		uint packedBottomLeft, uint packedBottomRight, uint packedTopLeft, uint packedTopRight,
		vec2 local, float slopeDistanceBlend, uint projectionAxis, vec3 geometricNormalWS,
		vec3 base_ddx, vec3 base_ddy,
		inout IdWeightContributions values, inout float interpolatedOverlayWeight) {
	uint backgroundId = idweight_background(packed);
	uint overlayId = idweight_overlay(packed);
	uint mode = idweight_mode(packed);
	float linearWeight = idweight_weight(packed);
	float slopeBlend = 0.0;
	float slopeWeight = linearWeight;
	if (mode != IDWEIGHT_MODE_SET && slopeDistanceBlend > 0.0) {
		float pairCoverage = idweight_bilinear_pair_coverage(
			packedBottomLeft, packedBottomRight, packedTopLeft, packedTopRight, packed, local);
		slopeBlend = idweight_slope_interior_blend(pairCoverage) * slopeDistanceBlend;
		slopeWeight = idweight_evaluate_slope_overlay_weight(
			packed, backgroundId, overlayId, slopeDistanceBlend,
			projectionAxis, geometricNormalWS, base_ddx, base_ddy);
	}
	float modeTargetWeight = idweight_resolve_mode_target_weight(mode, linearWeight, slopeWeight);
	float overlayWeight = mix(linearWeight, modeTargetWeight, idweight_saturate(slopeBlend));
	float backgroundWeight = 1.0 - overlayWeight;
	idweight_add_contribution(backgroundId, barycentric * backgroundWeight, values);
	if (overlayId != backgroundId) {
		idweight_add_contribution(overlayId, barycentric * overlayWeight, values);
	}
	interpolatedOverlayWeight += barycentric * overlayWeight;
}

float get_height(vec2 index_id, vec2 offset) {
	float height = texelFetch(_height_maps, get_index_coord(index_id + offset), 0).r;
//INSERT: FLAT_FRAGMENT
	return height;
}

)"

		R"(
void fragment() {
	// Recover UVs
	vec2 uv = UV;
	vec2 uv2 = UV2;
	
	// Lookup offsets, ID and blend weight
	vec3 region_uv = get_index_uv(uv2);
	const vec3 offsets = vec3(0, 1, 2);
	vec2 index_id = floor(uv);
	vec2 weight = fract(uv);
	vec2 invert = 1.0 - weight;
	vec4 weights = vec4(
		invert.x * weight.y, // 0
		weight.x * weight.y, // 1
		weight.x * invert.y, // 2
		invert.x * invert.y  // 3
	);

	ivec3 index[4];
	// control map lookups
	index[0] = get_index_coord(index_id + offsets.xy);
	index[1] = get_index_coord(index_id + offsets.yy);
	index[2] = get_index_coord(index_id + offsets.yx);
	index[3] = get_index_coord(index_id + offsets.xx);
	
	vec3 base_ddx = dFdxCoarse(v_vertex);
	vec3 base_ddy = dFdyCoarse(v_vertex);
	// Calculate the effective mipmap for regionspace, and when less than 0,
	// skip all extra lookups required for bilinear blend.
	float region_mip = log2(max(length(base_ddx.xz), length(base_ddy.xz)) * _vertex_density);
	bool bilerp = region_mip < 4.0 && any(greaterThan(ivec4(index[0].z, index[1].z, index[2].z, index[3].z), ivec4(-1)));

	// Terrain normals
	vec3 index_normal[4];
	float h[4];
	// Allows for additional derivatives, eg world background, brush previews etc
	float u = 0.0;
	float v = 0.0;

//INSERT: WORLD_NOISE_FRAGMENT

	h[3] = get_height(index_id, offsets.xx); // 0 (0, 0)
	h[2] = get_height(index_id, offsets.yx); // 1 (1, 0)
	h[0] = get_height(index_id, offsets.xy); // 2 (0, 1)
	index_normal[3] = normalize(vec3(h[3] - h[2] + u, _vertex_spacing, h[3] - h[0] + v));

	// Set flat world normal - overwritten if bilerp is true
	vec3 w_normal = index_normal[3];

	// Adjust derivatives for mipmap bias and depth blur effect
	float bias = mix(mipmap_bias,
		depth_blur + 1.,
		smoothstep(0.0, 1.0, (v_vertex_xz_dist - bias_distance) * DIV_1024));
	base_ddx *= bias;
	base_ddy *= bias;

	// Color map
	vec4 color_map = region_uv.z > -1.0 ? textureLod(_color_maps, region_uv, region_mip) : COLOR_MAP_DEF;

	// Branching smooth normals and manually interpolated color map - fixes cross region artifacts
	if (bilerp) {
		// 4 lookups if linear filtering, else 1 lookup.
		vec4 col_map[4];
		col_map[3] = index[3].z > -1 ? texelFetch(_color_maps, index[3], 0) : COLOR_MAP_DEF;
		#ifdef FILTER_LINEAR
		col_map[0] = index[0].z > -1 ? texelFetch(_color_maps, index[0], 0) : COLOR_MAP_DEF;
		col_map[1] = index[1].z > -1 ? texelFetch(_color_maps, index[1], 0) : COLOR_MAP_DEF;
		col_map[2] = index[2].z > -1 ? texelFetch(_color_maps, index[2], 0) : COLOR_MAP_DEF;

		color_map =
			col_map[0] * weights[0] +
			col_map[1] * weights[1] +
			col_map[2] * weights[2] +
			col_map[3] * weights[3] ;
		#else
		color_map = col_map[3];
		#endif

		// 5 lookups
		// Fetch the additional required height values for smooth normals
		h[1] = get_height(index_id, offsets.yy); // 3 (1, 1)
		float h_4 = get_height(index_id, offsets.yz); // 4 (1, 2)
		float h_5 = get_height(index_id, offsets.zy); // 5 (2, 1)
		float h_6 = get_height(index_id, offsets.zx); // 6 (2, 0)
		float h_7 = get_height(index_id, offsets.xz); // 7 (0, 2)

		// Calculate the normal for the remaining index ids.
		index_normal[0] = normalize(vec3(h[0] - h[1] + u, _vertex_spacing, h[0] - h_7 + v));
		index_normal[1] = normalize(vec3(h[1] - h_5 + u, _vertex_spacing, h[1] - h_4 + v));
		index_normal[2] = normalize(vec3(h[2] - h_6 + u, _vertex_spacing, h[2] - h[1] + v));

		// Set interpolated world normal
		w_normal =
			index_normal[0] * weights[0] +
			index_normal[1] * weights[1] +
			index_normal[2] * weights[2] +
			index_normal[3] * weights[3] ;
	}

	vec3 w_tangent = normalize(cross(w_normal, vec3(0.0, 0.0, 1.0)));
	vec3 w_binormal = normalize(cross(w_normal, w_tangent));

	// Apply terrain normals
	if (flat_terrain_normals) {
		NORMAL = normalize(cross(dFdyCoarse(VERTEX), dFdxCoarse(VERTEX)));
		TANGENT = normalize(cross(NORMAL, VIEW_MATRIX[2].xyz));
		BINORMAL = normalize(cross(NORMAL, TANGENT));
	} else {
		NORMAL = mat3(VIEW_MATRIX) * w_normal;
		TANGENT = mat3(VIEW_MATRIX) * w_tangent;
		BINORMAL = mat3(VIEW_MATRIX) * w_binormal;
	}

	material mat = material(vec4(0.0), vec4(0.0), 0., 0., 0., 0.);
	vec3 blendedNormalWS = vec3(0.0);
	uint materialCount = 1u;
	bool material_cached = surface_material_sample(v_vertex.xz, mat, blendedNormalWS);
	bool material_missing = _surface_material_required && !material_cached;
	if (material_missing) {
		// VT mode is strict: missing/pending material pages are visible diagnostics,
		// never silently replaced by the original terrain evaluator.
		mat = material(vec4(1.0, 0.0, 1.0, 0.0), vec4(w_normal, 1.0), 0., 1., 0., 1.);
		blendedNormalWS = w_normal;
	} else if (!material_cached) {
	// GLSL out parameters are undefined on a cache miss. Initialize the source
	// accumulator after that call, rather than relying on values it overwrote.
	mat = material(vec4(0.0), vec4(0.0), 0., 0., 0., 0.);
	blendedNormalWS = vec3(0.0);
	// ── IdWeight surface evaluation ──
	// Precise corner reads from the R16 surface map (no sampler interpolation).
	// R16 UNORM texelFetch returns a normalized float; scale back to the packed
	// 16-bit integer exactly (65536 discrete values fit float precisely).
	// The idweight cell is evaluated on the stored payload's own grid when the virtual
	// texture serves it. At density 1 that is exactly the per-cell contract, and a
	// denser payload is the same contract on a dyadically subdivided cell: the fixed
	// BL-TR diagonal survives dyadic subdivision, so the triangle selection below stays
	// consistent with the mesh. With the virtual texture off the region array is
	// authoritative, so the cell keeps the mesh's 1 m grid and the array path renders
	// exactly as it did before surface_density existed.
	vec2 surface_weight = _surface_vt_enabled ? fract(uv * float(max(1, _surface_density))) : weight;
	uvec4 surface = uvec4(0u);
	surface[3] = get_surface_value(surface_corner(uv, ivec2(offsets.xx)), index[3],
			get_surface_texel(uv, ivec2(offsets.xx)));
	// At distant mips only one corner is fetched. All triangle vertices must use
	// that sample; zero-filled corners would spuriously blend material ID 0.
	surface = uvec4(surface[3]);
	if (bilerp) {
		surface[0] = get_surface_value(surface_corner(uv, ivec2(offsets.xy)), index[0],
				get_surface_texel(uv, ivec2(offsets.xy)));
		surface[1] = get_surface_value(surface_corner(uv, ivec2(offsets.yy)), index[1],
				get_surface_texel(uv, ivec2(offsets.yy)));
		surface[2] = get_surface_value(surface_corner(uv, ivec2(offsets.yx)), index[2],
				get_surface_texel(uv, ivec2(offsets.yx)));
	}

	// Cell-local coordinates and triangle selection.
	// ONE fixed mesh diagonal in every cell: LowerLeft (BL, BR, TR)
	// when local.x > local.y, UpperLeft (BL, TL, TR) otherwise, with p0 = BL,
	// p1 = isLowerLeft ? BR : TL and p2 = TR. The clipmap must therefore keep
	// that same diagonal on every LOD
	// (see Terrain3DMesher::_generate_mesh); a per-cell alternating diagonal
	// makes this interpolation disagree with the triangles actually rendered.
	vec2 local = surface_weight;
	bool is_lower_left = local.x > local.y;
	uint p0 = surface[3]; // BL
	uint p1 = is_lower_left ? surface[2] : surface[0]; // BR or TL
	uint p2 = surface[1]; // TR
	float w0, w1, w2;
	if (is_lower_left) {
		w0 = 1.0 - local.x; // BL
		w1 = local.x - local.y; // BR
		w2 = local.y; // TR
	} else {
		w0 = 1.0 - local.y; // BL
		w1 = local.y - local.x; // TL
		w2 = local.x; // TR
	}

	// Select material candidates once, after pair-aware slope evaluation.
	float materialResidualSelector = idweight_stochastic_coverage01_with_salt(v_vertex, 0x68bc21ebu);
	uvec3 materialIds;
	vec3 materialWeights;

	// Random triplanar projection. The slope factor changes stochastic
	// coverage probability, not the number of texture samples.
	float triplanarFactor = idweight_get_triplanar_factor(w_normal);
	vec3 triplanarWeights = idweight_get_triplanar_weights(w_normal);
	uint projectionAxis = 1u; // XZ
	if (triplanarFactor > 0.0) {
		vec3 projectionWeights = mix(vec3(0.0, 1.0, 0.0), triplanarWeights, triplanarFactor);
		projectionAxis = idweight_select_stochastic_coverage_axis(v_vertex, projectionWeights);
	}

	// Pair-aware slope modification. Set and distant pixels stay linear; active
	// slope Pairs use four-corner coverage so the transition remains smooth
	// across the fixed mesh diagonal.
	float slopeDistanceBlend = 1.0 - smoothstep(
		IDWEIGHT_SLOPE_FULL_DISTANCE_SQ,
		IDWEIGHT_SLOPE_MAX_DISTANCE_SQ,
		dot(v_vertex - v_camera_pos, v_vertex - v_camera_pos));
	// Persistent material pages use a camera-independent slope policy. Cache
	// misses use that same policy, avoiding a different material while refining.
	if (_surface_material_enabled && (_surface_vt_enabled || _surface_svt_enabled)) {
		slopeDistanceBlend = 1.0;
	}
	IdWeightContributions pairValues = IdWeightContributions(0u, 0u, 0u, 0u, 0u, 0u, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0u);
	float overlayWeight = 0.0;
	idweight_add_pair_vertex(p0, w0, surface[3], surface[2], surface[0], surface[1], local, slopeDistanceBlend, projectionAxis, w_normal, base_ddx, base_ddy, pairValues, overlayWeight);
	idweight_add_pair_vertex(p1, w1, surface[3], surface[2], surface[0], surface[1], local, slopeDistanceBlend, projectionAxis, w_normal, base_ddx, base_ddy, pairValues, overlayWeight);
	idweight_add_pair_vertex(p2, w2, surface[3], surface[2], surface[0], surface[1], local, slopeDistanceBlend, projectionAxis, w_normal, base_ddx, base_ddy, pairValues, overlayWeight);
	idweight_select_budgeted_3(pairValues, materialResidualSelector, materialIds, materialWeights, materialCount);

	// 3 texture lookups max (one per selected layer).
	for (int layerIndex = 0; layerIndex < IDWEIGHT_MAX_LAYERS; layerIndex++) {
		if (uint(layerIndex) >= materialCount) {
			break;
		}
		accumulate_idweight_layer(int(materialIds[layerIndex]), materialWeights[layerIndex],
			base_ddx, base_ddy, projectionAxis, w_normal, mat, blendedNormalWS);
	}

	// normalize accumulated values back to 0.0 - 1.0 range.
	float weight_inv = 1.0 / max(mat.total_weight, 1e-8);
	mat.albedo_height *= weight_inv;
	mat.normal_rough *= weight_inv;
	mat.normal_map_depth *= weight_inv;
	mat.ao *= weight_inv;
	mat.ao_affect *= weight_inv;
	} // Source evaluation on a cache miss.
	if (materialCount == 0u) {
		ALBEDO = vec3(1.0, 0.0, 1.0);
		ROUGHNESS = 1.0;
		SPECULAR = 0.0;
		NORMAL_MAP = vec3(0.5, 0.5, 1.0);
		AO = 1.0;
	} else {

	// Blended world-space layer normals converted to terrain
	// tangent space.
	vec3 blendedNormal = normalize(blendedNormalWS + vec3(0.0, 0.0001, 0.0));
	vec3 normalTS = vec3(
		dot(blendedNormal, w_tangent),
		dot(blendedNormal, w_binormal),
		dot(blendedNormal, w_normal));
	vec3 normal_map = fma(normalize(normalTS), vec3(0.5), vec3(0.5));
	float distant_normal_amplifier = clamp(max(length(base_ddx.xz), length(base_ddy.xz)), 1., distant_normal_scale);
	mat.normal_map_depth *= distant_normal_amplifier;

	//INSERT: MACRO_VARIATION

	// Wetness/roughness modifier, converting 0 - 1 range to -1 to 1 range, clamped to Godot roughness values 
	float wetness = fma(color_map.a, -2., 1.);
	float roughness = clamp(mat.normal_rough.a - wetness, 0., 1.);
	
	// Specular w/ non-light-facing suppression. Apply wetness after so it reflects the sky after sunset
	float terrain_facing_light = clamp(dot(w_normal, normalize(_light_direction)), 0.0, 1.0);
	float specular = 1. - mat.normal_rough.a;
	specular *= mix(0.0, 1.0, terrain_facing_light);
	specular = clamp(specular + wetness, 0., 1.);

	// Apply PBR
//INSERT: OUTPUT_ALBEDO
//INSERT: OUTPUT_ALBEDO_GREY
//INSERT: OUTPUT_ROUGHNESS
//INSERT: OUTPUT_SPECULAR
//INSERT: OUTPUT_SPECULAR_NONE
//INSERT: OUTPUT_NORMAL_MAP
//INSERT: OUTPUT_AMBIENT_OCCLUSION
	if (material_missing) {
		float checker = mod(floor(FRAGCOORD.x / 12.0) + floor(FRAGCOORD.y / 12.0), 2.0);
		vec3 diagnostic = mix(vec3(1.0, 0.0, 1.0), vec3(0.1, 0.02, 0.1), checker);
		ALBEDO = vec3(0.0);
		EMISSION = diagnostic;
		AO = 1.0;
		SPECULAR = 0.0;
		ROUGHNESS = 1.0;
	}

	} // else (materialCount > 0)
}

)"
