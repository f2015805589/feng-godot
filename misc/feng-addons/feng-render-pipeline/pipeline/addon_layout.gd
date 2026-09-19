@tool
class_name FengAddonLayout
extends RefCounted
## Where the addon's own files live, resolved once for every module that loads them.
##
## The addon is a directory a project copies into `res://addons/`, so its paths are
## derived from this script's own location rather than hard-coded: a renamed or moved
## copy keeps working. Everything the addon loads from its own tree (the pipeline
## modules, the native pass scripts, the library templates) is addressed through here,
## so the layout is stated in exactly one place.

const CANONICAL_DIR := "res://addons/feng-render-pipeline"

static func dir() -> String:
	var script: Script = FengAddonLayout
	var script_path := script.resource_path if script != null else ""
	if script_path.is_empty():
		# Only reachable for a script with no file behind it (never true for the addon);
		# the canonical location is the best guess and keeps the paths well formed.
		return CANONICAL_DIR
	return script_path.get_base_dir().get_base_dir()

static func pipeline_dir() -> String:
	return dir() + "/pipeline"

static func passes_dir() -> String:
	return dir() + "/passes/"

static func library_dir() -> String:
	return dir() + "/library"

## Script of the autoload the editor plugin registers, which installs the project
## pipeline into a running game (see project_pipeline.gd).
static func pipeline_autoload_path() -> String:
	return dir() + "/project_pipeline.gd"
