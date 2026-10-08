@tool
class_name FengFXAAPass
extends FengShaderPass
## Neighborhood filtering needs an immutable source while writing scene color.
## The Texture Manager owns the per-viewport scratch texture like any declared
## output; no global image cache or per-pass viewport lifetime is introduced.

const SOURCE_COPY: StringName = &"fxaa_source"
var _copy_pass: FengShaderPass

func _init() -> void:
	inputs = _make_inputs()
	outputs = _make_outputs()

func _make_inputs() -> Array[TextureInput]:
	var source := TextureInput.new()
	source.binding = 0
	# This pass prepares its own source before sampling it, so it is an internal
	# custom binding rather than a previous-pass pipeline dependency.
	source.source = TextureInput.Source.CUSTOM
	source.custom_scope = PIPELINE_SCOPE
	source.custom_name = SOURCE_COPY
	var destination := TextureInput.new()
	destination.binding = 1
	destination.source = TextureInput.Source.COLOR
	destination.binding_type = TextureInput.BindingType.STORAGE_IMAGE
	return [source, destination]

func _make_outputs() -> Array[OutputDeclaration]:
	var output := OutputDeclaration.new()
	output.name = SOURCE_COPY
	output.usage = OutputDeclaration.Usage.SAMPLED | OutputDeclaration.Usage.STORAGE
	return [output]

func _render(buffers: RenderSceneBuffersRD, view: int, rd: RenderingDevice) -> void:
	if _copy_pass == null:
		_copy_pass = FengShaderPass.new()
		_copy_pass.shader_file = load(FengAddonLayout.library_dir() + "/fxaa/fxaa_copy.glsl")
		var source := TextureInput.new()
		var destination := inputs[0].duplicate(true) as TextureInput
		destination.binding = 1
		destination.binding_type = TextureInput.BindingType.STORAGE_IMAGE
		_copy_pass.inputs = [source, destination]
		_copy_pass.dispatch_target = SOURCE_COPY
	# Scene color is sampleable/storage-capable but has no COPY_FROM usage.
	# A small compute copy uses its existing contract without widening engine
	# texture flags or adding work to other/default passes.
	_copy_pass._render(buffers, view, rd)
	if not _copy_pass._shader.is_valid() or _copy_pass._binding_error:
		return
	super._render(buffers, view, rd)

func _take_owned_rids() -> Array[RID]:
	var rids := super._take_owned_rids()
	if _copy_pass != null:
		rids.append_array(_copy_pass._take_owned_rids())
		_copy_pass = null
	return rids
