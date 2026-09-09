#ifdef GDEXTENSION
#include <gdextension_interface.h>
#endif

#include <godot_cpp/core/class_db.hpp>

#include "register_types.h"
#include "renderdoc_capture.h"

void initialize_renderdoc_capture_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	ClassDB::register_class<RenderDocCapture>();
}

void uninitialize_renderdoc_capture_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
}

#ifdef GDEXTENSION
extern "C" {
// Initialization.
GDExtensionBool GDE_EXPORT renderdoc_capture_init(
		GDExtensionInterfaceGetProcAddress p_get_proc_address,
		GDExtensionClassLibraryPtr p_library,
		GDExtensionInitialization *r_initialization) {
	GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);

	init_obj.register_initializer(initialize_renderdoc_capture_module);
	init_obj.register_terminator(uninitialize_renderdoc_capture_module);
	init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SERVERS);

	return init_obj.init();
}
}
#endif /* GDEXTENSION */
