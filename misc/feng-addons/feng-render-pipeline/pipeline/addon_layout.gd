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

static func dir() -> String:
	var script: Script = FengAddonLayout
	return script.resource_path.get_base_dir().get_base_dir()

static func passes_dir() -> String:
	return dir() + "/passes/"

static func library_dir() -> String:
	return dir() + "/library"

## Script of the autoload the editor plugin registers, which installs the project
## pipeline into a running game (see project_pipeline.gd).
static func pipeline_autoload_path() -> String:
	return dir() + "/project_pipeline.gd"
