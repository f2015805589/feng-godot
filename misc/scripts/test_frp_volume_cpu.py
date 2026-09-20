"""Measure Volume main-thread time in an isolated real-GPU FRP project.

One camera, default renderer, one TAA parameter module per overlapping Volume.
Each case discards 20 warmup frames and samples 120 frames. Timing wrappers are
added only to the copied addon. Results include deferred apply, not GPU work.
"""
import argparse, os, shutil, subprocess, tempfile, sys
from pathlib import Path

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--addon-source', type=Path, default=root / 'misc/feng-addons/feng-render-pipeline',
                    help='Uninstrumented addon snapshot for before/after comparisons')
parser.add_argument('--profile', action='store_true')
parser.add_argument('--verify', action='store_true')
parser.add_argument('--verify-only', action='store_true')
options = parser.parse_args()
project = Path(tempfile.mkdtemp(prefix='volume-cpu-', dir=root / 'bin'))
shutil.copytree(options.addon_source, project / 'addons/feng-render-pipeline')
(project / 'project.godot').write_text('config_version=5\n[application]\nconfig/name="Volume CPU benchmark"\n[rendering]\nrenderer/rendering_method="frp"\n', encoding='utf-8')
compositor = project / 'addons/feng-render-pipeline/compositor.gd'
code = compositor.read_text(encoding='utf-8')
code = code.replace('func _apply() -> void:', '''var benchmark_apply_us := 0
func _apply() -> void:
	var started := Time.get_ticks_usec()
	_benchmark_original_apply()
	benchmark_apply_us += Time.get_ticks_usec() - started

func _benchmark_original_apply() -> void:''')
compositor.write_text(code, encoding='utf-8')
if '--profile' in sys.argv:
    renderer = project / 'addons/feng-render-pipeline/renderer.gd'
    code = renderer.read_text(encoding='utf-8')
    code += '\nstatic var benchmark_sections := {}\n'
    for name, signature, arguments, result_type in [
        ('_ensure_pipeline_initialized', 'emit: bool', 'emit', 'bool'),
        ('_sync_library', 'emit: bool', 'emit', 'bool'),
        ('_connect_passes', '', '', 'void'),
        ('get_pass_parameters', '', '', 'Dictionary'),
        ('_validate_schedule', '', '', 'PackedStringArray'),
        ('get_volume_context', '', '', 'Dictionary'),
    ]:
        code = code.replace(f'func {name}(', f'func _benchmark_original{name}(', 1)
        call = f'_benchmark_original{name}({arguments})'
        body = call if result_type == 'void' else 'var result = ' + call
        code += f'\nfunc {name}({signature}) -> {result_type}:\n\tvar start := Time.get_ticks_usec()\n\t{body}\n\tbenchmark_sections["{name}"] = benchmark_sections.get("{name}", 0) + Time.get_ticks_usec() - start\n'
        if result_type != 'void':
            code += '\treturn result\n'
    renderer.write_text(code, encoding='utf-8')
(project / 'benchmark.gd').write_text('''extends SceneTree
const Runtime = preload("res://addons/feng-render-pipeline/volume/volume_runtime.gd")
func _initialize():
	run.call_deferred()
func stats(values: Array) -> Dictionary:
	values.sort()
	var total := 0.0
	for value in values:
		total += value
	return {"mean_us": total / values.size(), "p95_us": values[int(values.size() * 0.95)], "max_us": values.back()}
func run():
	var renderer := FengRenderer.new()
	var camera := Camera3D.new()
	root.add_child(camera)
	camera.current = true
	var source: FengPass
	for candidate in renderer.get_volume_modules():
		if candidate.get_parameter_key() is int and candidate.get_parameter_key() == 6:
			source = candidate
	assert(source != null)
	for count in [1, 10, 100]:
		var compositor := FengCompositor.new()
		compositor.renderer = renderer
		camera.compositor = compositor
		camera.position.x = 20.0
		var volumes: Array = []
		for index in count:
			var volume := FengVolume.new()
			volume.profile = FengVolumeProfile.new()
			var module := FengVolumeModule.from_pass(source)
			module.set("parameters/enabled", false)
			module.set("parameters/jitter_phases", 32)
			volume.profile.modules = [module] as Array[FengVolumeModule]
			volume.blend_distance = 5.0
			root.add_child(volume)
			volume.set_process(false)
			volumes.append(volume)
		# Preconfigured fixed preset that actually enables an optional pass.
		for volume in volumes:
			volume.blend_distance = 0.0
			volume.profile.modules[0].set("parameters/enabled", true)
		for frame in 4:
			await process_frame
			await RenderingServer.frame_post_draw
		for event in ["outside_before_entry", "first_entry", "first_exit", "second_entry"]:
			camera.position.x = 0.0 if event in ["first_entry", "second_entry"] else 20.0
			var before := compositor.benchmark_apply_us
			var start := Time.get_ticks_usec()
			Runtime.evaluate_all()
			var check := Time.get_ticks_usec() - start
			await process_frame
			await RenderingServer.frame_post_draw
			var applied := compositor.benchmark_apply_us - before
			print("volume_boundary ", JSON.stringify({"volumes": count, "event": event, "evaluate_us": check, "apply_us": applied, "total_us": check + applied}))
		for mode in ["stationary_inside", "moving_blend", "moving_outside", "unbound_moving", "crossing_boundary", "fixed_preset_crossing"]:
			for volume in volumes:
				volume.unbound = mode == "unbound_moving"
				volume.blend_distance = 0.0 if mode in ["crossing_boundary", "fixed_preset_crossing"] else 5.0
				volume.profile.modules[0].set("parameters/enabled", mode == "fixed_preset_crossing")
			var checks: Array = []
			var applies: Array = []
			var totals: Array = []
			for frame in 140:
				var x := 0.0
				if mode == "moving_blend" or mode == "unbound_moving":
					x = 0.5 + fmod(frame * 0.037, 4.0)
				elif mode == "moving_outside":
					x = 20.0 + frame * 0.01
				elif mode in ["crossing_boundary", "fixed_preset_crossing"]:
					x = 0.0 if frame % 2 == 0 else 20.0
				camera.position.x = x
				var before := compositor.benchmark_apply_us
				var start := Time.get_ticks_usec()
				Runtime.evaluate_all()
				var check := Time.get_ticks_usec() - start
				await process_frame
				await RenderingServer.frame_post_draw
				var applied := compositor.benchmark_apply_us - before
				if frame >= 20:
					checks.append(check)
					applies.append(applied)
					totals.append(check + applied)
			print("volume_cpu ", JSON.stringify({"volumes": count, "mode": mode, "samples": totals.size(), "evaluate": stats(checks), "apply": stats(applies), "total": stats(totals)}))
		for volume in volumes:
			volume.free()
		await process_frame
	print("volume_cpu DONE")
	quit()
''', encoding='utf-8')
if '--profile' in sys.argv:
    script = project / 'benchmark.gd'
    code = script.read_text(encoding='utf-8').replace('print("volume_cpu DONE")', 'print("volume_cpu sections_us ", FengRenderer.benchmark_sections)\n\tprint("volume_cpu DONE")')
    code = code.replace('var before := compositor.benchmark_apply_us', 'FengRenderer.benchmark_sections.clear()\n\t\t\tvar before := compositor.benchmark_apply_us', 1)
    code = code.replace('print("volume_boundary ",', 'print("volume_sections ", event, " ", FengRenderer.benchmark_sections)\n\t\t\tprint("volume_boundary ",')
    script.write_text(code, encoding='utf-8')
env = dict(os.environ, APPDATA=str(project / 'config'), LOCALAPPDATA=str(project / 'cache'))
startup = subprocess.STARTUPINFO()
startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
startup.wShowWindow = 0
base = [str(root / 'bin/godot.windows.editor.x86_64.exe'), '--path', str(project), '--rendering-method', 'frp', '--rendering-driver', 'd3d12', '--resolution', '320x240', '--position', '-10000,-10000', '--disable-vsync']
print(project, flush=True)
runs = [('import', ['--editor', '--recovery-mode', '--import']), ('benchmark', ['--script', str(project / 'benchmark.gd')])]
if '--verify-only' in sys.argv:
    runs = runs[:1]
if '--verify' in sys.argv or '--verify-only' in sys.argv:
    runs += [(name, ['--script', str(root / 'misc/scripts/tests' / (name + '.gd'))])
             for name in ['frp_volume', 'frp_architecture', 'frp_view_state', 'frp_context', 'frp_passes']]
for name, extra in runs:
    with (project / (name + '.log')).open('w', encoding='utf-8') as log:
        result = subprocess.run(base + extra, stdout=log, stderr=subprocess.STDOUT, env=env, startupinfo=startup, timeout=180)
    output = (project / (name + '.log')).read_text(encoding='utf-8')
    print(output[-14000:], flush=True)
    errors = [line for line in output.splitlines()
              if 'ERROR:' in line and 'Failed to read the root certificate store.' not in line]
    if result.returncode or 'SCRIPT ERROR' in output or errors:
        raise SystemExit(1)
    if name == 'benchmark' and 'volume_cpu DONE' not in output:
        raise SystemExit('Volume benchmark did not complete')


