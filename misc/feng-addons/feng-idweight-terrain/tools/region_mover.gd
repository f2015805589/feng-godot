# This script can be used to move your regions by an offset. 
# Eventually this tool will find its way into a built in UI
# 
# Attach it to your Terrain3D node
# Save and reload your scene
# Select your Terrain3D node
# Enter a valid `offset` where all regions will be within -16, +15
# Run it
# It should unload the regions, rename files, and reload them
# Clear the script and resave your scene


@tool
extends Terrain3D


const MoveTransaction = preload("res://addons/feng-idweight-terrain/tools/region_move_transaction.gd")

@export var offset: Vector2i
@export_tool_button("Run") var run = start_rename


func start_rename() -> void:
	if offset == Vector2i.ZERO:
		return
	var directory := data_directory
	var dir := DirAccess.open(directory)
	if dir == null:
		push_error("Cannot open terrain directory: " + directory)
		return
	var exists := func(path: String) -> bool:
		return dir.file_exists(path) or dir.dir_exists(path) or dir.is_link(path)
	# Planning validates every filename, bound and collision before detaching
	# the terrain or renaming any file. Existing files are never overwritten.
	var plan := MoveTransaction.build_plan(dir.get_files(), offset,
		Terrain3DUtil.filename_to_location, Terrain3DUtil.location_to_filename, exists)
	if plan["error"] != OK:
		push_error(plan["message"])
		return
	data_directory = ""
	var result := MoveTransaction.execute(plan, dir.rename, exists)
	# Restore the component even after a failed rename or incomplete rollback.
	data_directory = directory
	EditorInterface.get_resource_filesystem().scan()
	if result["error"] != OK:
		push_error(str(result["message"]) + ": " + error_string(result["error"]))
		if not bool(result.get("rollback_complete", true)):
			push_error("Rollback was incomplete. No files were deleted; recover these names before retrying: " + str(result["recovery"]))
		return
	print("Moved %d terrain region files in %s" % [result["moved"], directory])
