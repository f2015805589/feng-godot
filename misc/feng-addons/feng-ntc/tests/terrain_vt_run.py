"""Encode evaluated VT channels, then exercise the real Terrain3D page pool with no NTC SDK."""
from pathlib import Path
import argparse
import os
import shutil
import subprocess
from run import ADDON, ROOT, WORK, deploy


def prepare(path, native):
    deploy(path, native=native)
    terrain = path / 'addons/feng-idweight-terrain'
    if not terrain.exists():
        subprocess.run(['cmd', '/c', 'mklink', '/J', str(terrain), str(ADDON.parent / terrain.name)],
                       check=True, capture_output=True, creationflags=subprocess.CREATE_NO_WINDOW)
    (path / '.godot').mkdir(exist_ok=True)
    extensions = 'res://addons/feng-idweight-terrain/feng-idweight-terrain.gdextension\n'
    if native:
        extensions += 'res://addons/feng-ntc/tools/feng_ntc.gdextension\n'
    (path / '.godot/extension_list.cfg').write_text(extensions, encoding='utf-8')


def execute(godot, path, script, driver=None):
    shutil.copy2(ADDON / 'tests' / script, path / script)
    command = [str(godot), '--path', str(path), '--script', 'res://' + script]
    if driver:
        command += ['--rendering-method', 'frp', '--rendering-driver', driver, '--position', '-32000,-32000']
    else:
        command += ['--headless', '--rendering-method', 'gl_compatibility']
    with (path / (script + '.log')).open('wb') as log:
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=300,
                                creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
    output = (path / (script + '.log')).read_text(encoding='utf-8', errors='replace')
    print(output, flush=True)
    return result.returncode == 0 and '_PASS' in output and 'ERROR:' not in output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime-only', action='store_true')
    parser.add_argument('--gpu', nargs='+', default=['d3d12', 'vulkan'])
    args = parser.parse_args()
    godot = ROOT / 'bin/godot.windows.editor.x86_64.exe'
    author = WORK / 'vt-page-author'
    if not args.runtime_only:
        prepare(author, True)
        if not execute(godot, author, 'terrain_vt_train_test.gd'): return 1
    for driver in args.gpu:
        runtime = WORK / ('vt-page-' + driver)
        prepare(runtime, False)
        for name in ['vt_pages.res', 'references.bin']:
            shutil.copy2(author / name, runtime / name)
        if not execute(godot, runtime, 'terrain_vt_runtime_test.gd', driver): return 1
        if not execute(godot, runtime, 'terrain_vt_sample_test.gd', driver): return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
