@tool
class_name FengNativeSpec
extends RefCounted
## Single accessor for the engine's FRP native pass set.
##
## The engine owns the pass ids, display names, mandatory entries, order
## constraints and default execution order (see FRPPipelineSpec) and reports them
## through RenderingServer.get_frp_pipeline_spec(). The addon reads them back
## instead of keeping a second copy that can drift out of sync.

const SPEC_METHOD := "get_frp_pipeline_spec"

static var _spec: Dictionary = {}

static func spec() -> Dictionary:
	if _spec.is_empty():
		if not RenderingServer.has_method(SPEC_METHOD):
			push_error("FengRenderer: this engine build does not expose the FRP native pass spec; rebuild the engine.")
			return {}
		_spec = RenderingServer.call(SPEC_METHOD)
	return _spec

static func pass_count() -> int:
	return int(spec().get("pass_count", 0))

## Native FRP operations. Executable grouped renderer boundaries, not one entry
## per draw or GPU dispatch.
static func pass_definitions() -> Array:
	return spec().get("passes", [])

## Default execution order, which is the engine's pass id order: shadow maps first
## (drawing them depends on nothing else in the frame), then virtual texture updates,
## the G-buffer, lighting, sky, transparent, temporal AA and post. The pipeline
## resource lists entries in this order and the renderer executes the list in order.
static func seed_order() -> Array:
	return spec().get("default_order", [])

## Native order constraints. A disabled optional pass_entry does not invalidate
## another enabled pass_entry; if both entries are enabled, the prerequisite must
## occur first.
static func order_edges() -> Array:
	return spec().get("edges", [])

static func mandatory_ids() -> Array:
	return spec().get("mandatory", [])

static func is_valid_id(p_native_id: int) -> bool:
	var count := pass_count()
	return count > 0 and p_native_id >= 0 and p_native_id < count

static func pass_name(p_native_id: int) -> String:
	for definition in pass_definitions():
		if int(definition["id"]) == p_native_id:
			return definition["name"]
	return "native id %d" % p_native_id
