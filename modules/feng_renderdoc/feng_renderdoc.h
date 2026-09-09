#ifndef FENG_RENDERDOC_MODULE_H
#define FENG_RENDERDOC_MODULE_H

#include "core/object/object.h"
#include "core/string/string_name.h"

class FengRenderDoc : public Object {
	GDCLASS(FengRenderDoc, Object);
	static FengRenderDoc *singleton;

	static bool hooked;
	static String dll_path;
	static void *api_ptr; // RENDERDOC_API_1_6_0 *

protected:
	static void _bind_methods();

public:
	static FengRenderDoc *get_singleton() { return singleton; }
	FengRenderDoc();
	~FengRenderDoc();

	// Probes renderdoc.dll and mounts it into the process. Must run before
	// any graphics API is initialized, so it is called from the module
	// initializer (SERVERS level). Controlled by the project settings key
	// "rendering/renderdoc/enable".
	void probe_and_mount();

	static bool is_hooked();
	static String get_dll_path();
	static String get_gui_path();
	static bool trigger_capture();
};

#endif // FENG_RENDERDOC_MODULE_H
