@tool
class_name FengSkyLightRuntime
extends RefCounted
## One selected FengSkyLight provider per World3D. Providers register on
## lifecycle/configuration changes; this registry does not scan the scene tree.

static var _providers_by_world: Dictionary = {} # world id -> registration-ordered provider id -> WeakRef
static var _world_by_provider: Dictionary = {} # provider id -> world id
static var _active_by_world: Dictionary = {} # world id -> WeakRef


static func retain_capture_effects_until_rendered(effects: Array[CompositorEffect]) -> void:
	var retained: Array[CompositorEffect] = []
	for effect in effects:
		if effect != null and is_instance_valid(effect):
			retained.append(effect)
	if retained.is_empty():
		return
	# Detach/cancel is submitted before this callback by the caller. The render
	# thread callback is the lifetime barrier: it holds each Resource through
	# any already queued capture work, then explicitly frees its owned pass RIDs.
	RenderingServer.call_on_render_thread(func():
		var rd := RenderingServer.get_rendering_device()
		if rd != null:
			for effect in retained:
				if is_instance_valid(effect) and effect.has_method("_cleanup_capture_resources"):
					effect.call("_cleanup_capture_resources", rd)
		retained.clear()
	)


static func refresh_provider(provider: FengSkyLight) -> void:
	if provider == null or not is_instance_valid(provider):
		return
	var provider_id := provider.get_instance_id()
	var previous_world_id := int(_world_by_provider.get(provider_id, 0))
	var world: World3D = provider.get_world_3d() if provider.is_inside_tree() else null
	var world_id := world.get_instance_id() if world != null else 0
	if previous_world_id != world_id:
		_remove_candidate(previous_world_id, provider_id)
		_world_by_provider.erase(provider_id)
		if previous_world_id != 0:
			_resolve_world(previous_world_id)
	if world_id == 0:
		return
	var providers: Dictionary = _providers_by_world.get(world_id, {})
	# Updating an existing key preserves its registration order.
	providers[provider_id] = weakref(provider)
	_providers_by_world[world_id] = providers
	_world_by_provider[provider_id] = world_id
	_resolve_world(world_id)
	var selected := _active_provider(world_id)
	if selected == provider:
		selected._feng_sky_light_refresh_active()


static func unregister_provider(provider: FengSkyLight) -> void:
	if provider == null or not is_instance_valid(provider):
		return
	var provider_id := provider.get_instance_id()
	var world_id := int(_world_by_provider.get(provider_id, 0))
	_remove_candidate(world_id, provider_id)
	_world_by_provider.erase(provider_id)
	if world_id != 0:
		_resolve_world(world_id)


static func active_for_world(world_id: int) -> FengSkyLight:
	return _active_provider(world_id)


static func snapshot_for_world(world_id: int) -> Dictionary:
	var provider := _active_provider(world_id)
	if provider == null:
		return {}
	return _tag_snapshot(provider._feng_sky_light_runtime_snapshot(), provider, world_id)


## Returns only the explicit active FengSkyLight's plain volumetric metadata.
## Unlike snapshot_for_world(), this does not ask the provider to create or
## read back CPU radiance SH data.
static func volumetric_metadata_for_world(world_id: int) -> Dictionary:
	var provider := _active_provider(world_id)
	if provider == null:
		return {}
	return _tag_snapshot(provider._feng_sky_light_volumetric_metadata(), provider, world_id)


static func _tag_snapshot(value: Dictionary, provider: FengSkyLight, world_id: int) -> Dictionary:
	if value.is_empty():
		return {}
	var snapshot := value.duplicate()
	snapshot["world_id"] = world_id
	snapshot["provider_id"] = provider.get_instance_id()
	return snapshot


static func is_active(provider: FengSkyLight, world_id: int) -> bool:
	return provider != null and is_instance_valid(provider) \
			and _active_provider(world_id) == provider


static func _remove_candidate(world_id: int, provider_id: int) -> void:
	if world_id == 0:
		return
	var providers: Dictionary = _providers_by_world.get(world_id, {})
	providers.erase(provider_id)
	if providers.is_empty():
		_providers_by_world.erase(world_id)


static func _resolve_world(world_id: int) -> void:
	if world_id == 0:
		return
	# Keep the raw owner so a provider that just became disabled or left this
	# world still receives its deactivation callback and releases native routes.
	var previous := _raw_active_provider(world_id)
	var providers: Dictionary = _providers_by_world.get(world_id, {})
	var selected: FengSkyLight
	var selected_priority := -2147483648
	for provider_id in providers.keys():
		var candidate: FengSkyLight = providers[provider_id].get_ref()
		if candidate == null or not candidate._feng_sky_light_is_candidate(world_id):
			providers.erase(provider_id)
			_world_by_provider.erase(provider_id)
			continue
		# Dictionary iteration keeps the earlier registration on equal priority.
		if selected == null or candidate.priority > selected_priority:
			selected = candidate
			selected_priority = candidate.priority
	if providers.is_empty():
		_providers_by_world.erase(world_id)
	if previous != selected:
		if previous != null:
			previous._feng_sky_light_set_active(false)
		if selected == null:
			_active_by_world.erase(world_id)
		else:
			_active_by_world[world_id] = weakref(selected)
			selected._feng_sky_light_set_active(true)


static func _active_provider(world_id: int) -> FengSkyLight:
	var provider := _raw_active_provider(world_id)
	if provider == null or not provider._feng_sky_light_is_candidate(world_id):
		return null
	return provider


static func _raw_active_provider(world_id: int) -> FengSkyLight:
	var reference: WeakRef = _active_by_world.get(world_id)
	var provider: FengSkyLight = reference.get_ref() if reference != null else null
	if provider == null or not is_instance_valid(provider):
		_active_by_world.erase(world_id)
		return null
	return provider
