@tool
class_name FOLVVolume
extends Node3D
## One OLV child per MagicGI volume; classification data updates independently.
const Data = preload("feng_olv_data.gd")
const Runner = preload("../feng-magic-gi/feng_magic_gi_olv_inference_runner.gd")
const SourceBaker = preload("../feng-magic-gi/feng_magic_gi_volume_source_baker.gd")
const Placement = preload("../feng-magic-gi/feng_magic_gi_placement.gd")
const Payload = preload("../feng-magic-gi/feng_magic_gi_olv_probe_domain_payload.gd")
const Tracker = preload("../feng-magic-gi/feng_magic_gi_scene_tracker.gd")
# Linear colors shared with MagicGI's OLV domain debug shaders.
const INTERIOR_DEBUG_COLOR := Color(0.08, 0.62, 1.0)
const EXTERIOR_DEBUG_COLOR := Color(1.0, 0.42, 0.08)
enum SelectionMode { REPLACE, ADD, TOGGLE }
enum ProbeFilter { ALL, OUTDOOR, INDOOR }

static func probe_display_color(label: int) -> Color:
	if label not in [1,2]: return Color(0.5,0.5,0.5)
	var linear := INTERIOR_DEBUG_COLOR if label == 2 else EXTERIOR_DEBUG_COLOR
	# Match MagicGI Debug's default ACES + sRGB display, independent of exposure.
	var value := Vector3(linear.r,linear.g,linear.b)
	value = (value*(2.51*value+Vector3.ONE*0.03))/(value*(2.43*value+Vector3.ONE*0.59)+Vector3.ONE*0.14)
	return Color(value.x,value.y,value.z).linear_to_srgb()

signal status_changed
signal selection_changed

@export var enabled := true:
	set(value):
		if enabled == value: return
		enabled = value
		_publish()
@export_dir var model_directory := "res://addons/feng-olv/model":
	set(value):
		if model_directory == value: return
		model_directory = value
		if is_inside_tree():
			status = "模型已更换，可独立更新 OLV；当前标签继续使用"
			status_changed.emit()
@export_storage var data: FOLVData:
	set(value):
		data = value
		_probe_view_key = ""
		_publish()
@export_file("*.res", "*.tres") var data_path := ""
@export var show_probes := true:
	set(value):
		if show_probes == value: return
		show_probes = value
		status_changed.emit()
@export_enum("全部", "仅室外", "仅室内") var probe_filter: int = ProbeFilter.ALL:
	set(value):
		probe_filter = clampi(value,0,2)
		clear_probe_selection()
		status_changed.emit()
@export var xray_probes := false:
	set(value):
		xray_probes = value
		clear_probe_selection()
		status_changed.emit()
@export_group("空间批量框")
@export var show_batch_box := false
@export var limit_to_batch_box := false:
	set(value):
		limit_to_batch_box = value
		if value: show_batch_box = true
		clear_probe_selection()
		status_changed.emit()
@export var batch_center := Vector3.ZERO
@export var batch_size := Vector3.ONE:
	set(value):
		batch_size = value.abs().max(Vector3.ONE * 0.001)

var selected_probes := PackedInt32Array()
var busy := false
var progress_done := 0
var progress_total := 0
var status := "尚未烘焙 OLV"
var last_error := ""
var _cancelled := false
var _runner: RefCounted
var _cached_source: Resource
var _cached_source_key := ""
var _source_load_error := ""
var _runtime_binding_key := ""
var _runtime_binding_cache: Dictionary = {}
var _probe_view_key := ""
var _probe_view: Dictionary = {}
var _probe_visibility: RefCounted
var _filtered_view_key := ""
var _filtered_view: Dictionary = {}

func _validate_property(property: Dictionary) -> void:
	if String(property.name) == "enabled": property.usage = PROPERTY_USAGE_STORAGE

func _ready() -> void:
	var warnings := _get_configuration_warnings()
	if not warnings.is_empty():
		status = warnings[0]
		update_configuration_warnings()
		return
	if data != null:
		status = "OLV 已加载 · %d 个手工标记" % data.overrides.size()
		if Engine.is_editor_hint() and FileAccess.get_sha256(model_directory.path_join("inference_manifest.json")) != data.model_bundle_sha256:
			status = "模型已变化，可独立更新 OLV；当前标签继续使用"
	var volume := get_source_volume()
	if volume != null and not volume.is_connected("bake_status_changed",_on_source_status_changed):
		volume.connect("bake_status_changed",_on_source_status_changed)
	_on_source_status_changed()
	_publish.call_deferred()

func _on_source_status_changed() -> void:
	if busy: return
	var volume := get_source_volume()
	if volume == null or bool(volume.call("is_baking")): return
	if data == null:
		status_changed.emit()
		return
	var manifest: Resource = volume.get("bake_manifest")
	if manifest == null or not data.matches_manifest(manifest):
		status = "GI 源数据已变化，请独立更新 OLV 标签"
		status_changed.emit()

func get_source_volume() -> Node3D:
	var node := get_parent()
	if node == null or not node.has_method("_load_active_source_page") or not node.has_method("get_olv_controller"):
		return null
	# A duplicated component cannot publish or edit the parent's labels.
	return node as Node3D if node.call("get_olv_controller") == self else null

func _get_configuration_warnings() -> PackedStringArray:
	var parent := get_parent()
	if parent == null or not parent.has_method("_load_active_source_page") or not parent.has_method("get_olv_controller"):
		return PackedStringArray(["OLV 必须作为 MagicGI Volume 的直接子节点；请从 MagicGI 面板打开 OLV。"])
	if parent.call("get_olv_controller") != self:
		return PackedStringArray(["每个 MagicGI Volume 只使用一个 OLV；该重复节点不会生效，请使用已有 OLV 节点。"])
	return PackedStringArray()

func get_probe_source() -> Resource:
	var volume := get_source_volume()
	if volume == null: return null
	var manifest: Resource = volume.get("bake_manifest")
	var path := manifest.resource_path if manifest != null else ""
	var key := str([path, manifest.get_instance_id() if manifest != null else 0,
		volume.global_transform, volume.size, volume.clv_cell_size,SourceBaker.ProbeExclusion.capture(volume)])
	if _cached_source != null and key == _cached_source_key: return _cached_source
	var loaded: Dictionary = volume.call("_load_active_source_page")
	_source_load_error = String(loaded.get("error", ""))
	_cached_source = loaded.get("source") if bool(loaded.get("ok", false)) else null
	_cached_source_key = key
	_probe_view_key = ""
	if not selected_probes.is_empty():
		selected_probes.clear()
		selection_changed.emit()
	return _cached_source

# Editor-only callers use the complete retained source, including every LOD of
# a paged bake. No camera/CLV residency culling or arbitrary display limit.
func get_probe_view() -> Dictionary:
	var source := get_probe_source()
	if source == null: return {}
	var key := "%d:%d" % [source.get_instance_id(), data.get_instance_id() if data != null else 0]
	if key == _probe_view_key: return _probe_view
	var labels := _labels_for_source(source)
	var positions := PackedVector3Array()
	var indices := PackedInt32Array()
	var classes := PackedByteArray()
	var counts := PackedInt32Array([0, 0, 0])
	for index in source.probe_count:
		if not source.cell_is_valid(index): continue
		var label := int(labels[index]) if index < labels.size() else 0
		if label not in [1, 2]: label = 0
		positions.append(source.cell_position(index))
		indices.append(index)
		classes.append(label)
		counts[label] += 1
	_probe_view = {"positions": positions, "indices": indices, "labels": classes,
		"counts": counts, "slot_count": source.probe_count}
	_probe_view_key = key
	return _probe_view

func get_filtered_probe_view() -> Dictionary:
	var view := get_probe_view()
	if view.is_empty() or (probe_filter == ProbeFilter.ALL and not limit_to_batch_box): return view
	var key := str([_probe_view_key,probe_filter,limit_to_batch_box,global_transform,batch_center,batch_size])
	if key == _filtered_view_key: return _filtered_view
	var result := {"positions":PackedVector3Array(),"indices":PackedInt32Array(),"labels":PackedByteArray()}
	var inverse := global_transform.affine_inverse()
	var box := AABB(batch_center-batch_size*0.5,batch_size)
	for i in view.indices.size():
		if probe_filter != ProbeFilter.ALL and view.labels[i] != probe_filter: continue
		if limit_to_batch_box and not box.has_point(inverse*view.positions[i]): continue
		result.positions.append(view.positions[i])
		result.indices.append(view.indices[i])
		result.labels.append(view.labels[i])
	_filtered_view_key = key
	_filtered_view = result
	return result

func get_visible_probe_view(camera: Camera3D) -> Dictionary:
	if _probe_visibility == null:
		_probe_visibility = load("res://addons/feng-olv/editor/olv_probe_visibility.gd").new()
	var view := get_filtered_probe_view()
	return _probe_visibility.visible_view(self,camera,view,str([_probe_view_key,probe_filter,
		limit_to_batch_box,global_transform,batch_center,batch_size]))

func _labels_for_source(source: Resource) -> PackedByteArray:
	var volume := get_source_volume()
	if data != null and volume != null and volume.bake_manifest != null \
			and data.matches_manifest(volume.bake_manifest) and data.payload != null \
			and data.payload.labels.size() == source.probe_count:
		return data.payload.labels
	if source.olv_probe_domain_payload != null:
		return source.olv_probe_domain_payload.labels
	return PackedByteArray()

func _publish() -> void:
	if not is_inside_tree(): return
	var volume := get_source_volume()
	if volume != null and volume.has_method("olv_data_changed"):
		volume.call("olv_data_changed")
	status_changed.emit()

func runtime_binding() -> Dictionary:
	if not enabled or data == null or data.payload == null or data.label_set == null:
		return {"managed": true, "enabled": false}
	var volume := get_source_volume()
	if volume == null: return {"managed": true, "enabled": false}
	var manifest: Resource = volume.get("bake_manifest")
	if manifest == null: return {"managed": true, "enabled": false}
	var key := "%d:%s:%d:%s" % [manifest.get_instance_id(),manifest.generation,data.get_instance_id(),data.label_set.labels_hash]
	if key != _runtime_binding_key:
		_runtime_binding_key = key
		_runtime_binding_cache = data.runtime_binding()
		# The exact source layout is checked when this sidecar is created. At
		# runtime its sealed payload and immutable GI generation are sufficient;
		# no debug source page, model or training data is loaded for this check.
		_runtime_binding_cache["source_binding_valid"] = data.matches_manifest(manifest) \
			and bool(data.payload.validate_seal(String(data.label_set.labels_hash)).get("ok",false))
		_runtime_binding_cache["manifest_instance_id"] = manifest.get_instance_id()
	return _runtime_binding_cache

func cancel() -> void:
	_cancelled = true
	status = "正在取消…"
	status_changed.emit()

func _is_cancelled() -> bool:
	return _cancelled or not is_inside_tree()

func _progress(stage: String, completed: int, total: int, _batch: int, _batches: int) -> void:
	status = stage
	progress_done = completed
	progress_total = total
	status_changed.emit()

func _error(message: String) -> bool:
	last_error = message
	status = message
	busy = false
	status_changed.emit()
	return false

func _context(source: Resource) -> Dictionary:
	return SourceBaker.make_olv_layout_context(get_source_volume(), source.geometry_signature,
		source.origin_world, source.dimensions,
		int(source.prepared_level_count) if source.has_method("olv_cell_lod") else 4,
		-1, float(source.spacing_m))

func import_existing_labels() -> bool:
	if busy: return false
	var source := get_probe_source()
	var volume := get_source_volume()
	if source == null or volume == null:
		return _error("请先烘焙 MagicGI 的 Probe 传输数据")
	if source.olv_probe_domain_payload == null:
		return _error("当前 GI 没有旧 OLV 标签，请点击「烘焙 / 更新 OLV 标签」")
	var payload: Resource = source.olv_probe_domain_payload
	if not bool(payload.validate_for_source(source).get("ok", false)):
		return _error("原 OLV 标签与当前 Probe 不匹配")
	var asset := Data.new()
	asset.automatic_labels = payload.labels.duplicate()
	asset.inference_metadata = SourceBaker._retained_olv_metadata(source, _context(source))
	asset.model_bundle_sha256 = payload.model_sha256
	asset.source_layout_sha256 = payload.source_layout_sha256
	return _bind_and_save(asset, source)

func update_labels(force_inference := true) -> bool:
	if busy: return false
	var volume := get_source_volume()
	if volume != null and volume.bake_manifest != null \
			and not is_equal_approx(volume.clv_cell_size, volume.bake_manifest.prepared_source_spacing_m):
		return _error("Probe 间距已从 %s m 改为 %s m；请先烘焙 GI，再更新 OLV。OLV 自动使用 GI 的 Probe，不需要另设密度。" % [
			str(volume.bake_manifest.prepared_source_spacing_m), str(volume.clv_cell_size)])
	var source := get_probe_source()
	if volume == null or not bool(volume.call("has_bake")):
		return _error("请先为当前场景完成 GI 传输烘焙；换 OLV 模型不需要重烘焙 GI")
	if source == null: return _error("OLV Probe 布局不可用：" + _source_load_error)
	if bool(volume.call("is_baking")): return _error("GI 正在烘焙，请完成后更新 OLV")
	busy = true
	_cancelled = false
	last_error = ""
	progress_done = 0
	progress_total = 0
	status = "正在更新 OLV…"
	status_changed.emit()
	var bundle_sha := FileAccess.get_sha256(model_directory.path_join("inference_manifest.json"))
	if bundle_sha.is_empty(): return _error("选择的模型缺少 inference_manifest.json")
	var binding: Dictionary = Payload.source_binding(source)
	if not bool(binding.get("ok", false)): return _error("Probe 数据绑定无效")
	if not force_inference and data != null and data.source_layout_sha256 == binding.source_layout_sha256 \
			and data.model_bundle_sha256 == bundle_sha:
		return _bind_and_save(data.duplicate(true), source)
	var watch := Tracker.stable_scene_signature(volume)
	var geometry := Placement.new()
	if not geometry.collect(volume, true, true, true, false,
			source.source_bounds_world.grow(maxf(source.trace_distance_m * (source.bake_bounces + 1), 8.1875))) \
			or Payload.sha256_bytes(geometry.faces.to_byte_array()) != source.geometry_triangles_sha256:
		return _error("场景几何已改变；保留原标签，请先更新 GI 传输")
	var started: Dictionary = await Runner.begin_bake(Callable(self,"_progress"), Callable(self,"_is_cancelled"), model_directory, bundle_sha)
	if not bool(started.get("ok", false)): return _error(String(started.get("error", "模型启动失败")))
	_runner = started.runner
	var inferred: Dictionary = await _runner.infer_source(source, geometry, _context(source), Callable(self,"_progress"), Callable(self,"_is_cancelled"))
	await _runner.close()
	_runner = null
	if _is_cancelled(): return _error("已取消，原标签保留")
	if not bool(inferred.get("ok", false)): return _error(String(inferred.get("error", "OLV 推理失败")))
	if watch != Tracker.stable_scene_signature(volume): return _error("场景已变化，原标签保留")
	var asset := Data.new()
	asset.automatic_labels = inferred.labels
	asset.inference_metadata = inferred.metadata
	asset.model_bundle_sha256 = bundle_sha
	asset.source_layout_sha256 = binding.source_layout_sha256
	# Sparse manual edits survive model updates only on the exact same lattice.
	if data != null and data.source_layout_sha256 == asset.source_layout_sha256:
		asset.overrides = data.overrides.duplicate(true)
	return _bind_and_save(asset, source)

func set_probe_overrides(values: Dictionary, expected_layout := "") -> bool:
	if busy: return false
	if data == null and not import_existing_labels(): return false
	if not expected_layout.is_empty() and data.source_layout_sha256 != expected_layout:
		return _error("这次编辑属于旧 Probe 布局，未修改当前标签")
	var source := get_probe_source()
	if source == null: return _error("没有可编辑的 Probe 数据")
	var asset := data.duplicate(true) as FOLVData
	asset.overrides = values.duplicate(true)
	return _bind_and_save(asset, source)

func overrides_for_selection(label: int) -> Dictionary:
	var values := data.overrides.duplicate(true) if data != null else {}
	for index in selected_probes:
		if label == 0: values.erase(index)
		else: values[index] = label
	return values

func _bind_and_save(asset: FOLVData, source: Resource) -> bool:
	var binding: Dictionary = Payload.source_binding(source)
	if not bool(binding.get("ok", false)) or asset.source_layout_sha256 != binding.source_layout_sha256:
		return _error("OLV 数据属于另一套 Probe；原数据保留")
	if asset.automatic_labels.size() != source.probe_count: return _error("OLV 标签数量不匹配")
	var labels := asset.automatic_labels.duplicate()
	for key: Variant in asset.overrides:
		if not key is int or key < 0 or key >= source.probe_count or not source.cell_is_valid(key) \
				or int(asset.overrides[key]) not in [1,2]:
			return _error("手工标签包含无效 Probe 或非室内/室外类别")
		labels[key] = int(asset.overrides[key])
	var context := _context(source)
	var inferred := {"labels": labels, "metadata": asset.inference_metadata.duplicate(true), "result": {}}
	# Bind on a shallow temporary source; transfer arrays and the GI asset are untouched.
	var transient := source.duplicate(false)
	var result: Dictionary = SourceBaker.new().bind_olv_result(transient, inferred, context)
	if not bool(result.get("ok", false)): return _error(String(result.get("error", "标签绑定失败")))
	asset.payload = transient.olv_probe_domain_payload
	asset.label_set = result.label_set
	asset.layout_context = get_source_volume().call("_manifest_olv_context", result.layout_context, result.label_set)
	asset.gi_manifest_signature = Data.manifest_signature(get_source_volume().get("bake_manifest"))
	asset.gi_bake_model_sha256 = String(source.olv_probe_domain_payload.model_sha256) if source.olv_probe_domain_payload != null else ""
	var output := data_path
	if output.is_empty():
		output = "res://bake/olv/%08x/domains.res" % (hash([get_source_volume().get_path(),get_tree().current_scene.scene_file_path if get_tree().current_scene != null else get_tree().edited_scene_root.scene_file_path]) & 0xffffffff)
	if not output.begins_with("res://"): return _error("OLV 数据必须保存在项目内")
	if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output.get_base_dir())) != OK:
		return _error("无法创建 OLV 数据目录")
	var staged := output.get_basename() + ".pending." + output.get_extension()
	var previous_uid := ResourceLoader.get_resource_uid(output) if FileAccess.file_exists(output) else -1
	if ResourceSaver.save(asset, staged) != OK: return _error("OLV 数据写入失败，原结果保留")
	var saved_uid := ResourceLoader.get_resource_uid(staged)
	if previous_uid >= 0 and saved_uid != previous_uid:
		if ResourceSaver.set_uid(staged, previous_uid) != OK:
			return _error("OLV 资源标识写入失败，原结果保留")
		if saved_uid >= 0 and ResourceUID.has_id(saved_uid): ResourceUID.remove_id(saved_uid)
		saved_uid = previous_uid
	if DirAccess.rename_absolute(ProjectSettings.globalize_path(staged), ProjectSettings.globalize_path(output)) != OK:
		return _error("OLV 数据发布失败，原结果保留")
	if saved_uid >= 0:
		if ResourceUID.has_id(saved_uid): ResourceUID.set_id(saved_uid,output)
		else: ResourceUID.add_id(saved_uid,output)
	asset.take_over_path(output)
	data_path = output
	data = asset
	busy = false
	status = "OLV 更新完成 · %d 个手工标记" % asset.overrides.size()
	progress_done = labels.size()
	progress_total = labels.size()
	_publish()
	return true

func probe_label(index: int) -> int:
	var source := get_probe_source()
	var labels := _labels_for_source(source) if source != null else PackedByteArray()
	return int(labels[index]) if index >= 0 and index < labels.size() else 0

func select_probe(index: int, append := false) -> void:
	select_probes(PackedInt32Array([index]), SelectionMode.TOGGLE if append else SelectionMode.REPLACE)

func select_probes(indices: PackedInt32Array, mode := SelectionMode.REPLACE) -> void:
	var source := get_probe_source()
	if source == null: return
	var values := {}
	if mode != SelectionMode.REPLACE:
		for index in selected_probes:
			if source.cell_is_valid(index): values[index] = true
	var seen := {}
	for index in indices:
		if not source.cell_is_valid(index) or seen.has(index): continue
		seen[index] = true
		if mode == SelectionMode.TOGGLE and values.has(index): values.erase(index)
		else: values[index] = true
	selected_probes = PackedInt32Array(values.keys())
	selected_probes.sort()
	selection_changed.emit()

func clear_probe_selection() -> void:
	selected_probes.clear()
	selection_changed.emit()

func select_all_probes() -> void:
	var view := get_filtered_probe_view()
	select_probes(view.get("indices", PackedInt32Array()))

func pick_probe(camera: Camera3D, screen_position: Vector2, radius := 12.0) -> int:
	var view := get_visible_probe_view(camera)
	var positions: PackedVector3Array = view.get("positions", PackedVector3Array())
	var indices: PackedInt32Array = view.get("indices", PackedInt32Array())
	var nearest := -1
	var best := radius * radius
	var nearest_depth := INF
	var camera_transform := camera.get_camera_transform()
	for i in positions.size():
		var point := positions[i]
		var view_depth := -camera_transform.basis.z.dot(point-camera_transform.origin)
		if view_depth < camera.near or view_depth > camera.far: continue
		var distance := camera.unproject_position(point).distance_squared_to(screen_position)
		var depth := camera_transform.origin.distance_squared_to(point)
		if distance < best - 0.01 or (absf(distance - best) < 0.01 and depth < nearest_depth):
			best = distance
			nearest_depth = depth
			nearest = indices[i]
	return nearest

func select_screen_rect(camera: Camera3D, screen_rect: Rect2, mode := SelectionMode.REPLACE) -> void:
	var view := get_visible_probe_view(camera)
	var positions: PackedVector3Array = view.get("positions", PackedVector3Array())
	var indices: PackedInt32Array = view.get("indices", PackedInt32Array())
	var selected := PackedInt32Array()
	var rect := screen_rect.abs()
	var camera_transform := camera.get_camera_transform()
	for i in positions.size():
		var view_depth := -camera_transform.basis.z.dot(positions[i]-camera_transform.origin)
		if view_depth >= camera.near and view_depth <= camera.far and rect.has_point(camera.unproject_position(positions[i])):
			selected.append(indices[i])
	select_probes(selected, mode)

func select_in_box() -> void:
	var source := get_probe_source()
	if source == null: return
	var selected := PackedInt32Array()
	var inverse := global_transform.affine_inverse()
	var box := AABB(batch_center - batch_size*0.5,batch_size)
	for index in get_filtered_probe_view().get("indices",PackedInt32Array()):
		if source.cell_is_valid(index) and box.has_point(inverse * source.cell_position(index)):
			selected.append(index)
	select_probes(selected)
