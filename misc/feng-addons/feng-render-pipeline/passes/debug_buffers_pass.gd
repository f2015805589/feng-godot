@tool
class_name FengDebugBuffersPass
extends FengShaderPass
## Presents one material/GI channel after Post Process, without tonemapping it.

enum Buffer { DIFFUSE, NORMAL, AO, ROUGHNESS, METALLIC, MOTION_VECTORS, MAGIC_GI }
const DEBUG_OUTPUT: StringName = &"debug_buffers"
const GI_OUTPUT: StringName = &"magic_gi"

@export_enum("Diffuse (Albedo)", "Normal (View Space)", "AO", "Roughness", "Metallic", "Motion Vectors", "Magic GI") var buffer: int = Buffer.DIFFUSE:
	set(value):
		var next := clampi(value, 0, Buffer.MAGIC_GI)
		if buffer == next:
			return
		buffer = next
		_configure_inputs()
		emit_changed()
@export_range(1.0, 256.0, 1.0) var motion_scale := 32.0:
	set(value):
		motion_scale = value
		emit_changed()
@export_range(-8.0, 8.0, 0.1) var gi_exposure := 0.0:
	set(value):
		gi_exposure = value
		emit_changed()

func _init() -> void:
	var output := OutputDeclaration.new()
	output.name = DEBUG_OUTPUT
	output.usage = OutputDeclaration.Usage.SAMPLED | OutputDeclaration.Usage.STORAGE | OutputDeclaration.Usage.COPY_TO
	outputs = [output]
	_configure_inputs()

## Serialized declarations follow the selected channel. Rebuild only if a saved
## resource's input contract no longer matches the current selection.
func ensure_frp_contract() -> bool:
	var expected := _expected_source()
	var changed := false
	var contract_ok := inputs.size() == 2 and inputs[0] != null and inputs[1] != null
	if contract_ok:
		contract_ok = inputs[0].binding == 0 \
				and inputs[0].source == TextureInput.Source.PIPELINE \
				and inputs[0].custom_name == DEBUG_OUTPUT \
				and inputs[0].binding_type == TextureInput.BindingType.STORAGE_IMAGE \
				and inputs[1].binding == 1 and inputs[1].source == expected
	if not contract_ok:
		_configure_inputs()
		changed = true
	if outputs.size() != 1 or outputs[0] == null or outputs[0].name != DEBUG_OUTPUT \
			or outputs[0].data_format != RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT \
			or outputs[0].usage != (OutputDeclaration.Usage.SAMPLED | OutputDeclaration.Usage.STORAGE | OutputDeclaration.Usage.COPY_TO):
		var output := OutputDeclaration.new()
		output.name = DEBUG_OUTPUT
		output.usage = OutputDeclaration.Usage.SAMPLED | OutputDeclaration.Usage.STORAGE | OutputDeclaration.Usage.COPY_TO
		outputs = [output]
		changed = true
	return changed

func _expected_source() -> int:
	match buffer:
		Buffer.DIFFUSE: return TextureInput.Source.ALBEDO
		Buffer.NORMAL: return TextureInput.Source.NORMAL_ROUGHNESS
		Buffer.AO, Buffer.ROUGHNESS, Buffer.METALLIC: return TextureInput.Source.ORM
		Buffer.MOTION_VECTORS: return TextureInput.Source.MOTION_VECTORS
		Buffer.MAGIC_GI: return TextureInput.Source.CUSTOM
	return TextureInput.Source.ALBEDO

func _configure_inputs() -> void:
	var target := TextureInput.new()
	target.binding = 0
	target.source = TextureInput.Source.PIPELINE
	target.custom_name = DEBUG_OUTPUT
	target.binding_type = TextureInput.BindingType.STORAGE_IMAGE
	var source := TextureInput.new()
	source.binding = 1
	source.source = _expected_source()
	if buffer == Buffer.MAGIC_GI:
		# Missing/disabled GI has an explicit black diagnostic instead of invalidating
		# the whole pipeline. The texture still belongs to the GI producer.
		source.custom_scope = TextureInput.PIPELINE_SCOPE
		source.custom_name = GI_OUTPUT
	inputs = [target, source]
	needs_motion_vectors = buffer == Buffer.MOTION_VECTORS

func get_frp_parameters() -> Dictionary:
	# Buffer chooses the texture contract and remains an authored property. Runtime
	# parameter dictionaries only tune values that do not change the bindings.
	return {"motion_scale": motion_scale, "gi_exposure": gi_exposure}

func get_volume_parameter_names() -> PackedStringArray:
	return PackedStringArray()

var _frame_options := Vector4()
var _invalid_buffer_override := false
var _buffer_override_warned := false

func _frp_execute(ctx: FRPPassContext) -> void:
	if ctx == null:
		return
	var resolved := get_resolved_parameters(ctx)
	_invalid_buffer_override = resolved.has("buffer") and int(resolved["buffer"]) != buffer
	if _invalid_buffer_override and not _buffer_override_warned:
		_buffer_override_warned = true
		push_warning("FengDebugBuffersPass: buffer selects a texture contract and cannot be overridden through pass parameters.")
	_frame_options = Vector4(
			float(buffer),
			float(resolved.get("motion_scale", motion_scale)),
			pow(2.0, float(resolved.get("gi_exposure", gi_exposure))),
			0.0
	)
	super._frp_execute(ctx)
	_frame_options = Vector4()
	var buffers := ctx.get_render_scene_buffers() as RenderSceneBuffersRD
	if buffers != null and buffers.has_texture(TextureInput.PIPELINE_SCOPE, DEBUG_OUTPUT):
		ctx.present(DEBUG_OUTPUT)

func _parameter_bytes() -> PackedByteArray:
	return PackedFloat32Array([_frame_options.x, _frame_options.y, _frame_options.z, _frame_options.w]).to_byte_array()

func refresh_resource_flags() -> void:
	# This pass derives motion-vector allocation from its selected source. Base FengPass
	# preserves manually declared flags for third-party passes without texture inputs.
	needs_motion_vectors = false
	super.refresh_resource_flags()

func _validate_runtime_inputs(buffers: RenderSceneBuffersRD, view: int) -> bool:
	if buffer == Buffer.MAGIC_GI and not inputs[1].get_texture(buffers, view).is_valid():
		return inputs[0].get_texture(buffers, view).is_valid()
	return super._validate_runtime_inputs(buffers, view)

func _render(buffers: RenderSceneBuffersRD, view: int, rd: RenderingDevice) -> void:
	if _invalid_buffer_override:
		rd.texture_clear(inputs[0].get_texture(buffers, view), Color(0, 0, 0, 1), 0, 1, 0, 1)
		return
	if buffer == Buffer.MAGIC_GI and not inputs[1].get_texture(buffers, view).is_valid():
		rd.texture_clear(inputs[0].get_texture(buffers, view), Color(0, 0, 0, 1), 0, 1, 0, 1)
		return
	super._render(buffers, view, rd)
