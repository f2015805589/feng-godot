#pragma once
#include "constants.h"
#include <godot_cpp/variant/rid.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/aabb.hpp>
#include <array>
#include <vector>

class Terrain3D;

// One regular grid, selected quadtree leaves, two instance lists: visible and
// offscreen shadow casters. Material/page ownership stays with Terrain3D.
class Terrain3DCDLOD {
	struct Batch {
		RID multimesh;
		RID instance;
		std::vector<RID> region_instances;
		std::vector<RID> region_draws;
		int capacity = 0;
		PackedFloat32Array previous;
		std::vector<float> previous_instances;
		AABB bounds;
		// The packed buffer, kept between passes: a fresh one per pass is an allocation and two
		// copies of up to 32 KB on the very frame this path's peak is measured against. The upload
		// resizes it to the batch capacity and this pass shrinks it back to the instance count, so
		// the allocation is reached once and then only re-used.
		PackedFloat32Array staging;
	};
	Terrain3D *_terrain = nullptr;
	RID _mesh;
	std::array<Batch, 2> _batches;
	int _grid = 32;
	bool _adaptive = true;
	int _selected = 0;
	int _visible = 0;
	struct Patch {
		std::array<float, 16> transform;
		AABB bounds;
	};
	std::vector<Patch> _patches;
	std::vector<uint8_t> _visibility;
	std::array<std::vector<float>, 2> _instance_lists;
	std::array<real_t, 7> _selection_key = {};
	bool _selection_valid = false;
	std::array<real_t, 26> _view_key = {};
	uint64_t _selection_builds = 0;
	double _cpu_update_ms = 0.0;
	// Where the last snap() spent its time: quadtree selection (only when the eye
	// moved), the frustum classification pass, and the instance packing/uploads that
	// follow a visibility change.
	double _rebuild_ms = 0.0;
	double _cull_ms = 0.0;
	double _pack_ms = 0.0;
	// The RenderingServer calls inside the packing phase (buffer upload, visible count,
	// bounds) and the CPU packing loop before them.
	double _upload_ms = 0.0;
	// The parts of the pass that produced `_peak_ms`, which is the worst `cpu_update_ms` since the
	// backend was created. The live fields above describe the last pass, and the peak is by
	// definition not the last pass - so without this the worst frame's cost can only be read as
	// four independent maxima, which need not come from the same frame and do not say which stage
	// the peak was.
	double _peak_ms = 0.0;
	double _peak_rebuild_ms = 0.0;
	double _peak_cull_ms = 0.0;
	double _peak_pack_ms = 0.0;
	double _peak_upload_ms = 0.0;
	int _peak_selected = 0;
	int _peak_visible = 0;
	void _upload(Batch &p_batch, PackedFloat32Array &p_data, const AABB &p_bounds);
	// The pass itself: selection, classification and packing. `snap()` is the scope that
	// publishes it, so the body can keep the early returns it uses to skip unchanged work.
	void _snap_impl();

public:
	~Terrain3DCDLOD();
	bool is_adaptive() const { return _adaptive; }
	int get_grid_size() const { return _grid; }
	void initialize(Terrain3D *p_terrain, RID p_material);
	void snap();
	void invalidate_selection() { _selection_valid = false; }
	void update();
	Dictionary get_stats() const;
	// The last pass's cost and the patch counts it selected, for the node's own monitor. A
	// cost near zero means the pass reused its previous result - nothing moved and nothing
	// changed - rather than a missing reading.
	double get_cpu_update_ms() const { return _cpu_update_ms; }
};
