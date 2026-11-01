@tool
class_name FOLVData
extends Resource
## OLV owns its automatic result and sparse edits; GI transfer remains immutable.
@export_storage var automatic_labels := PackedByteArray()
@export_storage var inference_metadata: Dictionary = {}
@export_storage var overrides: Dictionary = {}
@export_storage var payload: Resource
@export_storage var label_set: Resource
@export_storage var layout_context: Dictionary = {}
@export_storage var source_layout_sha256 := ""
@export_storage var model_bundle_sha256 := ""
@export_storage var gi_manifest_signature := ""
@export_storage var gi_bake_model_sha256 := ""

static func manifest_signature(manifest: Resource) -> String:
	return JSON.stringify([manifest.manifest_key,manifest.generation,manifest.bake_geometry_signature,
		manifest.bake_settings_signature,manifest.prepared_source_signature,
		manifest.prepared_source_origin_world,manifest.prepared_source_transform_world,
		manifest.prepared_source_size_m],"",true,true).sha256_text()

func matches_manifest(manifest: Resource) -> bool:
	return not gi_manifest_signature.is_empty() and gi_manifest_signature == manifest_signature(manifest)

func runtime_binding() -> Dictionary:
	return {"managed": true, "enabled": payload != null and label_set != null,
		"payload": payload, "label_set": label_set, "context": layout_context}
