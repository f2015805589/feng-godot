@tool
class_name FengRenderer
extends Resource
## Declarative FRP pipeline: a list of passes that is applied to a Compositor.
##
## A new FengRenderer is pre-populated with the built-in library passes, all
## enabled. Existing renderers stay in sync with the library: when a new
## built-in pass is added to DEFAULT_PASS_PATHS, it is appended automatically
## on the next apply() or inspector refresh. Disable or remove passes you do
## not need; removed passes are not re-added.
##
## apply() groups enabled passes by stage (preserving list order inside each
## stage), prepends the hidden FengTextureManager, and writes the result into
## Compositor.compositor_effects. Pass.enabled is applied natively by the
## engine (CompositorEffect::set_enabled updates the RID immediately), so
## toggling a pass does not require re-applying the renderer.

const PassBase = preload("passes/pass_base.gd")
const TextureManager = preload("passes/texture_manager.gd")

const LIBRARY_DIR := "res://addons/feng-render-pipeline/library"
## Built-in passes in default execution order. All library passes run at
## POST_TRANSPARENT, so list order is execution order. To add a built-in
## pass: drop its glsl + .tres into library/, then register the .tres path
## here. Existing FengRenderer resources pick it up automatically.
const DEFAULT_PASS_PATHS: Array[String] = [
	"tint/tint.tres",
	"blur/blur_h.tres",
	"blur/blur_v.tres",
	"fxaa/fxaa.tres",
	"color-grade/color_grade.tres",
	"bloom-lite/bloom_downsample.tres",
	"bloom-lite/bloom_blur.tres",
	"bloom-lite/bloom_composite.tres",
]

@export var passes: Array[PassBase] = []
## Manifest paths already synced into this renderer. Persisted so passes the
## user removed are not re-added and new library passes are added once.
@export_storage var _synced_library: Array[String] = []

var _manager: CompositorEffect

func _init() -> void:
	_manager = TextureManager.new()
	_sync_library(false)

func _get_property_list() -> Array:
	# Editor hook: keep the inspector in sync with the built-in library.
	_sync_library(false)
	return []

## Appends built-in library passes that are not yet part of this renderer.
## Passes the user removed stay removed (tracked in _synced_library).
func _sync_library(emit: bool) -> void:
	var changed := false
	for path in DEFAULT_PASS_PATHS:
		if _synced_library.has(path):
			continue
		var template = load(LIBRARY_DIR + "/" + path)
		if template == null:
			continue
		if not _has_matching_pass(template):
			passes.append(template.duplicate(true))
			changed = true
		_synced_library.append(path)
	if changed and emit:
		emit_changed()

func _has_matching_pass(template: Resource) -> bool:
	var template_shader: RDShaderFile = template.get("shader_file")
	if template_shader == null or template_shader.resource_path == "":
		return false
	for p in passes:
		if p == null:
			continue
		var p_shader: RDShaderFile = p.get("shader_file")
		if p_shader != null and p_shader.resource_path == template_shader.resource_path:
			return true
	return false

## Marks a library pass as already present so _sync_library() does not
## duplicate it. Used by the editor "Add Pass from Library" menu.
func mark_library_pass(path: String) -> void:
	var rel := path
	var prefix := LIBRARY_DIR + "/"
	if rel.begins_with(prefix):
		rel = rel.substr(prefix.length())
	if not _synced_library.has(rel):
		_synced_library.append(rel)

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_manager = null

func apply(compositor: Compositor) -> void:
	if compositor == null:
		return
	_sync_library(true)
	var effects: Array[CompositorEffect] = []
	effects.append(_manager)
	var manager_passes: Array[CompositorEffect] = []
	for p in passes:
		if p == null or not p.enabled:
			continue
		manager_passes.append(p)
		effects.append(p)
	_manager.passes = manager_passes
	compositor.compositor_effects = effects

func get_enabled_passes() -> Array[PassBase]:
	var result: Array[PassBase] = []
	for p in passes:
		if p != null and p.enabled:
			result.append(p)
	return result

func get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	var output_names := {}
	var binding_keys := {}
	for p in passes:
		if p == null:
			warnings.append("Pass list contains an empty entry.")
			continue
		for warning in p.get_configuration_warnings():
			warnings.append(warning)
		for output in p.outputs:
			if output == null or output.name == &"":
				continue
			if output_names.has(output.name):
				warnings.append("Output texture '%s' is produced by more than one pass." % output.name)
			output_names[output.name] = true
		for input in p.inputs:
			if input == null:
				continue
			if input.source == PassBase.TextureInput.Source.PIPELINE:
				if not output_names.has(input.custom_name):
					warnings.append("Pass input references pipeline texture '%s' that no pass produces." % input.custom_name)
			var key := "%s:%d" % [p.get_instance_id(), input.binding]
			if binding_keys.has(key):
				warnings.append("Pass declares texture binding %d more than once." % input.binding)
			binding_keys[key] = true
	return warnings
