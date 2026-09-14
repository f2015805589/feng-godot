// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/world3d.hpp>
#include <godot_cpp/core/version.hpp>

#include "logger.h"
#include "terrain_3d.h"
#include "terrain_3d_mesher.h"
#include "terrain_3d_cdlod.h"

///////////////////////////
// Private Functions
///////////////////////////

void Terrain3DMesher::_generate_mesh_types() {
	_clear_mesh_types();
	LOG(INFO, "Generating all Mesh segments for clipmap of size ", _mesh_size);
	// Every segment uses the same fixed BL-TR diagonal on every LOD. See
	// _generate_mesh() for why the IdWeight surface contract requires it.
	// Create initial set of Mesh blocks to build the clipmap
	// # 0 TILE - mesh_size x mesh_size tiles
	_mesh_rids.push_back(_generate_mesh(V2I(_mesh_size)));
	// # 1 EDGE_A - 2 by (mesh_size * 4 + 8) strips to bridge LOD transitions along +-Z axis
	_mesh_rids.push_back(_generate_mesh(Vector2i(2, _mesh_size * 4 + 8)));
	// # 2 EDGE_B - (mesh_size * 4 + 4) by 2 strips to bridge LOD transitions along +-X axis
	_mesh_rids.push_back(_generate_mesh(Vector2i(_mesh_size * 4 + 4, 2)));
	// # 3 FILL_A - 4 by mesh_size
	_mesh_rids.push_back(_generate_mesh(Vector2i(4, _mesh_size)));
	// # 4 FILL_B - mesh_size by 4
	_mesh_rids.push_back(_generate_mesh(Vector2i(_mesh_size, 4)));
	// # 5 STANDARD_TRIM_A - 2 by (mesh_size * 4 + 2) strips for LOD0 +-Z axis edge
	_mesh_rids.push_back(_generate_mesh(Vector2i(2, _mesh_size * 4 + 2)));
	// # 6 STANDARD_TRIM_B - (mesh_size * 4 + 2) by 2 strips for LOD0 +-X axis edge
	_mesh_rids.push_back(_generate_mesh(Vector2i(_mesh_size * 4 + 2, 2)));
	return;
}

// Every clipmap segment splits each quad along the SAME diagonal, bottom-left to
// top-right, on every LOD.
//
// The IdWeight surface evaluator assumes one fixed mesh diagonal: it picks
// LowerLeft (BL, BR, TR) when local.x > local.y and UpperLeft (BL, TL, TR)
// otherwise, for EVERY cell -- there is no per-cell alternation. If the mesh
// alternated its diagonals, the shader's barycentric reconstruction would
// disagree with the triangles actually rendered, and the painted material would
// break up into a herringbone of visible triangles.
//
// A uniform diagonal is also preserved under dyadic subdivision, so the
// per-texel reconstruction used at LOD0 stays consistent with the coarser
// LOD1+ segments.
RID Terrain3DMesher::_generate_mesh(const Vector2i &p_size) {
	PackedVector3Array vertices;
	PackedInt32Array indices;
	AABB aabb = AABB(V3_ZERO, Vector3(p_size.x, 0.1f, p_size.y));
	LOG(DEBUG, "Generating verticies and indices for a grid mesh of width: ", p_size.x, " and height: ", p_size.y);

	vertices.resize((p_size.x + 1) * (p_size.y + 1));
	indices.resize(p_size.x * p_size.y * 6);
	Vector3 *vertex = vertices.ptrw();
	int32_t *index = indices.ptrw();
	// Generate vertices
	for (int y = 0; y <= p_size.y; ++y) {
		for (int x = 0; x <= p_size.x; ++x) {
			// Match GDScript vertex definitions
			*vertex++ = Vector3(x, 0.f, y); // bottom-left
		}
	}

	// Generate indices for quads, all split along the BL-TR diagonal
	for (int y = 0; y < p_size.y; ++y) {
		for (int x = 0; x < p_size.x; ++x) {
			int bottomLeft = y * (p_size.x + 1) + x;
			int bottomRight = bottomLeft + 1;
			int topLeft = (y + 1) * (p_size.x + 1) + x;
			int topRight = topLeft + 1;

			*index++ = bottomLeft;
			*index++ = topRight;
			*index++ = topLeft;

			*index++ = bottomLeft;
			*index++ = bottomRight;
			*index++ = topRight;
		}
	}

	return _instantiate_mesh(vertices, indices, aabb);
}

RID Terrain3DMesher::_instantiate_mesh(const PackedVector3Array &p_vertices, const PackedInt32Array &p_indices, const AABB &p_aabb) {
	Array arrays;
	arrays.resize(RenderingServer::ARRAY_MAX);
	arrays[RenderingServer::ARRAY_VERTEX] = p_vertices;
	arrays[RenderingServer::ARRAY_INDEX] = p_indices;

	PackedVector3Array normals;
	normals.resize(p_vertices.size());
	normals.fill(V3_UP);
	arrays[RenderingServer::ARRAY_NORMAL] = normals;

	PackedFloat32Array tangents;
	tangents.resize(p_vertices.size() * 4);
	tangents.fill(0.0f);
	arrays[RenderingServer::ARRAY_TANGENT] = tangents;

	LOG(DEBUG, "Creating mesh via the Rendering server");
	RID mesh = RS->mesh_create();
	RS->mesh_add_surface_from_arrays(mesh, RenderingServer::PRIMITIVE_TRIANGLES, arrays);

	LOG(DEBUG, "Setting custom aabb: ", p_aabb.position, ", ", p_aabb.size);
	RS->mesh_set_custom_aabb(mesh, p_aabb);
	RS->mesh_surface_set_material(mesh, 0, _material.is_valid() ? _material : RID());

	return mesh;
}

void Terrain3DMesher::_generate_clipmap() {
	_clear_clipmap();
	_generate_mesh_types();
	_generate_offset_data();
	LOG(DEBUG, "Creating instances for all mesh segments for clipmap of size ", _mesh_size, " for ", _lods, " LODs");
	for (int level = 0; level < _lods + _tessellation_level; level++) {
		ClipmapLevel lod;
		// Group order also indexes the positioning offsets in snap(). LOD0
		// uses trims in the same slots as the outer rings' fills.
		const MeshType groups[] = { TILE, EDGE_A, EDGE_B,
			level == 0 ? STANDARD_TRIM_A : FILL_A,
			level == 0 ? STANDARD_TRIM_B : FILL_B };
		for (int group = 0; group < 5; ++group) {
			auto &instances = lod[group];
			const int count = group == 0 ? (level == 0 ? 16 : 12) : 2;
			instances.resize(count);
			for (int i = 0; i < count; ++i) {
				instances[i].rid = RS->instance_create2(_mesh_rids[groups[group]], _scenario);
			}
		}

		// Append LOD to _lod_rids array
		_clipmap_rids.push_back(std::move(lod));
	}
}

// Precomputes all instance offset data into lookup arrays that match created instances.
// All meshes are created with 0,0 as their origin and grow along +xz. Offsets account for this.
void Terrain3DMesher::_generate_offset_data() {
	LOG(INFO, "Computing all clipmap instance positioning offsets");
	_tile_pos_lod_0.clear();
	_trim_a_pos.clear();
	_trim_b_pos.clear();
	_edge_pos.clear();
	_fill_a_pos.clear();
	_fill_b_pos.clear();
	_tile_pos.clear();

	// LOD0 Tiles: Full 4x4 Grid of mesh size tiles
	_tile_pos_lod_0.push_back(Vector3(0, 0, _mesh_size));
	_tile_pos_lod_0.push_back(Vector3(_mesh_size, 0, _mesh_size));
	_tile_pos_lod_0.push_back(Vector3(_mesh_size, 0, 0));
	_tile_pos_lod_0.push_back(Vector3(_mesh_size, 0, -_mesh_size));
	_tile_pos_lod_0.push_back(Vector3(_mesh_size, 0, -_mesh_size * 2));
	_tile_pos_lod_0.push_back(Vector3(0, 0, -_mesh_size * 2));
	_tile_pos_lod_0.push_back(Vector3(-_mesh_size, 0, -_mesh_size * 2));
	_tile_pos_lod_0.push_back(Vector3(-_mesh_size * 2, 0, -_mesh_size * 2));
	_tile_pos_lod_0.push_back(Vector3(-_mesh_size * 2, 0, -_mesh_size));
	_tile_pos_lod_0.push_back(Vector3(-_mesh_size * 2, 0, 0));
	_tile_pos_lod_0.push_back(Vector3(-_mesh_size * 2, 0, _mesh_size));
	_tile_pos_lod_0.push_back(Vector3(-_mesh_size, 0, _mesh_size));
	// Inner tiles
	_tile_pos_lod_0.push_back(V3_ZERO);
	_tile_pos_lod_0.push_back(Vector3(-_mesh_size, 0, 0));
	_tile_pos_lod_0.push_back(Vector3(0, 0, -_mesh_size));
	_tile_pos_lod_0.push_back(Vector3(-_mesh_size, 0, -_mesh_size));

	// LOD0 Trims: Fixed 2 unit wide ring around LOD0 tiles.
	_trim_a_pos.push_back(Vector3(_mesh_size * 2, 0, -_mesh_size * 2));
	_trim_a_pos.push_back(Vector3(-_mesh_size * 2 - 2, 0, -_mesh_size * 2 - 2));
	_trim_b_pos.push_back(Vector3(-_mesh_size * 2, 0, -_mesh_size * 2 - 2));
	_trim_b_pos.push_back(Vector3(-_mesh_size * 2 - 2, 0, _mesh_size * 2));

	// LOD1+: 4x4 Ring of mesh size tiles, with one 2 unit wide gap on each axis for fill meshes.
	_tile_pos.push_back(Vector3(2, 0, _mesh_size + 2));
	_tile_pos.push_back(Vector3(_mesh_size + 2, 0, _mesh_size + 2));
	_tile_pos.push_back(Vector3(_mesh_size + 2, 0, -2));
	_tile_pos.push_back(Vector3(_mesh_size + 2, 0, -_mesh_size - 2));
	_tile_pos.push_back(Vector3(_mesh_size + 2, 0, -_mesh_size * 2 - 2));
	_tile_pos.push_back(Vector3(-2, 0, -_mesh_size * 2 - 2));
	_tile_pos.push_back(Vector3(-_mesh_size - 2, 0, -_mesh_size * 2 - 2));
	_tile_pos.push_back(Vector3(-_mesh_size * 2 - 2, 0, -_mesh_size * 2 - 2));
	_tile_pos.push_back(Vector3(-_mesh_size * 2 - 2, 0, -_mesh_size + 2));
	_tile_pos.push_back(Vector3(-_mesh_size * 2 - 2, 0, +2));
	_tile_pos.push_back(Vector3(-_mesh_size * 2 - 2, 0, _mesh_size + 2));
	_tile_pos.push_back(Vector3(-_mesh_size + 2, 0, _mesh_size + 2));

	// Edge offsets set edge pair positions to either both before, straddle, or both after
	// Depending on current LOD position within the next LOD, (via test_x or test_z in snap())
	_offset_a = real_t(_mesh_size * 2) + 2.f;
	_offset_b = real_t(_mesh_size * 2) + 4.f;
	_offset_c = real_t(_mesh_size * 2) + 6.f;
	_edge_pos.push_back(Vector3(_offset_a, _offset_a, -_offset_b));
	_edge_pos.push_back(Vector3(_offset_b, -_offset_b, -_offset_c));

	// Fills: Occupies the gaps between tiles for LOD1+ to complete the ring.
	_fill_a_pos.push_back(Vector3(_mesh_size - 2, 0, -_mesh_size * 2 - 2));
	_fill_a_pos.push_back(Vector3(-_mesh_size - 2, 0, _mesh_size + 2));
	_fill_b_pos.push_back(Vector3(_mesh_size + 2, 0, _mesh_size - 2));
	_fill_b_pos.push_back(Vector3(-_mesh_size * 2 - 2, 0, -_mesh_size - 2));

	return;
}

// Frees all clipmap instance RIDs. Mesh rids must be freed separately.
void Terrain3DMesher::_clear_clipmap() {
	LOG(INFO, "Freeing all clipmap instances");
	for (const auto &lod_array : _clipmap_rids) {
		for (const auto &mesh_array : lod_array) {
			for (const ClipmapInstance &instance : mesh_array) {
				const RID &rid = instance.rid;
				RS->free_rid(rid);
			}
		}
	}
	_clipmap_rids.clear();
	return;
}

// Frees all Mesh RIDs use for clipmap instances.
void Terrain3DMesher::_clear_mesh_types() {
	LOG(INFO, "Freeing all clipmap meshes");
	for (const RID &rid : _mesh_rids) {
		RS->free_rid(rid);
	}
	_mesh_rids.clear();
	return;
}

///////////////////////////
// Public Functions
///////////////////////////

void Terrain3DMesher::initialize(Terrain3D *p_terrain, const int p_mesh_size, const int p_lods, const int p_tessellation_level,
		const real_t p_vertex_spacing, const RID &p_material, const uint32_t p_render_layers, bool p_allow_cdlod) {
	if (p_terrain) {
		_terrain = p_terrain;
	} else {
		return;
	}
	if (!_terrain->is_inside_world()) {
		LOG(DEBUG, "Terrain3D's world3D is null");
		return;
	}

	LOG(INFO, "Initializing GeoMesh");
	_scenario = _terrain->get_world_3d()->get_scenario();
	_material = p_material;
	_lods = p_lods;
	_tessellation_level = p_tessellation_level;
	_mesh_size = p_mesh_size;
	_vertex_spacing = p_vertex_spacing;
	_render_layers = p_render_layers;
	_allow_cdlod = p_allow_cdlod;
	delete _cdlod; _cdlod = nullptr;
	_clear_clipmap(); _clear_mesh_types();
	if (!_allow_cdlod ||
		_terrain->get_material()->get_world_background() != Terrain3DMaterial::NONE ||
		_terrain->get_material()->is_shader_override_enabled()) {
		_generate_clipmap();
	}
	update();
	update_aabbs();
	reset_target_position();
	snap();
}

void Terrain3DMesher::destroy() {
	delete _cdlod; _cdlod = nullptr;
	LOG(INFO, "Destroying clipmap");
	_clear_clipmap();
	_clear_mesh_types();
	_tile_pos_lod_0.clear();
	_trim_a_pos.clear();
	_trim_b_pos.clear();
	_edge_pos.clear();
	_fill_a_pos.clear();
	_fill_b_pos.clear();
}

void Terrain3DMesher::snap() {
	IS_INIT(VOID);
	// Always update target position in shader
	Vector3 target_pos = _terrain->get_clipmap_target_position();
	if (_material.is_valid()) {
		RS->material_set_param(_material, "_target_pos", target_pos);
	}
	const Ref<Terrain3DMaterial> material = _terrain->get_material();
	const bool use_cdlod = _allow_cdlod && material.is_valid() &&
		material->get_world_background() == Terrain3DMaterial::NONE && !material->is_shader_override_enabled();
	if (_allow_cdlod && _material.is_valid()) {
		RS->material_set_param(_material, "_region_grid_enabled", use_cdlod);
		RS->material_set_param(_material, "_cdlod_enabled", use_cdlod && _terrain->is_cdlod_enabled());
	}
	if (use_cdlod != (_cdlod != nullptr) ||
		(_cdlod && (_cdlod->is_adaptive() != _terrain->is_cdlod_enabled() ||
			_cdlod->get_grid_size() != (_terrain->is_cdlod_enabled() ? _terrain->get_cdlod_patch_size() : _terrain->get_region_size())))) {
		if (use_cdlod) {
			_clear_clipmap(); _clear_mesh_types();
			delete _cdlod;
			_cdlod = new Terrain3DCDLOD();
			_cdlod->initialize(_terrain, _material);
		} else {
			delete _cdlod; _cdlod = nullptr;
			_generate_clipmap(); update(); update_aabbs(); reset_target_position();
		}
	}
	if (_cdlod) { _cdlod->snap(); return; }
	// If clipmap target hasn't moved enough, skip
	Vector2 target_pos_2d = v3v2(target_pos);
	real_t tessellation_density = 1.f / pow(2.f, _tessellation_level);
	real_t vertex_spacing = _vertex_spacing * tessellation_density;
	if (MAX(std::abs(_last_target_position.x - target_pos_2d.x), std::abs(_last_target_position.y - target_pos_2d.y)) < vertex_spacing) {
		return;
	}

	// Recenter terrain on the target
	_last_target_position = target_pos_2d;
	Vector3 snapped_pos = (target_pos / vertex_spacing).floor() * vertex_spacing;
	Vector3 pos = V3_ZERO;
	for (int lod = 0; lod < _clipmap_rids.size(); ++lod) {
		real_t snap_step = pow(2.f, lod + 1.f) * vertex_spacing;
		Vector3 lod_scale = Vector3(pow(2.f, lod) * vertex_spacing, 1.f, pow(2.f, lod) * vertex_spacing);

		// Snap pos.xz
		pos.x = round(snapped_pos.x / snap_step) * snap_step;
		pos.z = round(snapped_pos.z / snap_step) * snap_step;

		LOG(EXTREME, "Snapping clipmap LOD", lod, " to position: ", pos);

		// test_x and test_z for edge strip positions
		real_t next_snap_step = pow(2.f, lod + 2.f) * vertex_spacing;
		real_t next_x = round(snapped_pos.x / next_snap_step) * next_snap_step;
		real_t next_z = round(snapped_pos.z / next_snap_step) * next_snap_step;
		int test_x = CLAMP(int(round((pos.x - next_x) / snap_step)) + 1, 0, 2);
		int test_z = CLAMP(int(round((pos.z - next_z) / snap_step)) + 1, 0, 2);
		auto &lod_array = _clipmap_rids[lod];
		for (int mesh = 0; mesh < lod_array.size(); ++mesh) {
			auto &mesh_array = lod_array[mesh];
			for (int instance = 0; instance < mesh_array.size(); ++instance) {
				Transform3D t = Transform3D();
				switch (mesh) {
					case TILE: {
						t.origin = (lod == 0) ? _tile_pos_lod_0[instance] : _tile_pos[instance];
						break;
					}
					case EDGE_A: {
						Vector3 edge_pos_instance = _edge_pos[instance];
						t.origin.z -= _offset_a + (test_z * 2.f);
						t.origin.x = edge_pos_instance[test_x];
						break;
					}
					case EDGE_B: {
						Vector3 edge_pos_instance = _edge_pos[instance];
						t.origin.z = edge_pos_instance[test_z];
						t.origin.x -= _offset_a;
						break;
					}
					// LOD0 doesnt have fills so the trims share the same index.
					case FILL_A: {
						if (lod > 0) {
							t.origin = _fill_a_pos[instance];
						} else {
							t.origin = _trim_a_pos[instance];
						}
						break;
					}
					case FILL_B: {
						if (lod > 0) {
							t.origin = _fill_b_pos[instance];
						} else {
							t.origin = _trim_b_pos[instance];
						}
						break;
					}
					default: {
						break;
					}
				}
				t = t.scaled(lod_scale);
				t.origin += pos;
				ClipmapInstance &segment = mesh_array[instance];
				// Coarse rings often keep their position while the fine grid moves.
				// Exact equality avoids suppressing any actual geometry movement.
				if (!segment.positioned || segment.transform != t) {
					RS->instance_set_transform(segment.rid, t);
					RS->instance_teleport(segment.rid);
					segment.transform = t;
					segment.positioned = true;
				}
			}
		}
	}
	return;
}

// Iterates over every instance of every mesh and updates all properties.
void Terrain3DMesher::update() {
	if (_cdlod) { _cdlod->update(); return; }
	IS_INIT(VOID);
	if (!_terrain->is_inside_world()) {
		LOG(DEBUG, "Terrain3D's world3D is null");
		return;
	}
	bool baked_light;
	bool dynamic_gi;
	switch (_terrain->get_gi_mode()) {
		case GeometryInstance3D::GI_MODE_DISABLED: {
			baked_light = false;
			dynamic_gi = false;
		} break;
		case GeometryInstance3D::GI_MODE_DYNAMIC: {
			baked_light = false;
			dynamic_gi = true;
		} break;
		case GeometryInstance3D::GI_MODE_STATIC:
		default: {
			baked_light = true;
			dynamic_gi = false;
		} break;
	}

	RenderingServer::ShadowCastingSetting cast_shadows = _terrain->get_cast_shadows();
	bool visible = _terrain->is_visible_in_tree();

	LOG(INFO, "Updating all mesh instances for ", _clipmap_rids.size(), " LODs");
	for (const auto &lod_array : _clipmap_rids) {
		for (const auto &mesh_array : lod_array) {
			for (const ClipmapInstance &instance : mesh_array) {
				const RID &rid = instance.rid;
				RS->instance_set_visible(rid, visible);
				RS->instance_set_scenario(rid, _scenario);
				RS->instance_set_layer_mask(rid, _render_layers);
				RS->instance_geometry_set_cast_shadows_setting(rid, cast_shadows);
				RS->instance_geometry_set_flag(rid, RenderingServer::INSTANCE_FLAG_USE_BAKED_LIGHT, baked_light);
				RS->instance_geometry_set_flag(rid, RenderingServer::INSTANCE_FLAG_USE_DYNAMIC_GI, dynamic_gi);
			}
		}
	}
	return;
}

// Iterates over all meshes and updates their AABBs
// All instances of each mesh inherit the updated AABB
// Defaults to using the terrain parameters
void Terrain3DMesher::update_aabbs(const real_t p_cull_margin, const Vector2 &p_height_range) {
	IS_DATA_INIT(VOID);
	LOG(INFO, "Updating ", _mesh_rids.size(), " meshes AABBs")
	real_t cull_margin;
	Vector2 height_range;
	if (p_cull_margin < 0.f) {
		cull_margin = _terrain->get_cull_margin();
	} else {
		cull_margin = p_cull_margin;
	}
	if (p_height_range.x == FLT_MAX) {
		height_range = _terrain->get_data()->get_height_range();
	} else {
		height_range = p_height_range;
	}
	height_range.y += std::abs(height_range.x);
	for (const RID &rid : _mesh_rids) {
		AABB aabb = RS->mesh_get_custom_aabb(rid);
		aabb.position.y = height_range.x - cull_margin;
		aabb.size.y = height_range.y + cull_margin * 2.f;
		RS->mesh_set_custom_aabb(rid, aabb);
	}
	return;
}

Dictionary Terrain3DMesher::get_cdlod_stats() const {
	if (_cdlod) { return _cdlod->get_stats(); }
	Dictionary result;
	result["active"] = false;
	result["reason"] = "Enable CDLOD with World Background=None and the built-in terrain shader.";
	return result;
}

void Terrain3DMesher::invalidate_region_geometry() {
	if (_cdlod) { _cdlod->invalidate_selection(); }
}
