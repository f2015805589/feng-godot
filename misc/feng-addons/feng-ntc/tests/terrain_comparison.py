"""Run sequential, same-view Terrain VT memory/CPU/GPU comparisons on Windows.

CPU render time is the engine's measured viewport interval; VT update CPU time
comes from Terrain's own timer. GetProcessTimes is retained only as a diagnostic:
its coarse accounting quantizes short steady-state bursts on this Windows host,
so it must not be used to rank per-frame CPU work.
Scene/resource overrides exist only in each disposable Godot process.
"""
from __future__ import annotations

import argparse
import csv
import ctypes
from ctypes import wintypes
import json
from pathlib import Path
import statistics
import subprocess
import threading
import time

ADDON = Path(__file__).resolve().parents[1]
ROOT = ADDON.parents[2]
WORK = ADDON / 'tests/.work/terrain-comparison'


class ProcessCPU:
    def __init__(self, pid: int):
        self.dll = ctypes.WinDLL('kernel32', use_last_error=True)
        self.dll.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        self.dll.OpenProcess.restype = wintypes.HANDLE
        self.dll.GetProcessTimes.argtypes = [wintypes.HANDLE] + [ctypes.POINTER(wintypes.FILETIME)] * 4
        self.dll.GetProcessTimes.restype = wintypes.BOOL
        self.dll.CloseHandle.argtypes = [wintypes.HANDLE]
        self.handle = self.dll.OpenProcess(0x1000, False, pid)
        if not self.handle:
            raise ctypes.WinError(ctypes.get_last_error())

    def seconds(self) -> float:
        created, exited, kernel, user = [wintypes.FILETIME() for _ in range(4)]
        if not self.dll.GetProcessTimes(self.handle, ctypes.byref(created), ctypes.byref(exited), ctypes.byref(kernel), ctypes.byref(user)):
            raise ctypes.WinError(ctypes.get_last_error())
        return sum((item.dwHighDateTime << 32) | item.dwLowDateTime for item in (kernel, user)) / 10_000_000

    def close(self):
        self.dll.CloseHandle(self.handle)


def execute(godot: Path, project: Path, mode: str, index: int, frames: int, cache_pages: int = -1, motion: bool = False) -> dict:
    output = WORK / f'{mode}-{index}'
    command = [str(godot), '--path', str(project), '--script', 'res://addons/feng-ntc/tests/terrain_comparison.gd',
               '--rendering-method', 'frp', '--rendering-driver', 'd3d12', '--position', '-32000,-32000',
               '--resolution', '1280x720', '--audio-driver', 'Dummy', '--', f'--mode={mode}', f'--frames={frames}', f'--output={output}']
    if cache_pages >= 0: command.append(f'--cache-pages={cache_pages}')
    if motion: command.append('--motion')
    started = time.perf_counter()
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               creationflags=subprocess.CREATE_NO_WINDOW)
    cpu = ProcessCPU(process.pid)
    timer = threading.Timer(225, process.kill)
    timer.start()
    phases = {}
    passed = False
    errors = []
    try:
        with output.with_suffix('.log').open('w', encoding='utf-8') as log:
            for raw in iter(process.stdout.readline, b''):
                line = raw.decode('utf-8', errors='replace')
                if line.startswith('TERRAIN_COMPARISON_PHASE '):
                    event = json.loads(line.split(' ', 1)[1])
                    event['process_cpu_seconds'] = cpu.seconds()
                    event['process_wall_seconds'] = time.perf_counter()-started
                    phases[event['phase']] = event
                log.write(line)
                if 'ERROR:' in line and 'Failed to read the root certificate store.' not in line:
                    errors.append(line.strip())
                passed |= line.startswith('TERRAIN_COMPARISON_PASS ')
        result = process.wait(timeout=20)
    finally:
        timer.cancel()
        if process.poll() is None:
            process.kill()
            process.wait()
        cpu.close()
    if result or errors or not passed or 'steady_end' not in phases:
        raise RuntimeError(f'{mode}/{index} failed (exit {result}): {errors}; see {output}.log')
    report = json.loads(output.with_suffix('.json').read_text(encoding='utf-8'))
    begin, end = phases['steady_begin'], phases['steady_end']
    cpu_seconds = end['process_cpu_seconds']-begin['process_cpu_seconds']
    report['process_cpu_ms_per_frame'] = cpu_seconds*1000/frames
    report['process_cpu_counter_note'] = 'Diagnostic only; coarse Windows accounting can report zero for short steady CPU bursts. Use render_cpu_ms and vt_update_cpu_ms with their explicit scopes.'
    report['process_cpu_equivalent_cores'] = cpu_seconds/(end['process_wall_seconds']-begin['process_wall_seconds'])
    report['process_start_to_loaded_ms'] = phases['loaded']['process_wall_seconds']*1000
    report['loading_process_cpu_ms'] = phases['loaded']['process_cpu_seconds']*1000
    report['process_phases'] = phases
    report['repeat'] = index
    output.with_suffix('.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps({'mode': mode, 'repeat': index, 'video_mib': report['memory']['video']/1048576,
                      'cpu_work_ms_per_frame': report['process_cpu_ms_per_frame'],
                      'render_cpu_median_ms': report['render_cpu_ms']['median'],
                      'gpu_median_ms': report['gpu_ms']['median'],
                      'loaded_ms': report['process_start_to_loaded_ms']}, ensure_ascii=False), flush=True)
    return report


def summarize(reports: list[dict]) -> list[dict]:
    result = []
    for mode in dict.fromkeys(row['mode'] for row in reports):
        rows = [row for row in reports if row['mode'] == mode]
        first = rows[0]
        summaries = {
            'scene_video_mib': [r['memory']['video']/1048576 for r in rows],
            'vt_pages_and_staging_mib': [r['vt']['producer']['material_bytes']/1048576 for r in rows],
            'source_arrays_mib': [r['source_arrays']['gpu_bytes']/1048576 for r in rows],
            'neural_gpu_mib': [r['vt']['producer']['neural_gpu_bytes']/1048576 for r in rows],
            'neural_resident_mib': [r['vt']['producer'].get('neural_runtime',{}).get('compressed_bytes',0)/1048576 for r in rows],
            'neural_decoded_cache_mib': [r['vt']['producer'].get('neural_runtime',{}).get('decoded_bytes',0)/1048576 for r in rows],
            'terrain_material_mib': [(r['source_arrays']['gpu_bytes']+r['vt']['producer']['material_bytes']+r['vt']['producer']['neural_gpu_bytes'])/1048576 for r in rows],
            'svt_cell_cache_mib': [r['vt']['svt_cells']['bytes']/1048576 for r in rows],
            'render_cpu_ms': [r['render_cpu_ms']['median'] for r in rows],
            'vt_cpu_ms_per_update': [r['vt_update_cpu_ms']['median'] for r in rows],
            'gpu_ms': [r['gpu_ms']['median'] for r in rows],
            'gpu_p95_ms': [r['gpu_ms']['p95'] for r in rows],
            'process_start_to_loaded_ms': [r['process_start_to_loaded_ms'] for r in rows],
            'loading_cpu_ms': [r['loading_process_cpu_ms'] for r in rows],
            'loading_gpu_mean_ms': [r['loading_gpu_ms']['mean'] for r in rows],
            'loading_gpu_p95_ms': [r['loading_gpu_ms']['p95'] for r in rows],
            'loading_peak_video_mib': [r['loading_peak_video_bytes']/1048576 for r in rows],
        }
        entry = {'mode': mode, 'repeats': len(rows), 'frames_per_repeat': first['sample_count'],
                 'cpu': first['cpu_name'], 'gpu': first['gpu_name'], 'resolution': first['resolution'],
                 'ready_pages': first['vt']['producer']['ready_pages'], 'physical_slots': first['vt']['producer']['page_count']}
        entry['cpu_scope'] = 'render_cpu_ms: engine viewport CPU interval; vt_cpu_ms_per_update: Terrain VT update timer'
        entry['motion'] = first['motion']
        entry['gpu_scope'] = 'entire viewport, moving camera' if first['motion'] else 'entire viewport, stationary cache; no new page decodes (compressed sampler can evaluate uncached pixels)'
        entry['memory_scope'] = 'terrain_material_mib: source arrays + all physical pages/staging + neural GPU residency (including its bounded decoded cache); scene_video_mib also includes other scene allocations and state-dependent SVT cell cache'
        entry.update({key: statistics.median(values) for key, values in summaries.items()})
        entry['ranges'] = {key: [min(values), max(values)] for key, values in summaries.items()}
        result.append(entry)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--godot', type=Path, default=ROOT/'bin/godot.windows.editor.x86_64.exe')
    parser.add_argument('--project', type=Path, default=ROOT.parent/'PROJECT/test场景')
    parser.add_argument('--modes', nargs='+', choices=['raw', 'raw_vt', 'bc7', 'ntc', 'ntc_direct'], default=['raw', 'bc7', 'ntc'])
    parser.add_argument('--repeats', type=int, default=3)
    parser.add_argument('--frames', type=int, default=1200)
    parser.add_argument('--output-dir', type=Path)
    parser.add_argument('--cache-pages', type=int, default=-1)
    parser.add_argument('--motion', action='store_true')
    args = parser.parse_args()
    global WORK
    if args.output_dir: WORK = args.output_dir.resolve()
    WORK.mkdir(parents=True, exist_ok=True)
    reports = []
    # Rotate order to reduce clock, file-cache and background-load order effects.
    for repeat in range(1, args.repeats+1):
        offset = (repeat-1)%len(args.modes)
        for mode in args.modes[offset:] + args.modes[:offset]:
            reports.append(execute(args.godot.resolve(), args.project.resolve(), mode, repeat, args.frames, args.cache_pages, args.motion))
    summary = summarize(reports)
    (WORK/'summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding='utf-8')
    with (WORK/'summary.csv').open('w', encoding='utf-8-sig', newline='') as target:
        columns = [key for key in summary[0] if key != 'ranges']
        writer = csv.DictWriter(target, fieldnames=columns, extrasaction='ignore')
        writer.writeheader()
        writer.writerows(summary)
    print('TERRAIN_COMPARISON_COMPLETE '+str(WORK/'summary.json'), flush=True)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
