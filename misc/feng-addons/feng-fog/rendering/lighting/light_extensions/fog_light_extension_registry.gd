class_name FFogLightExtensionRegistry
extends RefCounted
## Main-thread, per-World3D weak registry. It walks only FRP's active native RID
## arrays, never the SceneTree, and emits no Node/Resource references.

const Layout = preload("fog_light_extension_layout.gd")
const METADATA_ABI_VERSION := 1
const EXTENSION_VALUE_KEYS := [
	"source_extension_id", "source_revision", "cookie_texture_rd_rid",
	"cookie_texture_resource_id", "cookie_texture_revision", "cookie_srgb",
	"cookie_strength", "mapping_type", "mapping_range_m",
	"tan_half_spot_angle", "area_half_size_m", "mapping_scale",
	"mapping_offset", "world_to_light", "barn_door_enabled",
	"barn_door_cos_angle", "barn_door_length_m", "source_length_m",
	"capsule_axis_local", "shadow_policy", "static_lighting_key",
]

static var _worlds: Dictionary = {} # world instance ID -> {light RID -> WeakRef}
static var _world_generations: Dictionary = {}
static var _metadata_snapshot_generation := 0


static func register_extension(p_extension: Node, p_world_id: int,
		p_light_rid: RID) -> bool:
	if p_extension == null or not is_instance_valid(p_extension) \
			or p_world_id == 0 or not p_light_rid.is_valid():
		return false
	var entries: Dictionary = _worlds.get(p_world_id, {})
	var previous: WeakRef = entries.get(p_light_rid)
	if previous != null:
		var previous_object := previous.get_ref()
		if previous_object != null and is_instance_valid(previous_object):
			if previous_object == p_extension:
				return true
			push_warning("Duplicate FFogLightExtension for one Light3D RID; the second extension is ignored.")
			return false
	entries[p_light_rid] = weakref(p_extension)
	_worlds[p_world_id] = entries
	_bump_generation(p_world_id)
	return true


static func unregister_extension(p_extension: Node, p_world_id: int,
		p_light_rid: RID) -> void:
	var entries: Dictionary = _worlds.get(p_world_id, {})
	if entries.is_empty() or not entries.has(p_light_rid):
		return
	var previous: WeakRef = entries[p_light_rid]
	if previous.get_ref() != p_extension:
		return
	entries.erase(p_light_rid)
	if entries.is_empty():
		_worlds.erase(p_world_id)
	else:
		_worlds[p_world_id] = entries
	_bump_generation(p_world_id)


## Main-thread phase. Resolves registered Nodes and Resources into plain values
## keyed by Light3D base RID. This phase deliberately does not consume renderer
## frame arrays, which may only be available later in the frame.
static func snapshot_metadata_for_world(p_world_id: int) -> Dictionary:
	if p_world_id == 0:
		return _invalid("World3D identity is invalid.")
	var entries: Dictionary = _worlds.get(p_world_id, {})
	var metadata_by_light_rid: Dictionary = {}
	var stale_rids: Array[RID] = []
	for light_rid in entries.keys():
		if not light_rid is RID or not light_rid.is_valid():
			continue
		var extension_ref: WeakRef = entries.get(light_rid)
		if extension_ref == null:
			continue
		var extension := extension_ref.get_ref() as Node
		if extension == null or not is_instance_valid(extension) or not extension.is_inside_tree() \
				or not extension.has_method("snapshot_for_light") \
				or not extension.has_method("get_target_light"):
			stale_rids.append(light_rid)
			continue
		var light := extension.call("get_target_light") as Light3D
		if light == null or not light.is_inside_tree():
			stale_rids.append(light_rid)
			continue
		var world := light.get_world_3d()
		if world == null or world.get_instance_id() != p_world_id \
				or light.get_base() != light_rid:
			stale_rids.append(light_rid)
			continue
		var native_kind := _native_kind_for_light(light)
		if native_kind < 0:
			stale_rids.append(light_rid)
			continue
		var extension_snapshot: Dictionary = extension.call("snapshot_for_light",
				p_world_id, light_rid, native_kind)
		if not _valid_extension_snapshot(extension_snapshot, p_world_id, light_rid):
			continue
		var plain_row: Dictionary = {
			"valid": true,
			"abi_version": Layout.ABI_VERSION,
			"world_id": p_world_id,
			"light_rid": light_rid,
			"native_kind": native_kind,
		}
		for key in EXTENSION_VALUE_KEYS:
			if extension_snapshot.has(key):
				plain_row[key] = extension_snapshot[key]
		metadata_by_light_rid[light_rid] = plain_row
	for light_rid in stale_rids:
		entries.erase(light_rid)
	if not stale_rids.is_empty():
		_bump_generation(p_world_id)
	if entries.is_empty():
		_worlds.erase(p_world_id)
	else:
		_worlds[p_world_id] = entries
	_metadata_snapshot_generation += 1
	if _metadata_snapshot_generation <= 0:
		_metadata_snapshot_generation = 1
	return {
		"valid": true,
		"abi_version": METADATA_ABI_VERSION,
		"world_id": p_world_id,
		"registry_generation": int(_world_generations.get(p_world_id, 0)),
		"snapshot_generation": _metadata_snapshot_generation,
		"by_light_rid": metadata_by_light_rid,
		"snapshot_thread_contract": "main_thread_plain_values_and_RIDs_only",
	}


## Render-side/value-only phase. This function reads no Node or Resource and
## joins by same-frame native base RID arrays while preserving FRP order.
static func join_native_frame(p_metadata: Dictionary, p_frame: Dictionary,
		p_expected_world_id: int = 0) -> Dictionary:
	if not bool(p_metadata.get("valid", false)) \
			or int(p_metadata.get("abi_version", 0)) != METADATA_ABI_VERSION:
		return _invalid("Light extension metadata is invalid or has an unsupported ABI.")
	if int(p_metadata.get("snapshot_generation", 0)) <= 0 \
			or int(p_metadata.get("registry_generation", -1)) < 0:
		return _invalid("Light extension metadata has an invalid snapshot or registry generation.")
	var world_id := p_expected_world_id
	if world_id == 0:
		world_id = int(p_frame.get("world_id", p_metadata.get("world_id", 0)))
	if world_id == 0 or int(p_metadata.get("world_id", 0)) != world_id:
		return _invalid("Light extension metadata belongs to a different World3D.")
	if p_frame.has("world_id") and int(p_frame["world_id"]) != world_id:
		return _invalid("Native frame belongs to a different World3D.")
	var native := Layout.collect_native_rows(p_frame)
	if not bool(native.get("valid", false)):
		return native
	var by_light_rid: Variant = p_metadata.get("by_light_rid")
	if not by_light_rid is Dictionary:
		return _invalid("Light extension metadata has no RID keyed value map.")
	var native_kinds_by_rid: Dictionary = {}
	for row in native["rows"]:
		native_kinds_by_rid[row["light_rid"]] = int(row["native_kind"])
	for light_rid in by_light_rid.keys():
		if not light_rid is RID or not light_rid.is_valid():
			return _invalid("Light extension metadata contains an invalid Light RID.")
		var metadata_row: Variant = by_light_rid[light_rid]
		if not _valid_plain_metadata_row(metadata_row, world_id, light_rid):
			return _invalid("Light extension metadata row is malformed or belongs to another light.")
		# Main-thread metadata covers registered lights in the world, while the
		# native arrays contain only this viewport's active/cull-visible lights.
		# A valid row absent from this frame is therefore harmless and ignored.
		if native_kinds_by_rid.has(light_rid) \
				and not metadata_native_kind_matches(metadata_row, int(native_kinds_by_rid[light_rid])):
			return _invalid("Light extension metadata native kind differs from the same-frame Light RID row.")
	var rows: Array = native["rows"]
	for index in rows.size():
		var row: Dictionary = rows[index]
		var metadata_row: Variant = by_light_rid.get(row["light_rid"])
		if metadata_row is Dictionary:
			for key in EXTENSION_VALUE_KEYS:
				if metadata_row.has(key):
					row[key] = metadata_row[key]
			rows[index] = row
	native["rows"] = rows
	native["world_id"] = world_id
	native["registry_generation"] = int(p_metadata.get("registry_generation", 0))
	native["snapshot_generation"] = int(p_metadata.get("snapshot_generation", 0))
	native["snapshot_thread_contract"] = "render_side_plain_values_and_RIDs_only"
	return native


## Compatibility helper for callers that already have same-frame light arrays.
static func snapshot_for_world(p_world_id: int, p_frame: Dictionary) -> Dictionary:
	return join_native_frame(snapshot_metadata_for_world(p_world_id), p_frame, p_world_id)


static func unregister_world(p_world_id: int) -> void:
	if _worlds.has(p_world_id):
		_worlds.erase(p_world_id)
		_bump_generation(p_world_id)


static func registered_light_count(p_world_id: int) -> int:
	var entries: Dictionary = _worlds.get(p_world_id, {})
	var count := 0
	for light_rid in entries.keys():
		var reference: WeakRef = entries[light_rid]
		var object := reference.get_ref()
		if object != null and is_instance_valid(object):
			count += 1
	return count


static func _native_kind_for_light(p_light: Light3D) -> int:
	if p_light is OmniLight3D:
		return Layout.KIND_OMNI
	if p_light is SpotLight3D:
		return Layout.KIND_SPOT
	if p_light is AreaLight3D:
		return Layout.KIND_AREA
	if p_light is DirectionalLight3D:
		return Layout.KIND_DIRECTIONAL
	return -1


static func _valid_extension_snapshot(p_snapshot: Variant, p_world_id: int,
		p_light_rid: RID) -> bool:
	if not p_snapshot is Dictionary or not bool(p_snapshot.get("valid", false)) \
			or int(p_snapshot.get("abi_version", 0)) != Layout.ABI_VERSION \
			or int(p_snapshot.get("world_id", 0)) != p_world_id \
			or p_snapshot.get("light_rid", RID()) != p_light_rid:
		return false
	var transform: Variant = p_snapshot.get("world_to_light")
	var area_half_size: Variant = p_snapshot.get("area_half_size_m")
	var mapping_scale: Variant = p_snapshot.get("mapping_scale")
	var mapping_offset: Variant = p_snapshot.get("mapping_offset")
	var texture_rid: Variant = p_snapshot.get("cookie_texture_rd_rid", RID())
	var texture_resource_id := int(p_snapshot.get("cookie_texture_resource_id", 0))
	var finite_values := [
		float(p_snapshot.get("mapping_range_m", NAN)),
		float(p_snapshot.get("tan_half_spot_angle", NAN)),
		float(p_snapshot.get("cookie_strength", NAN)),
		float(p_snapshot.get("barn_door_cos_angle", NAN)),
		float(p_snapshot.get("barn_door_length_m", NAN)),
		float(p_snapshot.get("source_length_m", NAN)),
	]
	for value in finite_values:
		if not is_finite(value):
			return false
	return int(p_snapshot.get("source_extension_id", 0)) != 0 \
			and int(p_snapshot.get("source_revision", 0)) > 0 \
			and int(p_snapshot.get("native_kind", -1)) >= Layout.KIND_OMNI \
			and int(p_snapshot.get("native_kind", -1)) <= Layout.KIND_DIRECTIONAL \
			and transform is Transform3D and transform.is_finite() \
			and area_half_size is Vector2 and area_half_size.is_finite() \
			and mapping_scale is Vector2 and mapping_scale.is_finite() \
			and mapping_offset is Vector2 and mapping_offset.is_finite() \
			and texture_rid is RID \
			and (texture_resource_id == 0 or Layout.is_resource_identity_valid(texture_resource_id)) \
			and int(p_snapshot.get("mapping_type", -1)) >= Layout.MAPPING_NONE \
			and int(p_snapshot.get("mapping_type", -1)) <= Layout.MAPPING_AREA_PLANE \
			and int(p_snapshot.get("shadow_policy", -1)) >= Layout.SHADOW_INHERIT_NATIVE \
			and int(p_snapshot.get("shadow_policy", -1)) <= Layout.SHADOW_HARDWARE_RT_OPT_IN \
			and float(p_snapshot.get("mapping_range_m", 0.0)) >= 0.0 \
			and float(p_snapshot.get("cookie_strength", -1.0)) >= 0.0 \
			and float(p_snapshot.get("cookie_strength", 2.0)) <= 1.0 \
			and float(p_snapshot.get("barn_door_length_m", -1.0)) >= 0.0 \
			and float(p_snapshot.get("source_length_m", -1.0)) >= 0.0 \
			and int(p_snapshot.get("capsule_axis_local", -1)) >= 0 \
			and int(p_snapshot.get("capsule_axis_local", 3)) <= 2


static func _valid_plain_metadata_row(p_row: Variant, p_world_id: int,
		p_light_rid: RID) -> bool:
	return _valid_extension_snapshot(p_row, p_world_id, p_light_rid)


static func metadata_native_kind_matches(p_row: Variant, p_native_kind: int) -> bool:
	return p_row is Dictionary and int(p_row.get("native_kind", -1)) == p_native_kind


static func _bump_generation(p_world_id: int) -> void:
	var generation := int(_world_generations.get(p_world_id, 0)) + 1
	if generation <= 0:
		generation = 1
	_world_generations[p_world_id] = generation


static func _invalid(p_reason: String) -> Dictionary:
	return {"valid": false, "abi_version": Layout.ABI_VERSION, "reason": p_reason, "rows": []}

