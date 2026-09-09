#include "register_types.h"

#include "core/config/project_settings.h"
#include "core/object/class_db.h"
#include "feng_renderdoc.h"
#include "modules/register_module_types.h"

static FengRenderDoc *_feng_renderdoc = nullptr;

void initialize_feng_renderdoc_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SERVERS) {
		return;
	}
	// Register project settings so the toggle is visible and GLOBAL_GET has
	// defaults. The editor plugin mirrors its Editor Settings toggle into
	// these keys before the editor restarts.
	if (!ProjectSettings::get_singleton()->has_setting("rendering/renderdoc/enable")) {
		ProjectSettings::get_singleton()->set_setting("rendering/renderdoc/enable", false);
	}
	ProjectSettings::get_singleton()->set_custom_property_info(PropertyInfo(Variant::BOOL, "rendering/renderdoc/enable", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_DEFAULT));
	if (!ProjectSettings::get_singleton()->has_setting("rendering/renderdoc/dll_path")) {
		ProjectSettings::get_singleton()->set_setting("rendering/renderdoc/dll_path", "");
	}
	ProjectSettings::get_singleton()->set_custom_property_info(PropertyInfo(Variant::STRING, "rendering/renderdoc/dll_path", PROPERTY_HINT_GLOBAL_FILE, "*.dll", PROPERTY_USAGE_DEFAULT));

	_feng_renderdoc = memnew(FengRenderDoc);
	ClassDB::register_class<FengRenderDoc>();
	// Must run before the display/rendering device is created so RenderDoc
	// can hook the graphics API (SERVERS level is before DisplayServer::create).
	_feng_renderdoc->probe_and_mount();
}

void uninitialize_feng_renderdoc_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SERVERS) {
		return;
	}
	if (_feng_renderdoc) {
		memdelete(_feng_renderdoc);
		_feng_renderdoc = nullptr;
	}
}
