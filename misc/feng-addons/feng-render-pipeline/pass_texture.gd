@tool
class_name FengPassTexture
extends Resource
## One declared texture input or output of a FengComputePass.

enum Source { COLOR, DEPTH, NORMAL_ROUGHNESS, ALBEDO, ORM, EMISSION, CUSTOM }
enum BindingType { SAMPLED_TEXTURE, STORAGE_IMAGE }

@export_range(0, 31) var binding: int = 0
@export var source: Source = Source.COLOR
@export var binding_type: BindingType = BindingType.STORAGE_IMAGE
@export var custom_scope: StringName
@export var custom_name: StringName

func get_texture(buffers: RenderSceneBuffersRD, view: int) -> RID:
	match source:
		Source.COLOR:
			return buffers.get_color_layer(view)
		Source.DEPTH:
			return buffers.get_depth_layer(view)
		_:
			var scope: StringName = custom_scope if source == Source.CUSTOM else &"deferred_clustered"
			var names := {Source.NORMAL_ROUGHNESS: &"normal_roughness", Source.ALBEDO: &"gbuffer_albedo", Source.ORM: &"gbuffer_orm", Source.EMISSION: &"gbuffer_emission"}
			var texture_name: StringName = custom_name if source == Source.CUSTOM else names[source]
			if not buffers.has_texture(scope, texture_name):
				return RID()
			return buffers.get_texture_slice(scope, texture_name, view, 0, 1, 1)
