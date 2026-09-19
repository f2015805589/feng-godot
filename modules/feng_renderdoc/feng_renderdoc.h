#ifndef FENG_RENDERDOC_MODULE_H
#define FENG_RENDERDOC_MODULE_H

#include "core/object/object.h"
#include "core/string/string_name.h"

class FengRenderDoc : public Object {
	GDCLASS(FengRenderDoc, Object);
	static FengRenderDoc *singleton;

	static bool hooked;
	static String dll_path;
	static String mount_status; // Why the last probe ended the way it did, for the UI.
	static void *api_ptr; // RENDERDOC_API_1_6_0 *

protected:
	static void _bind_methods();

public:
	static FengRenderDoc *get_singleton() { return singleton; }
	FengRenderDoc();
	~FengRenderDoc();

	// Probes renderdoc.dll and mounts it into the process. Must run before
	// any graphics API is initialized, so Main calls it immediately before
	// creating a graphical DisplayServer. Only editors with the capture plugin
	// enabled attach. The DLL stays loaded until this editor exits.
	void probe_and_mount();

	static bool is_hooked();
	static String get_dll_path();
	// Human-readable outcome of the startup probe. The capture UI shows it when the
	// button cannot capture, so a failed mount explains itself instead of only
	// reporting that the device is not attached.
	static String get_mount_status();
	static String get_gui_path(const String &p_configured_path = String());
	static bool trigger_capture(int p_window_id = 0);
	static int get_capture_count();
	static String get_capture_path(int p_index);
	static int get_overlay_bits();
	static Error set_editor_gui_path(const String &p_gui_path);
};

#endif // FENG_RENDERDOC_MODULE_H
