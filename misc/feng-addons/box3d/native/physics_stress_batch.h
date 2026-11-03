#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/rid.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <vector>

namespace godot { class PhysicsDirectBodyState3D; }

// Backend-neutral workload: public PhysicsServer3D / RenderingServer calls drive
// both backends. Only the optional core profiler reads Box3D-specific timers.
class FengPhysicsStressBatch : public godot::RefCounted {
	GDCLASS(FengPhysicsStressBatch, godot::RefCounted)
	std::vector<godot::RID> bodies;
	// The fixture owns these bodies until clear(); direct states share their lifetime.
	std::vector<godot::PhysicsDirectBodyState3D *> body_states;
	std::vector<godot::Transform3D> initial_poses;
	godot::RID shape;
	godot::PackedFloat32Array visual_buffer;
	bool sleep_enabled = false;
	void write_transform(int index, const godot::Transform3D &pose, float *buffer);

protected:
	static void _bind_methods();

public:
	~FengPhysicsStressBatch();
	void clear();
	void create(const godot::RID &space, int count, bool allow_sleep);
	void reset();
	void set_sleep_enabled(bool enabled);
	void agitate(int round);
	void sync_visuals(const godot::RID &multimesh);
	godot::Dictionary inspect() const;
	// Optional diagnostic readback; never used to simulate or synchronize bodies.
	godot::Dictionary core_profile() const;
	godot::PackedFloat32Array initial_buffer() const;
};
