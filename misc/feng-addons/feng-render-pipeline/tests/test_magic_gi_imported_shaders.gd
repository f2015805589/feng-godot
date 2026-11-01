extends SceneTree
## Exercise editor-imported SPIR-V, including the importer include-expansion path.

const LIBRARY := "res://addons/feng-render-pipeline/library/magic-gi/"

func _initialize() -> void:
	var failures := 0
	for name: String in ["magic_gi_prepared_volume_debug.glsl", "magic_gi_paged_volume_debug.glsl", "magic_gi_dynamic_volume_debug.glsl", "magic_gi_dynamic_volume_screen_resolve.glsl", "magic_gi_olv_partition_indices.glsl", "magic_gi_clv_partition_relight.glsl", "magic_gi_clv_partition_relight_r16.glsl"]:
		var shader := load(LIBRARY + name) as RDShaderFile
		if shader == null or not shader.base_error.is_empty():
			push_error("Cannot load imported shader: " + name)
			failures += 1
			continue
		var spirv := shader.get_spirv()
		if spirv == null or not spirv.compile_error_compute.is_empty():
			push_error("Imported compute shader failed: " + name + ": " + (spirv.compile_error_compute if spirv != null else "missing SPIR-V"))
			failures += 1
	if failures == 0:
		print("PASS Magic GI imported compute shaders")
	quit(1 if failures else 0)
