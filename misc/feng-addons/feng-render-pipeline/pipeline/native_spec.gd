@tool
class_name FengNativeSpec
extends RefCounted
## Single accessor for the engine's FRP native pass set.
##
## The engine owns the pass ids, display names, mandatory entries, order constraints and
## default execution order (see FRPPipelineSpec) and reports them through
## RenderingServer.get_frp_pipeline_spec(). The addon reads them back instead of keeping
## a second copy that can drift out of sync.
##
## The constants below are the one thing that has to be spelled out here as well: the
## ids are needed where only a constant can be used (the pass-script table in
## renderer.gd, the pass scripts' own `_native_pass_id()`). They are the engine's ids,
## so a renamed or reordered pass shows up as a mismatch between these constants and the
## names `pass_name()` reads back from the engine.

const SPEC_METHOD := "get_frp_pipeline_spec"

## Canonical native pass IDs, matching FRPPipelineSpec in the engine.
const PASS_SHADOW_PRECOMPUTE := 0
const PASS_VIRTUAL_TEXTURE := 1
const PASS_GBUFFER := 2
const PASS_LIGHTING := 3
const PASS_SKY := 4
const PASS_TRANSPARENT := 5
const PASS_TEMPORAL_AA := 6
const PASS_POST_PROCESS := 7

## Engine texture scopes and names the addon reads or writes.
const SCOPE_FRP_CLUSTERED: StringName = &"frp_clustered"
const SCOPE_PIPELINE: StringName = &"frp_pipeline"
const SCOPE_TONEMAPPER: StringName = &"Tonemapper"
const TEX_TONEMAPPER_DESTINATION: StringName = &"destination"
const TEX_GBUFFER_NORMAL_ROUGHNESS: StringName = &"normal_roughness"
const TEX_GBUFFER_ALBEDO: StringName = &"gbuffer_albedo"
const TEX_GBUFFER_ORM: StringName = &"gbuffer_orm"
const TEX_GBUFFER_EMISSION: StringName = &"gbuffer_emission"

static var _spec: Dictionary = {}

## The engine's FRP pass table, read once per session.
static func spec() -> Dictionary:
	if _spec.is_empty():
		if not RenderingServer.has_method(SPEC_METHOD):
			push_error("FengNativeSpec: this engine build does not expose the FRP native pass spec; rebuild the engine.")
			return {}
		_spec = RenderingServer.call(SPEC_METHOD)
	return _spec

static func pass_count() -> int:
	return int(spec().get("pass_count", 0))

## Native FRP operations. Executable grouped renderer boundaries, not one entry per draw
## or GPU dispatch.
static func pass_definitions() -> Array:
	return spec().get("passes", [])

## Default execution order, which is the engine's pass id order: shadow maps first
## (drawing them depends on nothing else in the frame), then virtual texture updates,
## the G-buffer, lighting, sky, transparent, temporal AA and post. The pipeline resource
## lists entries in this order and the renderer executes the list in order.
static func seed_order() -> Array:
	return spec().get("default_order", [])

## Native order constraints. A disabled optional pass_entry does not invalidate another
## enabled pass_entry; if both entries are enabled, the prerequisite must occur first.
static func order_edges() -> Array:
	return spec().get("edges", [])

static func mandatory_ids() -> Array:
	return spec().get("mandatory", [])

## Whether a pass ships disabled. Enabling its entry is what turns the effect on, and
## Temporal AA is the one pass that does.
static func is_optional_id(p_native_id: int) -> bool:
	for definition in pass_definitions():
		if int(definition["id"]) == p_native_id:
			return bool(definition.get("optional", false))
	return false

## The ids a fresh pipeline enables: every non-optional pass, in seed order.
static func default_ids() -> Array:
	var ids: Array = []
	for native_id in seed_order():
		if not is_optional_id(int(native_id)):
			ids.append(int(native_id))
	return ids

static func is_valid_id(p_native_id: int) -> bool:
	var count := pass_count()
	return count > 0 and p_native_id >= 0 and p_native_id < count

static func pass_name(p_native_id: int) -> String:
	for definition in pass_definitions():
		if int(definition["id"]) == p_native_id:
			return definition["name"]
	return "native id %d" % p_native_id
