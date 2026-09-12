"""Verify directional cascade coverage using real FRP GPU rendering."""
import argparse
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument("--editor", type=Path, default=ROOT / "bin/godot.windows.editor.x86_64.exe")
args = parser.parse_args()
fixture = Path(tempfile.mkdtemp(prefix="frp-shadow-range-", dir=ROOT / "bin"))
(fixture / "project.godot").write_text('config_version=5\n[application]\nconfig/name="Shadow range regression"\n', encoding="utf-8")
log = fixture / "test.log"
print(f"FIXTURE={fixture}", flush=True)
with log.open("w", encoding="utf-8") as out:
    result = subprocess.run([str(args.editor.resolve()), "--path", str(fixture), "--rendering-method", "frp", "--rendering-driver", "d3d12", "--audio-driver", "Dummy", "--resolution", "640x480", "--position", "-10000,-10000", "--script", str(ROOT / "misc/scripts/tests/frp_shadow_range.gd"), "--", str(fixture)], stdout=out, stderr=subprocess.STDOUT, timeout=180)
text = log.read_text(encoding="utf-8", errors="replace")
for line in text.splitlines():
    if line.startswith(("SHADOW_RANGE", "PASS", "ERROR:", "SCRIPT ERROR:")): print(line)
print(f"EXIT={result.returncode} LOG={log}")
raise SystemExit(result.returncode or int("PASS FRP distant shadow fade" not in text))
