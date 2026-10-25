@tool
class_name FMagicGIBaker
extends RefCounted
## Offline diffuse PRT: bake only geometry transport. Current light and the
## receiving material remain dynamic and are applied by the render pass.

const Data = preload("feng_magic_gi_data.gd")
const Placement = preload("feng_magic_gi_placement.gd")
const BakeJob = preload("feng_magic_gi_bake_job.gd")
const Manifest = preload("feng_magic_gi_manifest.gd")
const Page = preload("feng_magic_gi_page.gd")
const PageContext = preload("feng_magic_gi_page_context.gd")
const PagePlanner = preload("feng_magic_gi_page_planner.gd")
const SceneTracker = preload("feng_magic_gi_scene_tracker.gd")
const ProbeLayout = preload("feng_magic_gi_probe_layout.gd")
const Lighting = preload("feng_magic_gi_lighting.gd")
const Emission = preload("feng_magic_gi_emission.gd")
const BoundaryTensorBuilder = preload("feng_magic_gi_boundary_tensor_builder.gd")
const MAX_BAKE_PATHS := 100000000
const SAMPLER_REVISION := Data.SAMPLER_REVISION
const QMC_PRIME_BASES := [2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53, 59]
const MIN_VISIBILITY_RAYS_PER_TEXEL := 4

## The persisted geometry signature also identifies the estimator that created it.
## This leaves the v2 transport layout intact while making older random bakes stale.
static func signature_for_geometry(geometry_signature: int) -> int:
	return Data.signature_for_geometry(geometry_signature)

## Explicit v5 upgrade: keep light transport byte-for-byte and only build static
## blockers. Never assigns the volume or saves a scene; callers own that choice.
func upgrade_visibility_bake(volume: FMagicGIVolume, collected_geometry: Placement = null) -> Data:
	var previous: Data = volume.bake_data
	if not volume.is_inside_tree() or previous == null \
			or previous.format_version != Data.MOMENT_FORMAT_VERSION or not previous.is_valid():
		return null
	var geometry := collected_geometry
	if geometry == null:
		geometry = Placement.new()
		if not geometry.collect(volume, true, true, true):
			return null
	if previous.scene_signature != signature_for_geometry(geometry.scene_signature):
		return null
	var upgraded: Data = previous.duplicate(true)
	upgraded.format_version = Data.FORMAT_VERSION
	if not upgraded.matches_layout(volume.size, volume.probe_spacing, volume.surface_offset,
			volume.global_transform, volume.bake_samples, volume.bake_bounces,
			volume.bake_distance, volume.terrain_reflectance, volume.fallback_material_reflectance) \
			or not _build_visibility_geometry(upgraded, geometry.faces):
		return null
	upgraded.bake_version = maxi(previous.bake_version + 1, Time.get_ticks_usec())
	return upgraded if upgraded.is_valid() else null

static func _build_visibility_geometry(data: Data, faces: PackedVector3Array) -> bool:
	var blockers := Data.Visibility.build(faces)
	if blockers.is_empty():
		return false
	data.visibility_nodes = blockers.nodes
	data.visibility_triangles = blockers.triangles
	return true

func bake_volume(volume: FMagicGIVolume, generation: int) -> Data:
	if not volume.is_inside_tree():
		return null
	var lighting := Lighting.new()
	var sky_capture: Dictionary = await lighting._capture_bake_coefficient_sets(volume,
			Callable(self, "_bake_request_cancelled").bind(volume, generation))
	if not bool(sky_capture.get("ready", false)):
		push_warning("FMagicGI: " + String(sky_capture.get("error", "Bake-time Sky capture failed.")))
		return null
	if not _bake_request_current(volume, generation):
		return null
	var bake_lighting_sets: Dictionary = sky_capture.get("coefficient_sets", {})
	if bake_lighting_sets.is_empty():
		push_warning("FMagicGI: bake-time Sky capture returned no frozen lighting snapshot.")
		return null
	var bake_input_signature := SceneTracker.bake_content_signature(volume)
	var scene_watch_signature := SceneTracker.stable_scene_signature(volume)
	var geometry := Placement.new()
	if not geometry.collect(volume, true, true, true):
		push_warning("FMagicGI: " + geometry.error_message)
		return null
	# Placement collection is the immutable CPU snapshot used by all workers.
	# Capture its source boundary once and compare the same fingerprint after
	# workers finish instead of recollecting geometry and rebuilding the BVH.
	if geometry.positions.is_empty():
		push_warning("FMagicGI: no surfaces inside the volume; no air probes were created.")
		return null
	var rays: int = volume.bake_samples
	var bounces: int = volume.bake_bounces
	if rays < 1 or rays > 65536 or bounces < 1 or bounces > 8 or volume.bake_distance <= 0.0:
		push_warning("FMagicGI: invalid bake sample, bounce, or distance settings.")
		return null
	var directional_sources: Array[Dictionary] = bake_lighting_sets.get("directional_sources", [])
	var directional_source_signature := String(bake_lighting_sets.get(
			"directional_source_signature", ""))
	if directional_source_signature.is_empty() or not Data.is_valid_baked_indirect_directional_provenance(
			Data.BAKED_INDIRECT_SH_ALGORITHM_EXACT_DIRECTIONAL_NEE,
			directional_source_signature, _baked_directional_provenance(bake_lighting_sets)):
		push_warning("FMagicGI: exact directional-light bake snapshot is missing or invalid.")
		return null
	var eligible_directional_sources := _eligible_directional_source_count(directional_sources)
	var work_per_probe_sample := (bounces + 1) * (1 + geometry.emitters.groups.size()) \
			+ bounces * eligible_directional_sources
	var visibility_rays := maxi(rays,
			Data.VISIBILITY_TEXELS_PER_PROBE * MIN_VISIBILITY_RAYS_PER_TEXEL)
	var total_work := geometry.positions.size() * (rays * work_per_probe_sample + visibility_rays)
	if total_work > MAX_BAKE_PATHS:
		push_warning("FMagicGI: PRT, directional visibility, and emissive-source shadow rays exceed the 100,000,000 work limit; increase Probe Spacing or reduce samples, bounces, or emitter count.")
		return null
	var data := Data.new()
	data.format_version = Data.FORMAT_VERSION
	data.grid_dims = volume.grid_dimensions()
	data.volume_size = volume.size
	data.spacing = volume.probe_spacing
	data.adaptive_placement = volume.adaptive_placement
	data.minimum_probe_spacing = minf(volume.minimum_probe_spacing, volume.probe_spacing)
	data.probe_spacings = geometry.probe_spacings
	data.surface_offset = volume.surface_offset
	data.volume_transform = volume.global_transform
	data.world_to_grid = volume.world_to_grid_transform()
	data.bake_samples = rays
	data.bake_bounces = bounces
	data.bake_distance = volume.bake_distance
	data.terrain_reflectance = volume.terrain_reflectance
	data.material_reflectance = volume.fallback_material_reflectance
	var geometry_signature: int = geometry.scene_signature
	data.scene_signature = signature_for_geometry(geometry_signature)
	data.placement_layout_revision = ProbeLayout.PLACEMENT_LAYOUT_REVISION
	data.scene_watch_signature = scene_watch_signature
	data.scene_watch_signature_schema_version = SceneTracker.SIGNATURE_SCHEMA_CURRENT
	data.positions = geometry.positions
	data.surface_positions = geometry.surface_positions
	data.normals = geometry.normals
	if not _build_visibility_geometry(data, geometry.faces):
		push_warning("FMagicGI: could not build static segment blockers; discarded the incomplete bake.")
		return null
	data.transfer.resize(data.probe_count() * 27)
	data.primary_sky_visibility.resize(data.probe_count() * 9)
	data.visibility_moments.resize(data.probe_count() * Data.VISIBILITY_TEXELS_PER_PROBE
			* Data.VISIBILITY_MOMENT_CHANNELS)
	data.emitter_keys = geometry.emitters.keys
	data.emitter_static_signatures = geometry.emitters.static_signatures
	data.emitter_transport.resize(data.probe_count() * geometry.emitters.groups.size() * 6)
	data.directional = Data.DirectionalData.new()
	data.directional.allocate(data.probe_count(), geometry.emitters.groups.size())
	data.prepare_bake_exact_directional_secondary()
	var bake_emission_sources: PackedFloat32Array = Emission.new().read_source_values(volume, data)
	var qmc_dimension_count := (bounces + 1) * 2
	var qmc_base_coordinates := _build_qmc_base_coordinates(rays, qmc_dimension_count)
	var minimum_visibility_rays := Data.VISIBILITY_TEXELS_PER_PROBE * MIN_VISIBILITY_RAYS_PER_TEXEL
	var minimum_visibility_qmc_coordinates := _build_qmc_base_coordinates(minimum_visibility_rays, 2)
	var extra_visibility_qmc_coordinates := _build_qmc_base_coordinates(
			visibility_rays - minimum_visibility_rays, 2)
	var trace_scene: RefCounted = geometry.trace_scene
	var jobs_completed: bool = await _run_probe_jobs(data, volume, generation, trace_scene, geometry_signature,
			qmc_base_coordinates, minimum_visibility_qmc_coordinates,
			extra_visibility_qmc_coordinates, visibility_rays, directional_sources)
	if not jobs_completed:
		return null
	if not _build_baked_indirect_sh(data, bake_lighting_sets, bake_emission_sources):
		push_warning("FMagicGI: failed to produce the persistent indirect-radiance SH field.")
		return null
	data.clear_bake_exact_directional_secondary()
	# Material, Mesh, Terrain, texture, and source inputs are fingerprinted at the
	# boundary. This rejects edits made during worker yields without paying for a
	# second Placement traversal, material decode, and BVH build.
	if SceneTracker.bake_content_signature(volume) != bake_input_signature:
		push_warning("FMagicGI: scene geometry, material, Terrain, texture, or source inputs changed during baking; discarded stale transfer.")
		return null
	# The total SH is frozen from one lighting/emission snapshot. Reject the bake
	# if either dynamic input changed while worker jobs were running.
	var lighting_validation: Dictionary = lighting._validate_bake_coefficient_capture(
			volume, bake_lighting_sets)
	if not bool(lighting_validation.get("ready", false)):
		push_warning("FMagicGI: " + String(lighting_validation.get("error",
				"Sky input changed during bake; discarded the mixed-snapshot SH field.")))
		return null
	var current_lighting_sets: Dictionary = lighting_validation.get("coefficient_sets", {})
	var current_lighting_signature := hash([
		current_lighting_sets.get("lighting", PackedFloat32Array()),
		current_lighting_sets.get("sky_lighting", PackedFloat32Array()),
		ProjectSettings.get_setting("rendering/lights_and_shadows/use_physical_light_units", false)])
	var current_emission_sources: PackedFloat32Array = Emission.new().read_source_values(volume, data)
	if current_lighting_signature != data.baked_indirect_lighting_signature \
			or String(current_lighting_sets.get("directional_source_signature", "")) \
			!= data.baked_indirect_directional_source_signature \
			or hash(current_emission_sources) != data.baked_indirect_emission_signature:
		push_warning("FMagicGI: lighting or emissive sources changed during baking; discarded the mixed-snapshot SH field.")
		return null
	if not is_instance_valid(volume) or not volume.is_bake_request_current(generation) \
			or not data.matches_layout(
			volume.size, volume.probe_spacing, volume.surface_offset, volume.global_transform,
			volume.bake_samples, volume.bake_bounces, volume.bake_distance,
			volume.terrain_reflectance, volume.fallback_material_reflectance):
		push_warning("FMagicGI: volume changed during baking; discarded stale transfer.")
		return null
	if not data.build_cell_indices():
		push_warning("FMagicGI: probe lookup construction failed; discarded incomplete transport.")
		return null
	if int(volume.clv_cache_backend) == 1 and not volume.is_surfel_mode() \
			and not volume.chunked_baking:
		var boundary_payload: Dictionary = BoundaryTensorBuilder.build_records(
				volume, data, geometry)
		if bool(boundary_payload.get("valid", false)):
			if not data.set_baked_boundary_tensor_records(boundary_payload):
				data.invalidate_baked_boundary_tensor_records()
				push_warning("FMagicGI: optional boundary tensor correction was rejected by Data validation; the complete ordinary SH bake is retained.")
		else:
			data.invalidate_baked_boundary_tensor_records()
			push_warning("FMagicGI: optional boundary tensor correction was not generated (%s); the complete ordinary SH bake is retained." % String(boundary_payload.get("reason", "unknown_builder_failure")))
	data.bake_version = Time.get_ticks_usec()
	if not data.is_valid() or not data.has_baked_indirect_sh():
		push_warning("FMagicGI: generated PRT payload failed validation.")
		return null
	if not data.has_nonzero_transfer():
		push_warning("FMagicGI: " + volume.ZERO_TRANSFER_DIAGNOSTIC)
	return data

## Builds an immutable page generation. Pages are written under a unique folder;
## only after every page and the lightweight manifest reload successfully does
## the caller receive the manifest to publish on the Volume.
func bake_streamed_generation(volume: FMagicGIVolume, request_generation: int,
		selected_chunk: Vector2i = Vector2i(2147483647, 2147483647)) -> Dictionary:
	if not _bake_request_current(volume, request_generation):
		return {"error": "Bake was cancelled before page planning."}
	var lighting := Lighting.new()
	var sky_capture: Dictionary = await lighting._capture_bake_coefficient_sets(volume,
			Callable(self, "_bake_request_cancelled").bind(volume, request_generation))
	if not bool(sky_capture.get("ready", false)):
		return {"error": String(sky_capture.get("error", "Bake-time Sky capture failed."))}
	if not _bake_request_current(volume, request_generation):
		return {"error": "Bake was cancelled while waiting for the Sky snapshot."}
	var generation_lighting_sets: Dictionary = sky_capture.get("coefficient_sets", {})
	if generation_lighting_sets.is_empty():
		return {"error": "Bake-time Sky capture returned no frozen lighting snapshot."}
	var generation_directional_sources: Array[Dictionary] = generation_lighting_sets.get(
			"directional_sources", [])
	var generation_directional_signature := String(generation_lighting_sets.get(
			"directional_source_signature", ""))
	var generation_directional_provenance := _baked_directional_provenance(generation_lighting_sets)
	if generation_directional_signature.is_empty() \
			or not Data.is_valid_baked_indirect_directional_provenance(
			Data.BAKED_INDIRECT_SH_ALGORITHM_EXACT_DIRECTIONAL_NEE,
			generation_directional_signature, generation_directional_provenance):
		return {"error": "Bake-time exact DirectionalLight snapshot is missing or invalid."}
	var generation_sky_provenance := _baked_sky_provenance(generation_lighting_sets)
	if not Data.is_valid_baked_indirect_sky_provenance(generation_sky_provenance):
		return {"error": "Bake-time Sky provenance failed validation; the active generation was kept."}
	var world_bounds: AABB = volume.global_transform * AABB(-volume.size * 0.5, volume.size)
	var planned := PagePlanner.core_pages(world_bounds, volume.management_block_size,
		volume.core_page_size)
	if planned.is_empty():
		return {"error": "The Volume does not intersect a finite set of managed pages."}
	var selected_only := selected_chunk.x != 2147483647
	var generation_lighting_signature := hash([
		generation_lighting_sets.get("lighting", PackedFloat32Array()),
		generation_lighting_sets.get("sky_lighting", PackedFloat32Array()),
		ProjectSettings.get_setting("rendering/lights_and_shadows/use_physical_light_units", false)])
	var settings_signature := _streamed_settings_signature(volume)
	var scene_signature_before := SceneTracker.stable_scene_signature(volume)
	var bake_input_signature := SceneTracker.bake_content_signature(volume)
	var scene_watch_signature := scene_signature_before
	var rebuild: Dictionary = {}
	var old_entries: Array[Dictionary] = []
	var dirty_old_keys: Dictionary = {}
	var dirty_old_cores: Array[AABB] = []
	var trace_radius := volume.bake_distance * float(volume.bake_bounces + 1)
	var selected_chunk_bounds := AABB()
	if selected_only:
		var block_min := Vector3(selected_chunk.x * volume.management_block_size,
				world_bounds.position.y - trace_radius,
				selected_chunk.y * volume.management_block_size)
		selected_chunk_bounds = AABB(block_min, Vector3(volume.management_block_size,
				world_bounds.size.y + trace_radius * 2.0, volume.management_block_size))
	var old_manifest_valid := selected_only and volume.bake_manifest != null \
			and volume.bake_manifest.is_valid()
	if old_manifest_valid:
		for old_entry_value in volume.bake_manifest.page_entries:
			var old_entry: Dictionary = old_entry_value
			old_entries.append(old_entry)
			var old_influence := _old_entry_influence_bounds(old_entry, trace_radius)
			if _page_influence_intersects_chunk(old_influence, selected_chunk_bounds):
				var old_key := String(old_entry.get("page_key", ""))
				dirty_old_keys[old_key] = true
				var old_core: AABB = old_entry.get("core_bounds", AABB())
				dirty_old_cores.append(old_core)
	for entry in planned:
		var core: AABB = entry.core_bounds
		var should_bake := not selected_only \
				or int(entry.chunk_x) == selected_chunk.x and int(entry.chunk_z) == selected_chunk.y
		if selected_only and not should_bake:
			var influence := PagePlanner.influence_bounds(core, volume.probe_spacing,
				volume.minimum_probe_spacing, volume.clv_cell_size,
				volume.bake_distance, volume.bake_bounces)
			should_bake = _page_influence_intersects_chunk(influence, selected_chunk_bounds)
			if not should_bake:
				for old_core in dirty_old_cores:
					if PagePlanner.intersects_half_open(core, old_core):
						should_bake = true
						break
		if should_bake:
			rebuild[String(entry.page_key)] = entry.duplicate(true)
	if rebuild.is_empty():
		return {"error": "The selected management chunk has no affected pages."}
	if selected_only and volume.bake_manifest != null:
		if volume.bake_manifest.bake_settings_signature != settings_signature:
			return {"error": "Chunk rebake requires the same global bake settings as the current manifest; run a full Bake after changing bake settings."}
		if volume.bake_manifest.baked_indirect_sh_revision != Data.BAKED_INDIRECT_SH_REVISION:
			return {"error": "A full Bake is required to add the persistent indirect-radiance SH field to this older generation."}
		if not volume.bake_manifest.has_baked_indirect_sh():
			return {"error": "A full Bake is required because the current generation has no verified bake-time Sky provenance."}
		if volume.bake_manifest.baked_indirect_sh_algorithm \
				!= Data.BAKED_INDIRECT_SH_ALGORITHM_EXACT_DIRECTIONAL_NEE \
				or volume.bake_manifest.baked_indirect_directional_source_signature \
				!= generation_directional_signature:
			return {"error": "A full Bake is required after directional source algorithm/input changes; partial rebake would mix frozen indirect lighting."}
		if volume.bake_manifest.baked_indirect_sky_provenance != generation_sky_provenance:
			return {"error": "A full Bake is required because streamed pages must share one exact Sky provenance snapshot."}
		if volume.bake_manifest.baked_indirect_lighting_signature != generation_lighting_signature:
			return {"error": "A full Bake is required after Sky or indirect DirectionalLight changes; partial rebake would mix frozen indirect lighting."}
		if not _streamed_emission_snapshot_matches(volume, volume.bake_manifest):
			return {"error": "A full Bake is required after emissive-source changes; partial rebake would mix frozen indirect lighting."}
	var generation_id := "%d_%d" % [Time.get_ticks_usec(), volume.get_instance_id()]
	var output_root := volume.resolved_bake_directory()
	if output_root.is_empty() or not output_root.begins_with("res://"):
		return {"error": "The streamed bake output must be inside a writable res:// project directory."}
	var generation_root := output_root.path_join("generation_" + generation_id)
	var absolute_generation_root := ProjectSettings.globalize_path(generation_root)
	if DirAccess.make_dir_recursive_absolute(absolute_generation_root) != OK:
		return {"error": "Could not create the immutable page generation directory."}
	var final_entries: Array[Dictionary] = []
	if selected_only and volume.bake_manifest != null and volume.bake_manifest.is_valid():
		# A previous page may have been recursively split and therefore have no
		# matching base planned key. Drop it when its influence is dirty or its
		# ownership core is covered by a page being rebuilt; the new bake will
		# recreate the correct split layout.
		for old_entry in old_entries:
			var key := String(old_entry.get("page_key", ""))
			var old_core: AABB = old_entry.get("core_bounds", AABB())
			var discard_old := dirty_old_keys.has(key)
			if not discard_old:
				for rebuilt_spec_value in rebuild.values():
					var rebuilt_core: AABB = rebuilt_spec_value.get("core_bounds", AABB())
					if PagePlanner.intersects_half_open(old_core, rebuilt_core):
						discard_old = true
						break
			if not discard_old and not rebuild.has(key):
				final_entries.append(old_entry.duplicate(true))
	var pages_by_batch: Dictionary = {}
	var geometry_batch_size := minf(volume.core_page_size * 2.0, 64.0)
	for page_key in rebuild:
		var page_spec: Dictionary = rebuild[page_key]
		var core: AABB = page_spec.core_bounds
		var batch_x := floori(core.position.x / geometry_batch_size)
		var batch_y := floori(core.position.y / geometry_batch_size)
		var batch_z := floori(core.position.z / geometry_batch_size)
		var batch_key := "%d,%d/%d,%d,%d" % [int(page_spec.chunk_x), int(page_spec.chunk_z),
				batch_x, batch_y, batch_z]
		var grouped: Array = pages_by_batch.get(batch_key, [])
		grouped.append(page_spec)
		pages_by_batch[batch_key] = grouped
	var total_pages := rebuild.size()
	var completed_pages := 0
	for batch_key in pages_by_batch:
		if not _bake_request_current(volume, request_generation):
			return {"error": "Bake was cancelled; the previously published manifest remains active."}
		var batch_pages: Array = pages_by_batch[batch_key]
		var group_support := _union_support_bounds(batch_pages, volume)
		var geometry_context := PageContext.new()
		geometry_context.name = "_FMagicGIPageCollector"
		volume.add_child(geometry_context, false, Node.INTERNAL_MODE_BACK)
		geometry_context.configure(volume, group_support, group_support,
				volume.bake_distance * float(volume.bake_bounces + 1))
		var geometry := Placement.new()
		var trace_bounds := group_support.grow(volume.bake_distance * float(volume.bake_bounces + 1))
		var collected := geometry.collect(geometry_context, true, true, true, false, trace_bounds)
		var shared_geometry_ready := collected
		if not collected and not _is_page_collection_budget_error(geometry.error_message):
			geometry_context.free()
			return {"error": "Bounded page-batch geometry collection failed for %s: %s" % [batch_key, geometry.error_message]}
		var page_work: Array[Dictionary] = []
		for page_spec in batch_pages:
			page_work.append(page_spec.duplicate(true))
		var page_cursor := 0
		while page_cursor < page_work.size():
			if not _bake_request_current(volume, request_generation):
				geometry_context.free()
				return {"error": "Bake was cancelled; the previously published manifest remains active."}
			var page_spec: Dictionary = page_work[page_cursor]
			page_cursor += 1
			var page_key := String(page_spec.page_key)
			var core: AABB = page_spec.core_bounds
			var support := PagePlanner.support_bounds(core, volume.probe_spacing,
				volume.minimum_probe_spacing, volume.clv_cell_size)
			geometry_context.configure(volume, core, support,
					volume.bake_distance * float(volume.bake_bounces + 1))
			var page_geometry := geometry
			var page_result: Dictionary
			if not shared_geometry_ready:
				page_geometry = Placement.new()
				var page_trace_bounds := support.grow(
						volume.bake_distance * float(volume.bake_bounces + 1))
				if not page_geometry.collect(geometry_context, true, true, true, false,
						page_trace_bounds):
					page_result = {"split": _is_page_collection_budget_error(page_geometry.error_message)}
					if not bool(page_result.split):
						geometry_context.free()
						return {"error": "Page-local geometry collection failed for %s in batch %s: %s" % [page_key, batch_key, page_geometry.error_message]}
				else:
					page_result = await _bake_streamed_page(volume, request_generation,
							generation_id, page_key, core, support, page_geometry,
							generation_lighting_sets, generation_directional_sources)
			else:
				page_result = await _bake_streamed_page(volume, request_generation,
						generation_id, page_key, core, support, page_geometry,
						generation_lighting_sets, generation_directional_sources)
			if bool(page_result.get("split", false)):
				var minimum_extent := maxf(0.125, minf(volume.probe_spacing,
						volume.minimum_probe_spacing) * 0.5)
				var children := PagePlanner.split_core(core, minimum_extent)
				if children.size() != 2:
					geometry_context.free()
					return {"error": "Page %s still exceeds a hard grid/work/memory limit after reaching the minimum core extent." % page_key}
				for child in children:
					var child_key := PagePlanner.page_key_for_core(child,
							int(page_spec.chunk_x), int(page_spec.chunk_z), volume.core_page_size)
					page_work.append({"page_key": child_key, "core_bounds": child,
						"chunk_x": page_spec.chunk_x, "chunk_z": page_spec.chunk_z})
				total_pages += 1
				continue
			if not String(page_result.get("error", "")).is_empty():
				geometry_context.free()
				return {"error": String(page_result.error)}
			var page_entry: Dictionary = page_result.entry
			page_entry["baked_indirect_sh_revision"] = Data.BAKED_INDIRECT_SH_REVISION
			page_entry["baked_indirect_sky_provenance"] = generation_sky_provenance.duplicate(true)
			page_entry["baked_indirect_sh_algorithm"] = Data.BAKED_INDIRECT_SH_ALGORITHM_EXACT_DIRECTIONAL_NEE
			page_entry["baked_indirect_directional_source_signature"] = generation_directional_signature
			if not bool(page_result.get("empty", false)):
				var page_resource: Page = page_result.page
				var page_path := generation_root.path_join("page_" + _safe_page_filename(page_key) + ".res")
				if not _bake_request_current(volume, request_generation):
					geometry_context.free()
					return {"error": "Streamed bake was canceled before page publication; the active generation was kept."}
				var save_error := ResourceSaver.save(page_resource, page_path, ResourceSaver.FLAG_COMPRESS)
				if save_error != OK:
					geometry_context.free()
					return {"error": "Could not save immutable page %s (error %d)." % [page_key, save_error]}
				if not _bake_request_current(volume, request_generation):
					geometry_context.free()
					return {"error": "Streamed bake was canceled after writing an unreferenced page; the active generation was kept."}
				var reloaded := ResourceLoader.load(page_path, "", ResourceLoader.CACHE_MODE_IGNORE) as Page
				if reloaded == null or not reloaded.is_valid(generation_id, page_key) \
						or not reloaded.has_baked_indirect_sh() \
						or reloaded.data.baked_indirect_lighting_signature \
							!= generation_lighting_signature \
						or reloaded.baked_indirect_sh_algorithm \
							!= Data.BAKED_INDIRECT_SH_ALGORITHM_EXACT_DIRECTIONAL_NEE \
						or reloaded.baked_indirect_directional_source_signature \
							!= generation_directional_signature \
						or reloaded.baked_indirect_directional_source_provenance \
							!= generation_directional_provenance \
						or reloaded.baked_indirect_sky_provenance != generation_sky_provenance:
					geometry_context.free()
					return {"error": "Saved page %s failed reload validation." % page_key}
				page_entry["resource_path"] = page_path
				page_entry["content_hash"] = FileAccess.get_sha256(page_path)
				page_entry["version"] = reloaded.data.bake_version
				page_entry["empty"] = false
			else:
				page_entry["resource_path"] = ""
				page_entry["content_hash"] = ""
				page_entry["version"] = 0
				page_entry["empty"] = true
			final_entries.append(page_entry)
			completed_pages += 1
			volume.set_streamed_bake_progress(completed_pages, total_pages)
		geometry_context.free()
	var bake_input_signature_after := SceneTracker.bake_content_signature(volume)
	var lighting_validation: Dictionary = lighting._validate_bake_coefficient_capture(
			volume, generation_lighting_sets)
	if not bool(lighting_validation.get("ready", false)):
		return {"error": String(lighting_validation.get("error",
				"Sky input changed during the streamed bake; the old generation was kept."))}
	var lighting_sets_after: Dictionary = lighting_validation.get("coefficient_sets", {})
	var lighting_signature_after := hash([
		lighting_sets_after.get("lighting", PackedFloat32Array()),
		lighting_sets_after.get("sky_lighting", PackedFloat32Array()),
		ProjectSettings.get_setting("rendering/lights_and_shadows/use_physical_light_units", false)])
	if not _bake_request_current(volume, request_generation) \
			or bake_input_signature != bake_input_signature_after \
			or lighting_signature_after != generation_lighting_signature \
			or String(lighting_sets_after.get("directional_source_signature", "")) \
			!= generation_directional_signature \
			or not _streamed_entries_emission_snapshot_matches(volume, final_entries,
				generation_lighting_signature, generation_sky_provenance,
				Data.BAKED_INDIRECT_SH_ALGORITHM_EXACT_DIRECTIONAL_NEE,
				generation_directional_signature, generation_directional_provenance) \
			or settings_signature != _streamed_settings_signature(volume):
		return {"error": "Scene, lighting, or Volume changed during the streamed bake; the old generation was kept."}
	var manifest := Manifest.new()
	manifest.generation = generation_id
	manifest.scene_identity = SceneTracker.scene_identity(volume)
	manifest.volume_identity = SceneTracker.scene_relative_path(volume)
	manifest.manifest_key = _stable_manifest_key(output_root,
			manifest.scene_identity, manifest.volume_identity)
	manifest.world_bounds = world_bounds
	manifest.management_block_size = volume.management_block_size
	manifest.page_core_size = volume.core_page_size
	manifest.bake_settings_signature = settings_signature
	manifest.bake_samples = volume.bake_samples
	manifest.bake_bounces = volume.bake_bounces
	manifest.scene_watch_signature = scene_watch_signature
	manifest.scene_watch_signature_schema_version = SceneTracker.SIGNATURE_SCHEMA_CURRENT
	manifest.bake_geometry_signature = scene_watch_signature
	manifest.partial_generation = selected_only
	manifest.baked_indirect_sh_revision = Data.BAKED_INDIRECT_SH_REVISION
	manifest.baked_indirect_lighting_signature = generation_lighting_signature
	manifest.baked_indirect_sky_provenance = generation_sky_provenance.duplicate(true)
	manifest.baked_indirect_sh_algorithm = Data.BAKED_INDIRECT_SH_ALGORITHM_EXACT_DIRECTIONAL_NEE
	manifest.baked_indirect_directional_source_signature = generation_directional_signature
	manifest.baked_indirect_directional_source_provenance = generation_directional_provenance.duplicate(true)
	manifest.page_entries = final_entries
	manifest._build_spatial_index()
	if not manifest.is_valid() or not manifest.has_baked_indirect_sh():
		return {"error": "Generated page manifest failed validation: %s" % manifest.get_index_error()}
	var manifest_path := output_root.path_join("manifest_" + generation_id + ".res")
	if ResourceSaver.save(manifest, manifest_path, ResourceSaver.FLAG_COMPRESS) != OK:
		return {"error": "Could not save the final page manifest; the prior generation remains active."}
	var verified_manifest := ResourceLoader.load(manifest_path, "", ResourceLoader.CACHE_MODE_IGNORE) as Manifest
	if verified_manifest == null or not verified_manifest.is_valid() \
			or not verified_manifest.has_baked_indirect_sh():
		return {"error": "Published manifest failed reload validation; the prior generation remains active."}
	verified_manifest.resource_path = manifest_path
	return {"manifest": verified_manifest, "path": manifest_path,
		"pages": total_pages, "completed_pages": completed_pages,
		"settings_signature": settings_signature,
		"geometry_signature": scene_watch_signature,
		"scene_watch_signature": scene_watch_signature}

func _bake_streamed_page(volume: FMagicGIVolume, request_generation: int,
		generation_id: String, page_key: String, core: AABB, support: AABB,
		geometry: Placement, lighting_sets: Dictionary,
		directional_sources: Array[Dictionary]) -> Dictionary:
	var influence := PagePlanner.influence_bounds(core, volume.probe_spacing,
			volume.minimum_probe_spacing, volume.clv_cell_size,
			volume.bake_distance, volume.bake_bounces)
	if not PagePlanner.intersects_half_open(influence, influence):
		return {"error": "Page %s has invalid trace-influence bounds." % page_key}
	if geometry.faces.is_empty():
		return {"empty": true, "entry": _empty_page_entry(
				generation_id, page_key, core, support, influence)}
	if not geometry.sample_streamed_page(_page_context_for_geometry(geometry, volume, core, support)):
		if _is_splittable_page_error(geometry.error_message):
			return {"split": true}
		return {"error": geometry.error_message}
	var count := geometry.positions.size()
	if count == 0:
		return {"empty": true, "entry": _empty_page_entry(
				generation_id, page_key, core, support, influence)}
	var work_per_probe_sample := (volume.bake_bounces + 1) * (1 + geometry.emitters.groups.size()) \
			+ volume.bake_bounces * _eligible_directional_source_count(directional_sources)
	var visibility_rays := maxi(volume.bake_samples,
			Data.VISIBILITY_TEXELS_PER_PROBE * MIN_VISIBILITY_RAYS_PER_TEXEL)
	var total_work := count * (volume.bake_samples * work_per_probe_sample + visibility_rays)
	var data := _create_streamed_page_data(volume, geometry, page_key)
	if data == null:
		return {"error": "Page data could not be initialized."}
	var blockers := Data.Visibility.build(geometry.faces)
	if blockers.is_empty():
		return {"error": "Could not build page segment visibility."}
	data.visibility_nodes = blockers.nodes
	data.visibility_triangles = blockers.triangles
	data.emitter_keys = geometry.emitters.keys
	data.emitter_static_signatures = geometry.emitters.static_signatures
	data.directional = Data.DirectionalData.new()
	data.directional.allocate(count, geometry.emitters.groups.size())
	data.transfer.resize(count * 27)
	data.primary_sky_visibility.resize(count * 9)
	data.visibility_moments.resize(count * Data.VISIBILITY_TEXELS_PER_PROBE * Data.VISIBILITY_MOMENT_CHANNELS)
	data.emitter_transport.resize(count * geometry.emitters.groups.size() * 6)
	data.prepare_bake_exact_directional_secondary()
	var bake_emission_sources: PackedFloat32Array = Emission.new().read_source_values(volume, data)
	if PagePlanner.exceeds_page_limits(count, data.grid_dims, total_work,
			data.estimate_gpu_bytes(), data.estimate_cpu_bytes() + data.estimate_gpu_bytes() \
				+ count * (1 + 3 * 4 + 27 * 4 + 27 * 4 + 7 * 16),
			volume.gpu_resident_budget_bytes, volume.cpu_resident_budget_bytes):
		return {"split": true}
	var qmc_dimension_count := (volume.bake_bounces + 1) * 2
	var qmc_base_coordinates := _build_qmc_base_coordinates(volume.bake_samples, qmc_dimension_count)
	var minimum_visibility_rays := Data.VISIBILITY_TEXELS_PER_PROBE * MIN_VISIBILITY_RAYS_PER_TEXEL
	var minimum_visibility_qmc_coordinates := _build_qmc_base_coordinates(minimum_visibility_rays, 2)
	var extra_visibility_qmc_coordinates := _build_qmc_base_coordinates(
			visibility_rays - minimum_visibility_rays, 2)
	var page_signature := geometry.scene_signature
	if not await _run_probe_jobs(data, volume, request_generation, geometry.trace_scene,
			page_signature, qmc_base_coordinates, minimum_visibility_qmc_coordinates,
			extra_visibility_qmc_coordinates, visibility_rays, directional_sources):
		return {"error": "Page worker failed or was cancelled."}
	if not _build_baked_indirect_sh(data, lighting_sets, bake_emission_sources):
		return {"error": "Page could not produce its persistent indirect-radiance SH field."}
	data.clear_bake_exact_directional_secondary()
	if not data.build_cell_indices():
		return {"error": "Page lookup construction failed."}
	# The final sparse/fixed lookup arrays are created only after probe work.
	# Recheck with their real resident sizes before freezing the page; the early
	# estimate above cannot include these arrays yet.
	var indexed_gpu_bytes := data.estimate_gpu_bytes()
	var indexed_cpu_bytes := data.estimate_cpu_bytes() + indexed_gpu_bytes + count * 3 * 4
	if PagePlanner.exceeds_page_limits(count, data.grid_dims, total_work,
			indexed_gpu_bytes, indexed_cpu_bytes,
			volume.gpu_resident_budget_bytes, volume.cpu_resident_budget_bytes):
		return {"split": true}
	data.bake_version = Time.get_ticks_usec()
	data.scene_signature = Data.signature_for_geometry(hash([page_signature, page_key]))
	if not data.is_valid():
		return {"error": "Page payload failed v6 validation."}
	var page := Page.new()
	page.generation = generation_id
	page.page_key = page_key
	page.core_bounds = core
	page.support_bounds = support
	page.probe_count = count
	page.geometry_signature = page_signature
	page.settings_signature = _streamed_settings_signature(volume)
	page.baked_indirect_sh_revision = Data.BAKED_INDIRECT_SH_REVISION
	page.baked_indirect_sh_algorithm = data.baked_indirect_sh_algorithm
	page.baked_indirect_directional_source_signature = data.baked_indirect_directional_source_signature
	page.baked_indirect_directional_source_provenance = data.baked_indirect_directional_source_provenance.duplicate(true)
	page.baked_indirect_sky_provenance = data.baked_indirect_sky_provenance.duplicate(true)
	page.data = data
	page.cpu_bytes = indexed_cpu_bytes
	page.gpu_bytes = indexed_gpu_bytes
	if page.gpu_bytes <= 0 or page.gpu_bytes > volume.gpu_resident_budget_bytes / 2:
		return {"split": true}
	return {"page": page, "entry": {
		"page_key": page_key,
		"page_generation": generation_id,
		"core_bounds": core,
		"support_bounds": support,
		"influence_bounds": influence,
		"probe_count": count,
		"cpu_bytes": page.cpu_bytes,
		"gpu_bytes": page.gpu_bytes,
		"geometry_signature": page_signature,
		"settings_signature": page.settings_signature,
		"baked_indirect_sh_revision": Data.BAKED_INDIRECT_SH_REVISION,
		"baked_indirect_sh_algorithm": data.baked_indirect_sh_algorithm,
		"baked_indirect_directional_source_signature": data.baked_indirect_directional_source_signature,
		"resource_path": "",
		"content_hash": "",
		"empty": false,
	}}

func _create_streamed_page_data(volume: FMagicGIVolume, geometry: Placement,
		page_key: String) -> Data:
	var context := geometry._volume as PageContext
	if context == null:
		return null
	var data := Data.new()
	data.format_version = Data.FORMAT_VERSION
	data.grid_dims = context.grid_dimensions()
	data.volume_size = context.size
	data.spacing = volume.probe_spacing
	data.adaptive_placement = volume.adaptive_placement
	data.minimum_probe_spacing = minf(volume.minimum_probe_spacing, volume.probe_spacing)
	data.probe_spacings = geometry.probe_spacings
	data.surface_offset = volume.surface_offset
	data.volume_transform = context.global_transform
	data.world_to_grid = context.world_to_grid_transform()
	data.bake_samples = volume.bake_samples
	data.bake_bounces = volume.bake_bounces
	data.bake_distance = volume.bake_distance
	data.terrain_reflectance = volume.terrain_reflectance
	data.material_reflectance = volume.fallback_material_reflectance
	data.scene_signature = Data.signature_for_geometry(hash([geometry.scene_signature, page_key]))
	data.placement_layout_revision = ProbeLayout.PLACEMENT_LAYOUT_REVISION
	data.scene_watch_signature_schema_version = SceneTracker.SIGNATURE_SCHEMA_CURRENT
	data.positions = geometry.positions
	data.surface_positions = geometry.surface_positions
	data.normals = geometry.normals
	data.stable_probe_ids = geometry.stable_probe_ids
	return data

## Freeze the complete indirect incident radiance into one persistent SH9
## field. DirectionalData.relight() returns secondary coefficients in [0,27)
## and visibility-filtered primary Sky in [27,54); combine them before the
## receiver cosine evaluation, matching the existing PRT shader contract.
func _build_baked_indirect_sh(data: Data, lighting_sets: Dictionary,
		emission_sources: PackedFloat32Array) -> bool:
	if data == null or data.directional == null \
			or not data.directional is Data.DirectionalData:
		return false
	var lighting: PackedFloat32Array = lighting_sets.get("lighting", PackedFloat32Array())
	var sky_lighting: PackedFloat32Array = lighting_sets.get("sky_lighting", PackedFloat32Array())
	var sky_provenance := _baked_sky_provenance(lighting_sets)
	var directional_sources: Variant = lighting_sets.get("directional_sources", null)
	var directional_signature := String(lighting_sets.get("directional_source_signature", ""))
	var directional_provenance := _baked_directional_provenance(lighting_sets)
	var physical_units: Variant = lighting_sets.get("directional_physical_units", null)
	if lighting.size() != 27 or sky_lighting.size() != 27 \
			or emission_sources.size() != data.emitter_count() * 6 \
			or sky_lighting != sky_provenance.get("radiance_sh", PackedFloat32Array()) \
			or not Data.is_valid_baked_indirect_sky_provenance(sky_provenance) \
			or not directional_sources is Array \
			or physical_units == null \
			or directional_signature.is_empty() \
			or not Data.is_valid_baked_indirect_directional_provenance(
				Data.BAKED_INDIRECT_SH_ALGORITHM_EXACT_DIRECTIONAL_NEE,
				directional_signature, directional_provenance) \
			or directional_provenance.get("physical_units", null) != physical_units \
			or not data.validate_bake_exact_directional_secondary():
		return false
	var composed := PackedFloat32Array()
	composed.resize(data.probe_count() * 27)
	for probe in data.probe_count():
		var relit: PackedFloat32Array = data.directional.relight(
				probe, sky_lighting, sky_lighting, emission_sources)
		if relit.size() != 54:
			return false
		for coefficient in 27:
			var value := relit[coefficient] + relit[27 + coefficient] \
					+ data.bake_exact_directional_secondary[probe * 27 + coefficient]
			if not is_finite(value):
				return false
			composed[probe * 27 + coefficient] = value
	data._invalidate_baked_indirect_sh_validation_cache()
	data.invalidate_baked_boundary_tensor_records()
	data.baked_indirect_sh_revision = 0
	data.baked_indirect_sh.clear()
	data.baked_indirect_sh_algorithm = ""
	data.baked_indirect_directional_source_signature = ""
	data.baked_indirect_directional_source_provenance.clear()
	data.baked_indirect_sky_provenance.clear()
	data._sky_provenance_validation_cached = false
	data._sky_provenance_validation_result = false
	data.baked_indirect_sh = composed
	data.baked_indirect_lighting_signature = hash([
		lighting, sky_lighting, ProjectSettings.get_setting(
		"rendering/lights_and_shadows/use_physical_light_units", false)])
	data.baked_indirect_emission_signature = hash(emission_sources)
	data.baked_indirect_sky_provenance = sky_provenance
	data.baked_indirect_sh_algorithm = Data.BAKED_INDIRECT_SH_ALGORITHM_EXACT_DIRECTIONAL_NEE
	data.baked_indirect_directional_source_signature = directional_signature
	data.baked_indirect_directional_source_provenance = directional_provenance.duplicate(true)
	data._sky_provenance_validation_cached = false
	data._baked_directional_provenance_validation_cached = false
	data.baked_indirect_sh_revision = Data.BAKED_INDIRECT_SH_REVISION
	return data.has_baked_indirect_sh() and data.baked_indirect_sh_is_valid()

func _baked_sky_provenance(lighting_sets: Dictionary) -> Dictionary:
	var radiance: Variant = lighting_sets.get("sky_radiance_sh", PackedFloat32Array())
	if not radiance is PackedFloat32Array:
		return {}
	return {
		"schema_version": 1,
		"status": String(lighting_sets.get("sky_snapshot_status", "")),
		"source": String(lighting_sets.get("sky_source", "")),
		"source_mode": int(lighting_sets.get("sky_source_mode", -1)),
		"source_revision": int(lighting_sets.get("sky_source_revision", -1)),
		"radiance_unit": "scene_linear_radiance",
		"radiance_energy": float(lighting_sets.get("sky_radiance_energy", NAN)),
		"radiance_sh": radiance.duplicate(),
		"input_signature": String(lighting_sets.get("sky_input_signature", "")),
	}

func _streamed_emission_snapshot_matches(volume: FMagicGIVolume,
		manifest: Manifest) -> bool:
	if manifest == null or manifest.baked_indirect_sh_revision != Data.BAKED_INDIRECT_SH_REVISION:
		return false
	var emission := Emission.new()
	for entry_value in manifest.page_entries:
		var entry: Dictionary = entry_value
		if bool(entry.get("empty", false)):
			continue
		var page_path := String(entry.get("resource_path", ""))
		var page := ResourceLoader.load(page_path) as Page
		if page == null or page.data == null or not page.has_baked_indirect_sh() \
				or page.data.baked_indirect_lighting_signature \
				!= manifest.baked_indirect_lighting_signature \
				or page.baked_indirect_sky_provenance != manifest.baked_indirect_sky_provenance \
				or page.baked_indirect_sh_algorithm != manifest.baked_indirect_sh_algorithm \
				or page.baked_indirect_directional_source_signature \
				!= manifest.baked_indirect_directional_source_signature \
				or page.baked_indirect_directional_source_provenance \
				!= manifest.baked_indirect_directional_source_provenance:
			return false
		if hash(emission.read_source_values(volume, page.data)) \
				!= page.data.baked_indirect_emission_signature:
			return false
	return true

func _streamed_entries_emission_snapshot_matches(volume: FMagicGIVolume,
		entries: Array[Dictionary], lighting_signature: int, sky_provenance: Dictionary,
		algorithm: String, directional_signature: String,
		directional_provenance: Dictionary) -> bool:
	var emission := Emission.new()
	for entry in entries:
		if bool(entry.get("empty", false)):
			continue
		var page_path := String(entry.get("resource_path", ""))
		if page_path.is_empty():
			return false
		var page := ResourceLoader.load(page_path) as Page
		if page == null or page.data == null or not page.has_baked_indirect_sh() \
				or page.data.baked_indirect_lighting_signature != lighting_signature \
				or page.baked_indirect_sky_provenance != sky_provenance \
				or page.baked_indirect_sh_algorithm != algorithm \
				or page.baked_indirect_directional_source_signature != directional_signature \
				or page.baked_indirect_directional_source_provenance != directional_provenance:
			return false
		if hash(emission.read_source_values(volume, page.data)) \
				!= page.data.baked_indirect_emission_signature:
			return false
	return true

func _page_context_for_geometry(geometry: Placement, volume: FMagicGIVolume,
		core: AABB, support: AABB) -> PageContext:
	var context := geometry._volume as PageContext
	if context == null:
		context = PageContext.new()
		volume.add_child(context, false, Node.INTERNAL_MODE_BACK)
	context.configure(volume, core, support,
			volume.bake_distance * float(volume.bake_bounces + 1))
	return context

func _union_support_bounds(pages: Array, volume: FMagicGIVolume) -> AABB:
	var result := AABB()
	var initialized := false
	for entry_value in pages:
		var entry: Dictionary = entry_value
		var support := PagePlanner.support_bounds(entry.core_bounds, volume.probe_spacing,
				volume.minimum_probe_spacing, volume.clv_cell_size)
		if not initialized:
			result = support
			initialized = true
		else:
			result = result.merge(support)
	return result

func _empty_page_entry(generation_id: String, page_key: String,
		core: AABB, support: AABB, influence: AABB) -> Dictionary:
	return {"page_key": page_key, "page_generation": generation_id,
		"core_bounds": core, "support_bounds": support,
		"influence_bounds": influence, "probe_count": 0,
		"cpu_bytes": 0, "gpu_bytes": 0, "geometry_signature": 0,
		"settings_signature": 0, "resource_path": "", "content_hash": "", "empty": true}

func _eligible_directional_source_count(sources: Array[Dictionary]) -> int:
	var count := 0
	for source in sources:
		if int(source.get("sky_mode", -1)) != DirectionalLight3D.SKY_MODE_SKY_ONLY:
			count += 1
	return count

func _baked_directional_provenance(lighting_sets: Dictionary) -> Dictionary:
	var sources_value: Variant = lighting_sets.get("directional_sources", null)
	var physical_value: Variant = lighting_sets.get("directional_physical_units", null)
	if typeof(sources_value) != TYPE_ARRAY or typeof(physical_value) != TYPE_BOOL:
		return {}
	var sources: Array = sources_value
	return {
		"schema_version": Data.BAKED_DIRECTIONAL_SOURCE_SCHEMA_VERSION,
		"source_scale_convention": "godot_directional_nee_q_v1",
		"visibility_contract": "all_collected_static_triangles_v1",
		"angular_source_contract": "collimated_directional_v1",
		"light_masks_contract": "recorded_not_applied_to_bvh_v1",
		"physical_units": physical_value,
		"sources": sources.duplicate(true),
	}

static func _old_entry_influence_bounds(entry: Dictionary, trace_radius: float) -> AABB:
	var influence: AABB = entry.get("influence_bounds", AABB())
	if _valid_aabb(influence):
		return influence
	var support: AABB = entry.get("support_bounds", AABB())
	if not _valid_aabb(support) or not is_finite(trace_radius) or trace_radius < 0.0:
		return AABB()
	# Manifest v1 pre-release pages did not store influence bounds. Same-settings
	# partial rebakes can conservatively reconstruct them from their saved support.
	return support.grow(trace_radius)

static func _page_influence_intersects_chunk(influence: AABB, chunk_bounds: AABB) -> bool:
	return PagePlanner.intersects_half_open(influence, chunk_bounds)

static func _valid_aabb(bounds: AABB) -> bool:
	return bounds.position.is_finite() and bounds.size.is_finite() \
			and bounds.size.x > 0.0 and bounds.size.y > 0.0 and bounds.size.z > 0.0

func _is_splittable_page_error(message: String) -> bool:
	return message.contains("64 cells per axis") or message.contains("65,536-probe") \
			or message.contains("65,536-cell limit") or message.contains("bounded record limit") \
			or message.contains("cell-query budget") or message.contains("500,000-cell work limit")

func _is_page_collection_budget_error(message: String) -> bool:
	return message.contains("250,000-triangle sampling/signature budget") \
			or message.contains("500,000-cell work limit")

func _streamed_settings_signature(volume: FMagicGIVolume) -> int:
	return hash([volume.global_transform, volume.size, volume.probe_spacing,
		volume.minimum_probe_spacing, volume.surface_offset, volume.adaptive_placement,
		volume.bake_samples, volume.bake_bounces, volume.bake_distance,
		volume.terrain_reflectance, volume.fallback_material_reflectance,
		volume.management_block_size, volume.core_page_size, volume.clv_cell_size,
		ProbeLayout.PLACEMENT_LAYOUT_REVISION])

func _scene_signature_uncached(volume: FMagicGIVolume) -> int:
	return SceneTracker.stable_scene_signature(volume)

func _safe_page_filename(page_key: String) -> String:
	return page_key.replace("-", "m").replace(",", "_").replace("/", "__")

func _stable_manifest_key(output_root: String, scene_identity: String,
		volume_identity: String) -> String:
	return "%s|%s|%s" % [output_root.trim_suffix("/"), scene_identity, volume_identity]

## Keep at most one worker window in flight. Completing and merging each probe
## immediately lets a fast worker take the next slot without waiting for the
## slowest probe in an arbitrary batch.
func _run_probe_jobs(data: Data, volume: Node3D, generation: int,
		trace_scene: RefCounted, geometry_signature: int,
		qmc_base_coordinates: Array[PackedFloat64Array],
		minimum_visibility_qmc_coordinates: Array[PackedFloat64Array],
		extra_visibility_qmc_coordinates: Array[PackedFloat64Array],
		visibility_rays: int, directional_sources: Array[Dictionary] = []) -> bool:
	var worker_limit := clampi(_probe_worker_limit(), 1, 8)
	var next_probe := 0
	# One record owns each outstanding task's job and destination probe slot.
	var pending: Dictionary = {}
	var cancelled := false
	var failed := false
	while next_probe < data.probe_count() or not pending.is_empty():
		cancelled = cancelled or not _bake_request_current(volume, generation)
		var completed_tasks := PackedInt64Array()
		for task_id in pending:
			if WorkerThreadPool.is_task_completed(task_id):
				completed_tasks.append(task_id)
		if not completed_tasks.is_empty():
			var completed_records: Array[Dictionary] = []
			for task_id in completed_tasks:
				# Join before releasing the task's job or its immutable geometry snapshot.
				WorkerThreadPool.wait_for_task_completion(task_id)
				var record: Dictionary = pending[task_id]
				pending.erase(task_id)
				var job: BakeJob = record.job
				if not job.valid:
					failed = true
				completed_records.append(record)
			# Merge only after all newly completed jobs are known to be valid. Once a
			# cancellation or failure is known, remaining results are only joined.
			if not cancelled and not failed:
				for record in completed_records:
					var completed_job: BakeJob = record.job
					completed_job.merge(data, int(record.probe))
		if not cancelled and not failed:
			while next_probe < data.probe_count() and pending.size() < worker_limit:
				if not _bake_request_current(volume, generation):
					cancelled = true
					break
				var probe := next_probe
				var job := _create_bake_job(data, probe)
				var task_id := WorkerThreadPool.add_task(Callable(job, "run").bind(trace_scene,
					geometry_signature, probe, qmc_base_coordinates,
					minimum_visibility_qmc_coordinates, extra_visibility_qmc_coordinates,
					visibility_rays, directional_sources), false, "Magic GI Bake")
				if task_id < 0:
					failed = true
					break
				pending[task_id] = {"job": job, "probe": probe}
				next_probe += 1
		if (cancelled or failed) and pending.is_empty():
			break
		if not pending.is_empty():
			await Engine.get_main_loop().process_frame
	if failed:
		push_warning("FMagicGI: incomplete directional visibility; discarded the bake.")
	return not cancelled and not failed and next_probe == data.probe_count() \
		and _bake_request_current(volume, generation)

func _probe_worker_limit() -> int:
	return clampi(OS.get_processor_count() - 2, 1, 8)

func _create_bake_job(data: Data, probe: int) -> BakeJob:
	var job := BakeJob.new()
	job.initialize(data, probe)
	return job

func _bake_request_current(volume: Node3D, generation: int) -> bool:
	return is_instance_valid(volume) and volume.is_inside_tree() \
		and bool(volume.call("is_bake_request_current", generation))

func _bake_request_cancelled(volume: Node3D, generation: int) -> bool:
	return not _bake_request_current(volume, generation)

## Randomized Hammersley sequence: the first coordinate is stratified over N
## samples and later coordinates use radical inverses in distinct prime bases.
## Cranley-Patterson shifts preserve the uniform marginal distribution.
static func qmc_sample(sample_index: int, sample_count: int, dimension: int, shift: float) -> float:
	if sample_count <= 0 or sample_index < 0 or sample_index >= sample_count \
			or dimension < 0 or dimension > QMC_PRIME_BASES.size():
		return 0.0
	return fposmod(_qmc_base_coordinate(sample_index, sample_count, dimension) + shift, 1.0)

static func _qmc_base_coordinate(sample_index: int, sample_count: int, dimension: int) -> float:
	if dimension == 0:
		return (float(sample_index) + 0.5) / float(sample_count)
	return _radical_inverse(sample_index, QMC_PRIME_BASES[dimension - 1])

static func _build_qmc_base_coordinates(sample_count: int,
		dimension_count: int) -> Array[PackedFloat64Array]:
	var coordinates: Array[PackedFloat64Array] = []
	coordinates.resize(dimension_count)
	for dimension in dimension_count:
		var values := PackedFloat64Array()
		values.resize(sample_count)
		for sample_index in sample_count:
			values[sample_index] = _qmc_base_coordinate(sample_index, sample_count, dimension)
		coordinates[dimension] = values
	return coordinates

static func _radical_inverse(index: int, base: int) -> float:
	var result := 0.0
	var factor := 1.0 / float(base)
	var remaining := index
	while remaining > 0:
		var digit := remaining % base
		result += float(digit) * factor
		remaining = int(floor(float(remaining) / float(base)))
		factor /= float(base)
	return result

static func cosine_direction(normal: Vector3, u: float, v: float) -> Vector3:
	var tangent := normal.cross(Vector3.UP if absf(normal.y) < 0.99 else Vector3.RIGHT).normalized()
	var bitangent := normal.cross(tangent)
	var radius := sqrt(u)
	return (tangent * (radius * cos(TAU * v)) + bitangent * (radius * sin(TAU * v)) + normal * sqrt(1.0 - u)).normalized()

static func _cosine_direction_with_frame(normal: Vector3, u: float, v: float,
		tangent: Vector3, bitangent: Vector3) -> Vector3:
	var radius := sqrt(u)
	return (tangent * (radius * cos(TAU * v)) + bitangent * (radius * sin(TAU * v)) + normal * sqrt(1.0 - u)).normalized()
