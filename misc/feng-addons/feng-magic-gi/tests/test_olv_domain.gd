extends SceneTree
## CPU-only OLV v1 contract checks: labels, the per-corner gate, stable cell
## identity, the versioned sidecar and its orthogonality to prepared bricks.
##
## No bake, no GPU device, no native code. The prepared brick below is the
## smallest resource that satisfies FMagicGIPreparedTransferBrick's own
## validator, so the label lifecycle can be proven not to disturb it.

const Domain = preload("../feng_magic_gi_olv_domain.gd")
const LabelSet = preload("../feng_magic_gi_olv_label_set.gd")
const Brick = preload("../feng_magic_gi_prepared_transfer_brick.gd")

const SCENE_ID := "res://scenes/olv_fixture.tscn"
const VOLUME_ID := "FMagicGIVolume@1234567"
const LAYOUT_REVISION := 4
const GEOMETRY_SIGNATURE := 987654321
const LAYOUT_SIGNATURE := "prepared_free_space_bricks_v1|regular_cell_centers_v1|0.25"

## Hand-authored fixture: every label is treated as fully trusted, so the
## explicit policy threshold is 1.0. Nothing here hardcodes a threshold inside
## the API; each call passes its own.
const FIXTURE_CONFIDENCE := 1.0
const FIXTURE_MIN_CONFIDENCE := 1.0

const BRICK_PATH := "user://olv_brick.res"
const LABEL_PATH := "user://olv_labels.res"
const SCHEMA_PATH := "user://olv_labels_future_schema.res"

var _checks := 0
var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("REGRESSION: " + message)


func _check_ok(result: Dictionary, message: String) -> void:
	_checks += 1
	if not bool(result.get("ok", false)):
		_failures += 1
		push_error("REGRESSION: %s (error=%s)" % [message, result.get("error", "")])


func _check_error(result: Dictionary, fragment: String, message: String) -> void:
	_checks += 1
	var error := String(result.get("error", ""))
	if bool(result.get("ok", false)) or not error.contains(fragment):
		_failures += 1
		push_error("REGRESSION: %s (wanted error containing '%s', got ok=%s error='%s')" % [
				message, fragment, result.get("ok"), error])


func _identity(lod: int, cell: Vector3i) -> Dictionary:
	return Domain.cell_identity(SCENE_ID, VOLUME_ID, lod, cell, LAYOUT_REVISION)


func _new_label_set() -> Resource:
	var labels: Resource = LabelSet.new()
	_check_ok(labels.configure(SCENE_ID, VOLUME_ID, LAYOUT_REVISION, GEOMETRY_SIGNATURE,
			LAYOUT_SIGNATURE), "the sidecar binds to the fixture bake")
	return labels


func _run() -> void:
	_test_labels_and_decision_table()
	_test_identity_stability()
	_test_canonical_key_strictness()
	_test_label_set_roundtrip()
	_test_label_set_rejections()
	_test_merge_atomicity()
	_test_tampered_seal_gate()
	_test_seal_encoding_injectivity()
	_test_prepared_brick_orthogonality()
	_test_multi_room_limitation()
	print("MAGIC_GI_OLV_DOMAIN_RESULT failures=", _failures, " checks=", _checks)
	if _failures > 0:
		push_error("OLV domain contract failed: %d/%d" % [_failures, _checks])
	quit(1 if _failures > 0 else 0)


func _test_labels_and_decision_table() -> void:
	_check(Domain.LABEL_UNSET == 0 and Domain.LABEL_EXTERIOR == 1 and Domain.LABEL_INTERIOR == 2
			and Domain.LABEL_AMBIGUOUS == 3,
			"v1 label values stay UNSET=0 / EXTERIOR=1 / INTERIOR=2 / AMBIGUOUS=3")
	_check(not Domain.is_supervised_label(Domain.LABEL_UNSET),
			"UNSET is not a supervised class: a model never predicts missing data")
	_check(Domain.SUPERVISED_LABELS.size() == 3 and not Domain.SUPERVISED_LABELS.has(Domain.LABEL_UNSET),
			"the supervised label list excludes UNSET")
	_check(Domain.is_supervised_label(Domain.LABEL_AMBIGUOUS)
			and not Domain.is_decidable_label(Domain.LABEL_AMBIGUOUS)
			and Domain.is_decidable_label(Domain.LABEL_INTERIOR)
			and not Domain.is_decidable_label(Domain.LABEL_UNSET),
			"AMBIGUOUS is a supervised training class but is not decidable by the gate")
	_check(not Domain.is_valid_label(-1) and not Domain.is_valid_label(4),
			"label values outside the enum are invalid")
	_check(Domain.label_name(3) == "AMBIGUOUS" and Domain.label_name(9).begins_with("INVALID"),
			"diagnostic names cover valid and invalid labels")
	_check(Domain.decision_name(Domain.DECISION_ABSTAIN) == "ABSTAIN",
			"decisions have diagnostic names")

	# Same trusted domain blends; a different trusted domain is rejected before
	# interpolation and normalization; everything uncertain abstains.
	_check(Domain.decide(Domain.LABEL_INTERIOR, FIXTURE_CONFIDENCE, Domain.LABEL_INTERIOR,
			FIXTURE_CONFIDENCE, true, FIXTURE_MIN_CONFIDENCE) == Domain.DECISION_ALLOW,
			"the same trusted interior domain allows blending")
	_check(Domain.decide(Domain.LABEL_EXTERIOR, FIXTURE_CONFIDENCE, Domain.LABEL_EXTERIOR,
			FIXTURE_CONFIDENCE, true, FIXTURE_MIN_CONFIDENCE) == Domain.DECISION_ALLOW,
			"the same trusted exterior domain allows blending")
	_check(Domain.decide(Domain.LABEL_INTERIOR, FIXTURE_CONFIDENCE, Domain.LABEL_EXTERIOR,
			FIXTURE_CONFIDENCE, true, FIXTURE_MIN_CONFIDENCE) == Domain.DECISION_REJECT,
			"a cross-domain corner is rejected")
	_check(Domain.decide(Domain.LABEL_EXTERIOR, FIXTURE_CONFIDENCE, Domain.LABEL_INTERIOR,
			FIXTURE_CONFIDENCE, true, FIXTURE_MIN_CONFIDENCE) == Domain.DECISION_REJECT,
			"the cross-domain verdict is symmetric")

	for absent in [Domain.LABEL_UNSET, Domain.LABEL_AMBIGUOUS, 7, -1]:
		_check(Domain.decide(absent, FIXTURE_CONFIDENCE, Domain.LABEL_INTERIOR,
				FIXTURE_CONFIDENCE, true, FIXTURE_MIN_CONFIDENCE) == Domain.DECISION_ABSTAIN,
				"a receiver label of %s abstains" % Domain.label_name(absent))
		_check(Domain.decide(Domain.LABEL_INTERIOR, FIXTURE_CONFIDENCE, absent,
				FIXTURE_CONFIDENCE, true, FIXTURE_MIN_CONFIDENCE) == Domain.DECISION_ABSTAIN,
				"a candidate label of %s abstains" % Domain.label_name(absent))

	_check(Domain.decide(Domain.LABEL_INTERIOR, FIXTURE_CONFIDENCE, Domain.LABEL_EXTERIOR,
			FIXTURE_CONFIDENCE, false, FIXTURE_MIN_CONFIDENCE) == Domain.DECISION_ABSTAIN,
			"a mismatched hash abstains even for a confident cross-domain pair")
	_check(Domain.decide(Domain.LABEL_INTERIOR, FIXTURE_CONFIDENCE, Domain.LABEL_INTERIOR,
			FIXTURE_CONFIDENCE, false, FIXTURE_MIN_CONFIDENCE) == Domain.DECISION_ABSTAIN,
			"a mismatched hash abstains for a same-domain pair too: there is no partial trust")

	# The confidence threshold is caller policy, proven by changing it per call.
	var authored := 0.6
	_check(Domain.decide(Domain.LABEL_INTERIOR, 0.59, Domain.LABEL_INTERIOR, FIXTURE_CONFIDENCE,
			true, authored) == Domain.DECISION_ABSTAIN
			and Domain.decide(Domain.LABEL_INTERIOR, 0.61, Domain.LABEL_INTERIOR,
					FIXTURE_CONFIDENCE, true, authored) == Domain.DECISION_ALLOW,
			"a receiver confidence below the caller's explicit threshold abstains")
	_check(Domain.decide(Domain.LABEL_INTERIOR, FIXTURE_CONFIDENCE, Domain.LABEL_EXTERIOR, 0.59,
			true, authored) == Domain.DECISION_ABSTAIN
			and Domain.decide(Domain.LABEL_INTERIOR, FIXTURE_CONFIDENCE, Domain.LABEL_EXTERIOR,
					0.61, true, authored) == Domain.DECISION_REJECT,
			"a candidate confidence below the caller's explicit threshold abstains")
	_check(Domain.decide(Domain.LABEL_INTERIOR, authored, Domain.LABEL_INTERIOR, authored, true,
			authored) == Domain.DECISION_ALLOW,
			"a confidence exactly at the caller's threshold passes")
	_check(Domain.decide(Domain.LABEL_INTERIOR, authored, Domain.LABEL_INTERIOR,
			FIXTURE_CONFIDENCE, true, FIXTURE_MIN_CONFIDENCE) == Domain.DECISION_ABSTAIN,
			"the same confidence abstains under a stricter caller threshold: no threshold is baked in")
	_check(Domain.decide(Domain.LABEL_INTERIOR, NAN, Domain.LABEL_INTERIOR, FIXTURE_CONFIDENCE,
			true, authored) == Domain.DECISION_ABSTAIN
			and Domain.decide(Domain.LABEL_INTERIOR, INF, Domain.LABEL_INTERIOR,
					FIXTURE_CONFIDENCE, true, authored) == Domain.DECISION_ABSTAIN
			and Domain.decide(Domain.LABEL_INTERIOR, FIXTURE_CONFIDENCE, Domain.LABEL_INTERIOR,
					FIXTURE_CONFIDENCE, true, NAN) == Domain.DECISION_ABSTAIN,
			"a non-finite confidence or threshold fails closed")


func _test_identity_stability() -> void:
	var here := _identity(0, Vector3i(2, 1, 1))
	_check(Domain.identity_error(here).is_empty(), "a bound identity is keyable")
	var key := Domain.identity_key(here)
	_check(not key.is_empty(), "a bound identity has a canonical key")
	_check(Domain.parse_identity_key(key) == here, "the key round-trips through parse_identity_key")
	_check(Domain.identity_key(here) == key, "the same identity always yields the same key")

	# Halo: one global cell delivered by two different bricks must keep one
	# identity even though its brick-local index differs in each brick.
	var brick_a := _make_brick(Vector3i.ZERO, Vector3i(3, 3, 3), Vector3i.ZERO, Vector3i(3, 3, 3))
	var brick_b := _make_brick(Vector3i(1, 0, 0), Vector3i(3, 3, 3), Vector3i(2, 0, 0), Vector3i(1, 3, 3))
	_check(brick_a.is_valid() and brick_b.is_valid(), "both halo fixture bricks are valid")
	var halo_cell := Vector3i(2, 1, 1)
	var local_a: int = brick_a.cell_index(halo_cell)
	var local_b: int = brick_b.cell_index(halo_cell)
	_check(local_a >= 0 and local_b >= 0 and local_a != local_b,
			"the halo cell really does sit at different brick-local indices")
	_check(_global_cell_of(brick_a, local_a) == halo_cell and _global_cell_of(brick_b, local_b) == halo_cell,
			"each brick-local index resolves back to the same global cell")
	var identity_from_a := Domain.cell_identity(SCENE_ID, VOLUME_ID, 0,
			_global_cell_of(brick_a, local_a), LAYOUT_REVISION)
	var identity_from_b := Domain.cell_identity(SCENE_ID, VOLUME_ID, 0,
			_global_cell_of(brick_b, local_b), LAYOUT_REVISION)
	_check(Domain.identity_key(identity_from_a) == Domain.identity_key(identity_from_b),
			"a halo duplicate shares one identity although its brick-local index differs")

	var variants := {
		"scene_id": Domain.cell_identity("res://scenes/other.tscn", VOLUME_ID, 0, halo_cell,
				LAYOUT_REVISION),
		"volume_id": Domain.cell_identity(SCENE_ID, "OtherVolume@7654321", 0, halo_cell,
				LAYOUT_REVISION),
		"lod": Domain.cell_identity(SCENE_ID, VOLUME_ID, 1, halo_cell, LAYOUT_REVISION),
		"global_cell": Domain.cell_identity(SCENE_ID, VOLUME_ID, 0, halo_cell + Vector3i(0, 0, 1),
				LAYOUT_REVISION),
		"layout_revision": Domain.cell_identity(SCENE_ID, VOLUME_ID, 0, halo_cell,
				LAYOUT_REVISION + 1),
	}
	for name: String in variants:
		_check(Domain.identity_key(variants[name]) != key,
				"a different %s cannot collide with this cell's identity" % name)

	_check(not Domain.identity_error(Domain.cell_identity("", VOLUME_ID, 0, halo_cell, 0)).is_empty(),
			"an empty scene id is not keyable")
	_check(Domain.identity_error(Domain.cell_identity(SCENE_ID, VOLUME_ID, -1, halo_cell, 0))
			== "identity_lod_out_of_range"
			and Domain.identity_error(Domain.cell_identity(SCENE_ID, VOLUME_ID, Domain.MAX_LOD + 1,
					halo_cell, 0)) == "identity_lod_out_of_range",
			"a lod outside L0..L9 is rejected")
	_check(Domain.identity_error(Domain.cell_identity(SCENE_ID, VOLUME_ID, 0, halo_cell, -1))
			== "identity_layout_revision_negative", "a negative layout revision is rejected")
	_check(Domain.identity_key({"scene_id": SCENE_ID, "volume_id": VOLUME_ID, "lod": 0,
			"global_cell": Vector3(2, 1, 1), "layout_revision": 0}).is_empty(),
			"a float global cell is refused instead of truncated into a colliding identity")
	_check(Domain.identity_key(Domain.cell_identity(SCENE_ID + Domain.FIELD_SEPARATOR + "x",
			VOLUME_ID, 0, halo_cell, 0)).is_empty(),
			"an identifier containing the canonical separator cannot forge another identity")
	_check(Domain.parse_identity_key("not-a-key").is_empty()
			and Domain.parse_identity_key(key + "x").is_empty(),
			"malformed keys are refused instead of parsed loosely")


func _test_label_set_roundtrip() -> void:
	var labels := _new_label_set()
	_check_error(labels.validate(), "empty_labels_hash",
			"a sidecar without an integrity seal is refused")

	var receiver_cell := Vector3i(2, 1, 1)
	var candidate_cell := Vector3i(3, 1, 1)
	var ambiguous_cell := Vector3i(3, 2, 1)
	_check_ok(labels.set_receiver_label(_identity(0, receiver_cell), Domain.LABEL_INTERIOR),
			"the receiver domain is recorded")
	_check_ok(labels.merge_cell_labels([
		{"identity": _identity(0, candidate_cell), "label": Domain.LABEL_INTERIOR},
		{"identity": _identity(0, ambiguous_cell), "label": Domain.LABEL_AMBIGUOUS},
		# The paged cache hands one global cell to several bricks; an identical
		# halo duplicate is normal and must not read as a conflict.
		{"identity": _identity(0, candidate_cell), "label": Domain.LABEL_INTERIOR},
	]), "identical halo duplicates merge without conflict")
	_check(labels.cell_label_count() == 2 and labels.receiver_label_count() == 1,
			"halo duplicates collapse to one record per global cell")
	_check(labels.get_cell_label(_identity(0, candidate_cell)) == Domain.LABEL_INTERIOR
			and labels.get_cell_label(_identity(0, Vector3i(9, 9, 9))) == Domain.LABEL_UNSET,
			"an absent cell reads as UNSET instead of a guessed domain")
	_check(labels.get_receiver_label(_identity(0, candidate_cell)) == Domain.LABEL_UNSET,
			"a cell with no receiver label stays unknown, which the gate abstains on")

	labels.refresh_labels_hash()
	_check_ok(labels.validate(), "a sealed sidecar validates")
	var sealed := String(labels.labels_hash)

	var saved := ResourceSaver.save(labels, LABEL_PATH)
	_check(saved == OK, "the sidecar saves through ResourceSaver (error=%d)" % saved)
	var loaded: Resource = ResourceLoader.load(LABEL_PATH)
	if loaded == null:
		_check(false, "the sidecar loads back")
		return
	_check(loaded.get_script() == LabelSet, "the reloaded sidecar keeps its script contract")
	_check(String(loaded.scene_id) == SCENE_ID and String(loaded.volume_id) == VOLUME_ID
			and int(loaded.layout_revision) == LAYOUT_REVISION
			and int(loaded.geometry_signature) == GEOMETRY_SIGNATURE
			and String(loaded.layout_signature) == LAYOUT_SIGNATURE,
			"the reloaded sidecar keeps its bake binding")
	_check(String(loaded.labels_hash) == sealed, "the reloaded sidecar keeps its seal")
	_check_ok(loaded.validate(), "the reloaded sidecar still validates")
	_check(int(loaded.cell_labels.size()) == 2 and int(loaded.receiver_labels.size()) == 1,
			"the reloaded sidecar keeps every label record")
	_check(int(loaded.get_cell_label(_identity(0, candidate_cell))) == Domain.LABEL_INTERIOR
			and int(loaded.get_cell_label(_identity(0, ambiguous_cell))) == Domain.LABEL_AMBIGUOUS
			and int(loaded.get_receiver_label(_identity(0, receiver_cell))) == Domain.LABEL_INTERIOR,
			"every label survives the round trip with its own value")

	_check(bool(loaded.matches_bake(SCENE_ID, VOLUME_ID, LAYOUT_REVISION, GEOMETRY_SIGNATURE,
			LAYOUT_SIGNATURE)), "the sidecar matches its own bake")
	_check(not bool(loaded.matches_bake(SCENE_ID, VOLUME_ID, LAYOUT_REVISION,
			GEOMETRY_SIGNATURE + 1, LAYOUT_SIGNATURE)), "a changed geometry signature stops matching")
	_check(not bool(loaded.matches_bake(SCENE_ID, VOLUME_ID, LAYOUT_REVISION, GEOMETRY_SIGNATURE,
			LAYOUT_SIGNATURE + "|v2")), "a changed layout signature stops matching")
	_check(not bool(loaded.matches_bake("res://scenes/other.tscn", VOLUME_ID, LAYOUT_REVISION,
			GEOMETRY_SIGNATURE, LAYOUT_SIGNATURE))
			and not bool(loaded.matches_bake(SCENE_ID, "OtherVolume@1", LAYOUT_REVISION,
					GEOMETRY_SIGNATURE, LAYOUT_SIGNATURE))
			and not bool(loaded.matches_bake(SCENE_ID, VOLUME_ID, LAYOUT_REVISION + 1,
					GEOMETRY_SIGNATURE, LAYOUT_SIGNATURE)),
			"another scene, volume or layout revision stops matching")

	# End-to-end wiring: the sidecar feeds the pure gate.
	var same: Dictionary = loaded.gate_inputs(_identity(0, receiver_cell),
			_identity(0, candidate_cell), SCENE_ID, VOLUME_ID, LAYOUT_REVISION, GEOMETRY_SIGNATURE,
			LAYOUT_SIGNATURE)
	_check(bool(same["hashes_match"]) and int(same["receiver_label"]) == Domain.LABEL_INTERIOR
			and int(same["candidate_label"]) == Domain.LABEL_INTERIOR,
			"gate inputs resolve both labels with a matching seal")
	_check(Domain.decide(int(same["receiver_label"]), FIXTURE_CONFIDENCE,
			int(same["candidate_label"]), FIXTURE_CONFIDENCE, bool(same["hashes_match"]),
			FIXTURE_MIN_CONFIDENCE) == Domain.DECISION_ALLOW,
			"the assembled inputs allow a same-domain corner")

	var unknown_receiver: Dictionary = loaded.gate_inputs(_identity(0, candidate_cell),
			_identity(0, candidate_cell), SCENE_ID, VOLUME_ID, LAYOUT_REVISION, GEOMETRY_SIGNATURE,
			LAYOUT_SIGNATURE)
	_check(Domain.decide(int(unknown_receiver["receiver_label"]), FIXTURE_CONFIDENCE,
			int(unknown_receiver["candidate_label"]), FIXTURE_CONFIDENCE,
			bool(unknown_receiver["hashes_match"]), FIXTURE_MIN_CONFIDENCE) == Domain.DECISION_ABSTAIN,
			"a known candidate with an unknown receiver domain abstains")

	var stale: Dictionary = loaded.gate_inputs(_identity(0, receiver_cell), _identity(0, candidate_cell),
			SCENE_ID, VOLUME_ID, LAYOUT_REVISION, GEOMETRY_SIGNATURE + 1, LAYOUT_SIGNATURE)
	_check(not bool(stale["hashes_match"]) and Domain.decide(int(stale["receiver_label"]),
			FIXTURE_CONFIDENCE, int(stale["candidate_label"]), FIXTURE_CONFIDENCE,
			bool(stale["hashes_match"]), FIXTURE_MIN_CONFIDENCE) == Domain.DECISION_ABSTAIN,
			"a sidecar bound to another bake abstains instead of applying stale labels")

	var ambiguous: Dictionary = loaded.gate_inputs(_identity(0, receiver_cell), _identity(0, ambiguous_cell),
			SCENE_ID, VOLUME_ID, LAYOUT_REVISION, GEOMETRY_SIGNATURE, LAYOUT_SIGNATURE)
	_check(Domain.decide(int(ambiguous["receiver_label"]), FIXTURE_CONFIDENCE,
			int(ambiguous["candidate_label"]), FIXTURE_CONFIDENCE, bool(ambiguous["hashes_match"]),
			FIXTURE_MIN_CONFIDENCE) == Domain.DECISION_ABSTAIN,
			"an explicitly AMBIGUOUS candidate abstains rather than picking a domain")


func _test_label_set_rejections() -> void:
	var labels := _new_label_set()
	var cell := Vector3i(1, 1, 1)
	_check_error(labels.merge_cell_labels([{"identity": _identity(0, cell),
			"label": Domain.LABEL_UNSET}]), "record_label_not_supervised",
			"UNSET cannot be stored: it is the absence of a label, not a class")
	_check_error(labels.merge_cell_labels([{"identity": _identity(0, cell), "label": 4}]),
			"record_label_not_supervised", "an out-of-enum label is refused")
	_check_error(labels.merge_cell_labels([{"identity": _identity(0, cell), "label": -1}]),
			"record_label_not_supervised", "a negative label is refused")
	_check_error(labels.merge_cell_labels([{"identity": _identity(0, cell), "label": "INTERIOR"}]),
			"record_label_not_int", "a non-integer label is refused")
	_check_error(labels.merge_cell_labels([Vector3i(1, 1, 1)]), "record_not_dictionary",
			"a non-record entry is refused")
	_check_error(labels.merge_cell_labels([{"label": Domain.LABEL_INTERIOR}]),
			"record_identity_missing", "a record without an identity is refused")
	_check_error(labels.merge_cell_labels([{"identity": {"scene_id": SCENE_ID},
			"label": Domain.LABEL_INTERIOR}]), "record_unkeyable",
			"an incomplete identity is refused")
	_check_error(labels.merge_cell_labels([{"identity": Domain.cell_identity("res://scenes/other.tscn",
			VOLUME_ID, 0, cell, LAYOUT_REVISION), "label": Domain.LABEL_INTERIOR}]),
			"identity_mismatch", "another scene's cell cannot enter this sidecar")
	_check_error(labels.merge_cell_labels([{"identity": Domain.cell_identity(SCENE_ID, "OtherVolume@1",
			0, cell, LAYOUT_REVISION), "label": Domain.LABEL_INTERIOR}]), "identity_mismatch",
			"another volume's cell is refused, so volumes cannot share one review archive")
	_check_error(labels.merge_cell_labels([{"identity": Domain.cell_identity(SCENE_ID, VOLUME_ID, 0,
			cell, LAYOUT_REVISION + 1), "label": Domain.LABEL_INTERIOR}]),
			"layout_revision_mismatch", "a cell from another layout revision is refused")
	_check(labels.cell_label_count() == 0, "a rejected import commits nothing")

	# A conflict is refused on import; the deliberate single setter may replace.
	_check_ok(labels.merge_cell_labels([{"identity": _identity(0, cell),
			"label": Domain.LABEL_INTERIOR}]), "the first halo record is accepted")
	_check_ok(labels.merge_cell_labels([{"identity": _identity(0, cell),
			"label": Domain.LABEL_INTERIOR}]), "an identical halo duplicate is accepted")
	_check_error(labels.merge_cell_labels([{"identity": _identity(0, cell),
			"label": Domain.LABEL_EXTERIOR}]), "conflicting_label",
			"a conflicting halo label is refused instead of depending on brick load order")
	_check(int(labels.get_cell_label(_identity(0, cell))) == Domain.LABEL_INTERIOR,
			"the refused conflict left the original label intact")
	_check_ok(labels.set_cell_label(_identity(0, cell), Domain.LABEL_EXTERIOR),
			"the deliberate single setter still replaces a label")
	_check(int(labels.get_cell_label(_identity(0, cell))) == Domain.LABEL_EXTERIOR,
			"the deliberate replacement is visible")

	# The seal covers the binding header and the label payload.
	labels.refresh_labels_hash()
	_check_ok(labels.validate(), "the replacement validates once resealed")
	labels.cell_labels[Domain.identity_key(_identity(0, cell))] = Domain.LABEL_INTERIOR
	_check_error(labels.validate(), "labels_hash_mismatch",
			"an edited label without resealing breaks the seal")
	labels.geometry_signature = GEOMETRY_SIGNATURE + 1
	labels.refresh_labels_hash()
	_check_ok(labels.validate(), "resealing after a binding change validates")
	labels.labels_hash = ""
	_check_error(labels.validate(), "empty_labels_hash", "an empty seal is refused")

	# Unknown schema, refused through a real file round trip as well.
	var future := _new_label_set()
	future.schema_version = LabelSet.SCHEMA_VERSION + 1
	future.refresh_labels_hash()
	_check(ResourceSaver.save(future, SCHEMA_PATH) == OK,
			"a future-schema sidecar can be written for the loader path")
	var reloaded: Resource = ResourceLoader.load(SCHEMA_PATH)
	if reloaded == null:
		_check(false, "the future-schema sidecar loads")
	else:
		_check_error(reloaded.validate(), "unsupported_schema_version",
				"an unknown schema version is refused after a real file round trip")

	var alien := _new_label_set()
	alien.subject_kind = "surface_probe"
	alien.refresh_labels_hash()
	_check_error(alien.validate(), "unsupported_subject_kind",
			"a non-clv_cell subject kind is refused: probes need their own schema")

	var unbound: Resource = LabelSet.new()
	unbound.refresh_labels_hash()
	_check_error(unbound.validate(), "unbound_volume_identity", "an unbound sidecar is refused")
	_check_error(unbound.configure("", VOLUME_ID, 0, 0, "sig"), "empty_volume_identity",
			"an empty scene id cannot be configured")
	_check_error(unbound.configure(SCENE_ID, VOLUME_ID, -1, 0, "sig"), "layout_revision_negative",
			"a negative layout revision cannot be configured")
	_check_error(unbound.configure(SCENE_ID, VOLUME_ID, 0, 0, ""), "empty_layout_signature",
			"an empty layout signature cannot be configured")


func _test_canonical_key_strictness() -> void:
	var cell := Vector3i(1, 2, 3)
	var canonical := Domain.identity_key(_identity(0, cell))
	_check(not canonical.is_empty(), "the canonical key exists for the strictness checks")

	var aliases := {
		"zero-padded lod": _aliased_key(_identity(0, cell), 2, "0"),
		"signed layout revision": _aliased_key(_identity(0, cell), 4, "+"),
		"zero-padded coordinate": _aliased_key(_identity(0, cell), 3, "0"),
		"negative-zero coordinate": _aliased_key(_identity(0, Vector3i(0, 2, 3)), 3, "-"),
	}
	for name: String in aliases:
		var alias: String = aliases[name]
		_check(alias != canonical and Domain.parse_identity_key(alias).is_empty(),
				"a %s spelling is refused instead of aliasing the canonical key" % name)
	_check(Domain.parse_identity_key(canonical) == _identity(0, cell),
			"the canonical key still parses after the strictness change")

	# Legal negative coordinates must survive the very same rule.
	var negative := _identity(0, Vector3i(-3, -12, 7))
	_check(Domain.parse_identity_key(Domain.identity_key(negative)) == negative,
			"legal negative coordinates still round-trip")
	_check(Domain.is_canonical_int_token("-3") and Domain.is_canonical_int_token("0")
			and not Domain.is_canonical_int_token("-0")
			and not Domain.is_canonical_int_token("+4")
			and not Domain.is_canonical_int_token("04")
			and not Domain.is_canonical_int_token("1.0"),
			"canonical integer tokens exclude padding, an explicit sign and -0")

	# Second layer: a dead record spelled with an alias must not survive
	# validate() even when the sidecar is freshly sealed over that payload, so
	# the seal cannot launder an aliased key.
	var dead_cell := _new_label_set()
	dead_cell.cell_labels[aliases["zero-padded lod"]] = Domain.LABEL_INTERIOR
	dead_cell.refresh_labels_hash()
	_check_error(dead_cell.validate(), "cell_record_key_not_canonical",
			"a freshly sealed sidecar still refuses a cell record with an alias key")

	var dead_receiver := _new_label_set()
	dead_receiver.receiver_labels[aliases["signed layout revision"]] = Domain.LABEL_EXTERIOR
	dead_receiver.refresh_labels_hash()
	_check_error(dead_receiver.validate(), "receiver_record_key_not_canonical",
			"a freshly sealed sidecar still refuses a receiver record with an alias key")

	# A walkable alias must not become a second record for one cell either.
	var alias_pair := _new_label_set()
	alias_pair.cell_labels[canonical] = Domain.LABEL_INTERIOR
	alias_pair.cell_labels[aliases["zero-padded lod"]] = Domain.LABEL_EXTERIOR
	alias_pair.refresh_labels_hash()
	_check(alias_pair.cell_label_count() == 2 and not bool(alias_pair.validate()["ok"]),
			"an alias key cannot coexist with its canonical key as two labels for one cell")


func _test_merge_atomicity() -> void:
	var labels := _new_label_set()
	var settled := Vector3i(1, 1, 1)
	var incoming := Vector3i(2, 1, 1)
	var illegal := Vector3i(3, 1, 1)
	_check_ok(labels.set_cell_label(_identity(0, settled), Domain.LABEL_INTERIOR),
			"a settled cell label exists before the batches")
	_check_ok(labels.set_receiver_label(_identity(0, settled), Domain.LABEL_EXTERIOR),
			"a settled receiver label exists before the batches")
	labels.refresh_labels_hash()
	_check_ok(labels.validate(), "the settled sidecar validates and is sealed")
	var before := _snapshot(labels)

	# Legal first record, then a record conflicting with a pre-existing label.
	_check_error(labels.merge_cell_labels([
		{"identity": _identity(0, incoming), "label": Domain.LABEL_INTERIOR},
		{"identity": _identity(0, settled), "label": Domain.LABEL_EXTERIOR},
	]), "conflicting_label", "a cell batch conflicting with an existing label is refused")
	_check_snapshot(labels, before,
			"a refused cell batch commits neither its new record nor any change: both dictionaries and the seal are unchanged")

	# Same batch, same key, two different labels.
	_check_error(labels.merge_cell_labels([
		{"identity": _identity(0, incoming), "label": Domain.LABEL_INTERIOR},
		{"identity": _identity(0, incoming), "label": Domain.LABEL_EXTERIOR},
	]), "conflicting_label", "a conflict inside one cell batch is refused")
	_check_snapshot(labels, before, "an intra-batch cell conflict commits nothing")

	# Legal first record, then an illegal trailing record.
	_check_error(labels.merge_cell_labels([
		{"identity": _identity(0, incoming), "label": Domain.LABEL_INTERIOR},
		{"identity": _identity(0, illegal), "label": Domain.LABEL_UNSET},
	]), "record_label_not_supervised", "a cell batch with an illegal trailing record is refused")
	_check_snapshot(labels, before,
			"an illegal trailing cell record rolls back the legal leading record")

	# The same three shapes for receiver_labels.
	_check_error(labels.merge_receiver_labels([
		{"identity": _identity(0, incoming), "label": Domain.LABEL_INTERIOR},
		{"identity": _identity(0, settled), "label": Domain.LABEL_INTERIOR},
	]), "conflicting_label", "a receiver batch conflicting with an existing label is refused")
	_check_snapshot(labels, before, "a refused receiver batch commits nothing")
	_check_error(labels.merge_receiver_labels([
		{"identity": _identity(0, incoming), "label": Domain.LABEL_INTERIOR},
		{"identity": _identity(0, incoming), "label": Domain.LABEL_AMBIGUOUS},
	]), "conflicting_label", "a conflict inside one receiver batch is refused")
	_check_snapshot(labels, before, "an intra-batch receiver conflict commits nothing")
	_check_error(labels.merge_receiver_labels([
		{"identity": _identity(0, incoming), "label": Domain.LABEL_INTERIOR},
		{"identity": _identity(0, illegal), "label": Domain.LABEL_UNSET},
	]), "record_label_not_supervised", "a receiver batch with an illegal trailing record is refused")
	_check_snapshot(labels, before,
			"an illegal trailing receiver record rolls back the legal leading record")

	_check_ok(labels.validate(), "the seal still matches its payload after every refused batch")
	_check(not labels.has_cell_label(_identity(0, incoming))
			and not labels.has_cell_label(_identity(0, illegal))
			and not labels.has_receiver_label(_identity(0, incoming)),
			"no record from a refused batch is present")
	_check_ok(labels.merge_cell_labels([{"identity": _identity(0, incoming),
			"label": Domain.LABEL_INTERIOR}]),
			"the same batch succeeds once the conflicting record is removed")
	_check(int(labels.get_cell_label(_identity(0, incoming))) == Domain.LABEL_INTERIOR,
			"the now-valid record commits")
	_check(_snapshot(labels)["cell"] != before["cell"],
			"an accepted batch does change the dictionary, so the snapshot assertions above are not vacuous")


func _snapshot(labels: Resource) -> Dictionary:
	return {
		"cell": labels.cell_labels.duplicate(),
		"receiver": labels.receiver_labels.duplicate(),
		"hash": String(labels.labels_hash),
	}


## Committing anything from a refused batch means the live dictionary was
## mutated where a copy was required, so the entire dictionaries and the seal
## are compared, not just the records the batch happened to mention.
func _check_snapshot(labels: Resource, before: Dictionary, message: String) -> void:
	var after := _snapshot(labels)
	_check(after["cell"] == before["cell"] and after["receiver"] == before["receiver"]
			and after["hash"] == before["hash"], message)


## A key that spells one field differently ("00" for "0", "+4" for "4") and so
## would alias the same identity under a laxer parser.
func _aliased_key(identity: Dictionary, part_index: int, prefix: String) -> String:
	var parts := Domain.identity_key(identity).split(Domain.FIELD_SEPARATOR, true)
	parts[part_index] = prefix + parts[part_index]
	return Domain.FIELD_SEPARATOR.join(parts)


func _test_tampered_seal_gate() -> void:
	var receiver_cell := Vector3i(1, 1, 1)
	var candidate_cell := Vector3i(4, 1, 1)
	var labels := _new_label_set()
	_check_ok(labels.set_receiver_label(_identity(0, receiver_cell), Domain.LABEL_INTERIOR),
			"the tamper control records a receiver domain")
	_check_ok(labels.set_cell_label(_identity(0, candidate_cell), Domain.LABEL_INTERIOR),
			"the tamper control records a candidate domain")
	labels.refresh_labels_hash()
	_check_ok(labels.validate(), "the tamper control sidecar is sealed and valid")

	var intact: Dictionary = labels.gate_inputs(_identity(0, receiver_cell),
			_identity(0, candidate_cell), SCENE_ID, VOLUME_ID, LAYOUT_REVISION, GEOMETRY_SIGNATURE,
			LAYOUT_SIGNATURE)
	_check(bool(intact["hashes_match"]) and Domain.decide(int(intact["receiver_label"]),
			FIXTURE_CONFIDENCE, int(intact["candidate_label"]), FIXTURE_CONFIDENCE,
			bool(intact["hashes_match"]), FIXTURE_MIN_CONFIDENCE) == Domain.DECISION_ALLOW,
			"the intact control pair allows under the same expected bake")

	# Tamper the payload only. Every expected bake field stays byte-for-byte the
	# same, so matches_bake() is still true and only the seal can notice.
	labels.cell_labels[Domain.identity_key(_identity(0, candidate_cell))] = Domain.LABEL_EXTERIOR
	_check(bool(labels.matches_bake(SCENE_ID, VOLUME_ID, LAYOUT_REVISION, GEOMETRY_SIGNATURE,
			LAYOUT_SIGNATURE)),
			"the tampered sidecar still names the same bake, so matches_bake() alone cannot catch it")

	var tampered: Dictionary = labels.gate_inputs(_identity(0, receiver_cell),
			_identity(0, candidate_cell), SCENE_ID, VOLUME_ID, LAYOUT_REVISION, GEOMETRY_SIGNATURE,
			LAYOUT_SIGNATURE)
	_check(String(tampered["error"]) == "labels_hash_mismatch",
			"the gate reports the seal failure rather than trusting the labels")
	_check(not bool(tampered["hashes_match"]),
			"a tampered payload reports hashes_match=false although the expected bake never changed")
	_check(Domain.decide(int(tampered["receiver_label"]), FIXTURE_CONFIDENCE,
			int(tampered["candidate_label"]), FIXTURE_CONFIDENCE, bool(tampered["hashes_match"]),
			FIXTURE_MIN_CONFIDENCE) == Domain.DECISION_ABSTAIN,
			"a tampered payload abstains instead of applying an unverified label")

	# A/B: resealing the identical payload turns the identical inputs into a
	# REJECT, so the seal produced the abstain above. A gate missing the
	# validate() conjunct would have returned REJECT for the tampered pair.
	labels.refresh_labels_hash()
	var resealed: Dictionary = labels.gate_inputs(_identity(0, receiver_cell),
			_identity(0, candidate_cell), SCENE_ID, VOLUME_ID, LAYOUT_REVISION, GEOMETRY_SIGNATURE,
			LAYOUT_SIGNATURE)
	_check(bool(resealed["hashes_match"]) and Domain.decide(int(resealed["receiver_label"]),
			FIXTURE_CONFIDENCE, int(resealed["candidate_label"]), FIXTURE_CONFIDENCE,
			bool(resealed["hashes_match"]), FIXTURE_MIN_CONFIDENCE) == Domain.DECISION_REJECT,
			"resealing the same payload yields REJECT, proving the seal produced the abstain")


func _test_seal_encoding_injectivity() -> void:
	# A/B: side B moves one cell record's exact text into layout_signature and
	# drops the record. Under the retired plain concatenation both sidecars
	# produce byte-identical seal input; under the canonical encoding they must
	# not, so a record can never be smuggled through another field.
	var record_cell := Vector3i(1, 2, 3)
	var record_key := Domain.identity_key(_identity(0, record_cell))
	var plain := _new_label_set()
	_check_ok(plain.set_cell_label(_identity(0, record_cell), Domain.LABEL_INTERIOR),
			"the A side records one cell label")
	plain.refresh_labels_hash()

	var smuggled := _new_label_set()
	smuggled.layout_signature = LAYOUT_SIGNATURE + "\ncell" + Domain.FIELD_SEPARATOR + record_key \
			+ Domain.FIELD_SEPARATOR + str(Domain.LABEL_INTERIOR)
	smuggled.refresh_labels_hash()

	_check(plain.cell_label_count() == 1 and smuggled.cell_label_count() == 0,
			"the A/B sides really differ: one holds the record, the other only its text")
	_check(_retired_payload_text(plain) == _retired_payload_text(smuggled),
			"the retired concatenation really did collide for these two sidecars")
	_check(plain.compute_labels_hash() != smuggled.compute_labels_hash(),
			"the canonical seal encoding gives the colliding sidecars different hashes")
	_check_ok(smuggled.validate(),
			"the smuggled sidecar is itself well sealed: the encoding separates them, not a newline ban")
	_check(smuggled.seal_payload_json().contains("\\n"),
			"the canonical encoding escapes the embedded newline instead of splitting the payload")
	_check(JSON.parse_string(smuggled.seal_payload_json()) is Dictionary,
			"the seal input is valid canonical JSON")
	_check(smuggled.seal_payload_json() == JSON.stringify(smuggled.seal_payload(), "", true, true),
			"the seal encoding is reproducible, so the seal survives a reload")

	# Dictionary iteration order must not leak into the seal either.
	var forward := _new_label_set()
	forward.set_cell_label(_identity(0, Vector3i(5, 0, 0)), Domain.LABEL_INTERIOR)
	forward.set_cell_label(_identity(0, Vector3i(1, 0, 0)), Domain.LABEL_EXTERIOR)
	forward.refresh_labels_hash()
	var backward := _new_label_set()
	backward.set_cell_label(_identity(0, Vector3i(1, 0, 0)), Domain.LABEL_EXTERIOR)
	backward.set_cell_label(_identity(0, Vector3i(5, 0, 0)), Domain.LABEL_INTERIOR)
	backward.refresh_labels_hash()
	_check(forward.compute_labels_hash() == backward.compute_labels_hash(),
			"the canonical encoding ignores insertion order, so a reloaded sidecar keeps its seal")


## The retired seal input, kept only as the A/B control: plain newline-joined
## concatenation with no escaping. The test above shows it is not injective. It
## never seals anything.
func _retired_payload_text(labels: Resource) -> String:
	var lines := PackedStringArray([
		"schema%s%d" % [Domain.FIELD_SEPARATOR, labels.schema_version],
		"subject%s%s" % [Domain.FIELD_SEPARATOR, labels.subject_kind],
		"scene%s%s" % [Domain.FIELD_SEPARATOR, labels.scene_id],
		"volume%s%s" % [Domain.FIELD_SEPARATOR, labels.volume_id],
		"layout_revision%s%d" % [Domain.FIELD_SEPARATOR, labels.layout_revision],
		"geometry_signature%s%d" % [Domain.FIELD_SEPARATOR, labels.geometry_signature],
		"layout_signature%s%s" % [Domain.FIELD_SEPARATOR, labels.layout_signature],
	])
	var keys := PackedStringArray()
	for key: String in labels.cell_labels:
		keys.append(key)
	keys.sort()
	for key in keys:
		lines.append("cell%s%s%s%d" % [Domain.FIELD_SEPARATOR, key, Domain.FIELD_SEPARATOR,
				int(labels.cell_labels[key])])
	keys = PackedStringArray()
	for key: String in labels.receiver_labels:
		keys.append(key)
	keys.sort()
	for key in keys:
		lines.append("receiver%s%s%s%d" % [Domain.FIELD_SEPARATOR, key, Domain.FIELD_SEPARATOR,
				int(labels.receiver_labels[key])])
	return "\n".join(lines)


func _test_prepared_brick_orthogonality() -> void:
	var brick := _make_brick(Vector3i.ZERO, Vector3i(2, 2, 2), Vector3i.ZERO, Vector3i(2, 2, 2))
	_check(brick.is_valid(), "the minimal prepared brick fixture is valid before any label exists")
	var operators_before: PackedFloat32Array = brick.operators.duplicate()
	var validity_before: PackedByteArray = brick.validity.duplicate()
	_check(ResourceSaver.save(brick, BRICK_PATH) == OK, "the brick fixture saves for byte comparison")
	var bytes_before := FileAccess.get_file_as_bytes(BRICK_PATH)

	# Full label lifecycle, including labels that name this brick's own cells.
	var labels := _new_label_set()
	_check_ok(labels.set_receiver_label(_identity(0, Vector3i(0, 0, 0)), Domain.LABEL_INTERIOR),
			"a receiver label names a cell of the brick fixture")
	_check_ok(labels.merge_cell_labels([
		{"identity": _identity(0, Vector3i(0, 0, 0)), "label": Domain.LABEL_INTERIOR},
		{"identity": _identity(0, Vector3i(1, 0, 0)), "label": Domain.LABEL_EXTERIOR},
	]), "cross-domain labels are recorded beside the brick")
	labels.refresh_labels_hash()
	_check_ok(labels.validate(), "the label set beside the brick is valid")
	_check(ResourceSaver.save(labels, LABEL_PATH) == OK, "the label set saves next to the brick")
	var reloaded: Resource = ResourceLoader.load(LABEL_PATH)
	_check(reloaded != null and bool(reloaded.validate()["ok"]),
			"the label set reloads and validates independently of the brick")
	_check(ResourceSaver.save(brick, BRICK_PATH) == OK, "the brick fixture re-saves after the label lifecycle")

	var bytes_after := FileAccess.get_file_as_bytes(BRICK_PATH)
	_check(bytes_before == bytes_after,
			"serialized prepared brick bytes are identical before and after the label lifecycle")
	_check(brick.operators == operators_before and brick.validity == validity_before,
			"prepared operators and validity are byte-identical after the label lifecycle")
	_check(brick.is_valid(), "the prepared brick is still valid: domain labels never enter validity")
	var every_cell_supported := true
	for index in brick.cell_count():
		every_cell_supported = every_cell_supported and brick.validity[index] == 1
	_check(every_cell_supported, "no label turned an operator-supported cell invalid")


func _test_multi_room_limitation() -> void:
	# KNOWN v1 LIMITATION, asserted on purpose rather than hidden: two different
	# rooms that are both INTERIOR are indistinguishable to an interior/exterior
	# gate, so this gate ALLOWs across them. Multi-room isolation needs the
	# separate Depth/mixed route and is not claimed as solved by OLV v1.
	var labels := _new_label_set()
	var room_a := Vector3i(1, 1, 1)
	var room_b := Vector3i(1, 1, 9)
	_check_ok(labels.set_receiver_label(_identity(0, room_a), Domain.LABEL_INTERIOR),
			"room A is labelled INTERIOR")
	_check_ok(labels.set_cell_label(_identity(0, room_b), Domain.LABEL_INTERIOR),
			"room B is labelled INTERIOR too")
	labels.refresh_labels_hash()
	var inputs: Dictionary = labels.gate_inputs(_identity(0, room_a), _identity(0, room_b),
			SCENE_ID, VOLUME_ID, LAYOUT_REVISION, GEOMETRY_SIGNATURE, LAYOUT_SIGNATURE)
	var decision := Domain.decide(int(inputs["receiver_label"]), FIXTURE_CONFIDENCE,
			int(inputs["candidate_label"]), FIXTURE_CONFIDENCE, bool(inputs["hashes_match"]),
			FIXTURE_MIN_CONFIDENCE)
	_check(decision == Domain.DECISION_ALLOW,
			"KNOWN LIMITATION: two rooms that are both INTERIOR are allowed to blend; OLV v1 does not separate them")
	print("MAGIC_GI_OLV_KNOWN_LIMITATION rooms=", room_a, "/", room_b, " decision=",
			Domain.decision_name(decision))


## The smallest brick FMagicGIPreparedTransferBrick's own validator accepts: a
## header consistent with a real prepared page, no bake and no GPU involved.
func _make_brick(cell_origin: Vector3i, dimensions: Vector3i, core_cell_origin: Vector3i,
		core_dimensions: Vector3i) -> Resource:
	var brick: Resource = Brick.new()
	brick.format_version = 1
	brick.operator_schema_version = 2
	brick.level = 0
	brick.cell_origin = cell_origin
	brick.dimensions = dimensions
	brick.core_cell_origin = core_cell_origin
	brick.core_dimensions = core_dimensions
	brick.source_spacing_m = 0.25
	brick.source_origin_world = Vector3.ZERO
	brick.source_transform_world = Transform3D.IDENTITY
	brick.source_size_m = Vector3.ONE
	brick.domain_bounds_world = Transform3D.IDENTITY * AABB(-brick.source_size_m * 0.5,
			brick.source_size_m)
	brick.directional_source_signature = "olv-fixture-directional-source"
	brick.geometry_signature = GEOMETRY_SIGNATURE
	brick.probe_count = brick.cell_count()
	brick.emitter_count = 0
	brick.emitter_ids = PackedStringArray()
	brick.emitter_static_signatures = PackedInt64Array()
	var operators := PackedFloat32Array()
	operators.resize(brick.cell_count() * brick.operator_stride())
	operators.fill(0.01)
	brick.operators = operators
	var validity := PackedByteArray()
	validity.resize(brick.cell_count())
	validity.fill(1)
	brick.validity = validity
	brick.maximum_operator_row_l1 = _maximum_row_l1(brick)
	return brick


## Accumulated exactly the way is_valid() accumulates, so the declared bound can
## never spuriously reject the fixture.
func _maximum_row_l1(brick: Resource) -> float:
	var maximum := 0.0
	var columns: int = brick.operator_columns()
	var output_count: int = brick.operator_output_coefficient_count()
	for cell in brick.cell_count():
		for row in output_count:
			var row_l1 := 0.0
			for column in columns:
				row_l1 += absf(brick.operators[(cell * output_count + row) * columns + column])
			maximum = maxf(maximum, row_l1)
	return maximum


@warning_ignore("integer_division")
func _global_cell_of(brick: Resource, local_index: int) -> Vector3i:
	var dimensions: Vector3i = brick.dimensions
	var x := local_index % dimensions.x
	var y := (local_index / dimensions.x) % dimensions.y
	var z := local_index / (dimensions.x * dimensions.y)
	return brick.cell_origin + Vector3i(x, y, z)
