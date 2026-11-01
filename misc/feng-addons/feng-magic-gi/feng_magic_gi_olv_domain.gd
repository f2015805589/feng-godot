@tool
extends RefCounted
## OLV v1 visibility-domain contract for `clv_cell` subjects.
##
## The label answers "which visibility domain is this cell in", never "where
## should the probe move". This file owns the enum, the stable cell identity and
## the per-corner gate only: it never writes prepared `validity` (operator
## support), never touches source relocation and never modifies a transfer
## operator, so a domain label can never invalidate a supported cell.
##
## The gate below is this project's frozen experiment contract, not a claim
## about any third-party algorithm: the same trusted domain may blend, a
## different trusted domain is rejected before interpolation and normalization,
## and anything uncertain abstains to the complete legacy path. ABSTAIN must not
## be re-interpreted as "reject everything".
##
## Known v1 limitation: two rooms that are both INTERIOR share one label, so
## this gate cannot separate them. Multi-room isolation needs a Depth/mixed
## route and is deliberately outside OLV v1.

## No effective label. Not a training class: a model never predicts it, and it
## is never stored as a record in a label set.
const LABEL_UNSET := 0
const LABEL_EXTERIOR := 1
const LABEL_INTERIOR := 2
## Explicit ambiguity from geometry or human review. Supervised, but it decides
## ABSTAIN rather than pretending one domain is correct.
const LABEL_AMBIGUOUS := 3

const LABEL_NAMES := ["UNSET", "EXTERIOR", "INTERIOR", "AMBIGUOUS"]

## Labels a classifier may be trained on. UNSET is excluded on purpose.
const SUPERVISED_LABELS := [LABEL_EXTERIOR, LABEL_INTERIOR, LABEL_AMBIGUOUS]

## Domains the gate can act on. AMBIGUOUS is supervised but never decidable:
## an ambiguous corner must abstain instead of picking a side.
const GATE_LABELS := [LABEL_EXTERIOR, LABEL_INTERIOR]

const DECISION_ALLOW := 0
const DECISION_REJECT := 1
## Keep the old path unchanged: this is a full fallback, not a rejection.
const DECISION_ABSTAIN := 2

const DECISION_NAMES := ["ALLOW", "REJECT", "ABSTAIN"]

## Prepared clipmaps publish levels L0..L9 so a label can address any level the
## paged cache can resolve.
const MIN_LOD := 0
const MAX_LOD := 9

const SUBJECT_KIND_CLV_CELL := "clv_cell"

## Canonical identity fields are joined with U+001F so free-form scene/volume
## identifiers cannot forge a different tuple by embedding the separator.
const FIELD_SEPARATOR := "\u001f"


static func is_valid_label(label: int) -> bool:
	return label >= LABEL_UNSET and label < LABEL_NAMES.size()


static func is_supervised_label(label: int) -> bool:
	return SUPERVISED_LABELS.has(label)


## True only for the two domains the gate may blend or reject across.
static func is_decidable_label(label: int) -> bool:
	return GATE_LABELS.has(label)


static func label_name(label: int) -> String:
	return LABEL_NAMES[label] if is_valid_label(label) else "INVALID(%d)" % label


static func decision_name(decision: int) -> String:
	return DECISION_NAMES[decision] if decision >= 0 and decision < DECISION_NAMES.size() \
			else "INVALID(%d)" % decision


## Stable identity of one `clv_cell`. Brick-local indices are deliberately not
## part of it: the paged cache duplicates a global cell into neighboring halos,
## so the same global cell must resolve to one identity no matter which brick
## or halo copy delivered it.
static func cell_identity(scene_id: String, volume_id: String, lod: int,
		global_cell: Vector3i, layout_revision: int) -> Dictionary:
	return {
		"scene_id": scene_id,
		"volume_id": volume_id,
		"lod": lod,
		"global_cell": global_cell,
		"layout_revision": layout_revision,
	}


## Reason an identity cannot be keyed, or "" when it can. Callers get a specific
## cause instead of a silently merged or colliding label.
static func identity_error(identity: Dictionary) -> String:
	var scene_id: Variant = identity.get("scene_id")
	var volume_id: Variant = identity.get("volume_id")
	if not scene_id is String or not volume_id is String:
		return "identity_identifiers_not_string"
	if String(scene_id).is_empty():
		return "identity_scene_id_empty"
	if String(volume_id).is_empty():
		return "identity_volume_id_empty"
	if String(scene_id).contains(FIELD_SEPARATOR) or String(volume_id).contains(FIELD_SEPARATOR):
		return "identity_identifier_contains_field_separator"
	if typeof(identity.get("lod")) != TYPE_INT:
		return "identity_lod_not_int"
	var lod := int(identity.get("lod"))
	if lod < MIN_LOD or lod > MAX_LOD:
		return "identity_lod_out_of_range"
	if typeof(identity.get("layout_revision")) != TYPE_INT:
		return "identity_layout_revision_not_int"
	if int(identity.get("layout_revision")) < 0:
		return "identity_layout_revision_negative"
	if not identity.get("global_cell") is Vector3i:
		return "identity_global_cell_not_vector3i"
	return ""


## Canonical key, or "" when the identity is not keyable. Different scene,
## volume, lod, global cell or layout revision can never share a key.
static func identity_key(identity: Dictionary) -> String:
	if not identity_error(identity).is_empty():
		return ""
	var cell: Vector3i = identity["global_cell"]
	return FIELD_SEPARATOR.join(PackedStringArray([
		String(identity["scene_id"]),
		String(identity["volume_id"]),
		str(int(identity["lod"])),
		"%d,%d,%d" % [cell.x, cell.y, cell.z],
		str(int(identity["layout_revision"])),
	]))


## A canonical integer token carries no sign padding, no leading zero and no
## "-0", so one identity cannot be spelled two ways and alias another record.
## Legal negative coordinates survive: str(int("-3")) == "-3".
static func is_canonical_int_token(token: String) -> bool:
	return token.is_valid_int() and str(token.to_int()) == token


## Inverse of `identity_key`; {} unless the key is exactly canonical.
static func parse_identity_key(key: String) -> Dictionary:
	var parts := key.split(FIELD_SEPARATOR, true)
	if parts.size() != 5:
		return {}
	if not is_canonical_int_token(parts[2]) or not is_canonical_int_token(parts[4]):
		return {}
	var coordinates := parts[3].split(",", true)
	if coordinates.size() != 3:
		return {}
	for text in coordinates:
		if not is_canonical_int_token(text):
			return {}
	var identity := cell_identity(parts[0], parts[1], int(parts[2]),
			Vector3i(int(coordinates[0]), int(coordinates[1]), int(coordinates[2])), int(parts[4]))
	return {} if not identity_error(identity).is_empty() else identity


## Per-corner gate. `minimum_confidence` is an explicit, caller-owned policy
## value: this contract ships no default so no unexplained threshold can hide
## inside it. A hand-authored fixture may pass 1.0.
##
## ABSTAIN is returned for a hash mismatch, for either side being UNSET,
## AMBIGUOUS or invalid, and for either confidence below the caller's threshold
## or non-finite. Only two decidable labels that both pass can ALLOW or REJECT.
static func decide(receiver_label: int, receiver_confidence: float,
		candidate_label: int, candidate_confidence: float,
		hashes_match: bool, minimum_confidence: float) -> int:
	if not hashes_match:
		return DECISION_ABSTAIN
	if not is_decidable_label(receiver_label) or not is_decidable_label(candidate_label):
		return DECISION_ABSTAIN
	if not confidence_passes(receiver_confidence, minimum_confidence):
		return DECISION_ABSTAIN
	if not confidence_passes(candidate_confidence, minimum_confidence):
		return DECISION_ABSTAIN
	return DECISION_ALLOW if receiver_label == candidate_label else DECISION_REJECT


## A non-finite confidence or threshold fails closed instead of comparing.
static func confidence_passes(confidence: float, minimum_confidence: float) -> bool:
	if not is_finite(confidence) or not is_finite(minimum_confidence):
		return false
	return confidence >= minimum_confidence
