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
String FengRenderDoc::mount_status = "RenderDoc was not mounted when this editor started.";
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
		mount_status = "RenderDoc only attaches to a normal editor session (not to games, headless tools or recovery mode).";
		return;
	}
	if (!ProjectSettings::get_singleton()->has_setting("editor_plugins/enabled")) {
		mount_status = "The RenderDoc Capture plugin is not enabled for this project.";
		return;
	}
	const PackedStringArray plugins = ProjectSettings::get_singleton()->get("editor_plugins/enabled");
	if (!plugins.has("res://addons/feng-renderdoc-capture/plugin.cfg")) {
		mount_status = "The RenderDoc Capture plugin is not enabled for this project.";
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
		mount_status = "qrenderdoc.exe was not found. Install RenderDoc, or set RenderDoc > Capture > Executable Path, then restart the editor.";
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
	// The DLL has to come from a real installation, so every known root is searched
	// instead of trusting one path: a configured executable that sits in a folder
	// without a usable renderdoc.dll must not hide the installed copy.
	Vector<String> roots;
	const String exe_dir = OS::get_singleton()->get_executable_path().get_base_dir();
	Vector<String> candidate_roots;
	candidate_roots.append(gui_path.get_base_dir());
	candidate_roots.append(OS::get_singleton()->get_environment("FENG_RENDERDOC_PATH"));
	candidate_roots.append(exe_dir);
	candidate_roots.append(exe_dir.path_join("tools/RenderDoc"));
	candidate_roots.append(OS::get_singleton()->get_environment("ProgramFiles").path_join("RenderDoc"));
	candidate_roots.append("C:/Program Files/RenderDoc");
	for (const String &root : candidate_roots) {
		if (!root.is_empty() && !roots.has(root)) {
			roots.append(root);
		}
	}
	String probe_error;

	for (const String &root : roots) {
		for (int i = 0; dll_candidates[i] != nullptr; i++) {
			String path = root.path_join(dll_candidates[i]);
			if (!FileAccess::exists(path)) {
				continue;
			}
			Char16String path_utf16 = path.utf16();
			HMODULE mod = LoadLibraryW(reinterpret_cast<const wchar_t *>(path_utf16.get_data()));
			if (!mod) {
				probe_error = vformat("renderdoc.dll at %s could not be loaded (error %d).", path, (int)GetLastError());
				ERR_PRINT(vformat("[f_renderdoc] Failed to load %s (error %d)", path, (int)GetLastError()));
				continue;
			}
			typedef int(RENDERDOC_CC * PFN_GetAPI)(RENDERDOC_Version, void **);
			PFN_GetAPI get_api = (PFN_GetAPI)GetProcAddress(mod, "RENDERDOC_GetAPI");
			if (!get_api) {
				probe_error = vformat("renderdoc.dll at %s has no RENDERDOC_GetAPI export.", path);
				ERR_PRINT(vformat("[f_renderdoc] %s has no RENDERDOC_GetAPI export", path));
				continue;
			}
			if (get_api(eRENDERDOC_API_Version_1_6_0, &api_ptr) != 1) {
				ERR_PRINT(vformat("[f_renderdoc] %s: RENDERDOC_GetAPI failed", path));
				continue;
			}
			dll_path = path;
			hooked = true;
			// The DLL can come from another installation than the configured GUI.
			// Name both so a version mismatch between capture and analyzer is visible.
			const String gui_dir = gui_path.get_base_dir();
			const bool same_install = path.get_base_dir() == gui_dir;
			mount_status = same_install
					? vformat("RenderDoc mounted from %s.", path)
					: vformat("RenderDoc mounted from %s, but the configured executable is %s. Keep both from the same RenderDoc version.", path, gui_path);
			// Keep the editor silent outside explicitly requested captures.
			// Clear the F12 capture hotkey and hide the corner overlay so the
			// only capture path is the editor toolbar camera button.
			RENDERDOC_API_1_6_0 *rdoc = (RENDERDOC_API_1_6_0 *)api_ptr;
			rdoc->SetCaptureOptionU32(eRENDERDOC_Option_HookIntoChildren, 0);
			rdoc->SetCaptureKeys(nullptr, 0);
			rdoc->SetFocusToggleKeys(nullptr, 0);
			rdoc->MaskOverlayBits(0, 0);
			print_line(vformat("[f_renderdoc] RenderDoc mounted from %s (capture keys and overlay disabled)", path));
			if (!same_install) {
				WARN_PRINT(vformat("[f_renderdoc] the configured qrenderdoc.exe is %s, which is a different RenderDoc installation", gui_path));
			}
			return;
		}
	}
	print_line(vformat("[f_renderdoc] renderdoc.dll not found next to %s, below %s or in a Windows RenderDoc install; capture requests will be no-ops", gui_path, exe_dir));
	mount_status = probe_error.is_empty() ? vformat("renderdoc.dll was not found next to %s. The executable path has to point at the qrenderdoc.exe whose folder also holds renderdoc.dll.", gui_path) : probe_error;
#else
	print_verbose("[f_renderdoc] mounting only available on Windows");
	mount_status = "RenderDoc capture is only available on Windows in this build.";
#endif
}

bool FengRenderDoc::is_hooked() {
	return hooked;
}

String FengRenderDoc::get_mount_status() {
	return mount_status;
}

String FengRenderDoc::get_dll_path() {
	return dll_path;
}

String FengRenderDoc::get_gui_path(const String &p_configured_path) {
	if (!p_configured_path.is_empty()) {
		if (FileAccess::exists(p_configured_path)) {
			return p_configured_path;
		}
		// The cached path outlives the installation it pointed at when RenderDoc is
		// moved, upgraded or removed. Never let a stale cache entry disable the
		// search: fall through to auto-detection instead of reporting "not found".
		print_line(vformat("[f_renderdoc] cached RenderDoc path %s no longer exists; searching again", p_configured_path));
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
	ClassDB::bind_static_method("FengRenderDoc", D_METHOD("get_mount_status"), &FengRenderDoc::get_mount_status);
	ClassDB::bind_static_method("FengRenderDoc", D_METHOD("get_dll_path"), &FengRenderDoc::get_dll_path);
	ClassDB::bind_static_method("FengRenderDoc", D_METHOD("get_gui_path", "configured_path"), &FengRenderDoc::get_gui_path, DEFVAL(String()));
	ClassDB::bind_static_method("FengRenderDoc", D_METHOD("trigger_capture", "window_id"), &FengRenderDoc::trigger_capture, DEFVAL(0));
	ClassDB::bind_static_method("FengRenderDoc", D_METHOD("get_capture_count"), &FengRenderDoc::get_capture_count);
	ClassDB::bind_static_method("FengRenderDoc", D_METHOD("get_capture_path", "index"), &FengRenderDoc::get_capture_path);
	ClassDB::bind_static_method("FengRenderDoc", D_METHOD("get_overlay_bits"), &FengRenderDoc::get_overlay_bits);
	ClassDB::bind_static_method("FengRenderDoc", D_METHOD("set_editor_gui_path", "gui_path"), &FengRenderDoc::set_editor_gui_path);
}
