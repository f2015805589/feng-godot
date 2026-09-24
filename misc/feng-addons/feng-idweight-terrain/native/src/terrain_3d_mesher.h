// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_MESHER_CLASS_H
#define TERRAIN3D_MESHER_CLASS_H

#include "constants.h"
#include <array>
#include <vector>

class Terrain3D;
class Terrain3DCDLOD;

class Terrain3DMesher {
	CLASS_NAME_STATIC("Terrain3DMesher");

public: // Constants
	enum MeshType {
		TILE,
		EDGE_A,
		EDGE_B,
		FILL_A,
		FILL_B,
		STANDARD_TRIM_A,
		STANDARD_TRIM_B,
	};

private:
	Terrain3D *_terrain = nullptr;
	RID _scenario = RID();
	Terrain3DCDLOD *_cdlod = nullptr;
	bool _allow_cdlod = false;
	Vector2 _last_target_position = V2_MAX;

	std::vector<RID> _mesh_rids;
	// Five ordered groups: tiles, two edges, two fills (trims at LOD0).
	struct ClipmapInstance {
		RID rid;
		Transform3D transform;
		bool positioned = false;
	};
	using ClipmapLevel = std::array<std::vector<ClipmapInstance>, 5>;
	std::vector<ClipmapLevel> _clipmap_rids;

	// Mesh offset data
	// LOD0 only
	PackedVector3Array _trim_a_pos;
	PackedVector3Array _trim_b_pos;
	PackedVector3Array _tile_pos_lod_0;
	// LOD1 +
	PackedVector3Array _fill_a_pos;
	PackedVector3Array _fill_b_pos;
	PackedVector3Array _tile_pos;
	// All LOD Levels
	real_t _offset_a = 0.f;
	real_t _offset_b = 0.f;
	real_t _offset_c = 0.f;
	PackedVector3Array _edge_pos;

	RID _material;
	int _tessellation_level = 0;
	int _lods = 0;
	int _mesh_size = 0;
	real_t _vertex_spacing = 1.f;
	uint32_t _render_layers = 1u; // Bit 1 only

	void _generate_mesh_types();
	RID _generate_mesh(const Vector2i &p_size);
	RID _instantiate_mesh(const PackedVector3Array &p_vertices, const PackedInt32Array &p_indices, const AABB &p_aabb);
	void _generate_clipmap();
	void _generate_offset_data();

	void _clear_clipmap();
	void _clear_mesh_types();

public:
	Terrain3DMesher() {}
	~Terrain3DMesher() { destroy(); }

	void initialize(Terrain3D *p_terrain, const int p_mesh_size, const int p_lods, const int p_tessellation_level,
			const real_t p_vertex_spacing, const RID &p_material, const uint32_t p_render_layers, bool p_allow_cdlod = false);
	void destroy();

	void snap();
	Dictionary get_cdlod_stats() const;
	// The last geometry pass's cost, for the node's own `terrain/cdlod_cpu` monitor. Zero
	// while the compatible clipmap path is in use: that path has no CDLOD pass to report.
	double get_cdlod_cpu_ms() const;
	void invalidate_region_geometry();
	void reset_target_position() { _last_target_position = V2_MAX; }
	void update();
	void update_aabbs(const real_t p_cull_margin = -1.f, const Vector2 &p_height_range = V2_MAX);
};
// Inline Functions

#endif // TERRAIN3D_MESHER_CLASS_H
