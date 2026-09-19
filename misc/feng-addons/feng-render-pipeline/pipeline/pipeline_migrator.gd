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
) -> Array:
	var carried := {}
	var carried_before := []
	var legacy_enabled := {}
	var legacy_seen := {}
	var legacy_order: Array = []
	var last_anchor := -1

	for pass_entry in passes:
		if pass_entry is BuiltinPass:
			var old_id: int = (pass_entry as BuiltinPass).native_id
			if not LEGACY_NATIVE_ID_MAP.has(old_id):
				continue
			var new_id: int = LEGACY_NATIVE_ID_MAP[old_id]
			last_anchor = new_id
			if not legacy_seen.has(new_id):
				legacy_seen[new_id] = true
				legacy_order.append(new_id)
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
		migrated.append(_make_migrated_native(native_id, legacy_seen, legacy_enabled, make_native_pass_fn))
		emitted[native_id] = true
		for pass_entry in carried.get(native_id, []):
			migrated.append(pass_entry)

	# Optional entries the resource had are kept, in the order it had them.
	for native_id in legacy_order:
		if emitted.has(native_id):
			continue
		migrated.append(_make_migrated_native(native_id, legacy_seen, legacy_enabled, make_native_pass_fn))
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
) -> Array:
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
	legacy_seen: Dictionary,
	legacy_enabled: Dictionary,
	make_native_pass_fn: Callable
) -> PassBase:
	var pass_entry: PassBase = make_native_pass_fn.call(native_id)
	if legacy_seen.has(native_id):
		pass_entry.enabled = legacy_enabled[native_id]
	return pass_entry
