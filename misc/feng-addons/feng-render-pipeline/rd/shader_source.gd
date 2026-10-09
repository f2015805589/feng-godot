@tool
extends RefCounted


static func expand(path: String, source: String = "", depth: int = 0) -> String:
	if depth > 32:
		return ""
	var text := source
	if text.is_empty():
		if not FileAccess.file_exists(path):
			return ""
		text = FileAccess.get_file_as_string(path)
	if text.is_empty():
		return ""
	var output := PackedStringArray()
	for line in text.split("\n"):
		var trimmed := line.strip_edges()
		if not trimmed.begins_with("#include"):
			output.append(line)
			continue
		var first := trimmed.find("\"")
		var last := trimmed.rfind("\"")
		if first < 0 or last <= first:
			return ""
		var include_path := path.get_base_dir().path_join(
				trimmed.substr(first + 1, last - first - 1))
		var included := expand(include_path, "", depth + 1)
		if included.is_empty():
			return ""
		output.append(included)
	return "\n".join(output)
