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
	/// Builds and launches `renderdoccmd launch` for the current executable.
	/// Returns the spawned PID or -1.
	static int relaunch_with_renderdoc(const String &p_renderdoc_cmd);
};

} // namespace godot

#endif // FENG_RENDERDOC_CAPTURE_H
