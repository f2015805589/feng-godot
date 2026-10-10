@tool
class_name FengPassTexture
extends Resource
## One declared set=0 texture binding for a Feng pass.

const NativeSpec = preload("../pipeline/native_spec.gd")

const PIPELINE_SCOPE: StringName = NativeSpec.SCOPE_PIPELINE
const FRP_SCOPE: StringName = NativeSpec.SCOPE_FRP_CLUSTERED

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
	MOTION_VECTORS,
	# Complete DFG- and pre-exposed indirect specular term captured by deferred lighting.
	# Appended to preserve the serialized values of existing texture sources.
	INDIRECT_SPECULAR,
}

const TONEMAPPER_SCOPE: StringName = NativeSpec.SCOPE_TONEMAPPER
const TONEMAPPER_TEXTURE: StringName = NativeSpec.TEX_TONEMAPPER_DESTINATION

enum BindingType {
	SAMPLED_TEXTURE,
	STORAGE_IMAGE,
}

## The native pass that produces a source, or -1 for one no native pass owns (a pipeline
## texture or a custom scope). Color is the lit frame the Lighting pass resolves, the
## G-buffer attributes and the depth come from the G-buffer pass and the tone mapped
## image comes from Post Process / Tonemap. It lives next to the enum it maps, so a new
## source is added in one place.
static func required_native_pass(source: Source) -> int:
	match source:
		Source.COLOR:
			return NativeSpec.PASS_LIGHTING
		Source.DEPTH, Source.NORMAL_ROUGHNESS, Source.ALBEDO, Source.ORM, Source.EMISSION, Source.MOTION_VECTORS:
			return NativeSpec.PASS_GBUFFER
		Source.INDIRECT_SPECULAR:
			return NativeSpec.PASS_LIGHTING
		Source.TONEMAPPED:
			return NativeSpec.PASS_POST_PROCESS
	return -1

@export_range(0, 31) var binding: int = 0:
	set(value):
		if binding == value:
			return
		binding = value
		emit_changed()
@export var source: Source = Source.COLOR:
	set(value):
		if source == value:
			return
		source = value
		emit_changed()
@export var binding_type: BindingType = BindingType.SAMPLED_TEXTURE:
	set(value):
		if binding_type == value:
			return
		binding_type = value
		emit_changed()
@export var custom_scope: StringName = &"":
	set(value):
		if custom_scope == value:
			return
		custom_scope = value
		emit_changed()
@export var custom_name: StringName = &"":
	set(value):
		if custom_name == value:
			return
		custom_name = value
		emit_changed()

func get_texture(buffers: RenderSceneBuffersRD, view: int) -> RID:
	if buffers == null:
		return RID()
	match source:
		Source.COLOR:
			return buffers.get_color_layer(view)
		Source.DEPTH:
			return buffers.get_depth_layer(view)
		Source.MOTION_VECTORS:
			return buffers.get_velocity_layer(view)
		Source.NORMAL_ROUGHNESS:
			return _get_named_texture(buffers, FRP_SCOPE, NativeSpec.TEX_GBUFFER_NORMAL_ROUGHNESS, view)
		Source.ALBEDO:
			var albedo_name: StringName = &"gbuffer_albedo_storage" if binding_type == BindingType.STORAGE_IMAGE else NativeSpec.TEX_GBUFFER_ALBEDO
			return _get_named_texture(buffers, FRP_SCOPE, albedo_name, view, true)
		Source.ORM:
			return _get_named_texture(buffers, FRP_SCOPE, NativeSpec.TEX_GBUFFER_ORM, view)
		Source.EMISSION:
			return _get_named_texture(buffers, FRP_SCOPE, NativeSpec.TEX_GBUFFER_EMISSION, view)
		Source.INDIRECT_SPECULAR:
			return _get_named_texture(buffers, FRP_SCOPE, NativeSpec.TEX_INDIRECT_SPECULAR, view)
		Source.PIPELINE:
			return _get_named_texture(buffers, PIPELINE_SCOPE, custom_name, view)
		Source.TONEMAPPED:
			return _get_named_texture(buffers, TONEMAPPER_SCOPE, TONEMAPPER_TEXTURE, view)
		Source.CUSTOM:
			return _get_named_texture(buffers, custom_scope, custom_name, view)
	return RID()

func _get_named_texture(buffers: RenderSceneBuffersRD, scope: StringName, texture_name: StringName, view: int, explicit_format_view: bool = false) -> RID:
	if scope == &"" or texture_name == &"" or not buffers.has_texture(scope, texture_name):
		return RID()
	var texture_format = buffers.get_texture_format(scope, texture_name)
	if texture_format.array_layers <= view:
		if view == 0:
			return buffers.get_texture(scope, texture_name)
		return RID()
	if texture_format.array_layers == 1 and view == 0:
		return buffers.get_texture(scope, texture_name)
	if explicit_format_view:
		# RD slice creation resolves a shared view to its backing texture. Reapply the
		# named view's actual format so sRGB sampling remains explicit per array layer.
		var texture_view := RDTextureView.new()
		texture_view.format_override = texture_format.format
		return buffers.get_texture_slice_view(scope, texture_name, view, 0, 1, 1, texture_view)
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
