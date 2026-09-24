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
uniform float _avt_mip_distance[16];
uniform int _avt_mip_distance_count = 0;
uniform bool _avt_sectors_enabled = false;
uniform bool _avt_feedback = false;
// The recursive mip lookup the switch above enables: a miss recovers at a resident coarser level of
// the sector's local mip chain and, above it, of the independent dense fallback grid. Off, a miss
// is a miss. This is the reference implementation's `MatchMipLevel` walk - the fine loop and the
// coarse loop of `avt_resolve()` below - and it is the whole of what a page the view cannot be
// served resolves through. Nothing here evaluates the material source.
uniform float _avt_density_scale = 1.0;
uniform sampler2D _avt_sector_directory : filter_nearest, repeat_disable;
uniform int _avt_directory_mask = 0;
uniform int _avt_coarse_mip_cap = 2;
uniform float _avt_fine_section_world = 64.0;
uniform float _avt_fine_texel = 0.0009765625;
// The sample level at which the fallback table takes over. A sample at or above it reads the
// fallback table directly; one below it is an upgrade and goes through the sector directory and its
// page table for second-level addressing. Distinct from `_avt_coarse_mip_cap`, which is the
// fallback grid's own last mip: this one is in the sample's level units, so it is the number the
// plan and the read order can both be stated against.
uniform float _avt_adaptive_threshold_level = 0.0;
// Last published window center.xy, mip 1 page world span, mip 1 grid width.
uniform vec4 _avt_coarse_grid = vec4(0.0);
uniform ivec2 _avt_coarse_block = ivec2(0);
#endif
#ifdef TERRAIN_CLIPMAP
// The clipmap rings, and the only uniforms this method costs the shader. The whole block is inside
// `TERRAIN_CLIPMAP`, which the generated code defines for exactly the configurations whose *some*
// channel group is delivered by a ring (both groups `Direct` => no define => no uniforms, no samplers
// and no branch), so a method nobody selected is not merely unused here: it is absent.
// `_avt_coverage_distance` above is the band edge a ring serves inside, which is the one published
// reach both the material split and the height one are measured against.
//
// One table for every group, indexed `group * CLIPMAP_MAX_LEVELS + level`: the numeric state is the
// same for a height ring and any other, so a channel the ring gains adds no uniform of its own - it
// names its entry with `CLIPMAP_GROUP_<GROUP>`, which the generated code defines beside its arm. The
// atlas is one sampler per group rather than an array indexed at runtime: a sampler array index has
// to be a constant, so each arm passes its own and the shared addressing below takes it as a
// parameter.
//
// One entry per level, in level order: the level's *snapped* centre and its toroidal offset, so the
// shader's addressing is `Terrain3DClipmap::sample()`'s. `_clipmap_level_valid` is 1 for a level
// whose every texel is current and 0 for one that is mid-fill, mid-strip or mid-invalidation - a 0
// is what keeps a level that still holds the level it replaces out of a fragment. `_clipmap_band` is
// the two cells' claim in one mask: bit 0 the near band of that group, bit 1 the far one.
uniform highp sampler2DArray _clipmap_atlas[CLIPMAP_GROUP_COUNT] : filter_nearest, repeat_disable;
uniform vec2 _clipmap_center[CLIPMAP_GROUP_COUNT * CLIPMAP_MAX_LEVELS];
// Not `ivec2[...]`: Godot binds a uniform array from a packed array, and there is no packed ivec2.
// The values are whole texel counts, so the cast below is exact.
uniform vec2 _clipmap_ring[CLIPMAP_GROUP_COUNT * CLIPMAP_MAX_LEVELS];
uniform float _clipmap_level_valid[CLIPMAP_GROUP_COUNT * CLIPMAP_MAX_LEVELS];
// The rects of *stored* texels a reader must not serve from the ring's baked layers right now: the
// rects no bake has covered yet, and the rects the CPU side is still producing (between a job being
// queued and the bake that follows it, the level's stored texels are being replaced, so the layers
// describe world positions the level no longer covers). This is what makes a reader's readiness the
// *fragment's* rather than the level's: a level under a moving focus has a strip outstanding almost
// every tick, and a reader that fell back for the whole level whenever it did would never serve the
// material the ring actually holds. One row per level, `CLIPMAP_MAX_OUTSTANDING` entries each, and a
// count per level; a level with more outstanding rects than that answers with its whole square.
uniform vec4 _clipmap_outstanding[CLIPMAP_GROUP_COUNT * CLIPMAP_MAX_LEVELS * CLIPMAP_MAX_OUTSTANDING];
uniform int _clipmap_outstanding_count[CLIPMAP_GROUP_COUNT * CLIPMAP_MAX_LEVELS];
uniform int _clipmap_size[CLIPMAP_GROUP_COUNT];
uniform int _clipmap_level_count[CLIPMAP_GROUP_COUNT];
uniform float _clipmap_base_world[CLIPMAP_GROUP_COUNT];
uniform int _clipmap_band[CLIPMAP_GROUP_COUNT];
)"
		R"(
// How many values a group's texel holds, one layer each, and therefore how its layers are strided:
// slice `level * channels + channel`. One for every channel group the ring carries today - a height
// and a material texel are each one value - but it is a uniform rather than the constant 1 it has
// always been, because the material ring also carries the height beside the payload and the bake
// reads both from one array.
uniform int _clipmap_channels[CLIPMAP_GROUP_COUNT];
#ifdef TERRAIN_CLIPMAP_ATLAS
// The block atlas: the same clipmap layer, its content packed as discrete blocks into one texture
// per channel. `_clipmap_block` is the source (one layer a channel value) and `_clipmap_block_data`
// the block tables: one `R32F` texture holding the per-ring start points, the per-cell current-frame
// slot, offsets, readiness flags and the per-slot rect array, one row a channel group. The tables
// are a texture rather than uniform arrays because the material's uniform buffer is already close to
// the device's limit at the default region maximum; a texture costs one sampler and no uniform bytes.
// `clipmap_block_data()` below is the read, and the offsets are the CPU's own constants emitted as
// defines. The addressing that turns a world point into one of those cells is the generic block arm
// below; the start points are the per-ring block starts the CPU's `cell_for_world()` measures from.
uniform highp sampler2DArray _clipmap_block[CLIPMAP_GROUP_COUNT] : filter_nearest, repeat_disable;
uniform highp sampler2D _clipmap_block_data : filter_nearest, repeat_disable;
// One float of the block tables, by its index in the packed row: the texture is `R32F`, so the read
// is exact for the whole texel counts and the ids it holds. The layout is the CPU's own
// (`Terrain3DMaterial::_update_block_data_texture()`), emitted as defines, so an index cannot mean
// one thing here and another there. It is defined with the uniforms because the material split reads
// a group's band before the addressing below is reached.
float clipmap_block_data_at(int p_group, int p_index) {
	int index = p_group * CLIPMAP_ATLAS_DATA_STRIDE + p_index;
	return texelFetch(_clipmap_block_data,
					 ivec2(index % CLIPMAP_ATLAS_DATA_WIDTH, index / CLIPMAP_ATLAS_DATA_WIDTH), 0)
			.r;
}
#ifdef TERRAIN_CLIPMAP_ATLAS_MATERIAL
// The atlas's three baked arrays, one rect a block: the material the producer wrote out of the
// block's own payload and height. They are sampled by the *same* rect array the source lives in, so
// a block's material is the texel the block's height is.
uniform highp sampler2DArray _clipmap_block_baked_albedo : filter_linear, repeat_disable;
uniform highp sampler2DArray _clipmap_block_baked_normal : filter_linear, repeat_disable;
uniform highp sampler2DArray _clipmap_block_baked_params : filter_linear, repeat_disable;
#endif
#endif
#ifdef TERRAIN_CLIPMAP_MATERIAL
// The material group's *baked* layers: the three arrays a producer writes out of the ring's own
// texels - diffuse and height, an unencoded world normal and roughness, the parameters - one layer per
// level, which is what makes the ring a sampled material source rather than a payload one. They are
// declared only for the arm that samples them, and they are indexed exactly the way the payload layer
// is: by the *stored* texel, the one the level's ring offset names, because that is the frame that
// keeps pointing at the same world position as the level turns. A read here is therefore the payload
// read's own arithmetic - clamp the logical tap inside the level, turn it into the stored texel - with
// the baked layer instead of the payload. See `clipmap_baked_material()`.
uniform highp sampler2DArray _clipmap_baked_albedo : filter_linear, repeat_disable;
uniform highp sampler2DArray _clipmap_baked_normal : filter_linear, repeat_disable;
uniform highp sampler2DArray _clipmap_baked_params : filter_linear, repeat_disable;
// ---- The material group's detail layer ----
// A sparse, demand-resident layer of fine tiles *inside* the band the ring serves, and the only
// source that reaches the 1024 texels/m the near field is measured at: the ring is one dense level
// per octave, so its finest level is a coverage question rather than a density one, and the density
// has to be spent where a fragment reads it. A tile is `level + snapped tile X/Y`, addressed
// entirely in integers, and a level's directory is one texel a tile holding `slot + 1` (0 = "no
// readable tile").
//
// The directory bit is the whole of the reader's gate, which is what makes the fallback chain safe:
// a tile that is missing, still being produced, or invalidated by a move or an edit is *absent* from
// the directory rather than present with stale content, so this arm returns false and the fragment
// falls through to the ring's baked layers and then to the payload evaluation. `_detail_window_origin`
// is the world origin of directory texel (0,0) for each level and `_detail_tile_world` its tile span,
// so the shader's `floor((world - origin) / span)` and the CPU's integer tile index are the same
// index. Both come from `Terrain3DMaterialClipmapDetail::get_arm()`, which is why they cannot drift.
uniform highp sampler2DArray _detail_baked_albedo : filter_linear, repeat_disable;
uniform highp sampler2DArray _detail_baked_normal : filter_linear, repeat_disable;
uniform highp sampler2DArray _detail_baked_params : filter_linear, repeat_disable;
uniform highp sampler2D _detail_directory[CLIPMAP_DETAIL_MAX_LEVELS] : filter_nearest, repeat_disable;
uniform vec2 _detail_window_origin[CLIPMAP_DETAIL_MAX_LEVELS];
uniform float _detail_tile_world[CLIPMAP_DETAIL_MAX_LEVELS];
uniform float _detail_texel_world[CLIPMAP_DETAIL_MAX_LEVELS];
uniform float _detail_texels_per_meter[CLIPMAP_DETAIL_MAX_LEVELS];
uniform int _detail_enabled = 0;
uniform int _detail_level_count = 0;
uniform int _detail_tile_size = 0;
uniform int _detail_border = 0;
uniform int _detail_stored_size = 0;
uniform int _detail_directory_size = 0;
uniform int _detail_slots = 0;
#endif
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
const bool _svt_feedback = false;
const bool _surface_material_enabled = false;
const bool _surface_material_required = false;
const int _surface_vt_page_fade_frames = 0;
#else
uniform bool _surface_vt_enabled = false;
uniform int _surface_vt_region_size = 256;
uniform int _surface_vt_page_size = 256;
// Nine, not four: the near field asks for 8x anisotropic filtering by default and a gutter of n
// supports n - 0.5, so four admitted 3.5x and silently reduced every larger request. A stored page
// is `page_size + 2 * border`, which is 7.7% more texels a page than four was. The C++ default and
// the dock's range are the same number; see docs/vt_sampling_review.md.
uniform int _surface_vt_page_border = 5;
uniform int _surface_vt_pages_per_axis = 4;
uniform int _surface_vt_max_local_mip = 2;
uniform int _surface_vt_indirection_size = 256;
uniform highp sampler2D _surface_vt_indirection : filter_nearest, repeat_disable;
// Page-arrival fade: one byte per physical slot, holding how far a page has come in since its
// content landed (0 = only the level it replaced, 1 = the page itself). Indexed by the slot the
// indirection lookup already decoded, so it costs one extra fetch and no address arithmetic. A
// page that snaps in is a rectangular step in the image - which is what a fast turn makes
// obvious, because the view then refines in the page grid it is built from.
uniform highp sampler2D _surface_vt_page_fade : filter_nearest, repeat_disable;
// How long that ramp lasts, in ticks. 0 disables the fade and every page is settled at once.
uniform int _surface_vt_page_fade_frames = 0;
uniform highp sampler2DArray _surface_vt_atlas : repeat_disable;
// Layer -> virtual page block origin inside the indirection, or (-1, -1) when that
// sector has no block. Indexed by the layer slot the chunk directory returns.
uniform vec2 _surface_vt_blocks[MAX_REGIONS];
uniform float _surface_vt_block_sizes[MAX_REGIONS];
uniform bool _surface_material_enabled = false;
uniform bool _surface_material_required = false;
// The albedo arrays are colour textures: a block codec cannot hold the darks of a linear
// colour in five bits per channel, so the encoder stores the sRGB encoding of the page and
// the array is the codec's sRGB format. `source_color` is what makes the renderer sample the
// sRGB view of it, which is what turns those texels back into the linear colour the page was
// produced from. Without it the same array is sampled through its linear view and every
// compressed page renders brighter than the uncompressed one. The normal and parameter pages
// stay linear - a direction and a ratio are not colours - so they carry no such hint.
uniform highp sampler2DArray _surface_material_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform highp sampler2DArray _surface_material_normal : filter_linear_mipmap_anisotropic, repeat_disable;
uniform int _surface_normal_encoding = 0;
uniform bool _surface_params_encoded = false;
uniform int _surface_svt_normal_encoding = 0;
uniform bool _surface_svt_params_encoded = false;
uniform highp sampler2DArray _surface_material_params : filter_linear_mipmap_anisotropic, repeat_disable;
// Bound per frame from `Terrain3D::get_avt_anisotropy()`, which answers the request clamped by the
// gutter above; the clamp below is the shader's own copy of that physical bound, so a material
// that binds a wider number than its pages carry is still filtered inside the page.
uniform float _surface_vt_anisotropy = 8.0;
// The far field's own set. AVT and SVT store the same shared page pool in independent
// formats - an AVT page is rewritten by every edit, an SVT page is assembled once - so each
// tier samples the arrays it was produced into. A tier left uncompressed is bound the
// staging arrays, so these name the same textures as the three above in that case.
uniform highp sampler2DArray _surface_svt_material_albedo : source_color, filter_linear, repeat_disable;
uniform highp sampler2DArray _surface_svt_material_normal : filter_linear, repeat_disable;
uniform highp sampler2DArray _surface_svt_material_params : filter_linear, repeat_disable;
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
// Whether a fragment whose selected far-field level has no ready page may be served by a
// coarser resident level. Off by default: the level the distance rule selected is the
// one that must render, and a miss is the diagnostic. On restores the coarse walk.
uniform bool _svt_feedback = false;
uniform float _surface_svt_page_world = 512.0;
uniform int _surface_svt_page_size = 256;
// The same number as the near field's gutter, because both views share `vt_page_border`. The far
// field samples with a plain `textureLod` and no gradients, so this gutter is for its own mip
// transitions rather than for a filtering footprint; it grows with the near field's anyway.
uniform int _surface_svt_page_border = 5;
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
// How far a page has come in since its content landed: 0 while it is only the level it
// replaced, 1 once it is itself. The value is per physical slot, so a page that has settled
// costs one fetch and answers 1, and the whole mechanism disappears when the frame count is 0.
float surface_vt_page_fade(int p_slot) {
	if (_surface_vt_page_fade_frames <= 0 || p_slot < 0 || p_slot == 65535) { return 1.0; }
	if (p_slot >= textureSize(_surface_vt_page_fade, 0).x) { return 1.0; }
	return texelFetch(_surface_vt_page_fade, ivec2(p_slot, 0), 0).r;
}

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

// Sampling starts at the level the distance selects. With `_svt_feedback` off
// that is the only level tried: a page that is missing or still in production stays a miss
// and the caller renders the diagnostic, so the level that was selected is the level that
// was drawn. With the switch on the walk continues coarser, which recovers a fragment from
// a resident ancestor instead of diagnosing it.
bool surface_svt_sample(const vec2 p_world, out uint r_value) {
	if (!_surface_svt_enabled) {
		return false;
	}
	int half = _surface_svt_indirection_size >> 1;
	int stored = _surface_svt_page_size + 2 * _surface_svt_page_border;
	ivec2 page = ivec2(floor(p_world / _surface_svt_page_world));
	if (any(lessThan(page + ivec2(half), ivec2(0))) || any(greaterThanEqual(page + ivec2(half), ivec2(_surface_svt_indirection_size)))) { return false; }
	int start_mip = surface_svt_mip_for_distance(surface_svt_distance(p_world));
	// The loop bound is the whole switch: with the fallback off it equals start_mip, so
	// the body runs once and a `continue` ends the search instead of moving to a coarser
	// level. Nothing else in the body changes, which keeps the enabled path identical to
	// the walk this shader had before the switch existed.
	int last_mip = start_mip;
	if (_svt_feedback) { last_mip = _surface_svt_max_mip; }
	for (int mip = start_mip; mip <= last_mip; mip++) {
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

// Both virtual address spaces resolve into the material arrays of their own tier: the near
// field into the AVT set above, the far field into the SVT set below. A missing
// or pending selected page displays diagnostics; residency never selects a substitute mip.
// The one exception is the far field's opt-in `_svt_feedback` below, which is
// a request to trade that diagnostic for a coarser resident level.
// Storage decoding is shared by AVT and SVT. Staging/cache images remain in
// canonical signed world-normal form; only compressed sampled arrays use octahedra.
vec3 surface_decode_octahedral(vec2 encoded) {
	vec2 f = encoded * 2.0 - 1.0;
	vec3 n = vec3(f, 1.0 - abs(f.x) - abs(f.y));
	float t = clamp(-n.z, 0.0, 1.0);
	n.xy += mix(vec2(t), vec2(-t), greaterThanEqual(n.xy, vec2(0.0)));
	return normalize(n).xzy;
}

bool surface_decode_page(vec4 albedo, vec4 normal_rough, vec4 params,
		int normal_encoding, bool params_encoded, out material r_mat, out vec3 r_normal) {
	if (params.a < (params_encoded ? 0.49 : 0.99)) { return false; }
	if (normal_encoding != 0) {
		vec2 oct = normal_encoding == 2 ? normal_rough.ag : normal_rough.rg;
		normal_rough.xyz = surface_decode_octahedral(oct);
	}
	if (params_encoded) {
		normal_rough.a = clamp(params.a * 2.0 - 1.0, 0.0, 1.0);
		params.r *= 2.0;
	}
	r_mat = material(albedo, normal_rough, params.x, params.y, params.z, 1.0);
	r_normal = normal_rough.xyz;
	return true;
}

bool surface_material_slot(int slot, vec2 offset, int page_size, int border,
		out material r_mat, out vec3 r_normal) {
	if (slot < 0 || slot == 65535 || slot == 65534) { return false; }
	vec3 coord = vec3((offset * float(page_size) + float(border)) / float(page_size + border * 2), float(slot));
	vec4 params = textureLod(_surface_material_params, coord, 0.0);
	vec4 albedo = textureLod(_surface_material_albedo, coord, 0.0);
	vec4 normal_rough = textureLod(_surface_material_normal, coord, 0.0);
	return surface_decode_page(albedo, normal_rough, params, _surface_normal_encoding,
			_surface_params_encoded, r_mat, r_normal);
}

// AVT pages store one physical mip; virtual mips are separate pages. Keep the
// world-space derivatives explicit so page/fract discontinuities never enter
// the hardware anisotropic footprint. Padding is budgeted by avt_pixel_footprint.
bool avt_material_slot(int slot, vec2 offset, float texel_world, vec2 world_dx, vec2 world_dy,
		out material r_mat, out vec3 r_normal) {
	// 65534 is the plan marker (`PLANNED_PHYSICAL_PAGE_SLOT` in terrain_vt.h): a level the demand
	// plan names whose page has no content yet. It is not a slot - the pool is capped at 2047 - so
	// it must never be sampled, and rejecting it here keeps the fallback loop honest too.
	if (slot < 0 || slot == 65535 || slot == 65534) { return false; }
	float stored = float(_surface_vt_page_size + 2 * _surface_vt_page_border);
	vec3 coord = vec3((offset * float(_surface_vt_page_size) + float(_surface_vt_page_border)) / stored, float(slot));
	vec2 dx = world_dx / (texel_world * stored);
	vec2 dy = world_dy / (texel_world * stored);
	vec4 params = textureGrad(_surface_material_params, coord, dx, dy);
	vec4 albedo = textureGrad(_surface_material_albedo, coord, dx, dy);
	vec4 normal_rough = textureGrad(_surface_material_normal, coord, dx, dy);
	return surface_decode_page(albedo, normal_rough, params, _surface_normal_encoding,
			_surface_params_encoded, r_mat, r_normal);
}

float avt_pixel_footprint(vec2 dx, vec2 dy) {
	// Singular values of the world-XZ pixel Jacobian, including rotated views
	// whose two screen derivatives can both point mostly along the long axis.
	float a = dot(dx, dx);
	float b = dot(dx, dy);
	float c = dot(dy, dy);
	float major = sqrt(max(0.5 * (a + c + sqrt(max((a-c)*(a-c) + 4.0*b*b, 0.0))), 1e-16));
	float minor = abs(dx.x * dy.y - dx.y * dy.x) / major;
	// The fine virtual mip is floor(LOD), so its texel can be half the desired
	// footprint. Leave half a texel for bilinear support within the page gutter:
	// a ratio of n spans about n texels along the major axis, so its half-extent
	// is n / 2 and bilinear adds half a texel - the gutter admits `2 * border - 1`.
	// This is the shader's half of `Terrain3D::get_avt_anisotropy()`, which
	// publishes `_surface_vt_anisotropy` clamped by the same bound.
	float supported = max(1.0, 2.0 * float(_surface_vt_page_border) - 1.0);
	float anisotropy = max(1.0, min(_surface_vt_anisotropy, supported));
	return max(minor, major / anisotropy);
}

// The far field's resolve, against the SVT tier's arrays.
bool surface_svt_material_slot(int slot, vec2 offset, int page_size, int border,
		out material r_mat, out vec3 r_normal) {
	if (slot < 0 || slot == 65535) { return false; }
	vec3 coord = vec3((offset * float(page_size) + float(border)) / float(page_size + border * 2), float(slot));
	vec4 params = textureLod(_surface_svt_material_params, coord, 0.0);
	vec4 albedo = textureLod(_surface_svt_material_albedo, coord, 0.0);
	vec4 normal_rough = textureLod(_surface_svt_material_normal, coord, 0.0);
	return surface_decode_page(albedo, normal_rough, params, _surface_svt_normal_encoding,
			_surface_svt_params_encoded, r_mat, r_normal);
}

// Same contract as surface_svt_sample(): the selected level alone is tried unless the
// fallback switch asks for the coarser walk. A page whose material is still in production
// (`params.a < 0.99`) is a miss in both modes, because the walk would otherwise render an
// arbitrary younger level for a page that is simply late.
//
// A level whose page is still coming in is crossfaded against the next resident level, which
// is the level it is replacing: the first resident level is the fine one, and the walk only
// continues past it while that page's fade is incomplete. With the fade off, the first
// resident level is returned directly, exactly as before.
bool surface_svt_material_sample(vec2 world, out material r_mat, out vec3 r_normal) {
	if (_surface_svt_enabled) {
		ivec2 page = ivec2(floor(world / _surface_svt_page_world));
		ivec2 virtual_page = page + ivec2(_surface_svt_indirection_size >> 1);
		if (all(greaterThanEqual(virtual_page, ivec2(0))) && all(lessThan(virtual_page, ivec2(_surface_svt_indirection_size)))) {
			int start_mip = surface_svt_mip_for_distance(surface_svt_distance(world));
			int last_mip = start_mip;
			if (_svt_feedback) { last_mip = _surface_svt_max_mip; }
			// One level past the window, so a fade has something to blend against even when the
			// distance rule's level is the coarsest the walk would otherwise try.
			int walk_end = last_mip;
			if (_surface_vt_page_fade_frames > 0 && last_mip < _surface_svt_max_mip) { walk_end = last_mip + 1; }
			bool have = false;
			float blend = 0.0;
			material blended;
			vec3 blended_normal;
			for (int mip = start_mip; mip <= walk_end; mip++) {
				ivec2 coord = virtual_page >> mip;
				int level_size = max(1, _surface_svt_indirection_size >> mip);
				int slot = int(texelFetch(_surface_svt_indirection, coord, mip).r + 0.5);
				vec2 offset = fract(world / (_surface_svt_page_world * float(1 << mip)));
				material sample_mat;
				vec3 sample_normal;
				if (!surface_svt_material_slot(slot, offset, _surface_svt_page_size, _surface_svt_page_border, sample_mat, sample_normal)) { continue; }
				if (!have) {
					// The first resident level is the one being faded in.
					blended = sample_mat;
					blended_normal = sample_normal;
					have = true;
					blend = 1.0 - surface_vt_page_fade(slot);
					if (blend <= 0.001) { break; }
					continue;
				}
				// The next resident level is what it replaces.
				blended.albedo_height = mix(blended.albedo_height, sample_mat.albedo_height, blend);
				blended.normal_rough = mix(blended.normal_rough, sample_mat.normal_rough, blend);
				blended.normal_map_depth = mix(blended.normal_map_depth, sample_mat.normal_map_depth, blend);
				blended.ao = mix(blended.ao, sample_mat.ao, blend);
				blended.ao_affect = mix(blended.ao_affect, sample_mat.ao_affect, blend);
				blended_normal = mix(blended_normal, sample_normal, blend);
				blend = 0.0;
				break;
			}
			if (have) {
				r_mat = blended;
				r_normal = blended_normal;
				return true;
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
// Adaptive tier 0 has its own local mip chain. Tier 1 is the independent,
// dense low-resolution image; its mip indices are not fine-image mip indices.
//
// `texel_world` is the world size of the texel the resolve settled on, `fade` the arrival ramp of
// the slot it read and `last_mip` whether the walk reached the end of its table.
bool avt_resolve(vec2 world, float pixel_world, float minimum_texel, bool allow_coarse, vec2 world_dx, vec2 world_dy, out material result, out vec3 result_normal,
		out float texel_world, out float fade, out bool last_mip) {
	fade = 1.0;
	last_mip = false;
	if (_avt_coarse_grid.w < 1.0 || _avt_coarse_grid.z <= 0.0) { return false; }
	float coarse_texel = _avt_coarse_grid.z / float(_surface_vt_page_size);
	// The near field's reach bounds its *upgrade* path and nothing else. Reach is what the plan
	// that produces upgraded pages is sized against, so past it the plan names no fine page and an
	// upgrade that happens to be resident there must not outrank the fallback the rest of the view
	// is drawn from. The fallback tier is instead bounded by its own table: it is the last resort
	// for a fragment no upgrade covers, and past reach it is the only owner the near field has at
	// all - a fragment there has no other provider when the far field is off, and rejecting it is
	// what turns settled ground into a missing-page diagnostic.
	bool in_reach = distance(world, v_camera_pos.xz) < max(64.0, _avt_coverage_distance);
	// Which table answers this sample, stated as the level it asks for against the level the
	// fallback takes over at. At or above that level the fallback answers and the sector directory
	// and its page table are not touched at all; below it the sample is an upgrade and is addressed
	// through the directory. The two are the same fact as the texel comparison this replaced, but
	// stated once, in the units the plan classifies in: a level the plan never produced an upgrade
	// for cannot be asked of the upgrade path by a rounding difference.
	float level = log2(max(1.0, max(pixel_world, minimum_texel) / max(_avt_fine_texel, 1e-9)));
	if (in_reach && _avt_adaptive_threshold_level > 0.0 && level < _avt_adaptive_threshold_level) {
		vec2 local_grid = world / _avt_fine_section_world;
		ivec2 key = ivec2(floor(local_grid));
		vec4 entry;
		if (avt_find_sector(key, 0, entry)) {
			vec2 local = clamp(local_grid - vec2(key), vec2(0.0), vec2(0.99999994));
			int top = int(round(log2(entry.z)));
			float local_texel = _avt_fine_section_world / (entry.w * float(_surface_vt_page_size));
			int requested = min(top, int(floor(log2(max(1.0, pixel_world / local_texel)))));
			requested = max(requested, int(ceil(log2(max(1.0, minimum_texel / local_texel)))));
			for (int mip = requested; mip <= top; ++mip) {
				vec2 page_uv = local * entry.w / float(1 << mip);
				ivec2 page = (ivec2(entry.xy) >> mip) + ivec2(floor(page_uv));
				int slot = int(texelFetch(_surface_vt_indirection, page, mip).r + 0.5);
				texel_world = local_texel * float(1 << mip);
				if (texel_world >= coarse_texel) { break; }
				// 65534 is the demand plan's marker: this level is one the plan names and its page
				// simply has not arrived. Strict mode reports that as the miss it is; coarse recovery
				// continues to the next level, exactly as it does for any page still in production.
				if (slot == 65534) {
					if (!allow_coarse) { return false; }
					continue;
				}
				if (slot != 65535) {
					if (avt_material_slot(slot, fract(page_uv), texel_world, world_dx, world_dy, result, result_normal)) {
						fade = surface_vt_page_fade(slot);
						return true;
					}
					// A page the plan names whose content is not readable yet (still encoding, or
					// its parameters not compiled). Strict mode asks for that one page and reports
					// the miss instead of recovering at a coarser level of the same sector's chain:
					// that is what `surface_vt_feedback` off means (`vt_sampling_review.md`: "the
					// feedback property controls coarse recovery in the shader"), and it is the
					// contract `vt_transition_parent` and `vt_filtering` pin.
					if (!allow_coarse) { return false; }
					continue;
				}
				// 65535 here is not a late page: the plan does not name this level for this ground
				// at all. The plan is budget-limited, so the level a footprint asks for is a level
				// the near field will never hold unless the residency coarsens - and coarsening the
				// requested level is what keeps a strict view from drawing the missing-page
				// diagnostic forever. Walk on to the level the plan does hold; the marker above is
				// what distinguishes "late" from "never".
				continue;
			}
		}
	}
	int requested = 1 + min(_avt_coarse_mip_cap - 1, int(floor(log2(max(1.0, pixel_world / coarse_texel)))));
	requested = max(requested, 1 + int(ceil(log2(max(1.0, minimum_texel / coarse_texel)))));
	for (int mip = requested; mip <= _avt_coarse_mip_cap; ++mip) {
		int side = int(_avt_coarse_grid.w) >> (mip - 1);
		float span = _avt_coarse_grid.z * float(1 << (mip - 1));
		ivec2 world_cell = ivec2(floor(world / span));
		ivec2 first = ivec2(floor(_avt_coarse_grid.xy / span + vec2(0.5))) - ivec2(side / 2);
		if (any(lessThan(world_cell, first)) || any(greaterThanEqual(world_cell, first + ivec2(side)))) { continue; }
		ivec2 cell = world_cell & ivec2(side - 1);
		int slot = int(texelFetch(_surface_vt_indirection, (_avt_coarse_block >> mip) + cell, mip).r + 0.5);
		texel_world = coarse_texel * float(1 << (mip - 1));
		if (!avt_material_slot(slot, fract(world / span), texel_world, world_dx, world_dy, result, result_normal)) { continue; }
		fade = surface_vt_page_fade(slot);
		last_mip = mip == _avt_coarse_mip_cap;
		return true;
	}
	return false;
}

)"

R"(
// `r_texel` is the world size of the texel the resolve settled on and `r_fade` its arrival ramp;
// both are read by the blend below.
bool avt_filtered_sample(vec2 world, float pixel_world, vec2 world_dx, vec2 world_dy, out material r_mat, out vec3 r_normal) {
	float fine_texel;
	float fine_fade;
	bool last_mip;
	if (!avt_resolve(world, pixel_world, 0.0, _avt_feedback, world_dx, world_dy, r_mat, r_normal, fine_texel, fine_fade, last_mip)) { return false; }
	// The blend is the pixel footprint's mip interpolation, and - while a page is still coming in
	// - the level that page replaced. A page that has just arrived is resolved at full weight for
	// its own texels, so without the second term it appears as a rectangular step in the image;
	// with it the view sharpens. The coarser level is resolved for this even when the footprint
	// alone would not ask for it, and the arrival never outweighs the footprint blend.
	// Clamp the mip range at its actual end, independently of page residency.
	float arrival = 1.0 - fine_fade;
	if (last_mip || (pixel_world <= fine_texel && arrival <= 0.001)) { return true; }
	material coarse;
	vec3 coarse_normal;
	float coarse_texel;
	float coarse_fade;
	// Strict mode checks the requested fine page above. Its transition parent is
	// an availability query: skipping an unfinished intermediate parent must not
	// bypass the fade while a valid world ancestor is already resident.
	if (!avt_resolve(world, pixel_world, fine_texel * 1.001, true, world_dx, world_dy, coarse, coarse_normal, coarse_texel, coarse_fade, last_mip)) { return true; }
	// The coarser resolve can land on the same page when nothing coarser is resident; there is
	// then nothing to fade against and the sharp page stands.
	if (coarse_texel <= fine_texel) { return true; }
	float weight = arrival;
	if (pixel_world > fine_texel) {
		float mip_weight = clamp(log2(max(pixel_world / fine_texel, 1.0)) / log2(coarse_texel / fine_texel), 0.0, 1.0);
		weight = max(mip_weight, arrival);
	}
	r_mat.albedo_height = mix(r_mat.albedo_height, coarse.albedo_height, weight);
	r_mat.normal_rough = mix(r_mat.normal_rough, coarse.normal_rough, weight);
	r_mat.normal_map_depth = mix(r_mat.normal_map_depth, coarse.normal_map_depth, weight);
	r_mat.ao = mix(r_mat.ao, coarse.ao, weight);
	r_mat.ao_affect = mix(r_mat.ao_affect, coarse.ao_affect, weight);
	r_normal = mix(r_normal, coarse_normal, weight);
	// A parent can be arriving in the same burst as its child. Blending straight
	// to that parent's full-detail sample bypasses its fade and exposes the page
	// grid. Carry only its remaining contribution up the hierarchy until a
	// settled ancestor is found. The normal settled path still samples two pages.
	float remaining = weight;
	for (int ancestor = 0; ancestor < 32; ++ancestor) {
		if (last_mip || coarse_fade >= 0.999 || remaining <= 0.001) { break; }
		material parent;
		vec3 parent_normal;
		float parent_texel;
		float parent_fade;
		if (!avt_resolve(world, pixel_world, coarse_texel * 1.001, true, world_dx, world_dy, parent, parent_normal,
				parent_texel, parent_fade, last_mip) || parent_texel <= coarse_texel) { break; }
		remaining *= 1.0 - coarse_fade;
		r_mat.albedo_height += (parent.albedo_height - coarse.albedo_height) * remaining;
		r_mat.normal_rough += (parent.normal_rough - coarse.normal_rough) * remaining;
		r_mat.normal_map_depth += (parent.normal_map_depth - coarse.normal_map_depth) * remaining;
		r_mat.ao += (parent.ao - coarse.ao) * remaining;
		r_mat.ao_affect += (parent.ao_affect - coarse.ao_affect) * remaining;
		r_normal += (parent_normal - coarse_normal) * remaining;
		coarse = parent;
		coarse_normal = parent_normal;
		coarse_texel = parent_texel;
		coarse_fade = parent_fade;
	}
	return true;
}

// The paged methods' material for a fragment, and how much of the fragment is theirs:
// `r_page_share` is the fraction of it the pages own and `r_page_band` is whether the fragment lies
// inside the band they serve at all. Both are 1/true for a configuration with no ring on the material
// group - the shape the two paged methods have always had, and the reason those configurations compile
// and run the code they always did - while a ring's cell takes the band it names out of them. A miss
// leaves the share at `0`: the source evaluation is then the whole answer. `r_page_band` is what the
// strict-miss diagnostic reads, so a fragment the ring legitimately serves is not a diagnostic merely
// because no page stands behind it. See `evaluate_idweight_material()` for the other half.
bool surface_material_sample(vec2 world, out material r_mat, out vec3 r_normal, out float r_page_share,
		out bool r_page_band) {
	r_page_share = 1.0;
	r_page_band = true;
	if (!_surface_material_enabled) {
		r_page_share = 0.0;
		r_page_band = false;
		return false;
	}
#ifdef TERRAIN_CLIPMAP_MATERIAL
	// A ring cell turns the group's two *tiers* into its two *bands*: the ring owns the band its cell
	// names and the pages keep the other one, so what the pages own here is the other band's own curve
	// - the one the height arm serves by, at the distance this split already measures with. Both bits
	// set (the ring owns both bands) leaves them nothing, and so does a `Direct` other band. Zero means
	// no cell put this group on `Clipmap`, and then they keep the whole fragment.
	// Not `const`: these derive from a uniform, which Godot's shader language does not accept in a
	// constant expression.
	int ring_band = _clipmap_band[CLIPMAP_GROUP_MATERIAL] & 3;
#ifdef TERRAIN_CLIPMAP_ATLAS_MATERIAL
	// The block atlas is the same layer's other residency unit, and a cell may name it in one band
	// and the ring in the other: the two masks are one claim about which bands the clipmap layer
	// owns, so the pages keep what neither owns.
	int block_band = int(clipmap_block_data_at(CLIPMAP_GROUP_MATERIAL, CLIPMAP_ATLAS_DATA_BAND) + 0.5);
	ring_band = (ring_band | block_band) & 3;
#endif
	if (ring_band != 0) {
		float ring_reach = max(64.0, _avt_coverage_distance);
		float far_band = smoothstep(ring_reach * 0.75, ring_reach, distance(world, v_camera_pos.xz));
		// bit 0 = the ring owns the near band, so the pages keep the far one; bit 1 = the ring owns the
		// far band, so the pages keep the near one.
		r_page_share = (ring_band & 2) != 0 ? 0.0
										   : ((ring_band & 1) != 0 ? (_surface_svt_enabled ? far_band : 0.0) : 1.0 - far_band);
		r_page_band = r_page_share > 0.0;
		// Nothing paged in this fragment: the evaluation is the whole answer, and a strict-miss
		// diagnostic is not this fragment's business.
		if (r_page_share <= 0.0) {
			return false;
		}
		// The ring owns the near band, so the far one is the SVT's alone: the tier the cell replaced is
		// not asked, rather than asked and then overruled.
		if ((ring_band & 1) != 0) {
			return _surface_svt_enabled ? surface_svt_material_sample(world, r_mat, r_normal) : false;
		}
	}
#endif
	if (_surface_vt_enabled && _avt_sectors_enabled) {
		vec2 world_dx = dFdx(world);
		vec2 world_dy = dFdy(world);
		// Match the installed CPU plan's explicit quality/capacity LOD. A denied
		// fine page is not an asynchronous miss and must never be sampled forever.
		float pixel_world = avt_pixel_footprint(world_dx, world_dy) / max(_avt_density_scale, 0.000001);
		float reach = max(64.0, _avt_coverage_distance);
		float far_weight = _surface_svt_enabled ? smoothstep(reach * 0.75, reach, distance(world, v_camera_pos.xz)) : 0.0;
		if (far_weight >= 1.0) { return surface_svt_material_sample(world, r_mat, r_normal); }
		bool avt_ready = avt_filtered_sample(world, pixel_world, world_dx, world_dy, r_mat, r_normal);
		if (far_weight <= 0.0) { return avt_ready; }
		material far_mat;
		vec3 far_normal;
		bool svt_ready = surface_svt_material_sample(world, far_mat, far_normal);
		// Each tier resolves only through its own feedback hierarchy. The transition itself is
		// availability tolerant: while one side is still arriving, keep the independently
		// resolved side instead of turning individual terrain triangles into diagnostics.
		// This is not feedback chaining; outside this 25% transition band AVT and SVT remain
		// strict owners of their respective ranges.
		if (!avt_ready && !svt_ready) { return false; }
		if (!avt_ready) {
			r_mat = far_mat;
			r_normal = far_normal;
			return true;
		}
		if (!svt_ready) { return true; }
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
			return false; // AVT owns this region and resolves misses only through AVT feedback.
		}
	}
	return surface_svt_material_sample(world, r_mat, r_normal);
}
#else
bool surface_material_sample(vec2 world, out material r_mat, out vec3 r_normal, out float r_page_share,
		out bool r_page_band) {
	r_page_share = 0.0;
	r_page_band = false;
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

)"
// Another split, for the same reason as the one above: MSVC truncates a string literal past
// 16 kB, and the height channel's own reads and the vertex stage together crossed it.
		R"(
// ---- The height channel's two sources ----------------------------------------------------------
// The height group is delivered by the region texture array (`Direct`) or by the clipmap ring, in
// the band its cell names. Everything below is that choice in one place, and the array is the
// `#else` arm of every branch, so a configuration whose height group is `Direct` in both bands
// compiles exactly the read it always did.
//
// A ring read is always an explicit, clamped `texelFetch` and never a filtered one. The ring is
// toroidal: a tap outside a level would land on the far edge of the same level, which is a different
// world position, so no sampler may filter across it - the bilinear this file needs is rebuilt from
// four clamped taps instead. The array path is point-sampled for the same reason (its regions are
// separate layers), and the mesh's own nested vertex grids are what make the two agree where it
// matters.

// The region array's own read of one height texel, point sampled - the arm every fallback returns.
float array_height_point_uv(vec2 p_uv) {
	return texelFetch(_height_maps, get_index_coord(p_uv), 0).r;
}

// The region array's sub-texel read: the four corners of the cell that contains `pos` and the
// weights between them. This is the shipped height read, unchanged.
float array_height_interpolated_uv(vec2 pos) {
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

#ifdef TERRAIN_CLIPMAP
// The group's level inside the one table: `group * CLIPMAP_MAX_LEVELS + level`. Every read below goes
// through it, so a channel's index and a level's index cannot be confused.
int clipmap_level_index(int p_group, int p_level) {
	return p_group * CLIPMAP_MAX_LEVELS + p_level;
}

float clipmap_texel_world(int p_group, int p_level) {
	return _clipmap_base_world[p_group] * exp2(float(p_level)) / float(max(_clipmap_size[p_group], 1));
}

// Whether a level's own texel range contains a point - `Terrain3DClipmap::_contains_level()` exactly.
// Deliberately not `abs(point - centre) <= half`: that includes the far edge, which is one texel past
// the last stored one, and the clamped read below would answer it with the edge texel, i.e. with the
// value of a world position one texel away. The range is half-open, which is the set of texels the
// level stores.
bool clipmap_contains(int p_group, int p_level, vec2 p_world) {
	float half_size = _clipmap_base_world[p_group] * exp2(float(p_level)) * 0.5;
	vec2 local = (p_world - _clipmap_center[clipmap_level_index(p_group, p_level)] + vec2(half_size)) /
			clipmap_texel_world(p_group, p_level);
	float size = float(max(_clipmap_size[p_group], 1));
	return local.x >= 0.0 && local.y >= 0.0 && local.x < size && local.y < size;
}

// The finest level whose own texel range contains the point, and the coarsest when none does -
// `Terrain3DClipmap::level_for_world()` exactly. A level's centre is snapped to its own texel size,
// so two levels' coverage is not concentric and this is a search rather than a log2 of a shared
// centre.
int clipmap_level_for_world(int p_group, vec2 p_world) {
	int last = max(_clipmap_level_count[p_group] - 1, 0);
	for (int level = 0; level < last; level++) {
		if (clipmap_contains(p_group, level, p_world)) {
			return level;
		}
	}
	return last;
}

// The level's snapped grid, in logical texel units: `Terrain3DClipmap::sample()`'s own inverse of
// `world_of_logical()`, so the shader and the CPU read the same texel for the same world point. `z`
// is the level.
vec3 clipmap_address(int p_group, vec2 p_world) {
	int level = clipmap_level_for_world(p_group, p_world);
	float texel = clipmap_texel_world(p_group, level);
	float half_size = _clipmap_base_world[p_group] * exp2(float(level)) * 0.5;
	vec2 local = (p_world - _clipmap_center[clipmap_level_index(p_group, level)] + vec2(half_size)) / texel;
	return vec3(local, float(level));
}

// One stored texel, named by a *logical* index: the ring offset turns it into the stored one
// (`physical = (logical + ring) mod size`, the wrap `Terrain3DClipmap::_wrap()` applies), and the
// clamp keeps a tap at a level's edge inside that level instead of wrapping it onto the opposite
// edge, where the neighbouring level is the correct source. The atlas is the *caller's*: a sampler
// array index has to be constant, so each arm names its own and this stays shared. The layer is the
// level's *first* channel: this is the arm that reads a group's own value, and a group that carries
// more than one keeps them beside it (`_clipmap_channels`).
float clipmap_texel_at(int p_group, int p_level, vec2 p_logical, highp sampler2DArray p_atlas) {
	float size = float(max(_clipmap_size[p_group], 1));
	vec2 logical = clamp(p_logical, vec2(0.0), vec2(size - 1.0));
	vec2 physical = mod(logical + _clipmap_ring[clipmap_level_index(p_group, p_level)], vec2(size));
	int layer = p_level * max(_clipmap_channels[p_group], 1);
	return texelFetch(p_atlas, ivec3(ivec2(physical), layer), 0).r;
}

// The ring's share of a value at a world point: 1 where the ring serves, 0 where the source it
// replaces does, and a blend across the band edge. Zero has three causes and one meaning - read the
// fallback: the point is outside the band the two cells named, it is outside the coarsest level's own
// texel range, or `p_require_valid` and the level that would answer it is not current (mid-fill,
// mid-strip, mid-invalidation). The *measure* of the distance is the caller's, because the two stages
// ask different questions: the vertex stage is computing the vertical distance and measures
// horizontally, while the material split measures the fragment's 3D distance. `_avt_coverage_distance`
// is the one published reach both use.
//
// `p_require_valid` is the one thing a channel differs in: the height arm reads a level's own scalars,
// which are only there once the CPU side has drained the level, while the material arm reads the
// *baked* layers, whose readiness is a per-*rect* question the arm answers for itself
// (`clipmap_baked_material()`). A level's `valid` is therefore not this arm's gate, and asking for it
// here would make a level that is mid-strip fall back as a whole.
//
// The range test is what keeps a clamped read from being served as if it were an answer. A point no
// level contains is answered by the coarsest level *at its edge* - a different world position, and
// the reason `clipmap_texel_at()` clamps rather than wrapping - so the ring has nothing to say there
// and the source it replaces, which does, serves it. The CPU's `sample_vt_clipmap()` still answers
// that point: a reading of what the ring holds is not the same question as what a fragment may read.
float clipmap_weight(int p_group, vec2 p_world, float p_distance, bool p_require_valid) {
	if (_clipmap_level_count[p_group] <= 0) {
		return 0.0;
	}
	int level = clipmap_level_for_world(p_group, p_world);
	if (!clipmap_contains(p_group, level, p_world)) {
		return 0.0;
	}
	if (p_require_valid && _clipmap_level_valid[clipmap_level_index(p_group, level)] < 0.5) {
		return 0.0;
	}
	float reach = max(64.0, _avt_coverage_distance);
	float far_band = smoothstep(reach * 0.75, reach, p_distance);
	float weight = (_clipmap_band[p_group] & 1) != 0 ? 1.0 - far_band : 0.0;
	if ((_clipmap_band[p_group] & 2) != 0) {
		weight = max(weight, far_band);
	}
	return weight;
}

// One stored value at a world point through the addressing above, and the same bilinearly
// interpolated on the level's own grid. The weights are the level's, not the fallback grid's: a
// coarse level's texels are further apart than the finer grid's, so its fraction would sample inside
// one texel and read it as four.
float clipmap_texel(int p_group, vec2 p_world, highp sampler2DArray p_atlas) {
	vec3 address = clipmap_address(p_group, p_world);
	return clipmap_texel_at(p_group, int(address.z), floor(address.xy), p_atlas);
}

float clipmap_texel_interpolated(int p_group, vec2 p_world, highp sampler2DArray p_atlas) {
	vec3 address = clipmap_address(p_group, p_world);
	vec2 base = floor(address.xy);
	vec2 f = address.xy - base;
	int level = int(address.z);
	float v00 = clipmap_texel_at(p_group, level, base, p_atlas);
	float v10 = clipmap_texel_at(p_group, level, base + vec2(1.0, 0.0), p_atlas);
	float v01 = clipmap_texel_at(p_group, level, base + vec2(0.0, 1.0), p_atlas);
	float v11 = clipmap_texel_at(p_group, level, base + vec2(1.0, 1.0), p_atlas);
	return mix(mix(v00, v10, f.x), mix(v01, v11, f.x), f.y);
}

// ---- The block atlas's shared addressing ---------------------------------------------------------
// One cell of the block grid, resolved from a world point. The CPU's `cell_for_world()` in one
// function: walk the rings finest first, keep the ring whose own start point puts the point inside
// one of *its* cells (the 3x3 square is ring 0, the Chebyshev shell at distance d >= 2 is ring
// d - 1), and stop there. `found` is the coverage test - outside the grid every ring declines and
// the region array answers - `current`/`baked` are the gates the two arms read.
#ifdef TERRAIN_CLIPMAP_ATLAS
struct ClipmapBlockCell {
	bool found;
	bool current;
	bool baked;
	int ring;
	int gx;
	int gy;
	int slot;
	vec2 start;
	vec2 offset;
	vec4 rect;
	int texels;
	float texel;
};

ClipmapBlockCell clipmap_block_find(int p_group, vec2 p_world) {
	ClipmapBlockCell cell;
	cell.found = false;
	cell.current = false;
	cell.baked = false;
	cell.ring = -1;
	cell.gx = 0;
	cell.gy = 0;
	cell.slot = -1;
	cell.start = vec2(0.0);
	cell.offset = vec2(0.0);
	cell.rect = vec4(0.0);
	cell.texels = 1;
	cell.texel = 0.0;
	int rings = int(clipmap_block_data_at(p_group, CLIPMAP_ATLAS_DATA_RINGS) + 0.5);
	float base_world = clipmap_block_data_at(p_group, CLIPMAP_ATLAS_DATA_WORLD);
	if (rings <= 0 || base_world <= 0.0) {
		return cell;
	}
	// One unit is a 3x3 arrangement of *its own* blocks, and unit `r`'s blocks cover
	// `base_world * 2^r` metres: the shared ladder's own unit size, which is what makes the atlas serve
	// the density the LOD ring's unit `r` serves at the distance unit `r` stands at. Finest first, so a
	// shell's inner hole never answers for a finer unit - the nesting the user asked for.
	for (int ring = 0; ring < CLIPMAP_ATLAS_MAX_RINGS; ring++) {
		if (ring >= rings) {
			break;
		}
		float block_world = base_world * exp2(float(ring));
		vec2 start = vec2(clipmap_block_data_at(p_group, CLIPMAP_ATLAS_DATA_STARTS + ring * 2),
				clipmap_block_data_at(p_group, CLIPMAP_ATLAS_DATA_STARTS + ring * 2 + 1));
		// The block a coordinate names is a *half-open* square, `[start + b * W - W/2, ... + W/2)`,
		// so the index is `floor((world - start) / W + 0.5)` rather than `round(...)`: GLSL's
		// `round()` is implementation-defined at a tie, and at a boundary it picked the block below
		// the point, whose clamped edge texel is one block away from the array's.
		int gx = int(floor((p_world.x - start.x) / block_world + 0.5));
		int gy = int(floor((p_world.y - start.y) / block_world + 0.5));
		if (abs(gx) > 1 || abs(gy) > 1) {
			continue;
		}
		int cell_index = ring * 9 + (gy + 1) * 3 + (gx + 1);
		int slot = int(clipmap_block_data_at(p_group, CLIPMAP_ATLAS_DATA_SLOTS + cell_index) + 0.5);
		cell.found = true;
		cell.current = clipmap_block_data_at(p_group, CLIPMAP_ATLAS_DATA_CURRENT + cell_index) > 0.5;
		cell.baked = clipmap_block_data_at(p_group, CLIPMAP_ATLAS_DATA_BAKED + cell_index) > 0.5;
		cell.ring = ring;
		cell.gx = gx;
		cell.gy = gy;
		cell.slot = slot;
		cell.start = start;
		cell.offset = vec2(
				clipmap_block_data_at(p_group, CLIPMAP_ATLAS_DATA_OFFSETS + cell_index * 2),
				clipmap_block_data_at(p_group, CLIPMAP_ATLAS_DATA_OFFSETS + cell_index * 2 + 1));
		if (slot >= 0 && slot < CLIPMAP_ATLAS_MAX_SLOTS) {
			int rect_at = CLIPMAP_ATLAS_DATA_RECTS + slot * 4;
			cell.rect = vec4(clipmap_block_data_at(p_group, rect_at),
					clipmap_block_data_at(p_group, rect_at + 1),
					clipmap_block_data_at(p_group, rect_at + 2),
					clipmap_block_data_at(p_group, rect_at + 3));
		}
		cell.texels = max(1, int(cell.rect.z));
		cell.texel = block_world / float(cell.texels);
		return cell;
	}
	return cell;
}

// The world point the block's content index names, which is the block square carried to its own grid
// coordinate: `block start + gx * block_world - half a block`. The content is unrotated, so the
// stored index is the logical one - unlike the ring's level, which a movement turns.
vec2 clipmap_block_origin(int p_group, ClipmapBlockCell p_cell) {
	float base_world = clipmap_block_data_at(p_group, CLIPMAP_ATLAS_DATA_WORLD);
	float block_world = base_world * exp2(float(p_cell.ring));
	return p_cell.start + vec2(float(p_cell.gx), float(p_cell.gy)) * block_world -
			vec2(0.5 * block_world);
}

// The atlas texel a logical tap reads: clamped inside the block - there is no neighbour inside it,
// the world beyond belongs to another ring - and then the rect's own offset added. A tap at the edge
// therefore reads the block's edge texel rather than wrapping onto the opposite edge, which is the
// ring's clamp with a block instead of a level.
ivec2 clipmap_block_stored(ClipmapBlockCell p_cell, vec2 p_logical) {
	vec2 limit = max(vec2(float(p_cell.texels - 1)), vec2(0.0));
	vec2 clamped = clamp(p_logical, vec2(0.0), limit);
	return ivec2(p_cell.rect.xy + mod(clamped + p_cell.offset, vec2(float(p_cell.texels))));
}

// One stored value, point sampled, through the cell that answers the point. `p_require_current` is
// the height arm's gate - a height read is a cell's own scalars, which only exist once the CPU side
// has produced it - and the material arm asks for the *baked* gate instead.
float clipmap_block_texel_at(int p_group, vec2 p_world, highp sampler2DArray p_texture, int p_layer,
		bool p_require_current) {
	ClipmapBlockCell cell = clipmap_block_find(p_group, p_world);
	if (!cell.found || (p_require_current && !cell.current)) {
		return 0.0;
	}
	vec2 origin = clipmap_block_origin(p_group, cell);
	vec2 logical = floor((p_world - origin) / cell.texel);
	return texelFetch(p_texture, ivec3(clipmap_block_stored(cell, logical), p_layer), 0).r;
}

// The same value bilinearly interpolated on the block's own grid. Each of the four texels is a world
// position resolved through the cell that *owns* it, so a tap that leaves this block reads the
// neighbouring block rather than clamping to this one's edge - which is what makes the atlas's
// interpolated read the array's own at an internal block boundary.
float clipmap_block_texel_interpolated_at(int p_group, vec2 p_world, highp sampler2DArray p_texture,
		int p_layer, bool p_require_current) {
	ClipmapBlockCell cell = clipmap_block_find(p_group, p_world);
	if (!cell.found || (p_require_current && !cell.current)) {
		return 0.0;
	}
	vec2 origin = clipmap_block_origin(p_group, cell);
	vec2 address = (p_world - origin) / cell.texel;
	vec2 base = floor(address);
	vec2 f = address - base;
	float v00 = clipmap_block_texel_at(p_group, origin + (base + vec2(0.5, 0.5)) * cell.texel,
			p_texture, p_layer, p_require_current);
	float v10 = clipmap_block_texel_at(p_group, origin + (base + vec2(1.5, 0.5)) * cell.texel,
			p_texture, p_layer, p_require_current);
	float v01 = clipmap_block_texel_at(p_group, origin + (base + vec2(0.5, 1.5)) * cell.texel,
			p_texture, p_layer, p_require_current);
	float v11 = clipmap_block_texel_at(p_group, origin + (base + vec2(1.5, 1.5)) * cell.texel,
			p_texture, p_layer, p_require_current);
	return mix(mix(v00, v10, f.x), mix(v01, v11, f.x), f.y);
}
)"
// A split of its own: the weight below is a section rather than an addition to the addressing above,
// whose literal is at MSVC's 16 kB limit.
R"(
// The block's share of a value at a world point: the shared band rule, measured against the *atlas's*
// own band mask - the two cells may name the ring in one band and the atlas in the other, so the two
// units have a mask each rather than one. Zero means the array answers: the point is outside the
// grid, the atlas owns neither band here, or `p_require_current` and the cell that would answer is
// not current. The coverage test is the find above, which is why a point the grid does not hold - the
// one-time global block's world - falls back to the region array rather than to a minimal-resolution
// block, exactly as the ring's coverage rule does.
float clipmap_block_weight(int p_group, vec2 p_world, float p_distance, bool p_require_current) {
	int band = int(clipmap_block_data_at(p_group, CLIPMAP_ATLAS_DATA_BAND) + 0.5);
	if (int(clipmap_block_data_at(p_group, CLIPMAP_ATLAS_DATA_RINGS) + 0.5) <= 0 || (band & 3) == 0) {
		return 0.0;
	}
	ClipmapBlockCell cell = clipmap_block_find(p_group, p_world);
	if (!cell.found || (p_require_current && !cell.current)) {
		return 0.0;
	}
	float reach = max(64.0, _avt_coverage_distance);
	float far_band = smoothstep(reach * 0.75, reach, p_distance);
	float weight = (band & 1) != 0 ? 1.0 - far_band : 0.0;
	if ((band & 2) != 0) {
		weight = max(weight, far_band);
	}
	return weight;
}
#endif // TERRAIN_CLIPMAP_ATLAS
#endif // TERRAIN_CLIPMAP
)"
// A split of its own, for the reason every other one here has one: the string literal above is at
// MSVC's 16 kB limit, so the arm below is a section rather than an addition to it.
R"(
// ---- The height channel's ring arm ---------------------------------------------------------------
// The height group's own three reads, and nothing else: the level rule, the coverage test, the
// validity gate and the band blend above are the ring's and are shared with every other channel, so
// this arm is the group's index, its atlas, and the distance its stage is asking about.
#ifdef TERRAIN_CLIPMAP_HEIGHT
// Whether the *block atlas* is the unit that answers a point, when the group owns both. The atlas and
// the ring have a band mask each, and the finer unit - the larger weight - is what a reader takes;
// where only one owns the band the other's weight is zero, so this is that one. A group that owns
// only the ring returns false on the `#else`, and the arm below is the shipped ring read.
bool clipmap_height_uses_block(vec2 p_world) {
#ifdef TERRAIN_CLIPMAP_ATLAS_HEIGHT
	float distance_xz = length(p_world - v_camera_pos.xz);
	float block_weight = clipmap_block_weight(CLIPMAP_GROUP_HEIGHT, p_world, distance_xz, true);
	if (block_weight <= 0.0) {
		return false;
	}
	return block_weight >= clipmap_weight(CLIPMAP_GROUP_HEIGHT, p_world, distance_xz, true);
#else
	return false;
#endif
}

#ifdef TERRAIN_CLIPMAP_ATLAS_HEIGHT
float clipmap_block_height_at_world(vec2 p_world) {
	return clipmap_block_texel_at(CLIPMAP_GROUP_HEIGHT, p_world, _clipmap_block[CLIPMAP_GROUP_HEIGHT],
			0, true);
}

float clipmap_block_height_interpolated_at_world(vec2 p_world) {
	return clipmap_block_texel_interpolated_at(CLIPMAP_GROUP_HEIGHT, p_world,
			_clipmap_block[CLIPMAP_GROUP_HEIGHT], 0, true);
}
#endif

float clipmap_height_at_world(vec2 p_world) {
#ifdef TERRAIN_CLIPMAP_ATLAS_HEIGHT
	if (clipmap_height_uses_block(p_world)) {
		return clipmap_block_height_at_world(p_world);
	}
#endif
	return clipmap_texel(CLIPMAP_GROUP_HEIGHT, p_world, _clipmap_atlas[CLIPMAP_GROUP_HEIGHT]);
}

float clipmap_height_interpolated_at_world(vec2 p_world) {
#ifdef TERRAIN_CLIPMAP_ATLAS_HEIGHT
	if (clipmap_height_uses_block(p_world)) {
		return clipmap_block_height_interpolated_at_world(p_world);
	}
#endif
	return clipmap_texel_interpolated(CLIPMAP_GROUP_HEIGHT, p_world, _clipmap_atlas[CLIPMAP_GROUP_HEIGHT]);
}

// The height group's share of the height at a world point, measured horizontally: the vertex stage is
// computing the vertical distance, and the material split next door measures the fragment's 3D
// distance instead. The two are different questions and each is measured where it is asked.
float clipmap_height_weight(vec2 p_world) {
	// `true`: a height read is the cell's own scalars, and those are only there once the CPU side has
	// produced the block or drained the level - unlike the material arm, whose readiness is per rect
	// and is its own question.
	float distance_xz = length(p_world - v_camera_pos.xz);
	float weight = clipmap_weight(CLIPMAP_GROUP_HEIGHT, p_world, distance_xz, true);
#ifdef TERRAIN_CLIPMAP_ATLAS_HEIGHT
	weight = max(weight, clipmap_block_weight(CLIPMAP_GROUP_HEIGHT, p_world, distance_xz, true));
#endif
	return weight;
}
#endif // TERRAIN_CLIPMAP_HEIGHT

// How far apart the height reads of one normal are, in height-grid units: the ring's texel where the
// ring serves, and the height grid's own step where the array does. Never below 1 - a level finer
// than the height grid is still read at the grid's step, which is what those taps are stated in. One
// for a configuration with no ring arm, which is what keeps that path's arithmetic unchanged.
float height_tap_scale(vec2 p_uv) {
#ifdef TERRAIN_CLIPMAP_HEIGHT
	vec2 world = p_uv * _vertex_spacing;
	float weight = clipmap_height_weight(world);
	if (weight <= 0.0) {
		return 1.0;
	}
	float texel = clipmap_texel_world(CLIPMAP_GROUP_HEIGHT, clipmap_level_for_world(CLIPMAP_GROUP_HEIGHT, world));
#ifdef TERRAIN_CLIPMAP_ATLAS_HEIGHT
	if (clipmap_height_uses_block(world)) {
		// The block the point falls in is the source, so the taps are differenced at *its* texel: a
		// coarse block is a coarse normal, which is the same statement the ring's level makes.
		texel = clipmap_block_find(CLIPMAP_GROUP_HEIGHT, world).texel;
	}
#endif
	return mix(1.0, max(texel / _vertex_spacing, 1.0), weight);
#else
	return 1.0;
#endif
}

// One height texel, point sampled, through whichever source the height group's cells select.
float height_at_uv(vec2 p_uv) {
#ifdef TERRAIN_CLIPMAP_HEIGHT
	vec2 world = p_uv * _vertex_spacing;
	float weight = clipmap_height_weight(world);
	if (weight >= 1.0) {
		return clipmap_height_at_world(world);
	}
	float array_height = array_height_point_uv(p_uv);
	if (weight <= 0.0) {
		return array_height;
	}
	return mix(array_height, clipmap_height_at_world(world), weight);
#else
	return array_height_point_uv(p_uv);
#endif
}

// The sub-texel read the finest mesh LOD uses, through the same choice.
float interpolated_height(vec2 pos) {
#ifdef TERRAIN_CLIPMAP_HEIGHT
	vec2 world = pos * _vertex_spacing;
	float weight = clipmap_height_weight(world);
	if (weight >= 1.0) {
		return clipmap_height_interpolated_at_world(world);
	}
	float array_height = array_height_interpolated_uv(pos);
	if (weight <= 0.0) {
		return array_height;
	}
	return mix(array_height, clipmap_height_interpolated_at_world(world), weight);
#else
	return array_height_interpolated_uv(pos);
#endif
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
			// The two grids the geomorph interpolates between, each read through the group's own
			// source. Point reads: a tap is a vertex position on a nested grid, so a ring level whose
			// texels are the vertex's own step answers it with that vertex's height exactly, whichever
			// of the two rings that contain the vertex is selected.
			h = mix(height_at_uv(start_pos), height_at_uv(end_pos), vertex_lerp);
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

// One of the eight taps the terrain normal is reconstructed from. `p_tap_scale` is how far apart
// those taps are in height-grid units: 1 while the region array serves, and the serving clipmap
// level's texel where the ring does, so a coarse level is differenced at its own resolution instead
// of reading the same stored value eight times.
float get_height(vec2 index_id, vec2 offset, float p_tap_scale) {
	float height = height_at_uv(index_id + offset * p_tap_scale);
//INSERT: FLAT_FRAGMENT
	return height;
}

)"

		R"(
)"
// A split of its own, for the same reason as the ones above (MSVC truncates a string literal past
// 16 kB): the material group's ring arm and the source evaluation it feeds are a section rather than
// an addition to a literal that is already near the limit.
R"(
// ---- The material group's ring arm ---------------------------------------------------------------
#ifdef TERRAIN_CLIPMAP_MATERIAL
// How much of the clipmap layer the fragment is served by: the shared band rule at the horizontal
// distance the material split measures with, so the weight a fragment is banded by is the weight it
// is mixed by. Zero covers the bands the two cells named and the coverage of the grid; one means the
// layer is the only source the fragment has. Whether the layer can *answer* it is the arm's own
// question below, because the baked arrays' readiness is per rect and this weight is per fragment.
//
// The block atlas is the layer's other residency unit, so its own band mask is folded in here: the
// detail layer beneath keys off this weight, and a fragment the atlas serves must be one the detail
// layer considers its own - exactly as it is for the ring.
float clipmap_material_weight(vec2 p_world) {
	float distance_xz = distance(p_world, v_camera_pos.xz);
	float weight = clipmap_weight(CLIPMAP_GROUP_MATERIAL, p_world, distance_xz, false);
#ifdef TERRAIN_CLIPMAP_ATLAS_MATERIAL
	weight = max(weight, clipmap_block_weight(CLIPMAP_GROUP_MATERIAL, p_world, distance_xz, false));
#endif
	return weight;
}

// Whether one level's stored texel is one its layers do not describe yet - a rect the CPU side is still
// producing, or one the producer has not baked. It is the arm's readiness, at the granularity the ring
// actually produces: a strip.
bool clipmap_outstanding(int p_group, int p_level, ivec2 p_stored) {
	int count = _clipmap_outstanding_count[clipmap_level_index(p_group, p_level)];
	int row = clipmap_level_index(p_group, p_level) * CLIPMAP_MAX_OUTSTANDING;
	for (int index = 0; index < count; index++) {
		vec4 rect = _clipmap_outstanding[row + index];
		if (float(p_stored.x) >= rect.x && float(p_stored.x) < rect.z &&
				float(p_stored.y) >= rect.y && float(p_stored.y) < rect.w) {
			return true;
		}
	}
	return false;
}

// ---- The block atlas's baked material read --------------------------------------------------
#ifdef TERRAIN_CLIPMAP_ATLAS_MATERIAL
// Four taps of one block's baked arrays, bilinearly combined. Each tap is a world position resolved
// through the cell that *owns* it, so a tap that leaves this block reads the neighbouring block's
// rect rather than clamping to this one's edge - which is what makes the atlas's baked read the ring's
// own at an internal block boundary.
vec4 clipmap_block_baked_texel(highp sampler2DArray p_array, int p_group, ClipmapBlockCell p_cell,
		vec2 p_origin, vec2 p_base, vec2 p_fraction, out bool r_readable) {
	r_readable = true;
	vec2 tap00 = p_origin + (p_base + vec2(0.5, 0.5)) * p_cell.texel;
	vec2 tap10 = p_origin + (p_base + vec2(1.5, 0.5)) * p_cell.texel;
	vec2 tap01 = p_origin + (p_base + vec2(0.5, 1.5)) * p_cell.texel;
	vec2 tap11 = p_origin + (p_base + vec2(1.5, 1.5)) * p_cell.texel;
	ClipmapBlockCell c00 = clipmap_block_find(p_group, tap00);
	ClipmapBlockCell c10 = clipmap_block_find(p_group, tap10);
	ClipmapBlockCell c01 = clipmap_block_find(p_group, tap01);
	ClipmapBlockCell c11 = clipmap_block_find(p_group, tap11);
	if (!c00.found || !c00.baked || !c10.found || !c10.baked ||
			!c01.found || !c01.baked || !c11.found || !c11.baked) {
		r_readable = false;
		return vec4(0.0);
	}
	vec4 v00 = texelFetch(p_array, ivec3(clipmap_block_stored(c00,
							   floor((tap00 - clipmap_block_origin(p_group, c00)) / c00.texel)), 0), 0);
	vec4 v10 = texelFetch(p_array, ivec3(clipmap_block_stored(c10,
							   floor((tap10 - clipmap_block_origin(p_group, c10)) / c10.texel)), 0), 0);
	vec4 v01 = texelFetch(p_array, ivec3(clipmap_block_stored(c01,
							   floor((tap01 - clipmap_block_origin(p_group, c01)) / c01.texel)), 0), 0);
	vec4 v11 = texelFetch(p_array, ivec3(clipmap_block_stored(c11,
							   floor((tap11 - clipmap_block_origin(p_group, c11)) / c11.texel)), 0), 0);
	return mix(mix(v00, v10, p_fraction.x), mix(v01, v11, p_fraction.x), p_fraction.y);
}

// The material the block atlas's *baked arrays* hold at a world point. False means the fragment is not
// the atlas's, or the cell that would answer it has not been baked yet - a block whose source landed
// but whose producer's dispatch has not - and then the whole fragment falls through to the ring and
// then to the source evaluation rather than sampling a rect no dispatch has written. The gate is the
// *cell's* baked flag, which the producer sets when it acknowledges the rect, so it is a per-block
// answer and not a per-level one.
bool clipmap_block_baked_material(vec2 p_world, out material r_mat, out vec3 r_normal) {
	if (clipmap_block_weight(CLIPMAP_GROUP_MATERIAL, p_world, distance(p_world, v_camera_pos.xz), false) <= 0.0) {
		return false;
	}
	ClipmapBlockCell cell = clipmap_block_find(CLIPMAP_GROUP_MATERIAL, p_world);
	if (!cell.found || !cell.baked) {
		return false;
	}
	vec2 origin = clipmap_block_origin(CLIPMAP_GROUP_MATERIAL, cell);
	vec2 address = (p_world - origin) / cell.texel;
	vec2 base = floor(address);
	vec2 fraction = address - base;
	bool readable = true;
	vec4 albedo = clipmap_block_baked_texel(_clipmap_block_baked_albedo, CLIPMAP_GROUP_MATERIAL, cell,
			origin, base, fraction, readable);
	if (!readable) {
		return false;
	}
	vec4 normal_rough = clipmap_block_baked_texel(_clipmap_block_baked_normal, CLIPMAP_GROUP_MATERIAL,
			cell, origin, base, fraction, readable);
	if (!readable) {
		return false;
	}
	vec4 params = clipmap_block_baked_texel(_clipmap_block_baked_params, CLIPMAP_GROUP_MATERIAL, cell,
			origin, base, fraction, readable);
	if (!readable) {
		return false;
	}
	// The arrays hold the bake's own output rather than a page's storage encoding: the whole of the
	// decode is the readiness alpha, exactly the ring's baked read.
	return surface_decode_page(albedo, normal_rough, params, 0, false, r_mat, r_normal);
}
#endif // TERRAIN_CLIPMAP_ATLAS_MATERIAL

// The stored texel one corner of a level's bilinear footprint reads. The logical tap is clamped inside
// the level - there is no neighbour outside it, the world beyond belongs to a coarser level - and then
// turned into the stored texel the level's ring offset names, exactly as the ring's payload read does.
// The gate and the fetch use this one function, so a tap the arm refuses is the tap it would have read.
ivec2 clipmap_baked_tap(vec2 p_base, vec2 p_size, vec2 p_ring, int p_corner) {
	vec2 limit = max(p_size - vec2(1.0), vec2(0.0));
	vec2 logical = p_base + vec2(p_corner == 1 || p_corner == 3 ? 1.0 : 0.0,
									 p_corner >= 2 ? 1.0 : 0.0);
	return ivec2(mod(clamp(logical, vec2(0.0), limit) + p_ring, p_size));
}

// Four taps of one level's baked layer, bilinearly combined. The producer baked at exactly this density,
// which is what makes a coarser material ring a coarser material rather than the same one stretched.
vec4 clipmap_baked_texel(highp sampler2DArray p_array, int p_level, vec2 p_base, vec2 p_fraction,
		vec2 p_size, vec2 p_ring) {
	vec4 v00 = texelFetch(p_array, ivec3(clipmap_baked_tap(p_base, p_size, p_ring, 0), p_level), 0);
	vec4 v10 = texelFetch(p_array, ivec3(clipmap_baked_tap(p_base, p_size, p_ring, 1), p_level), 0);
	vec4 v01 = texelFetch(p_array, ivec3(clipmap_baked_tap(p_base, p_size, p_ring, 2), p_level), 0);
	vec4 v11 = texelFetch(p_array, ivec3(clipmap_baked_tap(p_base, p_size, p_ring, 3), p_level), 0);
	return mix(mix(v00, v10, p_fraction.x), mix(v01, v11, p_fraction.x), p_fraction.y);
}

// The material the ring's *baked layers* hold at a world point. This is the group's third sampled
// material beside the two paged tiers: the same three arrays a page carries, evaluated at the level's
// own texel centres by the same bake shader, from the ring's own payload and height. The addressing is
// the payload's - the level rule, the coverage test and the band curve are the shared ones - and the
// layer is indexed the way the payload layer is, by the *stored* texel, because that is the frame the
// ring offset keeps pointing at the same world position. False means the fragment is not the ring's, or
// one of the four texels its bilinear footprint reads is a texel the ring is still producing or has not
// baked - and then the whole footprint falls back to the source evaluation rather than blending a stale
// texel into it.
bool clipmap_baked_material(vec2 p_world, out material r_mat, out vec3 r_normal) {
#ifdef TERRAIN_CLIPMAP_ATLAS_MATERIAL
	// The block atlas first when it owns the fragment: it is the same layer's other residency unit,
	// and a cell that named it is the claim that the atlas serves this band. A cell whose bake has
	// not landed returns false and the ring below is then the fallback, exactly as the source
	// evaluation is when the ring has nothing.
	if (clipmap_block_baked_material(p_world, r_mat, r_normal)) {
		return true;
	}
#endif
	// The *ring's* own weight, not the combined one: a group whose band the atlas owns has a ring
	// that owns nothing, and running the level addressing below for it would read a level that does
	// not exist.
	if (clipmap_weight(CLIPMAP_GROUP_MATERIAL, p_world, distance(p_world, v_camera_pos.xz), false) <= 0.0) {
		return false;
	}
	vec3 address = clipmap_address(CLIPMAP_GROUP_MATERIAL, p_world);
	int level = int(address.z);
	vec2 size = vec2(float(max(_clipmap_size[CLIPMAP_GROUP_MATERIAL], 1)));
	vec2 base = floor(address.xy);
	vec2 fraction = address.xy - base;
	vec2 ring = _clipmap_ring[clipmap_level_index(CLIPMAP_GROUP_MATERIAL, level)];
	for (int corner = 0; corner < 4; corner++) {
		if (clipmap_outstanding(CLIPMAP_GROUP_MATERIAL, level, clipmap_baked_tap(base, size, ring, corner))) {
			return false;
		}
	}
	vec4 albedo = clipmap_baked_texel(_clipmap_baked_albedo, level, base, fraction, size, ring);
	vec4 normal_rough = clipmap_baked_texel(_clipmap_baked_normal, level, base, fraction, size, ring);
	vec4 params = clipmap_baked_texel(_clipmap_baked_params, level, base, fraction, size, ring);
	// The layers hold the bake's own output rather than a page's storage encoding: the whole of the
	// decode is the readiness alpha, which the producer writes as 1 - so the unencoded pair of
	// `surface_decode_page()` is exactly this, and a page's octahedral or packed forms never apply.
	return surface_decode_page(albedo, normal_rough, params, 0, false, r_mat, r_normal);
}

)"
// A split of its own: the detail arm is a section rather than an addition to the ring arm's
// literal, which is already near MSVC's 16 kB limit, and it is logically its own concern anyway -
// the ring arm samples a dense level, this one samples a sparse directory of tiles.
R"(
// ---- The material group's detail layer, sampled ------------------------------------------------
// The readable slot at a world point for one detail level, or -1. `r_tile_local` is the position
// inside the tile in [0,1), which is what the stored-texel address below is built from. The whole
// lookup is the directory fetch: a slot is published exactly while its bake has landed for the
// generation the tile was handed out under, so `-1` covers "not resident", "being produced" and
// "invalidated" with one answer - the fragment falls through to the ring.
//
// The directory is passed in rather than indexed here, because a *sampler* array index has to be a
// constant in a shader: `detail_baked_material()` below unrolls the level loop so every call names
// its sampler with a literal. The numeric tables around it are plain arrays and are indexed at
// runtime, which is what keeps the level count a setting instead of a compile-time shape.
int detail_slot_at(int p_level, highp sampler2D p_directory, vec2 p_world, out vec2 r_tile_local) {
	r_tile_local = vec2(0.0);
	if (p_level < 0 || p_level >= _detail_level_count || p_level >= CLIPMAP_DETAIL_MAX_LEVELS) {
		return -1;
	}
	float tile_world = _detail_tile_world[p_level];
	int directory_size = _detail_directory_size;
	if (tile_world <= 0.0 || directory_size <= 0) {
		return -1;
	}
	vec2 local = (p_world - _detail_window_origin[p_level]) / tile_world;
	ivec2 tile = ivec2(floor(local));
	if (tile.x < 0 || tile.y < 0 || tile.x >= directory_size || tile.y >= directory_size) {
		return -1;
	}
	int slot = int(texelFetch(p_directory, tile, 0).r + 0.5) - 1;
	if (slot < 0 || slot >= _detail_slots) {
		return -1;
	}
	r_tile_local = local - vec2(tile);
	return slot;
}

// One detail level's material at a world point: its three baked layers read bilinearly at the
// tile's own texel grid, through the gutter. `r_density` is the level's texels per metre, published
// so a probe can say *which* density answered rather than only that some material did - the 1024
// acceptance reads it. False means this level has no readable tile here.
bool detail_baked_level(int p_level, highp sampler2D p_directory, vec2 p_world, out material r_mat,
		out vec3 r_normal, out float r_density) {
	r_density = 0.0;
	int tile_size = _detail_tile_size;
	int border = _detail_border;
	int stored = _detail_stored_size;
	if (tile_size <= 0 || stored <= 0) {
		return false;
	}
	vec2 tile_local;
	int slot = detail_slot_at(p_level, p_directory, p_world, tile_local);
	if (slot < 0) {
		return false;
	}
	// The stored texel the bilinear footprint reads. The interior is `tile_size` texels wide and
	// the gutter `border` on each side, so a tap never leaves the stored square; the clamp is
	// there for the tile's own rim, where the tap before the first interior texel reads the
	// gutter - which the producer filled with the neighbouring ground, not with the rim.
	//
	// TODO(stage 3): the four taps below are an explicit bilinear read of level 0 of the tile - there
	// is no mip chain and no anisotropic footprint, so a grazing view or a fragment whose footprint
	// spans many detail texels filters only within its own two-by-two. That is the sampling work the
	// plan defers; the residency, the directory gate and the fallback chain are what this stage has
	// to get right, and they are what the taps depend on.
	vec2 address = tile_local * float(tile_size) + float(border) - 0.5;
	vec2 base = floor(address);
	vec2 fraction = address - base;
	vec2 limit = vec2(float(stored - 1));
	ivec2 c00 = ivec2(clamp(base, vec2(0.0), limit));
	ivec2 c10 = ivec2(clamp(base + vec2(1.0, 0.0), vec2(0.0), limit));
	ivec2 c01 = ivec2(clamp(base + vec2(0.0, 1.0), vec2(0.0), limit));
	ivec2 c11 = ivec2(clamp(base + vec2(1.0, 1.0), vec2(0.0), limit));
	vec4 a00 = texelFetch(_detail_baked_albedo, ivec3(c00, slot), 0);
	vec4 a10 = texelFetch(_detail_baked_albedo, ivec3(c10, slot), 0);
	vec4 a01 = texelFetch(_detail_baked_albedo, ivec3(c01, slot), 0);
	vec4 a11 = texelFetch(_detail_baked_albedo, ivec3(c11, slot), 0);
	vec4 n00 = texelFetch(_detail_baked_normal, ivec3(c00, slot), 0);
	vec4 n10 = texelFetch(_detail_baked_normal, ivec3(c10, slot), 0);
	vec4 n01 = texelFetch(_detail_baked_normal, ivec3(c01, slot), 0);
	vec4 n11 = texelFetch(_detail_baked_normal, ivec3(c11, slot), 0);
	vec4 p00 = texelFetch(_detail_baked_params, ivec3(c00, slot), 0);
	vec4 p10 = texelFetch(_detail_baked_params, ivec3(c10, slot), 0);
	vec4 p01 = texelFetch(_detail_baked_params, ivec3(c01, slot), 0);
	vec4 p11 = texelFetch(_detail_baked_params, ivec3(c11, slot), 0);
	vec4 albedo = mix(mix(a00, a10, fraction.x), mix(a01, a11, fraction.x), fraction.y);
	vec4 normal_rough = mix(mix(n00, n10, fraction.x), mix(n01, n11, fraction.x), fraction.y);
	vec4 params = mix(mix(p00, p10, fraction.x), mix(p01, p11, fraction.x), fraction.y);
	// The layers hold the bake's own output rather than a page's storage encoding, so the whole of
	// the decode is the readiness alpha - exactly the ring's baked read.
	r_density = _detail_texels_per_meter[p_level];
	return surface_decode_page(albedo, normal_rough, params, 0, false, r_mat, r_normal);
}

// The material the detail layer holds at a world point: the finest level with a readable tile. False
// means no detail level has one here, and then the caller must fall through to the ring's baked
// material and then to the source evaluation. That ordering is the whole of the fallback chain, and
// this function deliberately never reads a layer whose directory entry it did not just check: an
// unreadable tile is invisible, never stale.
bool detail_baked_material(vec2 p_world, out material r_mat, out vec3 r_normal, out float r_density) {
	r_density = 0.0;
	if (_detail_enabled == 0) {
		return false;
	}
	// The detail layer is a finer source *inside* the band the ring serves, not a second band: a
	// fragment the pages own, or one outside the ring's reach, has nothing to refine here.
	if (clipmap_material_weight(p_world) <= 0.0) {
		return false;
	}
	int count = clamp(_detail_level_count, 0, CLIPMAP_DETAIL_MAX_LEVELS);
	if (count > 0 && detail_baked_level(0, _detail_directory[0], p_world, r_mat, r_normal, r_density)) {
		return true;
	}
	if (count > 1 && detail_baked_level(1, _detail_directory[1], p_world, r_mat, r_normal, r_density)) {
		return true;
	}
	if (count > 2 && detail_baked_level(2, _detail_directory[2], p_world, r_mat, r_normal, r_density)) {
		return true;
	}
	if (count > 3 && detail_baked_level(3, _detail_directory[3], p_world, r_mat, r_normal, r_density)) {
		return true;
	}
	return false;
}
#endif // TERRAIN_CLIPMAP_MATERIAL
)"

// The source evaluation, in its own literal again for the same reason.
R"(
// ---- The source evaluation, in one function -------------------------------------------------------
// The material a fragment gets from the *stored payload*: the `R16` control texel - through the array or
// the paging method - resolved against the texture assets by the idweight rules. It is one function
// rather than a block inside `fragment()` because it has two callers by construction: the fragment of a
// group no page serves (which is the whole of its material) and the fragment of a group whose other band
// a page owns (which mixes this with the page's material). A ring on the material group is deliberately
// not one of its sources: the ring's channel is the *material*, so a fragment its layers cannot answer
// reads the payload where the shipped paths keep it, and the ring's own payload layer is nothing but the
// producer's input.
void evaluate_idweight_material(vec2 p_uv, vec2 p_weight, ivec3 p_index0, ivec3 p_index1, ivec3 p_index2,
		ivec3 p_index3, bool p_bilerp, vec3 p_w_normal, vec3 p_base_ddx, vec3 p_base_ddy,
		out material r_mat, out vec3 r_blended_normal, out uint r_material_count) {
	const vec3 offsets = vec3(0, 1, 2);
	// GLSL out parameters are undefined before the first write and the accumulation below adds into
	// them, so the accumulator starts here rather than at the caller.
	r_mat = material(vec4(0.0), vec4(0.0), 0., 0., 0., 0.);
	r_blended_normal = vec3(0.0);
	r_material_count = 1u;
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
	vec2 surface_weight = _surface_vt_enabled ? fract(p_uv * float(max(1, _surface_density))) : p_weight;
	uvec4 surface = uvec4(0u);
	surface[3] = get_surface_value(surface_corner(p_uv, ivec2(offsets.xx)), p_index3,
			get_surface_texel(p_uv, ivec2(offsets.xx)));
	// At distant mips only one corner is fetched. All triangle vertices must use
	// that sample; zero-filled corners would spuriously blend material ID 0.
	surface = uvec4(surface[3]);
	if (p_bilerp) {
		surface[0] = get_surface_value(surface_corner(p_uv, ivec2(offsets.xy)), p_index0,
				get_surface_texel(p_uv, ivec2(offsets.xy)));
		surface[1] = get_surface_value(surface_corner(p_uv, ivec2(offsets.yy)), p_index1,
				get_surface_texel(p_uv, ivec2(offsets.yy)));
		surface[2] = get_surface_value(surface_corner(p_uv, ivec2(offsets.yx)), p_index2,
				get_surface_texel(p_uv, ivec2(offsets.yx)));
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
	float triplanarFactor = idweight_get_triplanar_factor(p_w_normal);
	vec3 triplanarWeights = idweight_get_triplanar_weights(p_w_normal);
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
	idweight_add_pair_vertex(p0, w0, surface[3], surface[2], surface[0], surface[1], local, slopeDistanceBlend, projectionAxis, p_w_normal, p_base_ddx, p_base_ddy, pairValues, overlayWeight);
	idweight_add_pair_vertex(p1, w1, surface[3], surface[2], surface[0], surface[1], local, slopeDistanceBlend, projectionAxis, p_w_normal, p_base_ddx, p_base_ddy, pairValues, overlayWeight);
	idweight_add_pair_vertex(p2, w2, surface[3], surface[2], surface[0], surface[1], local, slopeDistanceBlend, projectionAxis, p_w_normal, p_base_ddx, p_base_ddy, pairValues, overlayWeight);
	idweight_select_budgeted_3(pairValues, materialResidualSelector, materialIds, materialWeights, r_material_count);

	// 3 texture lookups max (one per selected layer).
	for (int layerIndex = 0; layerIndex < IDWEIGHT_MAX_LAYERS; layerIndex++) {
		if (uint(layerIndex) >= r_material_count) {
			break;
		}
		accumulate_idweight_layer(int(materialIds[layerIndex]), materialWeights[layerIndex],
			p_base_ddx, p_base_ddy, projectionAxis, p_w_normal, r_mat, r_blended_normal);
	}

	// normalize accumulated values back to 0.0 - 1.0 range.
	float weight_inv = 1.0 / max(r_mat.total_weight, 1e-8);
	r_mat.albedo_height *= weight_inv;
	r_mat.normal_rough *= weight_inv;
	r_mat.normal_map_depth *= weight_inv;
	r_mat.ao *= weight_inv;
	r_mat.ao_affect *= weight_inv;
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
	// How far apart the eight taps below are, in height-grid units, and the world distance they stand
	// for: the height grid's own step while the region array serves this fragment, and the serving
	// clipmap level's texel while the ring does. One for a `Direct` height group, which is what keeps
	// that path's arithmetic unchanged.
	float height_scale = height_tap_scale(uv);
	float height_step = _vertex_spacing * height_scale;

//INSERT: WORLD_NOISE_FRAGMENT

	h[3] = get_height(index_id, offsets.xx, height_scale); // 0 (0, 0)
	h[2] = get_height(index_id, offsets.yx, height_scale); // 1 (1, 0)
	h[0] = get_height(index_id, offsets.xy, height_scale); // 2 (0, 1)
	index_normal[3] = normalize(vec3(h[3] - h[2] + u, height_step, h[3] - h[0] + v));

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
		h[1] = get_height(index_id, offsets.yy, height_scale); // 3 (1, 1)
		float h_4 = get_height(index_id, offsets.yz, height_scale); // 4 (1, 2)
		float h_5 = get_height(index_id, offsets.zy, height_scale); // 5 (2, 1)
		float h_6 = get_height(index_id, offsets.zx, height_scale); // 6 (2, 0)
		float h_7 = get_height(index_id, offsets.xz, height_scale); // 7 (0, 2)

		// Calculate the normal for the remaining index ids.
		index_normal[0] = normalize(vec3(h[0] - h[1] + u, height_step, h[0] - h_7 + v));
		index_normal[1] = normalize(vec3(h[1] - h_5 + u, height_step, h[1] - h_4 + v));
		index_normal[2] = normalize(vec3(h[2] - h_6 + u, height_step, h[2] - h[1] + v));

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
	// The paged methods' material, how much of this fragment they own, and whether the fragment is in
	// the band they serve at all. A group with no ring on `Clipmap` gets 1 and true here, which is the
	// whole of what this call used to answer; a ring's cell takes its band out of both, and then the
	// source evaluation below serves the rest - with the page material mixed in by that same weight, so
	// the mix across the band edge is the one the two paged methods already do.
	float page_share = 1.0;
	bool page_band = true;
	bool material_cached = surface_material_sample(v_vertex.xz, mat, blendedNormalWS, page_share, page_band);
	if (!material_cached) { page_share = 0.0; }
	bool material_missing = _surface_material_required && !material_cached && page_band;
	if (material_missing) {
		// VT mode is strict: missing/pending material pages are visible diagnostics,
		// never silently replaced by the original terrain evaluator.
		mat = material(vec4(1.0, 0.0, 1.0, 0.0), vec4(w_normal, 1.0), 0., 1., 0., 1.);
		blendedNormalWS = w_normal;
	} else if (!material_cached || page_share < 1.0) {
		material evaluated;
		vec3 evaluated_normal;
		uint evaluated_count = 1u;
		// The ring's *baked layers* first. Where the producer has written the level this fragment's
		// band is served by, they are the material - the group's third sampled source beside the two
		// paged tiers - and the payload evaluation below is what they replace. A level that is not
		// baked yet falls through to that evaluation unchanged, which is the answer it has always had:
		// the same content at the payload's own density, read through the control texel.
		//
		// The *detail* layer is read before it, because it is the finer of the two and the whole
		// point of the layer: the finest readable source wins. A detail tile that is missing, still
		// being produced, or invalidated is absent from its directory - never stale - so this is a
		// fallback *chain* rather than a choice between two cached answers: detail -> ring baked ->
		// source evaluation.
		bool evaluated_baked = false;
		float evaluated_detail_density = 0.0;
#ifdef TERRAIN_CLIPMAP_MATERIAL
		evaluated_baked = detail_baked_material(v_vertex.xz, evaluated, evaluated_normal,
				evaluated_detail_density);
		if (!evaluated_baked) {
			evaluated_baked = clipmap_baked_material(v_vertex.xz, evaluated, evaluated_normal);
		}
#endif
		if (!evaluated_baked) {
			evaluate_idweight_material(uv, weight, index[0], index[1], index[2], index[3], bilerp, w_normal,
					base_ddx, base_ddy, evaluated, evaluated_normal, evaluated_count);
		}
		if (!material_cached || page_share <= 0.0) {
			mat = evaluated;
			blendedNormalWS = evaluated_normal;
			materialCount = evaluated_count;
		} else {
			// The band the ring serves and the band the pages own: the page's share replaces the
			// evaluated material as it grows, which is what keeps a ring coarser than the pages from
			// stepping at the band edge.
			mat.albedo_height = mix(evaluated.albedo_height, mat.albedo_height, page_share);
			mat.normal_rough = mix(evaluated.normal_rough, mat.normal_rough, page_share);
			mat.normal_map_depth = mix(evaluated.normal_map_depth, mat.normal_map_depth, page_share);
			mat.ao = mix(evaluated.ao, mat.ao, page_share);
			mat.ao_affect = mix(evaluated.ao_affect, mat.ao_affect, page_share);
			blendedNormalWS = mix(evaluated_normal, blendedNormalWS, page_share);
			materialCount = max(evaluated_count, 1u);
		}
	}
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
	// Each layer's depth was already applied before projection and blending by
	// idweight_decode_normal(), in both source evaluation and the VT baker.
	// Applying their weighted depth again here scales the finished direction twice.
	mat.normal_map_depth = distant_normal_amplifier;

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
