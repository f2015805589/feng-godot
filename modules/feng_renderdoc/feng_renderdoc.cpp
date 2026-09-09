#include "feng_renderdoc.h"

#ifdef WINDOWS_ENABLED
#include <windows.h>
#endif

#include "core/config/project_settings.h"
#include "core/io/dir_access.h"
#include "core/io/file_access.h"
#include "core/object/class_db.h"
#include "core/os/os.h"
#include "core/string/print_string.h"
#include "thirdparty/misc/renderdoc_app.h"

FengRenderDoc *FengRenderDoc::singleton = nullptr;
bool FengRenderDoc::hooked = false;
String FengRenderDoc::dll_path;
void *FengRenderDoc::api_ptr = nullptr;

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
	// Only mount when explicitly enabled in project settings, so the
	// performance-sensitive RenderDoc path never activates by default.
	if (!GLOBAL_GET("rendering/renderdoc/enable")) {
		print_verbose("[f_renderdoc] mounting disabled by project setting");
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
	roots.append(OS::get_singleton()->get_executable_path().get_base_dir());
	const String exe_env = OS::get_singleton()->get_environment("FENG_RENDERDOC_PATH");
	if (!exe_env.is_empty()) {
		roots.append(exe_env);
	}
	const String def_path = GLOBAL_GET("rendering/renderdoc/dll_path");
	if (String(def_path).is_empty()) {
		// Common install locations.
		roots.append("C:/Program Files/RenderDoc");
		roots.append("C:/Program Files (x86)/RenderDoc");
		roots.append(OS::get_singleton()->get_environment("ProgramFiles").path_join("RenderDoc"));
		roots.append(OS::get_singleton()->get_environment("ProgramFiles(x86)").path_join("RenderDoc"));
	} else {
		roots.insert(0, def_path);
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
			typedef int(RENDERDOC_CC *PFN_GetAPI)(RENDERDOC_Version, void **);
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
			// Behave like UE4's RenderDoc integration: silent while running.
			// Clear the F12 capture hotkey and hide the corner overlay so the
			// only capture path is the editor toolbar camera button.
			RENDERDOC_API_1_6_0 *rdoc = (RENDERDOC_API_1_6_0 *)api_ptr;
			rdoc->SetCaptureKeys(nullptr, 0);
			rdoc->MaskOverlayBits(UINT32_MAX, eRENDERDOC_Overlay_None);
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

String FengRenderDoc::get_gui_path() {
	if (dll_path.is_empty()) {
		return String();
	}
	String dir = dll_path.get_base_dir();
	// GUI lives next to the DLL in modern installs; fall back to the root.
	Vector<String> candidates;
	candidates.append(dir.path_join("renderdoc.exe"));
	candidates.append(dir.path_join("../renderdoc.exe"));
	for (const String &c : candidates) {
		if (FileAccess::exists(c)) {
			return c;
		}
	}
	return String();
}

bool FengRenderDoc::trigger_capture() {
	if (!hooked || api_ptr == nullptr) {
		return false;
	}
#ifdef WINDOWS_ENABLED
	RENDERDOC_API_1_6_0 *api = (RENDERDOC_API_1_6_0 *)api_ptr;
	api->TriggerCapture();
	return true;
#else
	return false;
#endif
}

void FengRenderDoc::_bind_methods() {
	ClassDB::bind_static_method("FengRenderDoc", D_METHOD("is_hooked"), &FengRenderDoc::is_hooked);
	ClassDB::bind_static_method("FengRenderDoc", D_METHOD("get_dll_path"), &FengRenderDoc::get_dll_path);
	ClassDB::bind_static_method("FengRenderDoc", D_METHOD("get_gui_path"), &FengRenderDoc::get_gui_path);
	ClassDB::bind_static_method("FengRenderDoc", D_METHOD("trigger_capture"), &FengRenderDoc::trigger_capture);
}
