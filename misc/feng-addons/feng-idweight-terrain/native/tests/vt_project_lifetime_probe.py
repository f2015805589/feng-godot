"""Read-only project probe; requires a project, so it is not an auto-discovered runner."""
import argparse
import json
import os
from pathlib import Path
import shutil
import tempfile

from fixture import ROOT, ADDON_SOURCE, DEFAULT_EDITOR, write_fixture, run_with_offscreen_window


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project', type=Path, required=True)
    parser.add_argument('--scene', default='render/test.tscn')
    parser.add_argument('--window', type=int, default=240)
    parser.add_argument('--windows', type=int, default=6)
    parser.add_argument('--motion', choices=('orbit', 'snap'), default='orbit')
    parser.add_argument('--driver', default='d3d12')
    parser.add_argument('--editor', type=Path, default=DEFAULT_EDITOR)
    args = parser.parse_args()
    source = args.project.resolve()
    target = Path(tempfile.mkdtemp(prefix='terrain-project-lifetime-', dir=ROOT / 'bin'))
    write_fixture(target)
    for item in source.iterdir():
        if item.name in {'.godot', '.git', 'addons', 'project.godot'}:
            continue
        if item.is_dir():
            shutil.copytree(item, target / item.name)
        elif item.is_file():
            shutil.copy2(item, target / item.name)
    frp = target / 'addons/feng-render-pipeline'
    (frp / '.gdignore').unlink(missing_ok=True)
    shutil.copytree(ADDON_SOURCE / 'feng-render-pipeline', frp, dirs_exist_ok=True)
    (target / 'project.godot').write_text(
        'config_version=5\n[application]\nconfig/name="VT project lifetime"\n'
        '[autoload]\nFengProjectPipeline="*res://addons/feng-render-pipeline/project_pipeline.gd"\n'
        '[rendering]\nrenderer/rendering_method="frp"\n'
        'renderer/compositor="res://render/test_compositor.tres"\n', encoding='utf-8')
    env = dict(os.environ, APPDATA=str(target / 'config'), LOCALAPPDATA=str(target / 'cache'),
               VT_TEST_SCENE='res://' + args.scene, VT_TEST_WINDOW=str(args.window), VT_TEST_WINDOWS=str(args.windows),
               VT_TEST_MOTION=args.motion)
    base = [str(args.editor.resolve()), '--path', str(target), '--audio-driver', 'Dummy',
            '--rendering-method', 'frp', '--rendering-driver', args.driver,
            '--resolution', '640x360', '--position', '-10000,-10000']
    print('FIXTURE=' + str(target), flush=True)
    for name, extra in [('import', ['--headless', '--editor', '--import']),
                        ('lifetime', ['--script', str(Path(__file__).with_name('vt_project_lifetime.gd').resolve())])]:
        log = target / (name + '.log')
        with log.open('w', encoding='utf-8') as stream:
            code = run_with_offscreen_window(base + extra, env=env, stream=stream, timeout=1200)
        output = log.read_text(encoding='utf-8', errors='replace')
        errors = [line for line in output.splitlines() if 'ERROR:' in line and 'root certificate store' not in line]
        for line in output.splitlines():
            if line.startswith('VT_PROJECT '):
                sample = json.loads(line[len('VT_PROJECT '):])
                settings = sample.pop('settings')
                sample['queue_size'] = settings.get('vt_page_fade_queue_size')
                sample['queue_capacity'] = settings.get('vt_page_fade_queue_capacity')
                print('VT_PROJECT ' + json.dumps(sample), flush=True)
            elif line.startswith('PASS '):
                print(line, flush=True)
        missing_result = name == 'lifetime' and 'PASS project VT lifetime sampling completed' not in output
        if code != 0 or errors or missing_result:
            print(output[-6000:])
            return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
