"""Check that Feng Fog discovers its optional sky runtime after a late install."""

import argparse
import os
import shutil
import subprocess
import tempfile
import time
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[4]
FOG_ADDON_SOURCE = REPO_ROOT / "misc/feng-addons/feng-fog"
TEST_SCRIPT = "res://addons/feng-fog/tests/test_late_sky_runtime_load.gd"
MOCK_RUNTIME_RELATIVE_PATH = Path("addons/feng-sky/feng_sky_runtime.gd")
MOCK_REQUEST_RELATIVE_PATH = Path(".late_sky_runtime_mock_requested")
WINDOWS_FILE_ATTRIBUTE_REPARSE_POINT = 0x400
GODOT_ERROR_MARKERS = ("REGRESSION:", "SCRIPT ERROR:", "Parse Error:", "ERROR:")


def run(command: list[str], project: Path, env: dict[str, str]) -> str:
	result = subprocess.run(
		command,
		cwd=project,
		env=env,
		text=True,
		encoding="utf-8",
		errors="replace",
		stdout=subprocess.PIPE,
		stderr=subprocess.STDOUT,
		check=False,
		timeout=180,
	)
	log = project / "headless_editor_import.log"
	log.write_text(result.stdout, encoding="utf-8")
	print(result.stdout, end="")
	_reject_godot_errors(result.stdout, "Godot import")
	if result.returncode:
		raise SystemExit(f"Godot command failed with exit code {result.returncode}")
	return result.stdout


def _reject_godot_errors(output: str, label: str) -> None:
	error_count = sum(output.count(marker) for marker in GODOT_ERROR_MARKERS)
	if error_count:
		raise SystemExit(f"{label} output contains {error_count} error marker(s)")


def _is_reparse_point(path: Path) -> bool:
	try:
		metadata = path.lstat()
	except FileNotFoundError:
		return False
	if path.is_symlink():
		return True
	attributes = getattr(metadata, "st_file_attributes", 0)
	return bool(attributes & WINDOWS_FILE_ATTRIBUTE_REPARSE_POINT)


def _is_within(path: Path, parent: Path) -> bool:
	try:
		path.relative_to(parent)
		return True
	except ValueError:
		return False


def validate_scratch_tree(project: Path) -> Path:
	"""Reject junctions, symlinks, and paths that escape the temporary project."""
	project_real = project.resolve(strict=True)
	temp_root_real = Path(tempfile.gettempdir()).resolve(strict=True)
	if not _is_within(project_real, temp_root_real):
		raise SystemExit(f"Refusing scratch project outside the temp directory: {project_real}")
	if _is_reparse_point(project):
		raise SystemExit(f"Refusing a reparse-point scratch project: {project}")
	for directory, child_directories, files in os.walk(project, followlinks=False):
		current = Path(directory)
		for name in [*child_directories, *files]:
			entry = current / name
			if _is_reparse_point(entry):
				raise SystemExit(f"Refusing reparse point in scratch project: {entry}")
			if entry.is_file() and entry.stat().st_nlink > 1:
				raise SystemExit(f"Refusing hard-linked scratch file: {entry}")
	return project_real


def create_scratch_mock_runtime(project: Path) -> None:
	project_real = validate_scratch_tree(project)
	target = project / MOCK_RUNTIME_RELATIVE_PATH
	parent = target.parent
	parent_real = parent.resolve(strict=True)
	if not _is_within(parent_real, project_real):
		raise SystemExit(f"Refusing mock runtime outside scratch project: {parent_real}")
	if _is_reparse_point(parent) or _is_reparse_point(target):
		raise SystemExit(f"Refusing mock runtime path containing a reparse point: {target}")
	if target.exists() or target.is_symlink():
		raise SystemExit(f"Refusing to overwrite an existing mock runtime: {target}")
	placeholder_marker = parent / ".gdignore"
	if _is_reparse_point(placeholder_marker):
		raise SystemExit(f"Refusing a linked Feng Sky placeholder marker: {placeholder_marker}")
	placeholder_marker.unlink(missing_ok=True)
	# Removing the marker changes only this already-validated temporary folder.
	validate_scratch_tree(project)
	# The file is created by the host only after revalidating the real scratch
	# path. The test script itself never opens a file under addons/feng-sky.
	with target.open("x", encoding="utf-8") as mock_file:
		mock_file.write(
		"extends RefCounted\n\n"
		"static func snapshot_for_world(world_id: int) -> Dictionary:\n"
		"\tvar contribution := 0.5 if world_id == 42 else INF\n"
		"\treturn {\n"
		"\t\t\"world_id\": world_id,\n"
		"\t\t\"ambient_radiance\": Vector3(2.0, 3.0, 4.0),\n"
		"\t\t\"height_fog_contribution\": contribution,\n"
		"\t}\n",
		)
	if _is_reparse_point(target) or target.stat().st_nlink > 1:
		raise SystemExit(f"Mock runtime was unexpectedly linked: {target}")


def main() -> None:
	parser = argparse.ArgumentParser(description=__doc__)
	parser.add_argument("--editor", type=Path, required=True, help="Path to a Godot editor executable")
	args = parser.parse_args()
	editor = args.editor.resolve()
	if not editor.is_file():
		raise SystemExit(f"Godot editor not found: {editor}")

	project = Path(tempfile.mkdtemp(prefix="feng-fog-late-sky-"))
	print(f"Persistent scratch project and full logs: {project}")
	addons = project / "addons"
	addons.mkdir()
	shutil.copytree(FOG_ADDON_SOURCE, addons / "feng-fog")
	selected_addons = {"feng-fog"}
	for addon in sorted((REPO_ROOT / "misc/feng-addons").iterdir()):
		if addon.is_dir() and addon.name not in selected_addons and (addon / "plugin.cfg").is_file():
			placeholder = addons / addon.name
			placeholder.mkdir()
			(placeholder / ".gdignore").touch()
	# This placeholder prevents the desktop editor's sibling-addon linker
	# from substituting a junction for the intentionally absent optional sky.
	sky_placeholder = addons / "feng-sky"
	sky_placeholder.mkdir(exist_ok=True)
	(sky_placeholder / ".gdignore").touch()
	(project / "project.godot").write_text(
		'config_version=5\n[application]\nconfig/name="Feng Fog late sky load test"\n',
		encoding="utf-8",
	)
	env = dict(os.environ)
	env["APPDATA"] = str(project / "config")
	env["LOCALAPPDATA"] = str(project / "cache")
	validate_scratch_tree(project)
	run([str(editor), "--headless", "--editor", "--path", str(project), "--import"], project, env)
	validate_scratch_tree(project)
	log = project / "late_sky_runtime_test.log"
	with log.open("wb") as output_file:
		process = subprocess.Popen(
			[str(editor), "--headless", "--path", str(project), "--script", TEST_SCRIPT],
			cwd=project,
			env=env,
			stdout=output_file,
			stderr=subprocess.STDOUT,
		)
		request_path = project / MOCK_REQUEST_RELATIVE_PATH
		deadline = time.monotonic() + 30.0
		while process.poll() is None and not request_path.exists() and time.monotonic() < deadline:
			if _is_reparse_point(project) or _is_reparse_point(request_path):
				process.kill()
				process.wait(timeout=10)
				raise SystemExit("Refusing a reparse point while waiting for the test request")
			time.sleep(0.05)
		if process.poll() is None and request_path.exists():
			try:
				create_scratch_mock_runtime(project)
			except BaseException:
				process.kill()
				process.wait(timeout=10)
				raise
			try:
				process.wait(timeout=60)
			except subprocess.TimeoutExpired:
				process.kill()
				process.wait(timeout=10)
				raise SystemExit("Godot late-load test timed out")
		else:
			if process.poll() is None:
				process.kill()
				process.wait(timeout=10)
	output = log.read_text(encoding="utf-8", errors="replace")
	print(output, end="")
	_reject_godot_errors(output, "Godot late-load test")
	if process.returncode:
		raise SystemExit(f"Godot command failed with exit code {process.returncode}; see {log}")
	if "feng_fog late sky runtime load test passed" not in output:
		raise SystemExit("Godot did not report the expected late-load success marker")
	print("SUMMARY: pass=1 error_markers=0")


if __name__ == "__main__":
	main()
