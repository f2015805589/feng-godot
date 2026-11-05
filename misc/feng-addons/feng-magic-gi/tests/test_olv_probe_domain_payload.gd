extends SceneTree
## Contract tests for the optional one-byte-per-source-probe OLV sidecar and
## its offline CLV-preinterpolation gate. No classifier or runtime shader runs.

const Chunk = preload("../feng_magic_gi_volume_source_chunk.gd")
const Payload = preload("../feng_magic_gi_olv_probe_domain_payload.gd")
const Labels = preload("../feng_magic_gi_olv_label_set.gd")
const Domain = preload("../feng_magic_gi_olv_domain.gd")
const Inference = preload("../feng_magic_gi_olv_inference_runner.gd")

const SCENE_ID := "res://tests/olv_probe_payload_fixture.tscn"
const VOLUME_ID := "OLVProbePayloadFixture"
const LAYOUT_REVISION := 7
const LAYOUT_SIGNATURE := "free-space-clv-fixture-layout-v1"
var _geometry_sha := ""
var _model_sha := ""
var _feature_sha := ""

class EmptyBvh:
	extends RefCounted
	func intersect_segment(_from: Vector3, _to: Vector3) -> Dictionary:
		return {}

class GeometryStub:
	extends RefCounted
	var bvh := EmptyBvh.new()
	var bvh_ready := true

var _checks := 0
var _failures := 0
var BuilderScript: Script


func _initialize() -> void:
	call_deferred("_run")


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("REGRESSION: " + message)


func _run() -> void:
	_geometry_sha = "a4".repeat(32)
	_model_sha = "b5".repeat(32)
	_feature_sha = "c6".repeat(32)
	BuilderScript = load("res://addons/feng-magic-gi/feng_magic_gi_clv_transfer_builder.gd") as Script
	_check(BuilderScript != null, "the existing CLV preinterpolator parses for the optional OLV gate")
	if BuilderScript == null:
		_finish()
		return
	var source := _valid_source()
	_check(source.is_source_data_valid(), "the source fixture is a valid regular free-space chunk")
	_check(source.make_clv_preparation_signature() == source.directional_source_signature,
			"legacy preinterpolation cache signature is unchanged without an OLV asset")
	var labels := _target_labels(source)
	var payload := _new_payload(source, PackedByteArray([1, 2, 1]), labels)
	_check(payload != null, "one byte per logical source probe configures with explicit bindings")
	if payload == null:
		_finish()
		return
	source.olv_probe_domain_payload = payload
	_check(payload.labels.size() == source.probe_count and payload.label_for_logical_probe(1) == 2,
			"byte count and lookup use logical z-y-x cell index order")
	_check(bool(payload.validate_for_source(source, labels.labels_hash).ok),
		"source coordinates, exact triangles, model, schema and target-label hashes validate")
	_check(source.make_clv_preparation_signature() != source.directional_source_signature,
			"an attached probe-domain payload binds its bytes and metadata into prepared operators")
	_test_payload_pair(source, payload, labels)
	_test_fail_closed_bindings(source, payload, labels)
	_test_gather_filter_and_abstain(source, labels)
	_test_legacy_path_without_asset(source)
	_test_saved_label_reuse(source, labels)
	_test_renderer_spacing_bindings()
	_finish()


func _test_saved_label_reuse(source: Resource, labels: Resource) -> void:
	var baker := load("res://addons/feng-magic-gi/feng_magic_gi_volume_source_baker.gd") as Script
	var candidate := source.duplicate(true)
	var metadata := _metadata(candidate, labels)
	metadata["model_sha256"] = Inference.EXPECTED_MODEL_BUNDLE_SHA256
	metadata["feature_schema_id"] = Inference.EXPECTED_FEATURE_SCHEMA_ID
	metadata["feature_schema_sha256"] = Inference.EXPECTED_FEATURE_SCHEMA_SHA256
	metadata["decision_policy_id"] = Inference.EXPECTED_DECISION_POLICY_ID
	var payload := Payload.new()
	_check(bool(payload.configure_for_source(candidate, PackedByteArray([1,2,1]), metadata).ok),
		"current-model saved labels configure for the exact retained source")
	candidate.olv_probe_domain_payload = payload
	_check(baker.can_reuse_inferred_olv(candidate), "unchanged source and model reuse their saved label bytes")
	candidate.geometry_triangles_sha256 = "d7".repeat(32)
	_check(not baker.can_reuse_inferred_olv(candidate), "changed captured triangles cannot reuse saved labels")
	var complete := labels.duplicate(true)
	var original_hash := String(complete.labels_hash)
	complete.receiver_labels_complete = true
	_check(not bool(complete.validate().ok), "receiver-table completeness is covered by the integrity seal")
	complete.refresh_labels_hash()
	_check(bool(complete.validate().ok) and complete.labels_hash != original_hash,
		"complete receiver tables seal independently of legacy tables")


func _valid_source() -> Resource:
	var source: Resource = Chunk.new()
	source.allocate(Vector3i(3, 1, 1), PackedStringArray())
	source.source_size_m = Vector3(0.75, 0.25, 0.25)
	source.source_transform_world = Transform3D(Basis.IDENTITY, Vector3(0.375, 0.125, 0.125))
	source.source_bounds_world = AABB(Vector3.ZERO, source.source_size_m)
	source.domain_bounds_world = source.source_bounds_world
	source.origin_world = Vector3(0.125, 0.125, 0.125)
	source.trace_distance_m = 8.0
	source.bake_samples = 1
	source.bake_bounces = 1
	source.moment_rays = 256
	source.maximum_relocation_m = 0.05
	source.geometry_signature = 314159
	source.geometry_triangles_sha256 = _geometry_sha
	source.validity.fill(Chunk.RELOCATION_STATUS_VALID)
	for logical in source.probe_count:
		for incoming in 243:
			source.transfer[logical * 243 + incoming] = 0.0
		source.transfer[logical * 243] = [1.0, 10.0, 100.0][logical]
		for texel in Chunk.MOMENT_TEXELS_PER_CELL:
			source.receiver_visibility_moments[logical * 128 + texel * 2] = 2.0
			source.receiver_visibility_moments[logical * 128 + texel * 2 + 1] = 4.0
	source.directional_source_signature = source.make_directional_source_signature()
	return source


func _target_labels(source: Resource) -> Resource:
	var labels: Resource = Labels.new()
	_check(bool(labels.configure(SCENE_ID, VOLUME_ID, LAYOUT_REVISION,
			source.geometry_signature, LAYOUT_SIGNATURE).ok), "target labels bind to this geometry and layout")
	var identity := Domain.cell_identity(SCENE_ID, VOLUME_ID, 0, Vector3i.ZERO, LAYOUT_REVISION)
	_check(bool(labels.set_cell_label(identity, Domain.LABEL_EXTERIOR).ok),
			"target CLV cell label is stored by stable volume identity")
	labels.refresh_labels_hash()
	return labels


func _metadata(source: Resource, labels: Resource) -> Dictionary:
	var source_positions := PackedVector3Array()
	for logical_index in source.probe_count:
		source_positions.append(source.cell_position(logical_index))
	return {
		"scene_id": SCENE_ID,
		"volume_id": VOLUME_ID,
		"layout_revision": LAYOUT_REVISION,
		"target_layout_signature": LAYOUT_SIGNATURE,
		"target_label_set_sha256": labels.labels_hash,
		"geometry_triangles_sha256": _geometry_sha,
		"model_sha256": _model_sha,
		"feature_schema_id": "fixture-octa8-ray-schema-v1",
		"feature_schema_sha256": _feature_sha,
		"decision_policy_id": "fixture-three-seed-unanimous-confidence-gate-v1",
		"supported_probe_spacing_m": source.spacing_m,
		"supported_target_cell_spacings_m": PackedFloat32Array(Inference.target_cell_spacings(source)),
		"feature_context_extent_m": Vector3.ONE * 0.5,
		"supported_feature_context_extents_m": PackedVector3Array([Vector3.ONE * 0.5]),
		"source_probe_positions": source_positions,
	}


func _new_payload(source: Resource, values: PackedByteArray, labels: Resource) -> Resource:
	var payload: Resource = Payload.new()
	var result: Dictionary = payload.configure_for_source(source, values, _metadata(source, labels))
	_check(bool(result.get("ok", false)), "probe payload configures (%s)" % result.get("error", ""))
	return payload if bool(result.get("ok", false)) else null


func _context(labels: Resource, source: Resource) -> Dictionary:
	return {
		"label_set": labels,
		"scene_id": SCENE_ID,
		"volume_id": VOLUME_ID,
		"layout_revision": LAYOUT_REVISION,
		"layout_signature": LAYOUT_SIGNATURE,
		"grid_origin_world": source.origin_world,
		"base_cell_spacing_m": source.spacing_m,
	}


func _test_renderer_spacing_bindings() -> void:
	var pass_script := load("res://addons/feng-render-pipeline/passes/magic_gi_pass.gd") as Script
	var manifest_script := load("res://addons/feng-magic-gi/feng_magic_gi_manifest.gd") as Script
	var header_script := load("res://addons/feng-magic-gi/feng_magic_gi_prepared_source_header.gd") as Script
	var pass_value: Resource = pass_script.new()
	for spacing in [0.1, 0.25, 0.3, 1.0, 4.0, 5.0]:
		var source := _valid_source()
		source.spacing_m = spacing
		source.source_size_m = Vector3(source.dimensions) * spacing
		source.source_transform_world.origin = source.source_size_m * 0.5
		source.source_bounds_world = AABB(Vector3.ZERO, source.source_size_m)
		source.domain_bounds_world = source.source_bounds_world
		source.origin_world = Vector3.ONE * spacing * 0.5
		source.maximum_relocation_m = minf(0.05, spacing * 0.2)
		source.directional_source_signature = source.make_directional_source_signature()
		var labels := _target_labels(source)
		var payload := _new_payload(source, PackedByteArray([1,2,1]), labels)
		if payload == null: continue
		var context := _context(labels, source)
		context["labels_hash"] = labels.labels_hash
		var manifest: Resource = manifest_script.new()
		manifest.scene_identity = SCENE_ID
		manifest.volume_identity = VOLUME_ID
		var managed := {"managed": true, "enabled": true, "payload": payload,
			"label_set": labels, "context": context, "source_binding_valid": true,
			"manifest_instance_id": manifest.get_instance_id()}
		var snapshot := {"manifest": manifest, "olv_binding": managed}
		var header: Resource = header_script.new()
		header.origin_world = source.origin_world
		header.spacing_m = spacing
		header.geometry_signature = source.geometry_signature
		for input: Resource in [source, header]:
			_check(not pass_value._validated_native_olv_binding(snapshot, input).is_empty(),
				"independent OLV reaches the renderer at %s m for %s" % [spacing, input.get_script().resource_path])
			managed.source_binding_valid = false
			_check(pass_value._validated_native_olv_binding(snapshot, input).is_empty(),
				"cached acceptance cannot bypass a now-invalid source binding")
			managed.source_binding_valid = true
			_check(not pass_value._validated_native_olv_binding(snapshot, input).is_empty(),
				"a restored source binding restores OLV")
			managed.enabled = false
			_check(pass_value._validated_native_olv_binding(snapshot, input).is_empty(),
				"OLV disable works independently of grid spacing")
			managed.enabled = true
			context.base_cell_spacing_m = spacing * 2.0
			_check(pass_value._validated_native_olv_binding(snapshot, input).is_empty(),
				"a different label lattice still fails closed")
			context.base_cell_spacing_m = spacing


func _test_payload_pair(source: Resource, payload: Resource, labels: Resource) -> void:
	var header_path := "user://olv_probe_domain_header.json"
	var bytes_path := "user://olv_probe_domain.bin"
	var saved: Dictionary = payload.save_pair(header_path, bytes_path, source)
	_check(bool(saved.get("ok", false)) and int(saved.get("bytes", -1)) == source.probe_count,
			"export writes an exact one-byte-per-logical-probe binary payload")
	var loaded: Dictionary = Payload.load_pair(header_path, bytes_path, source, labels.labels_hash)
	_check(bool(loaded.get("ok", false)), "header and bytes reload against the exact source and target LabelSet (%s)" % loaded.get("error", ""))
	if bool(loaded.get("ok", false)):
		_check(loaded.payload.labels == payload.labels,
				"pair roundtrip preserves all domain bytes")
	var header_file := FileAccess.open(header_path, FileAccess.READ)
	var header_json: Dictionary = JSON.parse_string(header_file.get_as_text())
	header_file.close()
	header_json["byte_order"] = "clv-cell-index-v0"
	header_file = FileAccess.open(header_path, FileAccess.WRITE)
	header_file.store_string(JSON.stringify(header_json))
	header_file.close()
	_check(not bool(Payload.load_pair(header_path, bytes_path, source,
			labels.labels_hash).get("ok", false)),
			"tampered byte-order/codebook metadata is rejected even when payload bytes are intact")
	header_file = FileAccess.open(header_path, FileAccess.WRITE)
	header_file.store_string(JSON.stringify(payload.header_dictionary()))
	header_file.close()
	var file := FileAccess.open(bytes_path, FileAccess.READ_WRITE)
	if file != null:
		file.seek_end()
		file.store_8(0)
		file.close()
	var tampered: Dictionary = Payload.load_pair(header_path, bytes_path, source, labels.labels_hash)
	_check(not bool(tampered.get("ok", false)), "extra or changed payload bytes invalidate the header")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(header_path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(bytes_path))


func _test_fail_closed_bindings(source: Resource, payload: Resource, labels: Resource) -> void:
	var wrong_order: Resource = source.duplicate(true)
	wrong_order.global_cell_origin = Vector3i(1, 0, 0)
	_check(not bool(payload.validate_for_source(wrong_order, labels.labels_hash).ok),
			"same byte count with a different global origin rejects positional aliasing")
	var bad_scale := _metadata(source, labels)
	bad_scale["supported_probe_spacing_m"] = 0.5
	var rejected: Resource = Payload.new()
	_check(not bool(rejected.configure_for_source(source, payload.labels, bad_scale).ok),
			"a model trained for 0.5m probes cannot authorize the 0.25m source lattice")
	var bad_labels := PackedByteArray([1, 9, 1])
	var invalid_code: Resource = Payload.new()
	_check(not bool(invalid_code.configure_for_source(source, bad_labels,
			_metadata(source, labels)).ok), "out-of-range bytes are rejected")
	var bad_extent := _metadata(source, labels)
	bad_extent["feature_context_extent_m"] = Vector3.ONE * 0.25
	var unsupported_extent: Resource = Payload.new()
	_check(not bool(unsupported_extent.configure_for_source(source, payload.labels,
			bad_extent).ok), "a 0.5m-only model context cannot authorize untrained 0.25m feature extents")
	var bad_positions := _metadata(source, labels)
	var shifted_positions: PackedVector3Array = bad_positions.source_probe_positions.duplicate()
	shifted_positions[1].x += 0.0001
	bad_positions["source_probe_positions"] = shifted_positions
	var wrong_anchor: Resource = Payload.new()
	_check(not bool(wrong_anchor.configure_for_source(source, payload.labels,
			bad_positions).ok), "labels predicted at other coordinates cannot be assigned to logical probes")


func _test_gather_filter_and_abstain(source: Resource, labels: Resource) -> void:
	var payload := _new_payload(source, PackedByteArray([1, 2, 1]), labels)
	if payload == null: return
	source.olv_probe_domain_payload = payload
	var builder := _new_gather_builder(source)
	builder.call("_configure_olv_domain_filter", source, _context(labels, source))
	builder.set("_active_target_lod", 0)
	builder.call("_activate_olv_target", 0, source.origin_world, 0.25)
	_check(bool(builder.get("_olv_filter_enabled")), "only a fully validated payload and LabelSet enable filtering")
	var filtered: PackedFloat32Array = builder.call("_gather",
		Vector3(0.375, 0.125, 0.125), Vector3(0.375, 0.0, 0.125), Vector3.UP)
	builder.set("_olv_filter_enabled", false)
	var legacy: PackedFloat32Array = builder.call("_gather",
		Vector3(0.375, 0.125, 0.125), Vector3(0.375, 0.0, 0.125), Vector3.UP)
	_check(filtered.size() == legacy.size() and absf(filtered[0] - legacy[0]) > 0.001,
			"decidable exterior target excludes opposite-domain interior source probes before CLV fitting")

	var mixed_payload := _new_payload(source, PackedByteArray([1, 3, 1]), labels)
	if mixed_payload != null:
		source.olv_probe_domain_payload = mixed_payload
		var abstain_builder := _new_gather_builder(source)
		abstain_builder.call("_configure_olv_domain_filter", source, _context(labels, source))
		abstain_builder.set("_active_target_lod", 0)
		abstain_builder.call("_activate_olv_target", 0, source.origin_world, 0.25)
		var abstained: PackedFloat32Array = abstain_builder.call("_gather",
				Vector3(0.375, 0.125, 0.125), Vector3(0.375, 0.0, 0.125), Vector3.UP)
		_check(abstained.to_byte_array() == legacy.to_byte_array(),
				"a PHYSICAL_MIXED/AMBIGUOUS candidate abstains to the complete legacy gather")
		_check(int(abstain_builder.get("_stats").get(
				"olv_abstain_ambiguous_candidate_query_count", 0)) == 1,
				"ambiguous-candidate abstains have a separate per-query reason count")

	var unknown_target_builder := _new_gather_builder(source)
	unknown_target_builder.call("_configure_olv_domain_filter", source, _context(labels, source))
	unknown_target_builder.set("_active_target_lod", 0)
	unknown_target_builder.call("_activate_olv_target", 0, source.origin_world, 0.25)
	unknown_target_builder.set("_active_target_domain_label", Domain.LABEL_UNSET)
	var unknown_target: PackedFloat32Array = unknown_target_builder.call("_gather",
		Vector3(0.375, 0.125, 0.125), Vector3(0.375, 0.0, 0.125), Vector3.UP)
	_check(unknown_target.to_byte_array() == legacy.to_byte_array(),
		"an unknown target falls back to the complete legacy gather")
	_check(int(unknown_target_builder.get("_stats").get("olv_abstain_unknown_target_count", 0)) == 1,
		"unknown-target fallback is recorded as a separate rejection reason")

	var unsupported_builder := _new_gather_builder(source)
	unsupported_builder.call("_configure_olv_domain_filter", source, _context(labels, source))
	unsupported_builder.set("_active_target_lod", 0)
	unsupported_builder.call("_activate_olv_target", 0, source.origin_world, 0.25)
	unsupported_builder.set("_active_target_spacing_m", 0.375)
	var unsupported_target: PackedFloat32Array = unsupported_builder.call("_gather",
		Vector3(0.375, 0.125, 0.125), Vector3(0.375, 0.0, 0.125), Vector3.UP)
	_check(unsupported_target.to_byte_array() == legacy.to_byte_array(),
		"unsupported target spacing falls back to the complete legacy gather")
	_check(int(unsupported_builder.get("_stats").get("olv_abstain_unsupported_spacing_count", 0)) == 1,
		"unsupported-scale fallback is tracked separately from unknown labels")


func _test_legacy_path_without_asset(source: Resource) -> void:
	source.olv_probe_domain_payload = null
	var builder := _new_gather_builder(source)
	var result: PackedFloat32Array = builder.call("_gather",
		Vector3(0.375, 0.125, 0.125), Vector3(0.375, 0.0, 0.125), Vector3.UP)
	_check(result.size() == 64 and result[0] > 0.0,
			"without a validated asset the existing legacy candidate gather remains active")


func _new_gather_builder(source: Resource) -> RefCounted:
	var builder: RefCounted = BuilderScript.new()
	builder.set("_source", source)
	builder.set("_geometry", GeometryStub.new())
	builder.set("_columns", 16)
	builder.set("_output_coefficients", 4)
	builder.set("_support_radius", 0.65)
	builder.set("_stats", {"visibility_rays": 0})
	return builder


func _finish() -> void:
	print("MAGIC_GI_OLV_PROBE_DOMAIN_RESULT failures=", _failures, " checks=", _checks)
	quit(1 if _failures > 0 else 0)
