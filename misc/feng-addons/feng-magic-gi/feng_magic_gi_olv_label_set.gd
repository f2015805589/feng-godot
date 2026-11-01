@tool
extends Resource
## Versioned OLV domain sidecar for one Volume.
##
## Deliberately independent of `FMagicGIPreparedTransferBrick`: creating,
## saving, loading or dropping this resource cannot change prepared `validity`
## (operator support), `operators`, or source relocation. Prepared bricks stay
## the only owner of transfer operators.
##
## `cell_labels` are candidate/corner domains; `receiver_labels` are the
## shading point's own domain. Either may be missing for a cell, and a missing
## label reads as UNSET, which the gate turns into ABSTAIN instead of guessing.
##
## `labels_hash` is an integrity seal over the binding header and the sorted
## label payload, encoded canonically by `seal_payload()`/`seal_payload_json()`
## (sorted-key JSON, injective). A tampered, truncated or half-written sidecar
## is therefore rejected rather than applied partially.

const Domain = preload("feng_magic_gi_olv_domain.gd")

const SCHEMA_VERSION := 1

## Guard rail so a corrupted sidecar cannot allocate unbounded dictionaries.
const MAX_LABEL_RECORDS := 1048576

@export_storage var schema_version := SCHEMA_VERSION
@export_storage var subject_kind := Domain.SUBJECT_KIND_CLV_CELL
@export_storage var scene_id := ""
@export_storage var volume_id := ""
@export_storage var layout_revision := 0
## Bake identity this sidecar was produced from. `geometry_signature` matches
## `FMagicGIPreparedTransferBrick.geometry_signature`; `layout_signature` is the
## prepared layout/cell-lattice signature. Both are part of the seal.
@export_storage var geometry_signature := 0
@export_storage var layout_signature := ""
## Integrity seal over the header and label payload. Empty is rejected.
@export_storage var labels_hash := ""
## Canonical identity key -> supervised domain label.
@export_storage var cell_labels := {}
@export_storage var receiver_labels := {}
## Complete logical-position table: an omitted receiver anchor is unavailable,
## even when a relocated lighting probe still has a valid source label there.
@export_storage var receiver_labels_complete := false

## Monotonic in-memory revision for the runtime validation cache. The saved
## labels_hash remains the integrity seal; this revision only tells a consumer
## that one of the mutable LabelSet APIs changed the resource since its last
## validation. Direct dictionary edits should call mark_validation_changed().
var _validation_revision := 1


static func _fail(message: String) -> Dictionary:
	return {"ok": false, "error": message}


static func _ok() -> Dictionary:
	return {"ok": true, "error": ""}


func _touch_validation_revision() -> void:
	_validation_revision += 1
	emit_changed()


func get_validation_revision() -> int:
	return _validation_revision


## Call this after an intentional in-place edit to cell_labels or
## receiver_labels. Normal callers should use the mutation methods below.
func mark_validation_changed() -> void:
	_touch_validation_revision()


## Binds this sidecar to one bake. Labels are added separately.
func configure(p_scene_id: String, p_volume_id: String, p_layout_revision: int,
		p_geometry_signature: int, p_layout_signature: String) -> Dictionary:
	if p_scene_id.is_empty() or p_volume_id.is_empty():
		return _fail("empty_volume_identity")
	if p_scene_id.contains(Domain.FIELD_SEPARATOR) or p_volume_id.contains(Domain.FIELD_SEPARATOR):
		return _fail("identity_identifier_contains_field_separator")
	if p_layout_revision < 0:
		return _fail("layout_revision_negative")
	if p_layout_signature.is_empty():
		return _fail("empty_layout_signature")
	scene_id = p_scene_id
	volume_id = p_volume_id
	layout_revision = p_layout_revision
	geometry_signature = p_geometry_signature
	layout_signature = p_layout_signature
	_touch_validation_revision()
	return _ok()


func get_cell_label(identity: Dictionary) -> int:
	var key := Domain.identity_key(identity)
	return int(cell_labels[key]) if cell_labels.has(key) else Domain.LABEL_UNSET


func get_receiver_label(identity: Dictionary) -> int:
	var key := Domain.identity_key(identity)
	return int(receiver_labels[key]) if receiver_labels.has(key) else Domain.LABEL_UNSET


func has_cell_label(identity: Dictionary) -> bool:
	return cell_labels.has(Domain.identity_key(identity))


func has_receiver_label(identity: Dictionary) -> bool:
	return receiver_labels.has(Domain.identity_key(identity))


func cell_label_count() -> int:
	return cell_labels.size()


func receiver_label_count() -> int:
	return receiver_labels.size()


func remove_cell_label(identity: Dictionary) -> bool:
	var removed := cell_labels.erase(Domain.identity_key(identity))
	if removed:
		_touch_validation_revision()
	return removed


func remove_receiver_label(identity: Dictionary) -> bool:
	var removed := receiver_labels.erase(Domain.identity_key(identity))
	if removed:
		_touch_validation_revision()
	return removed


## Deliberate single assignment: an existing label is intentionally replaced.
## Use `merge_cell_labels` for duplicate-bearing imports, which rejects conflicts.
func set_cell_label(identity: Dictionary, label: int) -> Dictionary:
	var error := _record_error(identity, label, "cell")
	if not error.is_empty():
		return _fail(error)
	cell_labels[Domain.identity_key(identity)] = label
	_touch_validation_revision()
	return _ok()


func set_receiver_label(identity: Dictionary, label: int) -> Dictionary:
	var error := _record_error(identity, label, "receiver")
	if not error.is_empty():
		return _fail(error)
	receiver_labels[Domain.identity_key(identity)] = label
	_touch_validation_revision()
	return _ok()


## Imports records such as `{"identity": {...}, "label": LABEL_INTERIOR}`.
## Atomic: nothing is committed unless every record is acceptable.
##
## A halo duplicate of the same global cell carrying the same label is accepted
## (that is the normal paged case). The same global cell carrying two different
## labels is rejected, because which one won would otherwise depend on brick
## load order.
func merge_cell_labels(records: Array) -> Dictionary:
	var result := _merge_records(cell_labels, records, "cell")
	if bool(result["ok"]):
		cell_labels = result["labels"]
		_touch_validation_revision()
	return {"ok": result["ok"], "error": result["error"]}


func merge_receiver_labels(records: Array) -> Dictionary:
	var result := _merge_records(receiver_labels, records, "receiver")
	if bool(result["ok"]):
		receiver_labels = result["labels"]
		_touch_validation_revision()
	return {"ok": result["ok"], "error": result["error"]}


func _merge_records(existing: Dictionary, records: Array, kind: String) -> Dictionary:
	var merged := existing.duplicate()
	for index in records.size():
		var record: Variant = records[index]
		if not record is Dictionary:
			return _fail("%s_record_not_dictionary:%d" % [kind, index])
		var identity: Variant = record.get("identity")
		if not identity is Dictionary:
			return _fail("%s_record_identity_missing:%d" % [kind, index])
		if typeof(record.get("label")) != TYPE_INT:
			return _fail("%s_record_label_not_int:%d" % [kind, index])
		var label := int(record["label"])
		var identity_dictionary: Dictionary = identity
		var error := _record_error(identity_dictionary, label, kind)
		if not error.is_empty():
			return _fail("%s:%d" % [error, index])
		var key := Domain.identity_key(identity_dictionary)
		if merged.has(key) and int(merged[key]) != label:
			return _fail("%s_conflicting_label:%s:%s->%s" % [
					kind, key, Domain.label_name(int(merged[key])), Domain.label_name(label)])
		merged[key] = label
	if merged.size() > MAX_LABEL_RECORDS:
		return _fail("%s_records_exceed_budget" % kind)
	return {"ok": true, "error": "", "labels": merged}


## One record's acceptability, independent of whether it already exists.
func _record_error(identity: Dictionary, label: int, kind: String) -> String:
	# UNSET is the absence of a label, not a storable record.
	if not Domain.is_supervised_label(label):
		return "%s_record_label_not_supervised:%s" % [kind, Domain.label_name(label)]
	var key := Domain.identity_key(identity)
	if key.is_empty():
		return "%s_record_unkeyable:%s" % [kind, Domain.identity_error(identity)]
	var binding_error := _record_binding_error(key)
	if not binding_error.is_empty():
		return "%s_%s" % [kind, binding_error]
	return ""


## A record must belong to this sidecar's own scene, volume and layout revision;
## a label set can never absorb another Volume's cells.
func _record_binding_error(key: String) -> String:
	var identity := Domain.parse_identity_key(key)
	if identity.is_empty():
		return "record_key_not_canonical"
	if String(identity["scene_id"]) != scene_id or String(identity["volume_id"]) != volume_id:
		return "record_identity_mismatch"
	if int(identity["layout_revision"]) != layout_revision:
		return "record_layout_revision_mismatch"
	return ""


## Deterministic seal input: header first, then labels sorted by canonical key.
## Canonical seal input: one JSON object with sorted keys (JSON.stringify
## sort_keys) and full float precision, whose label records are arrays of
## {"key", "label"} objects sorted by canonical key.
##
## JSON string escaping keeps a value inside its own string, so the encoding is
## injective: record text cannot be moved into another field (for example into
## `layout_signature`) to reproduce the same seal. Never replace this with plain
## concatenation, and never "fix" it by only banning newlines; the retired
## newline-joined form collided exactly that way, and the contract test keeps
## that A/B so the encoding cannot silently regress.
func seal_payload() -> Dictionary:
	var payload := {
		"schema_version": schema_version,
		"subject_kind": subject_kind,
		"scene_id": scene_id,
		"volume_id": volume_id,
		"layout_revision": layout_revision,
		"geometry_signature": geometry_signature,
		"layout_signature": layout_signature,
		"cell_labels": sorted_records(cell_labels),
		"receiver_labels": sorted_records(receiver_labels),
	}
	# Preserve existing sidecar seals until the independent OLV update upgrades
	# them. The new semantics themselves must be covered by the integrity seal.
	if receiver_labels_complete:
		payload["receiver_labels_complete"] = true
	return payload


## Records ordered by canonical key, so the seal never depends on dictionary
## iteration order.
func sorted_records(labels: Dictionary) -> Array:
	var keys := PackedStringArray()
	for key: String in labels:
		keys.append(key)
	keys.sort()
	var records := []
	for key in keys:
		records.append({"key": key, "label": int(labels[key])})
	return records


func seal_payload_json() -> String:
	return JSON.stringify(seal_payload(), "", true, true)


func compute_labels_hash() -> String:
	return seal_payload_json().sha256_text()


## Reseals the sidecar after its labels or binding changed.
func refresh_labels_hash() -> void:
	labels_hash = compute_labels_hash()
	_touch_validation_revision()


func validate() -> Dictionary:
	if schema_version != SCHEMA_VERSION:
		return _fail("unsupported_schema_version:%d" % schema_version)
	if subject_kind != Domain.SUBJECT_KIND_CLV_CELL:
		return _fail("unsupported_subject_kind:%s" % subject_kind)
	if scene_id.is_empty() or volume_id.is_empty():
		return _fail("unbound_volume_identity")
	if scene_id.contains(Domain.FIELD_SEPARATOR) or volume_id.contains(Domain.FIELD_SEPARATOR):
		return _fail("identity_identifier_contains_field_separator")
	if layout_revision < 0:
		return _fail("layout_revision_negative")
	if layout_signature.is_empty():
		return _fail("empty_layout_signature")
	if labels_hash.is_empty():
		return _fail("empty_labels_hash")
	if cell_labels.size() + receiver_labels.size() > MAX_LABEL_RECORDS:
		return _fail("label_records_exceed_budget")
	for kind in ["cell", "receiver"]:
		var labels: Dictionary = cell_labels if kind == "cell" else receiver_labels
		for key: String in labels:
			if typeof(labels[key]) != TYPE_INT or not Domain.is_supervised_label(int(labels[key])):
				return _fail("%s_invalid_label:%s" % [kind, key])
			var binding_error := _record_binding_error(key)
			if not binding_error.is_empty():
				return _fail("%s_%s" % [kind, binding_error])
	if labels_hash != compute_labels_hash():
		return _fail("labels_hash_mismatch")
	return _ok()


## True only when this sidecar was produced from the active bake. The gate must
## ABSTAIN on a mismatch instead of applying stale domain labels.
func matches_bake(p_scene_id: String, p_volume_id: String, p_layout_revision: int,
		p_geometry_signature: int, p_layout_signature: String) -> bool:
	return scene_id == p_scene_id and volume_id == p_volume_id \
			and layout_revision == p_layout_revision \
			and geometry_signature == p_geometry_signature \
			and layout_signature == p_layout_signature


## Labels plus the bake-hash verdict, ready for `Domain.decide()`. Confidences
## and the minimum-confidence policy stay with the caller: this contract has no
## threshold of its own. An invalid sidecar reports `hashes_match = false` so
## the gate abstains rather than applying an unverified payload.
func gate_inputs(receiver_identity: Dictionary, candidate_identity: Dictionary,
		p_expected_scene_id: String, p_expected_volume_id: String,
		p_expected_layout_revision: int, p_expected_geometry_signature: int,
		p_expected_layout_signature: String) -> Dictionary:
	var validation := validate()
	var matched := bool(validation["ok"]) and matches_bake(p_expected_scene_id, p_expected_volume_id,
			p_expected_layout_revision, p_expected_geometry_signature, p_expected_layout_signature)
	return {
		"receiver_label": get_receiver_label(receiver_identity),
		"candidate_label": get_cell_label(candidate_identity),
		"hashes_match": matched,
		"error": String(validation["error"]),
	}
