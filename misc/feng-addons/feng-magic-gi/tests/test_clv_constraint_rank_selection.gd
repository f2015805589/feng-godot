extends SceneTree
## CPU-only checks for SH2 constraint rank and nearest-surface priority.

const Builder = preload("../feng_magic_gi_clv_transfer_builder.gd")
var checks := 0
var failures := 0

func _initialize() -> void:
	call_deferred("run")

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error(message)

func run() -> void:
	var opposing_axis_bases: Array[PackedFloat64Array] = [
		_basis(Vector3.DOWN), _basis(Vector3.RIGHT), _basis(Vector3.UP), _basis(Vector3.LEFT)]
	var opposing_selection := Builder.rank_independent_constraint_indices(opposing_axis_bases)
	check(opposing_selection == PackedInt32Array([0, 1, 2]),
		"±X/±Y SH2 rows have rank three; the nearest three stay and the fourth is not averaged into the fit")
	check(opposing_selection.size() < opposing_axis_bases.size(),
		"dependent opposite-normal rows are explicitly omitted")
	check(opposing_selection.size() > 0 and opposing_selection[0] == 0,
		"the nearest -Y roof row is retained ahead of its opposite and side constraints")

	var four_independent_bases: Array[PackedFloat64Array] = [
		_basis(Vector3.DOWN), _basis(Vector3.UP), _basis(Vector3.RIGHT), _basis(Vector3.BACK)]
	var four_selection := Builder.rank_independent_constraint_indices(four_independent_bases)
	check(four_selection == PackedInt32Array([0, 1, 2, 3]),
		"four independent SH2 directional rows retain all four constraints")

	var arbitrary_vectors: Array[PackedFloat64Array] = [
		PackedFloat64Array([1.0, 0.0, 0.0, 0.0]),
		PackedFloat64Array([1.0, 1.0, 0.0, 0.0]),
		PackedFloat64Array([1.0, 0.0, 1.0, 0.0]),
		PackedFloat64Array([1.0, 1.0, 1.0, 0.0]),
		PackedFloat64Array([1.0, 0.0, 0.0, 1.0])]
	var arbitrary_selection := Builder.rank_independent_constraint_indices(arbitrary_vectors)
	check(arbitrary_selection == PackedInt32Array([0, 1, 2, 4]),
		"rank revealing is based on the response basis, not special-cased world-axis normals")

	var limited_selection := Builder.rank_independent_constraint_indices(four_independent_bases, 2)
	check(limited_selection == PackedInt32Array([0, 1]),
		"a tighter rank cap still preserves nearest-first ordering")
	check(Builder.REVISION == 4,
		"the all-level direct footprint revision invalidates stale prepared operators")
	_finish()

func _basis(normal: Vector3) -> PackedFloat64Array:
	var full: PackedFloat64Array = Builder._irradiance_basis(normal)
	var result := PackedFloat64Array()
	result.resize(4)
	for index in 4:
		result[index] = full[index]
	return result

func _finish() -> void:
	print("CLV_CONSTRAINT_RANK_SELECTION_TESTS ", JSON.stringify({"checks": checks, "failures": failures}))
	quit(1 if failures > 0 else 0)
