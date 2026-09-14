#include "terrain_3d_cdlod.h"
#include "terrain_3d.h"
#include <godot_cpp/classes/world3d.hpp>
#include <godot_cpp/classes/time.hpp>
#include <functional>
#include <cstring>

Terrain3DCDLOD::~Terrain3DCDLOD() {
	for (Batch &batch : _batches) {
		for (RID instance : batch.region_instances) { RS->free_rid(instance); }
		for (RID draw : batch.region_draws) { RS->free_rid(draw); }
		if (batch.instance.is_valid()) { RS->free_rid(batch.instance); }
		if (batch.multimesh.is_valid()) { RS->free_rid(batch.multimesh); }
	}
	if (_mesh.is_valid()) { RS->free_rid(_mesh); }
}

void Terrain3DCDLOD::initialize(Terrain3D *p_terrain, RID p_material) {
	_terrain = p_terrain;
	_adaptive = _terrain->is_cdlod_enabled();
	_grid = _adaptive ? _terrain->get_cdlod_patch_size() : _terrain->get_region_size();
	PackedVector3Array vertices, normals;
	PackedFloat32Array tangents;
	PackedInt32Array indices;
	vertices.resize((_grid + 1) * (_grid + 1));
	normals.resize(vertices.size()); normals.fill(Vector3(0, 1, 0));
	tangents.resize(vertices.size() * 4); tangents.fill(0.f);
	indices.resize(_grid * _grid * 6);
	Vector3 *v = vertices.ptrw(); int32_t *idx = indices.ptrw();
	for (int z = 0; z <= _grid; ++z) {
		for (int x = 0; x <= _grid; ++x) { *v++ = Vector3(x, 0, z); }
	}
	for (int z = 0; z < _grid; ++z) {
		for (int x = 0; x < _grid; ++x) {
			const int a = z * (_grid + 1) + x, b = a + 1, c = a + _grid + 1, d = c + 1;
			*idx++ = a; *idx++ = d; *idx++ = c;
			*idx++ = a; *idx++ = b; *idx++ = d;
		}
	}
	Array arrays; arrays.resize(RenderingServer::ARRAY_MAX);
	arrays[RenderingServer::ARRAY_VERTEX] = vertices;
	arrays[RenderingServer::ARRAY_NORMAL] = normals;
	arrays[RenderingServer::ARRAY_TANGENT] = tangents;
	arrays[RenderingServer::ARRAY_INDEX] = indices;
	_mesh = RS->mesh_create();
	RS->mesh_add_surface_from_arrays(_mesh, RenderingServer::PRIMITIVE_TRIANGLES, arrays);
	RS->mesh_surface_set_material(_mesh, 0, p_material);
	for (Batch &batch : _batches) {
		if (!_adaptive) { continue; }
		batch.multimesh = RS->multimesh_create();
		RS->multimesh_set_mesh(batch.multimesh, _mesh);
		batch.instance = RS->instance_create2(batch.multimesh, _terrain->get_world_3d()->get_scenario());
	}
	update();

}

void Terrain3DCDLOD::_upload(Batch &p_batch, PackedFloat32Array &p_data, const AABB &p_bounds) {
	const uint64_t upload_started = Time::get_singleton()->get_ticks_usec();
	const int count = int(p_data.size() / 16);
	if (!_adaptive) {
		while (int(p_batch.region_instances.size()) > count) {
			RS->free_rid(p_batch.region_instances.back());
			p_batch.region_instances.pop_back();
			RS->free_rid(p_batch.region_draws.back());
			p_batch.region_draws.pop_back();
		}
		while (int(p_batch.region_instances.size()) < count) {
			// One-instance draw prevents the renderer from automatically merging
			// ordinary mesh instances back into one multi-region draw.
			RID draw = RS->multimesh_create();
			RS->multimesh_allocate_data(draw, 1, RenderingServer::MULTIMESH_TRANSFORM_3D, false, false);
			RS->multimesh_set_mesh(draw, _mesh);
			RS->multimesh_instance_set_transform(draw, 0, Transform3D());
			p_batch.region_draws.push_back(draw);
			p_batch.region_instances.push_back(RS->instance_create2(draw, _terrain->get_world_3d()->get_scenario()));
		}
		if (p_batch.previous != p_data || p_batch.bounds != p_bounds) {
			for (int i = 0; i < count; ++i) {
				const float *record = p_data.ptr() + i * 16;
				Transform3D transform;
				transform.basis.scale(Vector3(record[0], 1, record[10]));
				transform.origin = Vector3(record[3], record[7], record[11]);
				RS->instance_set_transform(p_batch.region_instances[i], transform);
				// Convert the conservative world bounds into this region's local space.
				RS->instance_set_custom_aabb(p_batch.region_instances[i], transform.affine_inverse().xform(p_bounds));
			}
			p_batch.previous = p_data;
			p_batch.bounds = p_bounds;
		}
		return;
	}
	if (count > p_batch.capacity) {
		p_batch.capacity = int(next_power_of_2(uint32_t(count)));
		RS->multimesh_allocate_data(p_batch.multimesh, p_batch.capacity, RenderingServer::MULTIMESH_TRANSFORM_3D, false, true);
		p_batch.previous_instances.clear();
	}
	if (p_batch.previous_instances.size() != size_t(p_data.size()) ||
			(p_data.size() && !std::equal(p_batch.previous_instances.begin(), p_batch.previous_instances.end(), p_data.ptr()))) {
		if (count) {
			p_batch.previous_instances.assign(p_data.ptr(), p_data.ptr() + p_data.size());
			// Keep only one packed allocation; RS retains it until the upload executes.
			p_data.resize(p_batch.capacity * 16);
			RS->multimesh_set_buffer(p_batch.multimesh, p_data);
		} else { p_batch.previous_instances.clear(); }
		RS->multimesh_set_visible_instances(p_batch.multimesh, count);
	}
	if (p_batch.bounds != p_bounds) {
		RS->multimesh_set_custom_aabb(p_batch.multimesh, p_bounds);
		p_batch.bounds = p_bounds;
	}
	_upload_ms += double(Time::get_singleton()->get_ticks_usec() - upload_started) / 1000.0;
}

void Terrain3DCDLOD::snap() {
	if (!_terrain || !_terrain->get_data() || !_terrain->get_camera()) { return; }
	const uint64_t started = Time::get_singleton()->get_ticks_usec();
	Camera3D *camera = _terrain->get_camera();
	const Vector3 eye = camera->get_global_position();
	const real_t spacing = _terrain->get_vertex_spacing();
	const real_t region_world = _terrain->get_region_size() * spacing;
	const real_t leaf_world = _grid * spacing / real_t(1 << _terrain->get_tessellation_level());
	const real_t ratio = _terrain->get_cdlod_lod_scale();
	const real_t margin = _terrain->get_cull_margin() + (_terrain->get_tessellation_level() > 0 ? Math::abs(_terrain->get_displacement_scale()) : real_t(0));
	const bool shadows = _terrain->get_cast_shadows() != RenderingServer::SHADOW_CASTING_SETTING_OFF;
	std::array<real_t, 7> key = {eye.x, eye.y, eye.z, region_world, leaf_world, ratio, margin};
	std::array<real_t, 26> view_key = {real_t(shadows)};
	int view_index = 1;
	const Transform3D transform = camera->get_global_transform();
	const Projection projection = camera->get_camera_projection();
	for (int c = 0; c < 3; ++c) {
		for (int row = 0; row < 3; ++row) { view_key[view_index++] = transform.basis.get_column(c)[row]; }
	}
	for (int c = 0; c < 4; ++c) {
		for (int row = 0; row < 4; ++row) { view_key[view_index++] = projection[c][row]; }
	}
	const bool rebuild = !_selection_valid || key != _selection_key;
	if (!rebuild && view_key == _view_key) {
		_rebuild_ms = 0.0;
		_cull_ms = 0.0;
		_pack_ms = 0.0;
		_upload_ms = 0.0;
		_cpu_update_ms = double(Time::get_singleton()->get_ticks_usec() - started) / 1000.0;
		return;
	}
	_view_key = std::move(view_key);
	_rebuild_ms = 0.0;
	if (rebuild) {
		_selection_valid = true;
		const TypedArray<Vector2i> locations = _terrain->get_data()->get_region_locations();
		_selection_key = std::move(key);
		++_selection_builds;
		_patches.clear();
		// Horizontal distance is shared by every vertex and node. Unlike per-node
		// centre distance it cannot give neighbouring vertices different morph LODs.
		// ratio >= 8 ensures a selected fine leaf has fully collapsed at a coarse
		// boundary before the neighbouring coarse leaf begins its next morph.
		std::function<void(real_t, real_t, real_t, const Vector2 &, bool)> visit;
		visit = [&](real_t x, real_t z, real_t size, const Vector2 &height, bool root) {
			const Vector3 lo(x - margin, height.x - margin, z - margin);
			const Vector3 hi(x + size + margin, height.y + margin, z + size + margin);
			const real_t dx = MAX(MAX(x - eye.x, real_t(0)), eye.x - x - size);
			const real_t dz = MAX(MAX(z - eye.z, real_t(0)), eye.z - z - size);
			const real_t split_distance = size * .5f * ratio;
			if (size > leaf_world * 1.001f && (!_adaptive || dx * dx + dz * dz < split_distance * split_distance)) {
				const real_t half = size * .5f;
				visit(x, z, half, height, false); visit(x + half, z, half, height, false);
				visit(x, z + half, half, height, false); visit(x + half, z + half, half, height, false);
				return;
			}
			const real_t scale = size / _grid;
			const float end = float(size * ratio);
			// The coarsest region root has no parent; never morph it toward an
			// unrepresented level. Region boundaries remain on the same dyadic grid.
			const float start = (root || !_adaptive) ? 1e30f : end * .75f;
			const float inverse = (root || !_adaptive) ? 0.f : 4.f / end;
			const float record[16] = { float(scale), 0, 0, float(x), 0, 1, 0, 0, 0, 0, float(scale), float(z), start, inverse, 0, 1 };
			Patch patch;
			std::copy(std::begin(record), std::end(record), patch.transform.begin());
			patch.bounds = AABB(lo, hi - lo);
			_patches.push_back(patch);
		};
		for (const Vector2i &location : locations) {
			Ref<Terrain3DRegion> region = _terrain->get_data()->get_region(location);
			if (region.is_null() || region->is_deleted()) { continue; }
			Vector2 heights = region->get_height_range();
			// Boundary vertices can sample the neighbouring height layer. Include
			// those ranges so a high shared edge is not culled with a low cell.
			for (int z = -1; z <= 1; ++z) {
				for (int x = -1; x <= 1; ++x) {
					Ref<Terrain3DRegion> neighbour = _terrain->get_data()->get_region(location + Vector2i(x, z));
					if (neighbour.is_null() || neighbour->is_deleted()) { continue; }
					const Vector2 range = neighbour->get_height_range();
					heights.x = MIN(heights.x, range.x); heights.y = MAX(heights.y, range.y);
				}
			}
			visit(location.x * region_world, location.y * region_world, region_world, heights, true);
		}
	}
	_rebuild_ms = double(Time::get_singleton()->get_ticks_usec() - started) / 1000.0;
	const uint64_t cull_started = Time::get_singleton()->get_ticks_usec();
	// Rotation changes visibility, not the distance-selected quadtree.
	const auto frustum = projection.get_projection_planes(camera->get_camera_transform());
	std::array<Plane, 6> planes;
	std::array<Vector3, 6> absolute_normals;
	for (int i = 0; i < 6; ++i) {
		planes[i] = frustum[i];
		absolute_normals[i] = planes[i].normal.abs();
	}
	bool visibility_changed = rebuild || _visibility.size() != _patches.size();
	_visibility.resize(_patches.size());
	for (size_t index = 0; index < _patches.size(); ++index) {
		const Patch &patch = _patches[index];
		const Vector3 extent = patch.bounds.size * .5f;
		const Vector3 center = patch.bounds.position + extent;
		bool visible = true;
		for (int i = 0; i < 6; ++i) {
			if (planes[i].distance_to(center) > absolute_normals[i].dot(extent)) { visible = false; break; }
		}
		const uint8_t classification = visible ? 0 : (shadows ? 1 : 2);
		visibility_changed |= _visibility[index] != classification;
		_visibility[index] = classification;
	}
	if (!visibility_changed) {
		_cull_ms = double(Time::get_singleton()->get_ticks_usec() - cull_started) / 1000.0;
		_pack_ms = 0.0;
		_upload_ms = 0.0;
		_cpu_update_ms = double(Time::get_singleton()->get_ticks_usec() - started) / 1000.0;
		return;
	}
	_cull_ms = double(Time::get_singleton()->get_ticks_usec() - cull_started) / 1000.0;
	const uint64_t pack_started = Time::get_singleton()->get_ticks_usec();
	_upload_ms = 0.0;
	auto &lists = _instance_lists;
	for (auto &list : lists) { list.clear(); list.reserve(_patches.size() * 16); }
	std::array<AABB, 2> bounds;
	std::array<bool, 2> has_bounds = {false, false};
	_selected = _visible = 0;
	for (size_t index = 0; index < _patches.size(); ++index) {
		const Patch &patch = _patches[index];
		const bool visible = _visibility[index] == 0;
		if (!visible && !shadows) { continue; }
		const int list = visible ? 0 : 1;
		lists[list].insert(lists[list].end(), patch.transform.begin(), patch.transform.end());
		bounds[list] = has_bounds[list] ? bounds[list].merge(patch.bounds) : patch.bounds;
		has_bounds[list] = true;
		++_selected;
		if (visible) { ++_visible; }
	}
	for (int i = 0; i < 2; ++i) {
		PackedFloat32Array data; data.resize(lists[i].size());
		if (!lists[i].empty()) { std::memcpy(data.ptrw(), lists[i].data(), lists[i].size() * sizeof(float)); }
		_upload(_batches[i], data, bounds[i]);
	}
	if (!_adaptive) { update(); }
	_pack_ms = double(Time::get_singleton()->get_ticks_usec() - pack_started) / 1000.0;
	_cpu_update_ms = double(Time::get_singleton()->get_ticks_usec() - started) / 1000.0;
}

void Terrain3DCDLOD::update() {
	if (!_terrain) { return; }
	for (int i = 0; i < 2; ++i) {
		std::vector<RID> instances = _batches[i].region_instances;
		if (_adaptive) { instances.push_back(_batches[i].instance); }
		for (const RID instance : instances) {
			RS->instance_set_visible(instance, _terrain->is_visible_in_tree() && (i == 0 || _terrain->get_cast_shadows() != RenderingServer::SHADOW_CASTING_SETTING_OFF));
			RS->instance_set_layer_mask(instance, _terrain->get_render_layers());
			RS->instance_geometry_set_cast_shadows_setting(instance, i == 0 ? _terrain->get_cast_shadows() : RenderingServer::SHADOW_CASTING_SETTING_SHADOWS_ONLY);
			RS->instance_geometry_set_flag(instance, RenderingServer::INSTANCE_FLAG_USE_BAKED_LIGHT, _terrain->get_gi_mode() == GeometryInstance3D::GI_MODE_STATIC);
			RS->instance_geometry_set_flag(instance, RenderingServer::INSTANCE_FLAG_USE_DYNAMIC_GI, _terrain->get_gi_mode() == GeometryInstance3D::GI_MODE_DYNAMIC);
		}
	}
}

Dictionary Terrain3DCDLOD::get_stats() const {
	Dictionary stats;
	stats["active"] = _adaptive;
	stats["selection_builds"] = int64_t(_selection_builds);
	stats["cpu_update_ms"] = _cpu_update_ms;
	stats["rebuild_ms"] = _rebuild_ms;
	stats["cull_ms"] = _cull_ms;
	stats["pack_ms"] = _pack_ms;
	stats["upload_ms"] = _upload_ms;
	stats["backend"] = _adaptive ? "CDLOD" : "Region grid";
	stats["selected_patches"] = _selected;
	stats["visible_patches"] = _visible;
	stats["shadow_only_patches"] = _selected - _visible;
	stats["main_batches"] = _adaptive ? (_visible > 0 ? 1 : 0) : _visible;
	stats["patch_size"] = _grid;
	return stats;
}
