@tool
class_name FengTextureManager
extends CompositorEffect
## Hidden compositor effect that owns FengPass output textures.
##
## Pass references are retained by the renderer resource. We collect enabled
## outputs on every callback because native CompositorEffect changes do not
## emit Resource.changed in all runtime paths.

const PassBase = preload("pass_base.gd")
const Output = preload("pass_output.gd")
const NativeSpec = preload("../pipeline/native_spec.gd")
const PIPELINE_SCOPE: StringName = NativeSpec.SCOPE_PIPELINE

@export var passes: Array[CompositorEffect] = []

var _buffer_signatures := {}
var _last_error := ""

func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_PRE_GBUFFER

func collect_enabled_outputs() -> Array[Output]:
	var result: Array[Output] = []
	var seen := {}
	for effect in passes:
		if effect == null or not effect is PassBase or not effect.is_enabled():
			continue
		# A pass delegates its contract to the script that implements it and to that
		# script's overlay: the object that declares the textures owns them, and only
		# while it runs.
		var source = effect.get_contract_source()
		if source == null:
			source = effect
		for output in source.outputs:
			if output == null or output.name == &"":
				continue
			if seen.has(output.name):
				_report("Duplicate pipeline output '%s'; using the first declaration." % output.name)
				continue
			seen[output.name] = true
			result.append(output)
	return result

func _render_callback(_stage: int, data: RenderData) -> void:
	if data == null:
		return
	var buffers := data.get_render_scene_buffers() as RenderSceneBuffersRD
	if buffers == null:
		return
	var outputs := collect_enabled_outputs()
	var signature := _make_signature(outputs)
	var buffer_key := buffers.get_instance_id()
	var needs_rebuild: bool = _buffer_signatures.get(buffer_key, "") != signature
	if not needs_rebuild:
		# RenderSceneBuffersRD clears named contexts when a viewport is resized or
		# reconfigured. The manager persists, so the signature can remain unchanged
		# while every texture has already been released.
		for output in outputs:
			if not buffers.has_texture(PIPELINE_SCOPE, output.name):
				needs_rebuild = true
				break
	if needs_rebuild:
		# A named texture cannot be resized or have its usage changed in place.
		# Clearing the scope lets RenderSceneBuffersRD release old RIDs before the
		# declarations are created again for this viewport.
		buffers.clear_context(PIPELINE_SCOPE)
		_buffer_signatures[buffer_key] = signature
		for output in outputs:
			var size: Vector2i = output.get_scaled_size(buffers.get_internal_size())
			var usage: int = output.usage
			if usage == 0:
				continue
			buffers.create_texture(
					PIPELINE_SCOPE,
					output.name,
					output.data_format,
					usage,
					RenderingDevice.TEXTURE_SAMPLES_1,
					size,
					0,
					1,
					true,
					false
			)
	_clear_report()

func _make_signature(outputs: Array[Output]) -> String:
	var fields := PackedStringArray()
	for output in outputs:
		fields.append("%s:%d:%d:%.6f:%.6f" % [output.name, output.data_format, output.usage, output.scale.x, output.scale.y])
	return "|".join(fields)

func _report(message: String) -> void:
	if message == _last_error:
		return
	push_error("FengTextureManager: " + message)
	_last_error = message

func _clear_report() -> void:
	_last_error = ""
