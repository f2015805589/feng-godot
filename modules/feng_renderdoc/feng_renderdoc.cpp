#include "feng_renderdoc.h"

#ifdef WINDOWS_ENABLED
#include <windows.h>
#endif

#include "thirdparty/misc/renderdoc_app.h"

#include "core/config/engine.h"
#include "core/config/project_settings.h"
#include "core/io/config_file.h"
#include "core/io/dir_access.h"
#include "core/io/file_access.h"
#include "core/object/class_db.h"
#include "core/os/os.h"
#include "core/string/print_string.h"
#include "servers/display/display_server.h"

FengRenderDoc *FengRenderDoc::singleton = nullptr;
bool FengRenderDoc::hooked = false;
String FengRenderDoc::dll_path;
void *FengRenderDoc::api_ptr = nullptr;

static String get_editor_config_path() {
	return ProjectSettings::get_singleton()->get_project_data_path().path_join("renderdoc/editor.cfg");
}

FengRenderDoc::FengRenderDoc() {
	singleton = this;
}

FengRenderDoc::~FengRenderDoc() {
	if (singleton == this) {
		singleton = nullptr;
	}
}

void FengRenderDoc::probe_and_mount() {
	ERR_FAIL_COND(hooked);
	// Capture the editor's existing rendering device, never a reconstructed
	// scene in another engine process. Attach before graphics initialization.
	if (!Engine::get_singleton()->is_editor_hint() || Engine::get_singleton()->is_recovery_mode_hint()) {
		return;
	}
	if (!ProjectSettings::get_singleton()->has_setting("editor_plugins/enabled")) {
		return;
	}
	const PackedStringArray plugins = ProjectSettings::get_singleton()->get("editor_plugins/enabled");
	if (!plugins.has("res://addons/feng-renderdoc-capture/plugin.cfg")) {
		return;
	}
	String configured_path;
	if (FileAccess::exists(get_editor_config_path())) {
		Ref<ConfigFile> config;
		config.instantiate();
		if (config->load(get_editor_config_path()) == OK) {
			configured_path = config->get_value("editor", "gui_path", String());
		}
	}
	const String gui_path = get_gui_path(configured_path);
	if (gui_path.is_empty()) {
		print_verbose("[f_renderdoc] qrenderdoc.exe was not found; editor capture unavailable.");
		return;
	}

#ifdef WINDOWS_ENABLED
	// renderdoc.dll ships inside the RenderDoc install. Probe a few layouts;
	// the GUI lives next to the DLL in modern installs.
	const char *dll_candidates[] = {
		"renderdoc.dll",
		"win64_x64/renderdoc.dll",
		"win32_x64/renderdoc.dll",
		nullptr,
	};
	Vector<String> roots;
	roots.append(gui_path.get_base_dir());
	roots.append(OS::get_singleton()->get_executable_path().get_base_dir());
	const String exe_env = OS::get_singleton()->get_environment("FENG_RENDERDOC_PATH");
	if (!exe_env.is_empty()) {
		roots.append(exe_env);
	}

	for (const String &root : roots) {
		for (int i = 0; dll_candidates[i] != nullptr; i++) {
			String path = root.path_join(dll_candidates[i]);
			if (!FileAccess::exists(path)) {
				continue;
			}
			Char16String path_utf16 = path.utf16();
			HMODULE mod = LoadLibraryW(reinterpret_cast<const wchar_t *>(path_utf16.get_data()));
			if (!mod) {
				ERR_PRINT(vformat("[f_renderdoc] Failed to load %s (error %d)", path, (int)GetLastError()));
				continue;
			}
			typedef int(RENDERDOC_CC * PFN_GetAPI)(RENDERDOC_Version, void **);
			PFN_GetAPI get_api = (PFN_GetAPI)GetProcAddress(mod, "RENDERDOC_GetAPI");
			if (!get_api) {
				ERR_PRINT(vformat("[f_renderdoc] %s has no RENDERDOC_GetAPI export", path));
				continue;
			}
			if (get_api(eRENDERDOC_API_Version_1_6_0, &api_ptr) != 1) {
				ERR_PRINT(vformat("[f_renderdoc] %s: RENDERDOC_GetAPI failed", path));
				continue;
			}
			dll_path = path;
			hooked = true;
			// Keep the editor silent outside explicitly requested captures.
			// Clear the F12 capture hotkey and hide the corner overlay so the
			// only capture path is the editor toolbar camera button.
			RENDERDOC_API_1_6_0 *rdoc = (RENDERDOC_API_1_6_0 *)api_ptr;
			rdoc->SetCaptureOptionU32(eRENDERDOC_Option_HookIntoChildren, 0);
			rdoc->SetCaptureKeys(nullptr, 0);
			rdoc->SetFocusToggleKeys(nullptr, 0);
			rdoc->MaskOverlayBits(0, 0);
			print_line(vformat("[f_renderdoc] RenderDoc mounted from %s (capture keys and overlay disabled)", path));
			return;
		}
	}
	print_line("[f_renderdoc] renderdoc.dll not found; capture requests will be no-ops");
#else
	print_verbose("[f_renderdoc] mounting only available on Windows");
#endif
}

bool FengRenderDoc::is_hooked() {
	return hooked;
}

String FengRenderDoc::get_dll_path() {
	return dll_path;
}

String FengRenderDoc::get_gui_path(const String &p_configured_path) {
	if (!p_configured_path.is_empty()) {
		return FileAccess::exists(p_configured_path) ? p_configured_path : String();
	}
	Vector<String> roots;
	if (!dll_path.is_empty()) {
		roots.push_back(dll_path.get_base_dir());
		roots.push_back(dll_path.get_base_dir().get_base_dir());
	}
	roots.push_back(OS::get_singleton()->get_environment("FENG_RENDERDOC_PATH"));
	roots.push_back(OS::get_singleton()->get_executable_path().get_base_dir().path_join("tools/RenderDoc"));
	roots.push_back(OS::get_singleton()->get_environment("ProgramFiles").path_join("RenderDoc"));
	roots.push_back("C:/Program Files/RenderDoc");
	for (const String &root : roots) {
		if (root.is_empty()) {
			continue;
		}
		const String candidate = root.path_join("qrenderdoc.exe");
		if (FileAccess::exists(candidate)) {
			return candidate;
		}
	}
	return String();
}

bool FengRenderDoc::trigger_capture(int p_window_id) {
	if (!hooked || api_ptr == nullptr) {
		return false;
	}
#ifdef WINDOWS_ENABLED
	RENDERDOC_API_1_6_0 *api = (RENDERDOC_API_1_6_0 *)api_ptr;
	api->MaskOverlayBits(0, 0);
	api->SetCaptureKeys(nullptr, 0);
	api->SetFocusToggleKeys(nullptr, 0);
	const String capture_dir = ProjectSettings::get_singleton()->globalize_path(ProjectSettings::get_singleton()->get_project_data_path().path_join("renderdoc/captures"));
	if (DirAccess::make_dir_recursive_absolute(capture_dir) != OK) {
		return false;
	}
	api->SetCaptureFilePathTemplate(capture_dir.path_join(vformat("capture_%d_%d", OS::get_singleton()->get_process_id(), OS::get_singleton()->get_ticks_usec())).utf8().get_data());
	const uint64_t window = DisplayServer::get_singleton()->window_get_native_handle(DisplayServerEnums::WINDOW_HANDLE, p_window_id);
	if (!window) {
		return false;
	}
	api->SetActiveWindow(nullptr, reinterpret_cast<RENDERDOC_WindowHandle>(window));
	api->TriggerCapture();
	return true;
#else
	return false;
#endif
}

int FengRenderDoc::get_capture_count() {
	return api_ptr ? int(((RENDERDOC_API_1_6_0 *)api_ptr)->GetNumCaptures()) : 0;
}

String FengRenderDoc::get_capture_path(int p_index) {
	if (!api_ptr || p_index < 0 || p_index >= get_capture_count()) {
		return String();
	}
	RENDERDOC_API_1_6_0 *api = (RENDERDOC_API_1_6_0 *)api_ptr;
	uint32_t length = 0;
	if (!api->GetCapture(p_index, nullptr, &length, nullptr) || length == 0) {
		return String();
	}
	Vector<char> path;
	path.resize(length + 1);
	path.write[length] = 0;
	if (!api->GetCapture(p_index, path.ptrw(), &length, nullptr)) {
		return String();
	}
	return String::utf8(path.ptr());
}

int FengRenderDoc::get_overlay_bits() {
	return api_ptr ? int(((RENDERDOC_API_1_6_0 *)api_ptr)->GetOverlayBits()) : 0;
}

Error FengRenderDoc::set_editor_gui_path(const String &p_gui_path) {
	// Cache the editor setting for the next graphics-device initialization.
	// EditorSettings itself is created after that initialization.
	const String path = get_editor_config_path();
	Ref<ConfigFile> config;
	config.instantiate();
	if (FileAccess::exists(path) && config->load(path) == OK && String(config->get_value("editor", "gui_path", String())) == p_gui_path) {
		return OK;
	}
	Error err = DirAccess::make_dir_recursive_absolute(path.get_base_dir());
	if (err != OK) {
		return err;
	}
	config->set_value("editor", "gui_path", p_gui_path);
	return config->save(path);
}

void FengRenderDoc::_bind_methods() {
	ClassDB::bind_static_method("FengRenderDoc", D_METHOD("is_hooked"), &FengRenderDoc::is_hooked);
	ClassDB::bind_static_method("FengRenderDoc", D_METHOD("get_dll_path"), &FengRenderDoc::get_dll_path);
	ClassDB::bind_static_method("FengRenderDoc", D_METHOD("get_gui_path", "configured_path"), &FengRenderDoc::get_gui_path, DEFVAL(String()));
	ClassDB::bind_static_method("FengRenderDoc", D_METHOD("trigger_capture", "window_id"), &FengRenderDoc::trigger_capture, DEFVAL(0));
	ClassDB::bind_static_method("FengRenderDoc", D_METHOD("get_capture_count"), &FengRenderDoc::get_capture_count);
	ClassDB::bind_static_method("FengRenderDoc", D_METHOD("get_capture_path", "index"), &FengRenderDoc::get_capture_path);
	ClassDB::bind_static_method("FengRenderDoc", D_METHOD("get_overlay_bits"), &FengRenderDoc::get_overlay_bits);
	ClassDB::bind_static_method("FengRenderDoc", D_METHOD("set_editor_gui_path", "gui_path"), &FengRenderDoc::set_editor_gui_path);
}
