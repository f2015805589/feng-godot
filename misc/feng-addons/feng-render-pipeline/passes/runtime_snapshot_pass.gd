@tool
class_name FengRuntimeSnapshotPass
extends FengShaderPass
## Base for passes whose GPU work is fed by an addon's world-scoped runtime
## snapshot service (feng-magic-gi, feng-fog).
##
## The coupling stays on the addon's side: the pass only knows a script path
## that exposes `snapshots() -> Array[Dictionary]`, each snapshot carrying the
## render targets it applies to. Per frame the matching snapshot and the scene
## data are captured around the super call so _render() sees them as
## _frame_snapshot / _frame_scene_data.

var _runtime_script_checked := false
var _runtime_script: Script
var _frame_snapshot: Dictionary = {}
var _frame_scene_data: RenderSceneData
var _ubo := RID()

## The addon runtime script exposing static `snapshots()`. Subclasses override.
func runtime_script_path() -> String:
	return ""

func _frp_execute(ctx: FRPPassContext) -> void:
	var buffers := ctx.get_render_scene_buffers() as RenderSceneBuffersRD if ctx != null else null
	_frp_execute_with_snapshot(ctx, _snapshot_for_target(buffers))

## Dedicated off-screen capture path. The caller supplies a frozen world snapshot
## because reflection captures have no viewport render target to route by.
func _frp_execute_with_snapshot(ctx: FRPPassContext, snapshot: Dictionary) -> void:
	_frame_snapshot = snapshot
	_frame_scene_data = null
	if ctx != null:
		var render_data := ctx.get_render_data()
		if render_data != null:
			_frame_scene_data = render_data.get_render_scene_data()
	super._frp_execute(ctx)
	_frame_snapshot = {}
	_frame_scene_data = null

func _snapshot_for_target(buffers: RenderSceneBuffersRD) -> Dictionary:
	if buffers == null:
		return {}
	var runtime_script := _get_runtime_script()
	if runtime_script == null:
		return {}
	var target := buffers.get_render_target()
	if runtime_script.has_method("snapshot_for_target"):
		var matched: Variant = runtime_script.call("snapshot_for_target", target)
		return matched if matched is Dictionary else {}
	var snapshots: Variant = runtime_script.call("snapshots")
	if not snapshots is Array:
		return {}
	for snapshot in snapshots:
		if not snapshot is Dictionary:
			continue
		var targets: Variant = snapshot.get("render_targets", [])
		if targets is Array and targets.has(target):
			return snapshot
	return {}

func _get_runtime_script() -> Script:
	if not _runtime_script_checked:
		_runtime_script_checked = true
		if ResourceLoader.exists(runtime_script_path()):
			var loaded: Variant = load(runtime_script_path())
			if loaded is Script:
				_runtime_script = loaded
	return _runtime_script

func _inputs_match(actual: Array[TextureInput], expected: Array[TextureInput]) -> bool:
	if actual.size() != expected.size():
		return false
	for i in actual.size():
		var left := actual[i]
		var right := expected[i]
		if left == null or left.binding != right.binding or left.source != right.source \
				or left.binding_type != right.binding_type or left.custom_scope != right.custom_scope \
				or left.custom_name != right.custom_name:
			return false
	return true

func _outputs_match(actual: Array[OutputDeclaration], expected: Array[OutputDeclaration]) -> bool:
	if actual.size() != expected.size():
		return false
	for i in actual.size():
		var left := actual[i]
		var right := expected[i]
		if left == null or left.name != right.name or left.data_format != right.data_format \
				or left.usage != right.usage or left.scale != right.scale:
			return false
	return true

## Uploads the frame's uniform block. The UBO is created lazily so a pass that
## never gets a snapshot stays a true no-op with no GPU state.
func _commit_frame_ubo(values: PackedFloat32Array, ubo_size: int, rd: RenderingDevice) -> bool:
	if values.size() * 4 != ubo_size:
		_report("Uniform layout does not match the shader block.")
		return false
	var bytes := values.to_byte_array()
	if not _ubo.is_valid():
		_ubo = rd.uniform_buffer_create(ubo_size)
		if not _ubo.is_valid():
			return false
	return rd.buffer_update(_ubo, 0, bytes.size(), bytes) == OK

func _ubo_uniform(binding: int) -> RDUniform:
	var uniform_buffer := RDUniform.new()
	uniform_buffer.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	uniform_buffer.binding = binding
	uniform_buffer.add_id(_ubo)
	return uniform_buffer

## std430 packing helpers shared by snapshot passes' frame UBOs: a Projection is
## four vec4 columns, a Transform3D is three basis vec4s plus an origin vec4.
static func _append_projection(values: PackedFloat32Array, projection: Projection) -> void:
	for column in 4:
		var axis: Vector4 = projection[column]
		values.append_array(PackedFloat32Array([axis.x, axis.y, axis.z, axis.w]))

static func _append_transform(values: PackedFloat32Array, transform: Transform3D) -> void:
	var axes := [transform.basis.x, transform.basis.y, transform.basis.z]
	for axis in axes:
		values.append_array(PackedFloat32Array([axis.x, axis.y, axis.z, 0.0]))
	values.append_array(PackedFloat32Array([transform.origin.x, transform.origin.y, transform.origin.z, 1.0]))

func _take_owned_rids() -> Array[RID]:
	var rids := super._take_owned_rids()
	rids.append(_ubo)
	_ubo = RID()
	return rids
