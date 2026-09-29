@tool
class_name FengSkyAtmosphere
extends WorldEnvironment
## A scene-authored sky provider. The inherited WorldEnvironment selects the
## first environment for each World3D, so this component follows the same rule.

var _owned_environment: Environment
var _owned_sky: Sky

## The component owns a private Sky and sky material. Replacing this property
## keeps the Environment background in sky mode and avoids editing shared assets.
@export var sky: Sky:
	get:
		return environment.sky if environment != null else null
	set(value):
		if environment == null:
			_ensure_private_environment()
		if value == _owned_sky and environment.sky == _owned_sky:
			_enforce_sky_background()
			return
		_owned_sky = _make_local_sky(value)
		environment.sky = _owned_sky
		_enforce_sky_background()

func _init() -> void:
	var default_environment := Environment.new()
	default_environment.resource_local_to_scene = true
	_owned_environment = default_environment
	environment = default_environment
	_owned_sky = _make_default_sky()
	environment.sky = _owned_sky
	environment.background_mode = Environment.BG_SKY

func _enter_tree() -> void:
	_sync_environment()
	set_process(Engine.is_editor_hint())

func _ready() -> void:
	_sync_environment()

func _exit_tree() -> void:
	set_process(false)

func _process(_delta: float) -> void:
	# WorldEnvironment.environment is inherited, so a tool script cannot attach a
	# setter to it. Watch for an inspector replacement and localize it before the
	# component enforces its sky settings. This runs in the editor only.
	if Engine.is_editor_hint() and (
		environment != _owned_environment
		or (
			environment != null
			and (environment.sky != _owned_sky or environment.background_mode != Environment.BG_SKY)
		)
	):
		_sync_environment()

func _sync_environment() -> void:
	_ensure_private_environment()
	_enforce_sky_background()

func _ensure_private_environment() -> void:
	if environment == null:
		var created := Environment.new()
		created.resource_local_to_scene = true
		_owned_environment = created
		_owned_sky = null
		environment = created
		return

	if environment == _owned_environment:
		if environment.sky != _owned_sky:
			_owned_sky = _make_local_sky(environment.sky)
			environment.sky = _owned_sky
		return

	var source := environment
	var local_environment := source.duplicate(true) as Environment
	if local_environment == null:
		push_error("FengSkyAtmosphere could not duplicate its Environment resource.")
		local_environment = Environment.new()
	local_environment.resource_local_to_scene = true
	_owned_sky = _make_local_sky(source.sky)
	local_environment.sky = _owned_sky
	_owned_environment = local_environment
	environment = local_environment

func _enforce_sky_background() -> void:
	if environment == null:
		return
	if environment.background_mode != Environment.BG_SKY:
		environment.background_mode = Environment.BG_SKY

func _make_default_sky() -> Sky:
	var default_sky := Sky.new()
	default_sky.resource_local_to_scene = true
	var material := PhysicalSkyMaterial.new()
	material.resource_local_to_scene = true
	default_sky.sky_material = material
	return default_sky

func _make_local_sky(source: Sky) -> Sky:
	if source == null:
		return null

	var local_sky := source.duplicate(true) as Sky
	if local_sky == null:
		push_error("FengSkyAtmosphere could not duplicate its Sky resource.")
		return null
	local_sky.resource_local_to_scene = true

	var source_material := source.sky_material
	if source_material != null:
		var local_material := local_sky.sky_material
		if local_material == source_material:
			local_material = source_material.duplicate(true) as Material
			local_sky.sky_material = local_material
		if local_material == null:
			push_error("FengSkyAtmosphere could not duplicate its Sky material.")
			return local_sky
		local_material.resource_local_to_scene = true
		if local_material is ShaderMaterial and local_material.shader != null:
			var local_shader := local_material.shader.duplicate(true) as Shader
			if local_shader == null:
				push_error("FengSkyAtmosphere could not duplicate its Sky shader.")
				local_material.shader = null
			else:
				local_shader.resource_local_to_scene = true
				local_material.shader = local_shader

	return local_sky

func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if environment == null:
		warnings.append("FengSkyAtmosphere needs an Environment resource.")
	elif environment.sky == null:
		warnings.append("No Sky is assigned; the world background will use the Environment fallback color.")
	if not is_inside_tree():
		return warnings
	var world := get_viewport().find_world_3d()
	if world != null and environment != null and world.get_environment() != environment:
		warnings.append("Another WorldEnvironment is first in this World3D, so FengSkyAtmosphere does not affect it.")
	return warnings
