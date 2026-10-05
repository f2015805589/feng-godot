@tool
class_name FengSkyLightRuntime
extends RefCounted
## One selected FengSkyLight provider per World3D. Providers register on
## lifecycle/configuration changes; this registry does not scan the scene tree.

static var _providers_by_world: Dictionary = {} # world id -> provider id -> {ref, order}
static var _world_by_provider: Dictionary = {} # provider id -> world id
static var _active_by_world: Dictionary = {} # world id -> WeakRef
static var _registration_order := 0


static func refresh_provider(provider: Object) -> void:
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
	if not providers.has(provider_id):
		_registration_order += 1
		providers[provider_id] = {"ref": weakref(provider), "order": _registration_order}
	else:
		var entry: Dictionary = providers[provider_id]
		entry["ref"] = weakref(provider)
		providers[provider_id] = entry
	_providers_by_world[world_id] = providers
	_world_by_provider[provider_id] = world_id
	_resolve_world(world_id)
	var selected := _active_provider(world_id)
	if selected == provider and selected.has_method("_feng_sky_light_refresh_active"):
		selected.call("_feng_sky_light_refresh_active")


static func unregister_provider(provider: Object) -> void:
	if provider == null or not is_instance_valid(provider):
		return
	var provider_id := provider.get_instance_id()
	var world_id := int(_world_by_provider.get(provider_id, 0))
	_remove_candidate(world_id, provider_id)
	_world_by_provider.erase(provider_id)
	if world_id != 0:
		_resolve_world(world_id)
	if _providers_by_world.is_empty():
		_world_by_provider.clear()


static func active_for_world(world_id: int) -> Object:
	return _active_provider(world_id)


static func snapshot_for_world(world_id: int) -> Dictionary:
	var provider := _active_provider(world_id)
	if provider == null or not is_instance_valid(provider) \
			or not provider.has_method("_feng_sky_light_runtime_snapshot"):
		return {}
	var value: Variant = provider.call("_feng_sky_light_runtime_snapshot")
	if not value is Dictionary or value.is_empty():
		return {}
	var snapshot: Dictionary = value.duplicate()
	snapshot["world_id"] = world_id
	snapshot["provider_id"] = provider.get_instance_id()
	return snapshot


static func is_active(provider: Object, world_id: int) -> bool:
	return provider != null and is_instance_valid(provider) \
			and _active_provider(world_id) == provider


static func _remove_candidate(world_id: int, provider_id: int) -> void:
	if world_id == 0:
		return
	var providers: Dictionary = _providers_by_world.get(world_id, {})
	providers.erase(provider_id)
	if providers.is_empty():
		_providers_by_world.erase(world_id)
	else:
		_providers_by_world[world_id] = providers


static func _resolve_world(world_id: int) -> void:
	if world_id == 0:
		return
	# Keep the raw owner so a provider that just became disabled or left this
	# world still receives its deactivation callback and releases native routes.
	var previous := _raw_active_provider(world_id)
	var providers: Dictionary = _providers_by_world.get(world_id, {})
	var selected: Object
	var selected_priority := -2147483648
	var selected_order := 2147483647
	for provider_id in providers.keys():
		var entry: Dictionary = providers[provider_id]
		var reference: WeakRef = entry.get("ref")
		var candidate := reference.get_ref() if reference != null else null
		if candidate == null or not is_instance_valid(candidate) \
				or not candidate.has_method("_feng_sky_light_is_candidate") \
				or not bool(candidate.call("_feng_sky_light_is_candidate", world_id)):
			providers.erase(provider_id)
			_world_by_provider.erase(provider_id)
			continue
		var priority := int(candidate.get("priority"))
		var order := int(entry.get("order", 0))
		if selected == null or priority > selected_priority \
				or (priority == selected_priority and order < selected_order):
			selected = candidate
			selected_priority = priority
			selected_order = order
	if providers.is_empty():
		_providers_by_world.erase(world_id)
	else:
		_providers_by_world[world_id] = providers
	if previous != selected:
		if previous != null and is_instance_valid(previous) \
				and previous.has_method("_feng_sky_light_set_active"):
			previous.call("_feng_sky_light_set_active", false)
		if selected == null:
			_active_by_world.erase(world_id)
		else:
			_active_by_world[world_id] = weakref(selected)
			if selected.has_method("_feng_sky_light_set_active"):
				selected.call("_feng_sky_light_set_active", true)
	elif selected == null:
		_active_by_world.erase(world_id)


static func _active_provider(world_id: int) -> Object:
	var provider := _raw_active_provider(world_id)
	if provider == null or not provider.has_method("_feng_sky_light_is_candidate") \
			or not bool(provider.call("_feng_sky_light_is_candidate", world_id)):
		return null
	return provider


static func _raw_active_provider(world_id: int) -> Object:
	var reference: WeakRef = _active_by_world.get(world_id)
	var provider := reference.get_ref() if reference != null else null
	if provider == null or not is_instance_valid(provider):
		_active_by_world.erase(world_id)
		return null
	return provider
