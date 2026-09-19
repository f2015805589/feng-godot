@tool
class_name FengPassTexture
extends Resource
## One declared set=0 texture binding for a Feng pass.

const PIPELINE_SCOPE: StringName = &"frp_pipeline"
const FRP_SCOPE: StringName = &"frp_clustered"

enum Source {
	COLOR,
	DEPTH,
	NORMAL_ROUGHNESS,
	ALBEDO,
	ORM,
	EMISSION,
	CUSTOM,
	PIPELINE,
	# The engine's tone mapped image: what the deferred tone mapping step produced.
	# Reading it is what makes an "after tonemap" effect a post-process effect.
	TONEMAPPED,
}

const TONEMAPPER_SCOPE: StringName = &"Tonemapper"
const TONEMAPPER_TEXTURE: StringName = &"destination"

enum BindingType {
	SAMPLED_TEXTURE,
	STORAGE_IMAGE,
}

@export_range(0, 31) var binding: int = 0
@export var source: Source = Source.COLOR
@export var binding_type: BindingType = BindingType.SAMPLED_TEXTURE
@export var custom_scope: StringName = &""
@export var custom_name: StringName = &""

## Compatibility alias for early library templates. PIPELINE resolves through
## custom_name internally.
@export var pipeline_name: StringName:
	get:
		return custom_name
	set(value):
		custom_name = value

func get_texture(buffers: RenderSceneBuffersRD, view: int) -> RID:
	if buffers == null:
		return RID()
	match source:
		Source.COLOR:
			return buffers.get_color_layer(view)
		Source.DEPTH:
			return buffers.get_depth_layer(view)
		Source.NORMAL_ROUGHNESS:
			return _get_named_texture(buffers, FRP_SCOPE, &"normal_roughness", view)
		Source.ALBEDO:
			return _get_named_texture(buffers, FRP_SCOPE, &"gbuffer_albedo", view)
		Source.ORM:
			return _get_named_texture(buffers, FRP_SCOPE, &"gbuffer_orm", view)
		Source.EMISSION:
			return _get_named_texture(buffers, FRP_SCOPE, &"gbuffer_emission", view)
		Source.PIPELINE:
			return _get_named_texture(buffers, PIPELINE_SCOPE, custom_name, view)
		Source.TONEMAPPED:
			return _get_named_texture(buffers, TONEMAPPER_SCOPE, TONEMAPPER_TEXTURE, view)
		Source.CUSTOM:
			return _get_named_texture(buffers, custom_scope, custom_name, view)
	return RID()

func _get_named_texture(buffers: RenderSceneBuffersRD, scope: StringName, texture_name: StringName, view: int) -> RID:
	if scope == &"" or texture_name == &"" or not buffers.has_texture(scope, texture_name):
		return RID()
	var texture_format = buffers.get_texture_format(scope, texture_name)
	if texture_format.array_layers <= view:
		if view == 0:
			return buffers.get_texture(scope, texture_name)
		return RID()
	return buffers.get_texture_slice(scope, texture_name, view, 0, 1, 1)

func get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if binding < 0 or binding > 31:
		warnings.append("Texture binding must be between 0 and 31.")
	if source == Source.PIPELINE and custom_name == &"":
		warnings.append("Pipeline texture bindings require a custom_name output name.")
	if source == Source.CUSTOM and (custom_scope == &"" or custom_name == &""):
		warnings.append("Custom texture bindings require both custom_scope and custom_name.")
	if source == Source.DEPTH and binding_type == BindingType.STORAGE_IMAGE:
		warnings.append("Depth textures can only be used with a sampled texture binding.")
	return warnings
