#!/usr/bin/env python3
"""Static guard for the obsolete Windows linker; actual Windows I/O is separate."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[3]
source = (ROOT / "misc/feng-addons/link_plugin.ps1").read_text()
code = "\n".join(line for line in source.splitlines() if not line.lstrip().startswith("#"))
assert not re.search(r"\b(Remove-Item|rmdir|del)\b", code, re.IGNORECASE), "Linker must never delete existing project data"
assert "Get-Item -LiteralPath $Link -Force -ErrorAction SilentlyContinue" in code
assert "[IO.Path]::GetFullPath($target) -eq [IO.Path]::GetFullPath($Source)" in code
conflict = code.index('Write-Host "ERROR: keeping existing addon untouched: $Link"')
assert code.index("exit 1", conflict) < code.index("cmd /c mklink"), "Existing conflicts must stop before junction creation"
print("PASS legacy linker static safety: no deletion, exact junction no-op, conflicts fail closed")
