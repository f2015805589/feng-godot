#include "renderdoc_capture.h"

#include <windows.h>

#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include "renderdoc_app.h"

namespace godot {

static RENDERDOC_API_1_6_0 *rdoc_api = nullptr;
static wchar_t rdoc_module_path[MAX_PATH] = { 0 }; // POD only; no Godot objects at static init time.

RenderDocCapture::RenderDocCapture() {}

bool RenderDocCapture::is_loaded() {
	return rdoc_api != nullptr;
}

String RenderDocCapture::get_renderdoc_module_path() {
	if (rdoc_api != nullptr) {
		return String::utf16((const char16_t *)rdoc_module_path, (int)wcslen(rdoc_module_path));
	}
	HMODULE mod = GetModuleHandleW(L"renderdoc.dll");
	if (mod == nullptr) {
		return String();
	}
	pRENDERDOC_GetAPI rdoc_get_api = (pRENDERDOC_GetAPI)GetProcAddress(mod, "RENDERDOC_GetAPI");
	if (rdoc_get_api == nullptr) {
		return String();
	}
	int ret = rdoc_get_api(eRENDERDOC_API_Version_1_6_0, (void **)&rdoc_api);
	if (ret != 1) {
		rdoc_api = nullptr;
		return String();
	}
	DWORD len = GetModuleFileNameW(mod, rdoc_module_path, MAX_PATH);
	if (len == 0 || len >= MAX_PATH) {
		return String();
	}
	UtilityFunctions::print("[frd] renderdoc.dll hooked: ", String::utf16((const char16_t *)rdoc_module_path, (int)len));
	return String::utf16((const char16_t *)rdoc_module_path, (int)len);
}

bool RenderDocCapture::trigger_capture() {
	if (rdoc_api == nullptr || rdoc_api->TriggerCapture == nullptr) {
		return false;
	}
	rdoc_api->TriggerCapture();
	UtilityFunctions::print("[frd] RenderDoc: frame capture triggered");
	return true;
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
	ClassDB::bind_static_method("RenderDocCapture", D_METHOD("relaunch_with_renderdoc", "renderdoc_cmd"), &RenderDocCapture::relaunch_with_renderdoc);
}

} // namespace godot
