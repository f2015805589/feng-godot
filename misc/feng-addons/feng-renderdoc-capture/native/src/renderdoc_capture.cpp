#include "renderdoc_capture.h"

#include <windows.h>

#include <godot_cpp/classes/dir_access.hpp>
#include <godot_cpp/classes/display_server.hpp>
#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include "renderdoc_app.h"

namespace godot {

static RENDERDOC_API_1_6_0 *rdoc_api = nullptr;
static wchar_t rdoc_module_path[MAX_PATH] = { 0 }; // POD only; no Godot objects at static init time.

RenderDocCapture::RenderDocCapture() {}

// Probes the renderdoc.dll this process is already running under and returns its
// in-application API. The engine loads RenderDoc before the graphics device is created,
// so the DLL is present whenever a capture is possible at all.
static RENDERDOC_API_1_6_0 *acquire_api() {
	if (rdoc_api != nullptr) {
		return rdoc_api;
	}
	HMODULE mod = GetModuleHandleW(L"renderdoc.dll");
	if (mod == nullptr) {
		return nullptr;
	}
	pRENDERDOC_GetAPI rdoc_get_api = (pRENDERDOC_GetAPI)GetProcAddress(mod, "RENDERDOC_GetAPI");
	if (rdoc_get_api == nullptr) {
		return nullptr;
	}
	if (rdoc_get_api(eRENDERDOC_API_Version_1_6_0, (void **)&rdoc_api) != 1) {
		rdoc_api = nullptr;
		return nullptr;
	}
	DWORD len = GetModuleFileNameW(mod, rdoc_module_path, MAX_PATH);
	if (len == 0 || len >= MAX_PATH) {
		rdoc_module_path[0] = 0;
		return rdoc_api;
	}
	UtilityFunctions::print("[frd] renderdoc.dll hooked: ", String::utf16((const char16_t *)rdoc_module_path, (int)len));
	return rdoc_api;
}

bool RenderDocCapture::is_loaded() {
	return rdoc_api != nullptr;
}

String RenderDocCapture::get_renderdoc_module_path() {
	if (acquire_api() == nullptr || rdoc_module_path[0] == 0) {
		return String();
	}
	return String::utf16((const char16_t *)rdoc_module_path, (int)wcslen(rdoc_module_path));
}

bool RenderDocCapture::trigger_capture() {
	if (rdoc_api == nullptr || rdoc_api->TriggerCapture == nullptr) {
		return false;
	}
	rdoc_api->TriggerCapture();
	UtilityFunctions::print("[frd] RenderDoc: frame capture triggered");
	return true;
}

// Renders one frame here and captures exactly that frame. Waiting for "the next presented
// frame" instead can land on a UI-only update: the editor stops rendering unchanged
// viewports while idle, and such a capture holds a handful of commands and none of the
// scene passes, which is useless for inspecting the render pipeline.
String RenderDocCapture::capture_frame(int p_window_id) {
	RENDERDOC_API_1_6_0 *api = acquire_api();
	DisplayServer *display = DisplayServer::get_singleton();
	RenderingServer *rendering = RenderingServer::get_singleton();
	if (api == nullptr || display == nullptr || rendering == nullptr) {
		return String();
	}
	const int64_t window = display->window_get_native_handle(DisplayServer::WINDOW_HANDLE, p_window_id);
	if (window == 0) {
		return String();
	}
	const RENDERDOC_WindowHandle wnd = reinterpret_cast<RENDERDOC_WindowHandle>(window);
	// The overlay and the capture hotkeys are not wanted while the editor is instrumented.
	api->MaskOverlayBits(0, 0);
	api->SetCaptureKeys(nullptr, 0);
	api->SetFocusToggleKeys(nullptr, 0);
	// Same place the engine module writes to, so both capture paths land side by side.
	const String capture_dir = ProjectSettings::get_singleton()->globalize_path("res://.godot/renderdoc/captures");
	if (DirAccess::make_dir_recursive_absolute(capture_dir) != OK) {
		UtilityFunctions::printerr("[frd] could not create the capture directory: ", capture_dir);
		return String();
	}
	const String file_template = capture_dir.path_join(vformat("capture_%d_%d",
			OS::get_singleton()->get_process_id(), Time::get_singleton()->get_ticks_usec()));
	api->SetCaptureFilePathTemplate(file_template.utf8().get_data());
	api->SetActiveWindow(nullptr, wnd);
	if (api->IsFrameCapturing()) {
		// Two overlapping captures are undefined; a capture that never ended would be one.
		api->DiscardFrameCapture(nullptr, wnd);
	}
	api->StartFrameCapture(nullptr, wnd);
	// Draws the editor's viewport tree -- docked 3D viewports included -- and presents it,
	// so the capture holds the scene passes, the backbuffer and a Present event.
	rendering->force_draw(true, 0.0);
	if (!api->EndFrameCapture(nullptr, wnd)) {
		// Nothing was recorded: close the capture so RenderDoc is not left mid-frame.
		api->DiscardFrameCapture(nullptr, wnd);
		UtilityFunctions::printerr("[frd] RenderDoc recorded nothing for the rendered frame");
		return String();
	}
	const uint32_t capture_count = api->GetNumCaptures();
	if (capture_count == 0) {
		return String();
	}
	uint32_t length = 0;
	if (!api->GetCapture(capture_count - 1, nullptr, &length, nullptr) || length == 0) {
		return String();
	}
	PackedByteArray path;
	path.resize(int(length) + 1);
	path[length] = 0;
	if (!api->GetCapture(capture_count - 1, (char *)path.ptrw(), &length, nullptr)) {
		return String();
	}
	const String capture = String::utf8((const char *)path.ptr());
	UtilityFunctions::print("[frd] captured the rendered frame: ", capture);
	return capture;
}

int RenderDocCapture::relaunch_with_renderdoc(const String &p_renderdoc_cmd) {
	String exe_path = OS::get_singleton()->get_executable_path();
	PackedStringArray args = OS::get_singleton()->get_cmdline_args();
	PackedStringArray cmdline_parts;
	// renderdoccmd launch <exe> <args...> starts the target hooked into
	// RenderDoc without forcing a graphics API; the project renderer (e.g.
	// D3D12) is preserved. argv[0] of get_cmdline_args() is the executable
	// path; the rest carries the original editor/project arguments.
	cmdline_parts.push_back("launch");
	cmdline_parts.push_back(exe_path);
	for (int i = 1; i < args.size(); i++) {
		cmdline_parts.push_back(args[i]);
	}
	String full_cmd = p_renderdoc_cmd + String(" ") + String(" ").join(cmdline_parts);
	UtilityFunctions::print("[frd] launching: ", full_cmd);
	int32_t ok = OS::get_singleton()->create_process(p_renderdoc_cmd, cmdline_parts);
	if (ok == 0) {
		UtilityFunctions::printerr("[frd] failed to launch renderdoccmd");
		return -1;
	}
	return int(ok);
}

void RenderDocCapture::_bind_methods() {
	ClassDB::bind_static_method("RenderDocCapture", D_METHOD("is_loaded"), &RenderDocCapture::is_loaded);
	ClassDB::bind_static_method("RenderDocCapture", D_METHOD("get_renderdoc_module_path"), &RenderDocCapture::get_renderdoc_module_path);
	ClassDB::bind_static_method("RenderDocCapture", D_METHOD("trigger_capture"), &RenderDocCapture::trigger_capture);
	ClassDB::bind_static_method("RenderDocCapture", D_METHOD("capture_frame", "window_id"), &RenderDocCapture::capture_frame, DEFVAL(0));
	ClassDB::bind_static_method("RenderDocCapture", D_METHOD("relaunch_with_renderdoc", "renderdoc_cmd"), &RenderDocCapture::relaunch_with_renderdoc);
}

} // namespace godot
