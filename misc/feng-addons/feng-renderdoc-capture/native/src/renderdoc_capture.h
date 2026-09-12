#ifndef FENG_RENDERDOC_CAPTURE_H
#define FENG_RENDERDOC_CAPTURE_H

#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

namespace godot {

class RenderDocCapture : public Object {
	GDCLASS(RenderDocCapture, Object)

protected:
	static void _bind_methods();

public:
	RenderDocCapture();

	/// True when this process was launched with RenderDoc hooked in.
	static bool is_loaded();
	/// Returns renderdoc.dll path when hooked, empty otherwise.
	static String get_renderdoc_module_path();
	/// Triggers a capture of the next frame. Returns true when issued.
	static bool trigger_capture();
	/// Renders one frame on demand and captures exactly that frame, returning the path of
	/// the written capture. Empty when RenderDoc could not record it.
	///
	/// This replaces waiting for "the next presented frame": the editor stops rendering
	/// unchanged viewports while idle, so a queued capture can land on a UI-only update
	/// that contains a handful of commands and none of the scene passes. The frame is
	/// rendered inside the capture instead, so what lands in the file is what the button
	/// drew.
	static String capture_frame(int p_window_id);
	/// Builds and launches `renderdoccmd launch` for the current executable.
	/// Returns the spawned PID or -1.
	static int relaunch_with_renderdoc(const String &p_renderdoc_cmd);
};

} // namespace godot

#endif // FENG_RENDERDOC_CAPTURE_H
