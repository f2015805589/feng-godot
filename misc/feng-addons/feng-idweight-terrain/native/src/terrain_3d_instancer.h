// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_INSTANCER_CLASS_H
#define TERRAIN3D_INSTANCER_CLASS_H

#include <godot_cpp/classes/multi_mesh.hpp>
#include <godot_cpp/classes/multi_mesh_instance3d.hpp>
#include <unordered_map>
#include <unordered_set>

#include "constants.h"
#include "terrain_3d_region.h"

class Terrain3D;
class Terrain3DAssets;

class Terrain3DInstancer : public Object {
	GDCLASS(Terrain3DInstancer, Object);
	CLASS_NAME();
	friend Terrain3D;

public: // Constants
	static inline const int CELL_SIZE = 32;

	enum InstancerMode {
		DISABLED,
		//PLACEHOLDER,
		NORMAL,
	};

private:
	Terrain3D *_terrain = nullptr;

	// MM Resources stored in Terrain3DRegion::_instances as
	// Region::_instances{mesh_id:int} -> cell{v2i} -> [ TypedArray<Transform3D>, PackedColorArray, modified:bool ]

	// The pair of MMI and multimesh RIDs for one cell of one mesh and LOD, owned by this instancer:
	// _mmi_rids{region_loc} -> mesh{v2i(mesh_id,lod)} -> cell{v2i} -> std::pair<mmi_RID, mm_RID>.
	//
	// This map is the only place an MMI or a multimesh RID lives, so every teardown path has to walk
	// *it* rather than the data's regions: a region that has been unloaded or removed is gone from the
	// data while its entries are still here. `_mesh_ids_at()` copies the ids at a location, because
	// freeing one erases entries from the map being walked.

	using CellMMIDict = std::unordered_map<Vector2i, std::pair<RID, RID>, Vector2iHash>;
	using MeshMMIDict = std::unordered_map<Vector2i, CellMMIDict, Vector2iHash>;
	std::unordered_map<Vector2i, MeshMMIDict, Vector2iHash> _mmi_rids;

	// MMI Updates tracked in a unique Set of <region_location, mesh_id>
	// <V2I_MAX, -2> means destroy first, then update everything
	// <V2I_MAX, -1> means update everything without destroying first
	// <reg_loc, -1> means update all meshes in that region
	// <V2I_MAX, N> means update mesh ID N in all regions
	//
	// `<V2I_MAX, -1>` is not hypothetical: it is what `update_mmis()` queues with its default arguments,
	// and `initialize()` calls it that way. A pass of this repository deleted the arm that read it, the
	// guard that skipped it in the pair loop and the check for it below, on the reading that only a
	// rebuild ever queued a sentinel. The refresh then did nothing and treated V2I_MAX as a region,
	// logging "Errant null region found at: (2147483647, 2147483647)" once per mesh id - so instances
	// never appeared after a scene load. Both pieces are back; native/tests/terrain_instancer_refresh.gd
	// is the test that would have caught it.
	using V2IIntPair = std::unordered_set<std::pair<Vector2i, int>, PairVector2iIntHash>;
	V2IIntPair _queued_updates;

	InstancerMode _mode = NORMAL;
	uint32_t _density_counter = 0;

	uint32_t _get_density_count(const real_t p_density);
	int _get_master_lod(const Ref<Terrain3DMeshAsset> &p_ma);
	void _process_updates();
	void _update_mmi_by_region(const Terrain3DRegion *p_region, const int p_mesh_id);
	void _set_mmi_lod_ranges(RID p_mmi, const Ref<Terrain3DMeshAsset> &p_ma, const int p_lod);
	void _update_vertex_spacing(const real_t p_vertex_spacing);
	void _release_orphaned_regions();
	void _recount_master_lods(const std::unordered_set<int> &p_meshes);
	std::vector<int> _mesh_ids_at(const Vector2i &p_region_loc);
	void _destroy_mmi_by_location(const Vector2i &p_region_loc, const int p_mesh_id);
	void _destroy_mmi_by_cell(const Vector2i &p_region_loc, const int p_mesh_id, const Vector2i p_cell, const int p_lod = INT32_MAX);
	void _backup_region(const Ref<Terrain3DRegion> &p_region);
	RID _create_multimesh(const int p_mesh_id, const int p_lod, const TypedArray<Transform3D> &p_xforms = TypedArray<Transform3D>(), const PackedColorArray &p_colors = PackedColorArray()) const;
	Vector2i _get_cell(const Vector3 &p_global_position, const int p_region_size) const;
	Array _get_usable_height(const Vector3 &p_global_position, const Vector2 &p_slope_range, const bool p_on_collision, const real_t p_raycast_start) const;

public:
	Terrain3DInstancer() {}
	~Terrain3DInstancer() { destroy(); }

	void initialize(Terrain3D *p_terrain);
	void destroy();

	void clear_by_mesh(const int p_mesh_id);
	void clear_by_location(const Vector2i &p_region_loc, const int p_mesh_id);
	void clear_by_region(const Ref<Terrain3DRegion> &p_region, const int p_mesh_id);

	void set_mode(const InstancerMode p_mode);
	InstancerMode get_mode() const { return _mode; }
	bool is_enabled() const { return _mode != DISABLED; }

	void add_instances(const Vector3 &p_global_position, const Dictionary &p_params);
	void remove_instances(const Vector3 &p_global_position, const Dictionary &p_params);
	void add_multimesh(const int p_mesh_id, const Ref<MultiMesh> &p_multimesh, const Transform3D &p_xform = Transform3D(), const bool p_update = true);
	void add_transforms(const int p_mesh_id, const TypedArray<Transform3D> &p_xforms, const PackedColorArray &p_colors = PackedColorArray(), const bool p_update = true);
	void append_location(const Vector2i &p_region_loc, const int p_mesh_id, const TypedArray<Transform3D> &p_xforms,
			const PackedColorArray &p_colors, const bool p_update = true);
	void append_region(const Ref<Terrain3DRegion> &p_region, const int p_mesh_id, const TypedArray<Transform3D> &p_xforms,
			const PackedColorArray &p_colors, const bool p_update = true);
	void update_transforms(const AABB &p_aabb);
	int get_closest_mesh_id(const Vector3 &p_global_position) const;
	void copy_paste_dfr(const Terrain3DRegion *p_src_region, const Rect2i &p_src_rect, const Terrain3DRegion *p_dst_region);

	void swap_ids(const int p_src_id, const int p_dst_id);
	void update_mmis(const int p_mesh_id = -1, const Vector2i &p_region_loc = V2I_MAX, const bool p_rebuild = false);

	void reset_density_counter() { _density_counter = 0; }

protected:
	static void _bind_methods();
};

using InstancerMode = Terrain3DInstancer::InstancerMode;
VARIANT_ENUM_CAST(Terrain3DInstancer::InstancerMode);

// Allows us to instance every X function calls for sparse placement
// Modifies _density_counter, not const!
inline uint32_t Terrain3DInstancer::_get_density_count(const real_t p_density) {
	uint32_t count = 0;
	if (p_density < 1.f && _density_counter++ % uint32_t(1.f / p_density) == 0) {
		count = 1;
	} else if (p_density >= 1.f) {
		count = uint32_t(p_density);
	}
	return count;
}

// Use lod0 to track instance counter and set AABB, but in shadows_only lod0 doesn't exist
inline int Terrain3DInstancer::_get_master_lod(const Ref<Terrain3DMeshAsset> &p_ma) {
	if (p_ma.is_valid() && p_ma->get_cast_shadows() == SHADOWS_ONLY) {
		return p_ma->get_shadow_impostor();
	}
	return 0;
}

#endif // TERRAIN3D_INSTANCER_CLASS_H