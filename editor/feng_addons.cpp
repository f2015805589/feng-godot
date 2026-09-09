/**************************************************************************/
/*  feng_addons.cpp                                                       */
/**************************************************************************/
/*                         This file is part of:                          */
/*                             GODOT ENGINE                               */
/*                        https://godotengine.org                         */
/**************************************************************************/
/* Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md). */
/* Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.                  */
/*                                                                        */
/* Permission is hereby granted, free of charge, to any person obtaining  */
/* a copy of this software and associated documentation files (the        */
/* "Software"), to deal in the Software without restriction, including    */
/* without limitation the rights to use, copy, modify, merge, publish,    */
/* distribute, sublicense, and/or sell copies of the Software, and to     */
/* permit persons to whom the Software is furnished to do so, subject to  */
/* the following conditions:                                              */
/*                                                                        */
/* The above copyright notice and this permission notice shall be         */
/* included in all copies or substantial portions of the Software.        */
/*                                                                        */
/* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,        */
/* EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF     */
/* MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. */
/* IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY   */
/* CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,   */
/* TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE      */
/* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                 */
/**************************************************************************/

#include "feng_addons.h"

#include "core/config/project_settings.h"
#include "core/io/dir_access.h"
#include "core/io/file_access.h"
#include "core/os/os.h"
#include "core/string/print_string.h"

#ifdef WINDOWS_ENABLED
#include <windows.h>

#include <winioctl.h>
#endif

static Error _link_feng_addon(const String &p_source, const String &p_target) {
#ifdef WINDOWS_ENABLED
	// Directory junctions work without administrator rights or Developer Mode.
	// Use the Windows API directly, so paths never pass through a shell.
	const Char16String target = p_target.replace_char('/', '\\').utf16();
	const String source = p_source.replace_char('/', '\\');
	const Char16String substitute = (source.begins_with("\\\\") ? "\\??\\UNC\\" + source.substr(2) : "\\??\\" + source).utf16();
	const Char16String display = source.utf16();
	struct JunctionData {
		DWORD tag;
		WORD data_length;
		WORD reserved;
		WORD substitute_offset;
		WORD substitute_length;
		WORD print_offset;
		WORD print_length;
		WCHAR path[1];
	};
	const size_t substitute_bytes = substitute.length() * sizeof(WCHAR);
	const size_t display_bytes = display.length() * sizeof(WCHAR);
	const size_t data_bytes = 8 + substitute_bytes + display_bytes + 2 * sizeof(WCHAR);
	ERR_FAIL_COND_V(data_bytes + 8 > MAXIMUM_REPARSE_DATA_BUFFER_SIZE, ERR_INVALID_PARAMETER);
	Vector<uint8_t> buffer;
	buffer.resize(data_bytes + 8);
	memset(buffer.ptrw(), 0, buffer.size());
	JunctionData *data = reinterpret_cast<JunctionData *>(buffer.ptrw());
	data->tag = IO_REPARSE_TAG_MOUNT_POINT;
	data->data_length = data_bytes;
	data->substitute_length = substitute_bytes;
	data->print_offset = substitute_bytes + sizeof(WCHAR);
	data->print_length = display_bytes;
	memcpy(data->path, substitute.get_data(), substitute_bytes);
	memcpy(reinterpret_cast<uint8_t *>(data->path) + data->print_offset, display.get_data(), display_bytes);
	if (!CreateDirectoryW((LPCWSTR)target.get_data(), nullptr)) {
		return ERR_CANT_CREATE;
	}
	HANDLE handle = CreateFileW((LPCWSTR)target.get_data(), GENERIC_WRITE, 0, nullptr, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS, nullptr);
	if (handle == INVALID_HANDLE_VALUE) {
		RemoveDirectoryW((LPCWSTR)target.get_data());
		return ERR_CANT_OPEN;
	}
	DWORD returned = 0;
	const bool success = DeviceIoControl(handle, FSCTL_SET_REPARSE_POINT, data, buffer.size(), nullptr, 0, &returned, nullptr);
	CloseHandle(handle);
	if (!success) {
		RemoveDirectoryW((LPCWSTR)target.get_data());
		return FAILED;
	}
	return OK;
#else
	return DirAccess::create(DirAccess::ACCESS_FILESYSTEM)->create_link(p_source, p_target);
#endif
}

void setup_feng_addons() {
	ProjectSettings *settings = ProjectSettings::get_singleton();
	const String project_dir = settings->get_resource_path();
	if (!FileAccess::exists(project_dir.path_join("project.godot"))) {
		return;
	}
	const String exe_dir = OS::get_singleton()->get_executable_path().get_base_dir();
	const String source_dir = exe_dir.path_join("../misc/feng-addons").simplify_path();
	Ref<DirAccess> source = DirAccess::open(source_dir);
	if (source.is_null()) {
		return;
	}
	Ref<DirAccess> da = DirAccess::create(DirAccess::ACCESS_FILESYSTEM);
	PackedStringArray enabled;
	if (settings->has_setting("editor_plugins/enabled")) {
		enabled = settings->get_setting("editor_plugins/enabled");
	}
	bool changed = false;
	source->list_dir_begin();
	for (String name = source->get_next(); !name.is_empty(); name = source->get_next()) {
		const String plugin_source = source_dir.path_join(name);
		if (!source->current_is_dir() || name.begins_with(".") || !FileAccess::exists(plugin_source.path_join("plugin.cfg"))) {
			continue;
		}
		const String addons_dir = project_dir.path_join("addons");
		const String target = addons_dir.path_join(name);
		if (da->is_equivalent(plugin_source, target)) {
			// Preserve the user's enabled/disabled choice on subsequent launches.
			continue;
		}
		const String old_source = exe_dir.path_join("addons").path_join(name).simplify_path();
		const bool migrating = da->is_link(target) && da->read_link(target).simplify_path() == old_source;
		if (migrating) {
			// Migrate only links created by the old engine. Never remove their targets.
			if (da->remove(target) != OK) {
				WARN_PRINT(vformat("feng-godot: Could not update addon link: %s", target));
				continue;
			}
		} else if (da->is_link(target) || da->dir_exists(target) || da->file_exists(target)) {
			WARN_PRINT(vformat("feng-godot: Keeping existing addon at %s; source addon was not linked.", target));
			continue;
		}
		if (da->make_dir_recursive(addons_dir) != OK || _link_feng_addon(plugin_source, target) != OK) {
			if (migrating && _link_feng_addon(old_source, target) != OK) {
				WARN_PRINT(vformat("feng-godot: Could not restore previous addon link: %s", target));
			}
			WARN_PRINT(vformat("feng-godot: Could not link %s to %s.", target, plugin_source));
			continue;
		}
		const String config = "res://addons/" + name + "/plugin.cfg";
		if (!migrating && !enabled.has(config)) {
			enabled.push_back(config);
			changed = true;
		}
		print_line(vformat("feng-godot: Linked %s -> %s", target, plugin_source));
	}
	source->list_dir_end();
	if (changed) {
		settings->set_setting("editor_plugins/enabled", enabled);
		if (settings->save() != OK) {
			WARN_PRINT("feng-godot: Could not save enabled addon settings.");
		}
	}
}
