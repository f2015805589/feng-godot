// The worker-side half of the near field's plan: the immutable input one plan is a function of,
// and the selection that turns it into page requests.
//
// It is declared here rather than in terrain_3d_avt.h because that file is records only, and rather
// than inside either .cpp because two files need it: the demand pass builds a `PlanInput` when it
// submits a plan (terrain_3d_sector_avt.cpp), and the plan worker consumes one
// (terrain_3d_avt_plan.cpp). Naming the hand-off in one place is what lets the worker be read on its
// own: everything it is allowed to look at is a field of this struct, copied in at submit time, so
// the worker never reads terrain state while the main thread is changing it.
//
// No algorithm belongs in this file. The selection is declared here and defined in its own .cpp.

#ifndef TERRAIN3D_AVT_PLAN_H
#define TERRAIN3D_AVT_PLAN_H

#include "terrain_3d_avt.h"
#include "terrain_3d_page_pipeline.h"
#include "terrain_3d_vt_visibility.h"

#include <memory>
#include <vector>

#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector3.hpp>

namespace TerrainAVT {

// Immutable input of one plan. The camera and the source snapshot are copied in
// when the plan is submitted, so the worker never reads terrain state while the
// main thread changes it.
struct PlanInput {
	std::vector<Terrain3DAVTSector> working;
	std::shared_ptr<const Terrain3DPagePipeline::Snapshot> source;
	TerrainVT::VisibleView view;
	bool bounds_ready = false;
	Vector3 camera_position;
	// Demand can lead the view; submission priority belongs to the eye being drawn.
	Vector3 priority_camera_position;
	Vector2 focus;
	float reach = 0.f;
	float exact_radius = 0.f;
	float logical_ratio = 0.f;
	float texels_per_pixel = 1.f;
	int budget = 0;
	int root_level = 0;
	int page_size = 0;
};

// Selects the page set for one plan key. Runs on the plan worker; the result is
// published through `r_job.ready` for the main thread to install.
void plan_pages(Terrain3DAVTRefinement &r_job, const PlanInput &p_input);

} // namespace TerrainAVT

#endif // TERRAIN3D_AVT_PLAN_H
