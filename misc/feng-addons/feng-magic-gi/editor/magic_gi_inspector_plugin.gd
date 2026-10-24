@tool
extends EditorInspectorPlugin
## Inspector for FMagicGIVolume: bake controls and streamed/legacy status.

const Volume = preload("../feng_magic_gi_volume.gd")
const Data = preload("../feng_magic_gi_data.gd")
const DirectionalData = preload("../feng_magic_gi_directional_data.gd")
const Runtime = preload("../feng_magic_gi_runtime.gd")
const ProjectPipeline = preload("../../feng-render-pipeline/project_pipeline.gd")
const MagicGIPass = preload("../../feng-render-pipeline/passes/magic_gi_pass.gd")

func _can_handle(object: Object) -> bool:
	return object is Volume

func _parse_begin(_object: Object) -> void:
	var volume := _object as Volume
	var container := VBoxContainer.new()
	var info := Label.new()
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var runtime_info := Label.new()
	runtime_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var ui := {"info": info, "runtime_info": runtime_info}
	var status_callback := Callable(self, "_update_status").bind(volume, info, ui)
	volume.bake_status_changed.connect(status_callback)
	info.tree_exiting.connect(_disconnect_status_callback.bind(volume, status_callback), CONNECT_ONE_SHOT)
	container.add_child(info)
	container.add_child(runtime_info)
	var preview_info := Label.new()
	preview_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	container.add_child(preview_info)
	var runtime_timer := Timer.new()
	runtime_timer.wait_time = 0.5
	runtime_timer.timeout.connect(_update_runtime_status.bind(volume, runtime_info))
	runtime_timer.timeout.connect(_update_preview_status.bind(volume, preview_info))
	container.add_child(runtime_timer)
	runtime_timer.tree_entered.connect(runtime_timer.start, CONNECT_ONE_SHOT)

	var bake_row := HBoxContainer.new()
	ui["bake_row"] = bake_row
	var bake_button := Button.new()
	bake_button.pressed.connect(_on_bake_pressed.bind(volume, ui))
	bake_row.add_child(bake_button)
	ui["bake_button"] = bake_button
	var cancel_button := Button.new()
	cancel_button.pressed.connect(volume.cancel_bake)
	bake_row.add_child(cancel_button)
	ui["cancel_button"] = cancel_button
	container.add_child(bake_row)

	var chunk_row := HBoxContainer.new()
	var chunk_label := Label.new()
	chunk_label.text = "Chunk X/Z"
	chunk_row.add_child(chunk_label)
	var chunk_x := _make_chunk_coordinate()
	chunk_row.add_child(chunk_x)
	var chunk_z := _make_chunk_coordinate()
	chunk_row.add_child(chunk_z)
	var chunk_button := Button.new()
	chunk_button.text = "Bake Selected Block"
	chunk_button.pressed.connect(_on_chunk_bake_pressed.bind(volume, chunk_x, chunk_z, ui))
	chunk_row.add_child(chunk_button)
	container.add_child(chunk_row)
	ui["chunk_row"] = chunk_row
	ui["chunk_button"] = chunk_button

	var quality_label := Label.new()
	quality_label.text = "Bake quality (rays per point)"
	container.add_child(quality_label)
	ui["quality_label"] = quality_label
	var quality := OptionButton.new()
	for preset_index in Volume.BAKE_QUALITY_SAMPLES.size():
		var samples: int = Volume.BAKE_QUALITY_SAMPLES[preset_index]
		quality.add_item("%s — %d rays" % [Volume.BAKE_QUALITY_NAMES[preset_index], samples], samples)
	var selected_index := -1
	for item_index in quality.item_count:
		if quality.get_item_id(item_index) == volume.bake_samples:
			selected_index = item_index
			break
	if selected_index < 0:
		quality.add_item("Custom — %d rays" % volume.bake_samples, volume.bake_samples)
		selected_index = quality.item_count - 1
	quality.select(selected_index)
	quality.item_selected.connect(_on_quality_selected.bind(quality, volume, info, ui))
	container.add_child(quality)
	ui["quality"] = quality

	var refresh := Button.new()
	refresh.text = "Refresh Surface Points"
	refresh.pressed.connect(volume.refresh_surface_points)
	container.add_child(refresh)
	ui["refresh_button"] = refresh
	_update_status(volume, info, ui)
	add_custom_control(container)
	_update_preview_status(volume, preview_info)

func _update_preview_status(volume: FMagicGIVolume, info: Label) -> void:
	if not is_instance_valid(volume) or not is_instance_valid(info):
		return
	info.visible = not volume.is_surfel_mode() and volume.has_free_space_source_generation() \
		and (volume.show_probes or volume.show_sh_probes)
	if not info.visible:
		return
	var snapshot := Runtime.preview_snapshot(volume)
	var count: int = snapshot.get("positions", PackedVector3Array()).size()
	var mode := "CLV Cells" if volume.display_probes_by_clv else "Source Probes"
	if not volume.display_probes_by_clv and snapshot.get("source_kind", "") == "prepared_brick":
		mode = "Prepared Core Cells"
	info.text = "Probe Preview: %s / %d" % [mode, count]
	if volume.display_probes_by_clv:
		info.text += "\nSelect an actual resident level L0–L9; availability follows the baked generation."
	if volume.show_sh_probes:
		info.text += "\nLive SH spheres: %d / %d (uniform sample, max 256)" % [mini(count, 256), count]
	if not bool(snapshot.get("current_available", false)):
		info.text += "\n" + String(snapshot.get("status", "Waiting for live GI response"))

func _make_chunk_coordinate() -> SpinBox:
	var coordinate := SpinBox.new()
	coordinate.min_value = -1000000.0
	coordinate.max_value = 1000000.0
	coordinate.step = 1.0
	coordinate.rounded = true
	coordinate.custom_minimum_size.x = 84.0
	return coordinate

func _on_quality_selected(index: int, quality: OptionButton, volume: FMagicGIVolume,
		info: Label, ui: Dictionary) -> void:
	if not is_instance_valid(volume):
		return
	var samples: int = quality.get_item_id(index)
	if volume.bake_samples == samples:
		return
	volume.bake_samples = samples
	EditorInterface.mark_scene_as_unsaved()
	_update_status(volume, info, ui)

func _update_status(volume: FMagicGIVolume, info: Label, ui: Dictionary) -> void:
	if not is_instance_valid(volume) or not is_instance_valid(info):
		return
	if volume.is_surfel_mode():
		info.text = "Surfel MagicGI: realtime surface cache"
		_update_controls(volume, ui)
		return
	if volume.bake_manifest != null and is_instance_valid(volume.bake_manifest):
		var stream: Dictionary = Runtime.streaming_status(volume)
		var progress: Vector2i = volume.streamed_bake_progress()
		var page_count := volume.bake_manifest.get_page_count()
		var cpu_current := int(stream.get("cpu_committed_bytes", stream.get("cpu_resident_bytes", 0)))
		var gpu_current := int(stream.get("gpu_committed_bytes", stream.get("gpu_resident_bytes", 0)))
		if volume.bake_manifest.transport_domain == "prepared_free_space_bricks_v1":
			var runtime := _magic_gi_runtime_state(volume)
			info.text = "Paged CLV PRT: %.0f m camera radius; %d baked levels, %d total bricks. Resident %d / requested %d; loading %d." % [
				volume.gi_radius_m, volume.bake_manifest.prepared_level_count, page_count,
				int(stream.get("resident_pages", 0)), int(stream.get("active_pages", 0)), int(stream.get("loading_pages", 0))]
			info.text += "\nCPU %.1f / %.0f MiB; actual GPU pool + fields %.1f / %.0f MiB." % [
				float(cpu_current) / 1048576.0, float(volume.cpu_resident_budget_bytes) / 1048576.0,
				float(runtime.get("gpu_bytes", 0)) / 1048576.0, float(volume.gpu_resident_budget_bytes) / 1048576.0]
			info.text += "\nFully outside bricks are released; intersecting bricks retain interpolation support."
		elif volume.has_free_space_source_generation():
			var valid_probes := 0
			var stored_probes := 0
			var packed_source := false
			for entry in volume.bake_manifest.page_entries:
				valid_probes += int(entry.get("valid_cell_count", entry.get("probe_count", 0)))
				stored_probes += int(entry.get("stored_probe_count", entry.get("probe_count", 0)))
				packed_source = packed_source or int(entry.get("free_space_source_format_version", 1)) >= 2
			info.text = "Free-space CLV PRT: %d source lattice slots at .25 m; %d valid probes, %d stored samples in %d page(s). CPU %.1f / %.0f MiB; GPU estimate %.1f / %.0f MiB." % [
				volume.saved_probe_count(), valid_probes, stored_probes, page_count,
				float(cpu_current) / 1048576.0, float(volume.cpu_resident_budget_bytes) / 1048576.0,
				float(gpu_current) / 1048576.0, float(volume.gpu_resident_budget_bytes) / 1048576.0]
			if packed_source:
				info.text += "\nCompact source storage; prepared CLV transfer is preserved exactly."
		else:
			info.text = "分块 Bake：%d 个管理页，%d 个烘焙点；已驻留 %d，加载中 %d。CPU %.1f / %.0f MiB；GPU 估算 %.1f / %.0f MiB；上传预算 %.0f MiB/帧。" % [
				page_count, volume.saved_probe_count(), int(stream.get("resident_pages", 0)), int(stream.get("loading_pages", 0)),
				float(cpu_current) / 1048576.0, float(volume.cpu_resident_budget_bytes) / 1048576.0,
				float(gpu_current) / 1048576.0, float(volume.gpu_resident_budget_bytes) / 1048576.0,
				float(volume.upload_budget_bytes_per_frame) / 1048576.0]
		if volume.is_baking():
			if volume.uses_free_space_clv_bake():
				info.text += "\nFree-space bake: %s (%d / %d cells)." % [
					volume.free_space_bake_stage(), progress.x, progress.y]
			else:
				info.text += "\n烘焙进度：%d / %d 页。" % [progress.x, progress.y]
		if volume.needs_rebake():
			info.text += "\n当前场景或设置与这份 Bake 不匹配；仍保留可用的旧结果。"
		var stream_warning := String(stream.get("warning", ""))
		if not stream_warning.is_empty():
			info.text += "\n" + stream_warning
	elif volume.has_bake() and volume.bake_data != null and not volume.needs_rebake():
		info.text = "%d surface samples baked with %d rays/point (randomized QMC sampler r%d, bake v%d)." % [
			volume.bake_data.probe_count(), volume.bake_data.bake_samples,
			Data.SAMPLER_REVISION, volume.bake_data.bake_version]
		if not volume.has_nonzero_indirect_transfer():
			info.text += "\n" + Volume.ZERO_TRANSFER_DIAGNOSTIC
	elif volume.bake_data != null and volume.has_usable_bake() and volume.needs_rebake():
		var details := "; ".join(volume.bake_staleness_reasons())
		info.text = "当前显示上次烘焙，仅供预览；场景或烘焙设置已变化，请重新 Bake。\n%d 个采样点，烘焙 %d rays/point，当前设置 %d rays/point。\n%s" % [
			volume.bake_data.probe_count(), volume.bake_data.bake_samples, volume.bake_samples, details]
	elif volume.bake_data != null and not volume.has_usable_bake():
		info.text = "Bake 数据无效或不完整，Magic GI 不会使用它。请重新 Bake。"
	elif volume.bake_data != null:
		info.text = "正在检查场景与上次 Bake 的匹配状态…"
	elif volume.uses_free_space_clv_bake():
		var dims := volume.grid_dimensions()
		var source_cells := dims.x * dims.y * dims.z
		info.text = "No free-space CLV PRT source yet: %d regular .25 m cells, %d transport rays/cell, 256 minimum visibility-moment rays/cell." % [
			source_cells, volume.bake_samples]
	else:
		var point_count := volume.candidate_probe_count() if volume.candidate_probe_count() > 0 else volume.probe_count()
		info.text = "No bake yet: %d surface points, %.2f m spacing, %d rays/point." % [
			point_count, volume.probe_spacing, volume.bake_samples]
	if volume.is_refreshing() and not volume.uses_free_space_clv_bake():
		info.text += "\n" + volume.surface_refresh_progress() + "."
	elif not volume.uses_free_space_clv_bake() and volume.candidate_probe_count() > 0:
		info.text += "\n已采集 %d 个候选表面点%s。" % [volume.candidate_probe_count(),
			"（设置变化后已过期）" if not volume.is_candidate_layout_current() else ""]
	_update_controls(volume, ui)
	var runtime_info: Label = ui.get("runtime_info")
	if is_instance_valid(runtime_info):
		_update_runtime_status(volume, runtime_info)

func _update_runtime_status(volume: FMagicGIVolume, info: Label) -> void:
	if not is_instance_valid(volume) or not is_instance_valid(info):
		return
	if volume.is_surfel_mode() or volume.clv_cache_backend != 1:
		info.visible = false
		info.text = ""
		return
	info.visible = true
	if volume.uses_free_space_clv_bake():
		if not volume.has_free_space_source_generation() or volume.bake_manifest == null \
				or not volume.bake_manifest.is_valid():
			info.text = "Free-space CLV Block PRT is selected; bake a regular .25 m TransferMatrix source volume. Legacy surface pages and baked indirect SH are not converted automatically."
			return
		if volume.needs_rebake():
			info.text = "Free-space CLV source is stale. Runtime dynamic relighting is not reported active; run a full free-space CLV PRT Bake."
			return
		var state := _magic_gi_runtime_state(volume)
		var status := String(state.get("status", "no_runtime_state"))
		var renderer_active := bool(state.get("renderer_path_active", false))
		var resident_cells := int(state.get("resident_cells", 0))
		if str(state.get("backend", "")) in ["preinterpolated_clv_transfer", "paged_preinterpolated_clv_transfer"]:
			info.text = "CLV PRT: .25 m finest spacing; %d levels of %d³; %d valid cells / %d resident slots; GPU relight revision %d; renderer %s; status=%s." % [
				int(state.get("resident_levels", 0)), int(state.get("clipmap_resolution", 16)),
				int(state.get("valid_resident_cells", 0)), resident_cells,
				int(state.get("relight_serial", 0)), "active" if renderer_active else "not confirmed", status]
			info.text += "\nCapacity: Magic GI pass > Prepared CLV Resolution. Windows scroll with camera position, independently of view direction."
			if str(state.get("backend", "")) == "paged_preinterpolated_clv_transfer":
				info.text += "\nRadius %.0f m; loaded bricks %d; upload last %.2f MiB. Upload threshold is diagnostic, not a per-frame throttle." % [
					float(state.get("gi_radius_m", 512)), int(state.get("loaded_bricks", 0)),
					float(state.get("uploaded_operator_bytes_last_update", 0)) / 1048576.0]
			return
		var revision := int(state.get("relight_lighting_revision", -1))
		var pending := int(state.get("geometry_pending_blocks", state.get("pending_blocks", 0)))
		info.text = "Free-space CLV Block PRT: source generation valid (%d cells); renderer path %s; resident %d; relight revision %d; geometry pending %d; status=%s. Runtime state confirms routing, not per-pixel sample coverage." % [
			volume.saved_probe_count(), "active" if renderer_active else "not confirmed",
			resident_cells, revision, pending, status]
		return
	if volume.bake_data == null or not volume.has_usable_bake():
		info.text = "MagicDawn CLV Block PRT is selected, but no usable local PRT bake is available."
		return
	if volume.needs_rebake():
		info.text = "Bake data is stale. Dynamic CLV PRT is not reported active; run a full PRT Bake after resolving the shown stale-data reasons."
		return
	var probe_count := volume.bake_data.probe_count()
	var source_count := volume.bake_data.emitter_count()
	var directional: Resource = volume.bake_data.directional
	var directional_data := directional as DirectionalData
	if directional_data == null or not directional_data.is_valid(probe_count, source_count):
		info.text = "The selected backend requires a valid data.directional revision-1 TransferMatrix. This older bake is not converted from baked indirect SH; run a full local PRT Bake."
		return
	var state := _magic_gi_runtime_state(volume)
	var model := String(state.get("prt_model", ""))
	var status := String(state.get("status", "no_runtime_state"))
	var relight_serial := int(state.get("relight_serial", 0))
	if model != "CLV_BLOCK_RELIGHT" or relight_serial <= 0:
		info.text = "TransferMatrix ready (SH degree 0–2, 9 real orthonormal coefficients); CLV Block PRT is configured but a resident relight is not confirmed. status=%s" % status
		return
	var lighting_revision := int(state.get("lighting_revision", 0))
	var completed_revision := int(state.get("relight_lighting_revision", -1))
	var relight_pending := bool(state.get("relight_pending", true))
	var pending_blocks := int(state.get("geometry_pending_blocks", state.get("pending_blocks", -1)))
	var resident_faces := int(state.get("resident_face_slots", state.get("last_relight_faces", 0)))
	var last_gpu_ms := float(state.get("last_relight_gpu_ms", 0.0))
	var relight_state := "dispatch pending" if relight_pending or completed_revision < lighting_revision else "dispatch submitted"
	info.text = "Dynamic MagicDawn CLV Block PRT (%s): lighting revision %d, submitted %d, resident face slots %d, relight #%d; geometry blocks pending %d; last relight %.3f ms. SH degree 0–2, 9 real orthonormal coefficients; cell spacing %.2f m." % [
		relight_state, lighting_revision, completed_revision, resident_faces, relight_serial,
		pending_blocks, last_gpu_ms, volume.clv_cell_size]

func _magic_gi_runtime_state(volume: FMagicGIVolume) -> Dictionary:
	var renderer: Object = _scene_renderer(volume)
	if renderer == null:
		renderer = _renderer_from_compositor(ProjectPipeline.resolve())
	if renderer == null or not renderer.has_method("get"):
		return {"status": "frp_renderer_unavailable"}
	var passes: Variant = renderer.get("passes")
	if not passes is Array:
		return {"status": "frp_pass_list_unavailable"}
	for pass_entry in passes:
		if pass_entry is MagicGIPass and pass_entry.has_method("get_magicdawn_runtime_state"):
			return pass_entry.get_magicdawn_runtime_state()
	return {"status": "magic_gi_pass_missing"}

func _scene_renderer(volume: FMagicGIVolume) -> Object:
	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null and volume.is_inside_tree():
		root = volume.get_tree().edited_scene_root
	if root == null:
		return null
	var cameras := root.find_children("*", "Camera3D", true, false)
	if root is Camera3D:
		cameras.push_front(root)
	for camera in cameras:
		if camera.current:
			var renderer := _renderer_from_compositor(camera.get("compositor"))
			if renderer != null:
				return renderer
	var environments := root.find_children("*", "WorldEnvironment", true, false)
	if root is WorldEnvironment:
		environments.push_front(root)
	for environment in environments:
		var renderer := _renderer_from_compositor(environment.get("compositor"))
		if renderer != null:
			return renderer
	return null

func _renderer_from_compositor(compositor: Object) -> Object:
	if compositor == null or not is_instance_valid(compositor) or not compositor.has_method("get"):
		return null
	var renderer: Variant = compositor.get("renderer")
	return renderer if renderer is Resource else null

func _update_controls(volume: FMagicGIVolume, ui: Dictionary) -> void:
	var prt_visible := not volume.is_surfel_mode()
	var source_bake := volume.uses_free_space_clv_bake()
	var runtime_info: Label = ui.get("runtime_info")
	if is_instance_valid(runtime_info):
		runtime_info.visible = prt_visible and volume.clv_cache_backend == 1
	var bake_row: HBoxContainer = ui.get("bake_row")
	if is_instance_valid(bake_row):
		bake_row.visible = prt_visible
	var quality_label: Label = ui.get("quality_label")
	if is_instance_valid(quality_label):
		quality_label.visible = prt_visible
		quality_label.text = "Bake quality (transport rays per source cell)" if source_bake \
				else "Bake quality (rays per surface point)"
	var quality: OptionButton = ui.get("quality")
	if is_instance_valid(quality):
		quality.visible = prt_visible
	var refresh: Button = ui.get("refresh_button")
	if is_instance_valid(refresh):
		refresh.visible = prt_visible
	if not prt_visible:
		var chunk_row: HBoxContainer = ui.get("chunk_row")
		if is_instance_valid(chunk_row):
			chunk_row.visible = false
		return
	var baking := volume.is_baking()
	var refreshing := volume.is_refreshing()
	var cancel_requested := volume.is_bake_cancel_requested()
	var bake_button: Button = ui.get("bake_button")
	if is_instance_valid(bake_button):
		var default_bake_label := "Bake Streamed PRT" if volume.chunked_baking else "Bake PRT Transfer"
		if volume.uses_free_space_clv_bake():
			default_bake_label = "Bake Free-space CLV PRT"
		bake_button.text = "Baking..." if baking else default_bake_label
		bake_button.disabled = baking
	var cancel_button: Button = ui.get("cancel_button")
	if is_instance_valid(cancel_button):
		cancel_button.visible = baking or refreshing
		cancel_button.disabled = cancel_requested or not (baking or refreshing)
		cancel_button.text = "Canceling..." if cancel_requested else ("Cancel Refresh" if refreshing and not baking else "Cancel Bake")
	quality = ui.get("quality")
	if is_instance_valid(quality):
		quality.disabled = baking
	var chunk_row: HBoxContainer = ui.get("chunk_row")
	if is_instance_valid(chunk_row):
		chunk_row.visible = volume.chunked_baking and not volume.uses_free_space_clv_bake()
		var chunk_label := chunk_row.get_child(0) as Label
		if chunk_label != null:
			chunk_label.text = "Chunk X/Z · %.0f m" % volume.management_block_size
	var chunk_button: Button = ui.get("chunk_button")
	if is_instance_valid(chunk_button):
		chunk_button.disabled = baking or not volume.chunked_baking or volume.uses_free_space_clv_bake()
	refresh = ui.get("refresh_button")
	if is_instance_valid(refresh):
		refresh.visible = not volume.uses_free_space_clv_bake()
		refresh.disabled = baking or volume.uses_free_space_clv_bake()
		refresh.text = "Refresh Again" if refreshing else "Refresh Surface Points"

func _disconnect_status_callback(volume: FMagicGIVolume, callback: Callable) -> void:
	if is_instance_valid(volume) and volume.bake_status_changed.is_connected(callback):
		volume.bake_status_changed.disconnect(callback)

func _on_bake_pressed(volume: FMagicGIVolume, ui: Dictionary) -> void:
	if not is_instance_valid(volume) or volume.is_baking():
		return
	var info: Label = ui.get("info")
	if is_instance_valid(info):
		_update_status(volume, info, ui)
	var ok: bool = await volume.bake()
	if not is_instance_valid(volume):
		return
	if ok:
		EditorInterface.mark_scene_as_unsaved()
	if is_instance_valid(info):
		_update_status(volume, info, ui)
	EditorInterface.inspect_object(volume)

func _on_chunk_bake_pressed(volume: FMagicGIVolume, chunk_x: SpinBox,
		chunk_z: SpinBox, ui: Dictionary) -> void:
	if not is_instance_valid(volume) or volume.is_baking():
		return
	var info: Label = ui.get("info")
	var ok: bool = await volume.bake_chunk(roundi(chunk_x.value), roundi(chunk_z.value))
	if not is_instance_valid(volume):
		return
	if ok:
		EditorInterface.mark_scene_as_unsaved()
	if is_instance_valid(info):
		_update_status(volume, info, ui)
	EditorInterface.inspect_object(volume)
