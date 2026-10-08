@tool
class_name FengPipelineMigrator
extends RefCounted
## Rewrites a pipeline resource authored against an older FRP pass set into a current
## schedule, keeping the enabled state and the relative position of custom passes.

const NativeSpec = preload("native_spec.gd")
const PassBase = preload("../passes/pass_base.gd")
const BuiltinPass = preload("../passes/builtin_pass.gd")

## Old FRP pass ids mapped to the entry that now owns their work.
## The pre-collapse ids of removed entries (SSAO, SSIL, SSR, GI, debug geometry)
## are deliberately absent.
const LEGACY_NATIVE_ID_MAP := {
	16: 1, 1: 0, 0: 2, 2: 3, 7: 4, 11: 5, 14: 6, 15: 7,
	4: 2, 3: 5, 5: 7, 8: 4, 9: 3, 10: 5, 12: 7, 13: 7,
}

## Migrates a pass array authored before schema 5 (pre-collapse native IDs).
static func migrate_native_pass_set(
	passes: Array,
	native_default_ids: Array,
	make_native_pass_fn: Callable
) -> Array[PassBase]:
	var carried := {}
	var carried_before := []
	var legacy_enabled := {}
	var last_anchor := -1

	for pass_entry in passes:
		if pass_entry is BuiltinPass:
			var old_id: int = (pass_entry as BuiltinPass).native_id
			if not LEGACY_NATIVE_ID_MAP.has(old_id):
				continue
			var new_id: int = LEGACY_NATIVE_ID_MAP[old_id]
			last_anchor = new_id
			if not legacy_enabled.has(new_id):
				legacy_enabled[new_id] = pass_entry.enabled
			continue
		if pass_entry == null:
			continue
		ensure_custom_identity(pass_entry, carried_before.size() + carried.size())
		if last_anchor < 0:
			carried_before.append(pass_entry)
			continue
		if not carried.has(last_anchor):
			carried[last_anchor] = []
		carried[last_anchor].append(pass_entry)

	var migrated: Array[PassBase] = []
	for pass_entry in carried_before:
		migrated.append(pass_entry)

	var emitted := {}
	for native_id in native_default_ids:
		migrated.append(_make_migrated_native(native_id, legacy_enabled, make_native_pass_fn))
		emitted[native_id] = true
		for pass_entry in carried.get(native_id, []):
			migrated.append(pass_entry)

	# Optional entries the resource had are kept, in the order it had them.
	for native_id in legacy_enabled:
		if emitted.has(native_id):
			continue
		migrated.append(_make_migrated_native(native_id, legacy_enabled, make_native_pass_fn))
		emitted[native_id] = true
		for pass_entry in carried.get(native_id, []):
			migrated.append(pass_entry)

	return migrated

## Migrates passes from early schema versions without native entries: the schedule is
## re-seeded and each custom pass keeps its position relative to the entry its stage
## used to follow.
static func migrate_legacy_passes(
	passes: Array,
	native_seed_ids: Array,
	is_optional_fn: Callable,
	make_native_pass_fn: Callable
) -> Array[PassBase]:
	var legacy: Array[PassBase] = []
	for p in passes:
		if p is PassBase:
			legacy.append(p)
	var buckets := {}
	for anchor in range(-1, NativeSpec.pass_count()):
		buckets[anchor] = []
	for ordinal in legacy.size():
		var pass_entry := legacy[ordinal]
		if pass_entry == null:
			continue
		ensure_custom_identity(pass_entry, ordinal)
		var anchor := legacy_anchor_for_pass(pass_entry)
		if not buckets.has(anchor):
			anchor = -1
		buckets[anchor].append(pass_entry)

	var migrated: Array[PassBase] = []
	for pass_entry in buckets[-1]:
		migrated.append(pass_entry)

	for native_id in native_seed_ids:
		var pass_entry: PassBase = make_native_pass_fn.call(native_id)
		if is_optional_fn.call(native_id):
			pass_entry.enabled = false
		migrated.append(pass_entry)
		for carried in buckets.get(native_id, []):
			migrated.append(carried)

	return migrated

## The entry an old-stage pass used to follow. `stage` is only a placement hint now, so
## this is what an early resource's order can be recovered from.
static func legacy_anchor_for_pass(pass_entry: PassBase) -> int:
	match pass_entry.stage:
		CompositorEffect.EFFECT_CALLBACK_TYPE_PRE_GBUFFER, CompositorEffect.EFFECT_CALLBACK_TYPE_PRE_OPAQUE:
			return -1
		CompositorEffect.EFFECT_CALLBACK_TYPE_POST_GBUFFER:
			return NativeSpec.PASS_GBUFFER
		CompositorEffect.EFFECT_CALLBACK_TYPE_PRE_LIGHTING:
			return NativeSpec.PASS_VIRTUAL_TEXTURE
		CompositorEffect.EFFECT_CALLBACK_TYPE_POST_LIGHTING:
			return NativeSpec.PASS_LIGHTING
		CompositorEffect.EFFECT_CALLBACK_TYPE_POST_OPAQUE:
			return NativeSpec.PASS_LIGHTING
		CompositorEffect.EFFECT_CALLBACK_TYPE_POST_SKY:
			return NativeSpec.PASS_SKY
		CompositorEffect.EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT, CompositorEffect.EFFECT_CALLBACK_TYPE_POST_TRANSPARENT:
			return NativeSpec.PASS_TRANSPARENT
	return NativeSpec.PASS_TRANSPARENT

## Gives a pass that predates stable ids one, derived from what identifies it: the
## shader it loads, its own resource path, or the instance itself.
static func ensure_custom_identity(pass_entry: PassBase, ordinal: int) -> void:
	if pass_entry == null or pass_entry.stable_id != "":
		return
	var shader = pass_entry.get("shader_file")
	var identity := ""
	if shader != null and shader.resource_path != "":
		identity = shader.resource_path
	elif pass_entry.resource_path != "":
		identity = pass_entry.resource_path
	else:
		identity = "instance:%d" % pass_entry.get_instance_id()
	pass_entry.stable_id = "custom:%s:%d" % [identity, ordinal]

static func _make_migrated_native(
	native_id: int,
	legacy_enabled: Dictionary,
	make_native_pass_fn: Callable
) -> PassBase:
	var pass_entry: PassBase = make_native_pass_fn.call(native_id)
	if legacy_enabled.has(native_id):
		pass_entry.enabled = legacy_enabled[native_id]
	elif native_id == NativeSpec.PASS_TEMPORAL_AA:
		pass_entry.enabled = false
	return pass_entry

## Schema 10 repairs the released Sky → Cloud → Trace → Fog sequence.
## Require unique stock identities and scripts so authored replacements keep their order.
static func migrate_cloud_fog_order(passes: Array[PassBase]) -> bool:
	var sky_index := -1
	for i in passes.size():
		if passes[i] is BuiltinPass and passes[i].native_id == NativeSpec.PASS_SKY:
			if sky_index >= 0:
				return false
			sky_index = i
	if sky_index < 0 or sky_index + 3 >= passes.size():
		return false
	var sky := passes[sky_index] as BuiltinPass
	if sky.stable_id != "native:%d" % NativeSpec.PASS_SKY or sky.implementation == null:
		return false
	var sky_script := sky.implementation.get_script() as Script
	if sky_script == null or sky_script.resource_path != FengAddonLayout.passes_dir() + "native/sky_pass.gd" \
			or sky.implementation.get("overlay") != null:
		return false

	var stock := {
		&"library:volumetric_cloud": "cloud/volumetric_cloud.tres",
		&"library:cloud_trace": "cloud/cloud_trace.tres",
		&"library:height_fog": "height-fog/height_fog.tres",
	}
	var expected_index := sky_index
	for stable_id in stock:
		expected_index += 1
		var template := load(FengAddonLayout.library_dir() + "/" + stock[stable_id])
		var target_script: Script = template.get_script() if template != null else null
		if target_script == null:
			return false
		var found := false
		for i in passes.size():
			var entry := passes[i]
			if entry == null:
				continue
			var script: Script = entry.get_script()
			var matches_script := script != null and script.resource_path == target_script.resource_path
			if entry.stable_id == stable_id or matches_script:
				if i != expected_index or entry.stable_id != stable_id or not matches_script:
					return false
				found = true
		if not found:
			return false
	var trace := passes[sky_index + 2]
	passes[sky_index + 2] = passes[sky_index + 3]
	passes[sky_index + 3] = trace
	return true

## Schema 6 placed Color Grade and optional Bloom before exposure. UE meters
## scene color after temporal AA and before Bloom, then grades during tonemapping.
## Move only the managed Eye Adaptation entry, preserving every other pass's order.
static func migrate_eye_adaptation_order(passes: Array[PassBase]) -> bool:
	var eye_index := -1
	var first_after_eye := passes.size()
	for i in passes.size():
		var pass_entry: FengPass = passes[i]
		if pass_entry == null:
			continue
		if pass_entry.stable_id == &"library:eye_adaptation":
			eye_index = i
		elif pass_entry.stable_id in [
			&"library:bloom_downsample", &"library:bloom_blur",
			&"library:bloom_composite", &"library:color_grade",
		]:
			first_after_eye = mini(first_after_eye, i)
		elif pass_entry is BuiltinPass and (pass_entry as BuiltinPass).native_id == NativeSpec.PASS_BLOOM:
			first_after_eye = mini(first_after_eye, i)
	var temporal_index := native_index(passes, NativeSpec.PASS_TEMPORAL_AA)
	var post_index := native_index(passes, NativeSpec.PASS_POST_PROCESS)
	if eye_index < 0 or first_after_eye >= eye_index or (temporal_index >= 0 and first_after_eye <= temporal_index) or (post_index >= 0 and first_after_eye >= post_index):
		return false
	var eye_pass := passes[eye_index]
	passes.remove_at(eye_index)
	passes.insert(first_after_eye, eye_pass)
	return true

## Schema 8 adds the engine-owned Bloom preparation pass. Insert it after the existing
## Eye Adaptation entry (or before Color Grade/Post when no exposure pass exists) while
## leaving every authored entry in the same relative order.
static func migrate_bloom_pass(passes: Array[PassBase], make_native_pass_fn: Callable) -> bool:
	if native_index(passes, NativeSpec.PASS_BLOOM) >= 0:
		return false

	var insert_index := -1
	for i in passes.size():
		var pass_entry: FengPass = passes[i]
		if pass_entry != null and pass_entry.stable_id == &"library:eye_adaptation":
			insert_index = i + 1
			break
	if insert_index < 0:
		for i in passes.size():
			var pass_entry: FengPass = passes[i]
			if pass_entry == null:
				continue
			if pass_entry.stable_id == &"library:color_grade":
				insert_index = i
				break
		if insert_index < 0:
			insert_index = native_index(passes, NativeSpec.PASS_POST_PROCESS)
	if insert_index < 0:
		insert_index = seed_insert_index(passes, NativeSpec.PASS_BLOOM)

	passes.insert(insert_index, make_native_pass_fn.call(NativeSpec.PASS_BLOOM))
	return true

## Position the seed order gives an entry, relative to the entries already present.
static func seed_insert_index(passes: Array, native_id: int) -> int:
	var seed_ids := NativeSpec.default_ids()
	var target: int = seed_ids.find(native_id)
	for i in passes.size():
		var pass_entry: FengPass = passes[i]
		if not pass_entry is BuiltinPass:
			continue
		var existing_pos: int = seed_ids.find((pass_entry as BuiltinPass).native_id)
		if existing_pos >= 0 and existing_pos > target:
			return i
	return passes.size()

static func native_index(passes: Array, native_id: int) -> int:
	for i in passes.size():
		var pass_entry: FengPass = passes[i]
		if pass_entry is BuiltinPass and (pass_entry as BuiltinPass).native_id == native_id:
			return i
	return -1
