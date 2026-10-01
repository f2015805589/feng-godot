extends RefCounted
## Two-phase filename relocation. No terrain/native dependency and no deletion.
## Callers must keep the directory idle while executing: DirAccess has no atomic
## no-replace rename or cross-file transaction. A process crash is not rolled back.


static func build_plan(files: PackedStringArray, offset: Vector2i, decode: Callable, encode: Callable, exists: Callable, minimum: int = -16, maximum: int = 15) -> Dictionary:
	var moves: Array[Dictionary] = []
	for source in files:
		if not source.match("terrain3d*.res"):
			continue
		var location: Vector2i = decode.call(source)
		if str(encode.call(location)) != source:
			return _failure(ERR_INVALID_DATA, "Malformed region filename: " + source)
		# Do the addition as 64-bit integers before constructing Vector2i, whose
		# components could otherwise wrap on a very large authored offset.
		var x := int(location.x) + int(offset.x)
		var y := int(location.y) + int(offset.y)
		if x < minimum or x > maximum or y < minimum or y > maximum:
			return _failure(ERR_INVALID_PARAMETER, "Moved region is outside supported bounds: " + source)
		var target: String = encode.call(Vector2i(x, y))
		if target == source:
			continue
		moves.append({"source": source, "target": target, "temporary": "tmp_" + target})
	var validation := validate_plan(moves, exists)
	if validation["error"] != OK:
		return validation
	return {"error": OK, "message": "", "moves": moves}


static func validate_plan(moves: Array[Dictionary], exists: Callable) -> Dictionary:
	var sources := {}
	var targets := {}
	var temporary_paths := {}
	for move in moves:
		for key in ["source", "target", "temporary"]:
			var name: Variant = move.get(key)
			if not name is String or name.is_empty() or name.get_file() != name or name in [".", ".."] or "\\" in name:
				return _failure(ERR_INVALID_DATA, "Region move contains an invalid relative filename")
		if sources.has(move["source"]) or targets.has(move["target"]) or temporary_paths.has(move["temporary"]):
			return _failure(ERR_INVALID_DATA, "Region move contains duplicate paths")
		sources[move["source"]] = true
		targets[move["target"]] = true
		temporary_paths[move["temporary"]] = true
	for move in moves:
		if not exists.call(move["source"]):
			return _failure(ERR_FILE_NOT_FOUND, "Region disappeared before moving: " + str(move["source"]))
		if exists.call(move["target"]) and not sources.has(move["target"]):
			return _failure(ERR_ALREADY_EXISTS, "Destination already exists: " + str(move["target"]))
		if sources.has(move["temporary"]) or targets.has(move["temporary"]) or exists.call(move["temporary"]):
			return _failure(ERR_ALREADY_EXISTS, "Temporary move path already exists: " + str(move["temporary"]))
	return {"error": OK, "message": ""}


static func execute(plan: Dictionary, rename: Callable, exists: Callable) -> Dictionary:
	if int(plan.get("error", ERR_INVALID_DATA)) != OK:
		return plan
	var moves: Array[Dictionary] = []
	for move in plan.get("moves", []):
		moves.append(move.duplicate())
	var validation := validate_plan(moves, exists)
	if validation["error"] != OK:
		return validation
	for move in moves:
		move["current"] = move["source"]
	# Phase one vacates every source. This permits chains, swaps and cycles
	# without overwriting a region that has not moved yet.
	for move in moves:
		var error := _rename_without_replacement(move["current"], move["temporary"], rename, exists)
		if error != OK:
			return _rollback(moves, error, "Could not stage region: " + str(move["source"]), rename, exists)
		move["current"] = move["temporary"]
	# Phase two publishes all final names only after every source is safe.
	for move in moves:
		var error := _rename_without_replacement(move["current"], move["target"], rename, exists)
		if error != OK:
			return _rollback(moves, error, "Could not publish region: " + str(move["target"]), rename, exists)
		move["current"] = move["target"]
	return {"error": OK, "message": "", "moved": moves.size(), "rollback_complete": true, "recovery": []}


static func _rename_without_replacement(source: String, target: String, rename: Callable, exists: Callable) -> Error:
	if exists.call(target):
		return ERR_ALREADY_EXISTS
	return rename.call(source, target)


static func _rollback(moves: Array[Dictionary], error: Error, message: String, rename: Callable, exists: Callable) -> Dictionary:
	var rollback_errors: Array[String] = []
	# First return already published targets to their unique temporary paths,
	# so restoring sources remains safe even for swaps and cycles.
	for i in range(moves.size() - 1, -1, -1):
		var move := moves[i]
		if move["current"] != move["target"]:
			continue
		var rollback_error := _rename_without_replacement(move["current"], move["temporary"], rename, exists)
		if rollback_error == OK:
			move["current"] = move["temporary"]
		else:
			rollback_errors.append(str(move["current"]) + ": " + error_string(rollback_error))
	for i in range(moves.size() - 1, -1, -1):
		var move := moves[i]
		if move["current"] == move["source"]:
			continue
		var rollback_error := _rename_without_replacement(move["current"], move["source"], rename, exists)
		if rollback_error == OK:
			move["current"] = move["source"]
		else:
			rollback_errors.append(str(move["current"]) + ": " + error_string(rollback_error))
	var recovery: Array[Dictionary] = []
	for move in moves:
		if move["current"] != move["source"]:
			recovery.append({"original": move["source"], "current": move["current"]})
	return {"error": error, "message": message, "rollback_complete": recovery.is_empty(), "rollback_errors": rollback_errors, "recovery": recovery}


static func _failure(error: Error, message: String) -> Dictionary:
	return {"error": error, "message": message, "rollback_complete": true, "recovery": []}
