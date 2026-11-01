#!/usr/bin/env python3
"""Isolated CPU contract checks for the OLV v1 domain labels.

Copies only the feng-magic-gi addon into a disposable headless project, so the
checks need no bake, no GPU device and none of the other test suites. The
scratch project and its log stay under bin/, then Temp/ inside the repository,
and only then the system temporary directory.
"""

import argparse
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
DEFAULT_EDITOR = ROOT / "bin/godot.windows.editor.x86_64.exe"
TEST_SCRIPT = "res://addons/feng-magic-gi/tests/test_olv_domain.gd"

# The result line is parsed, not substring-matched: it must be a whole line of
# its own, and the check count must clear the current suite expectation. A
# passing run is therefore a claim about how much was checked, not just about
# the word "failures=0" appearing somewhere in the log.
RESULT_RE = re.compile(r"^MAGIC_GI_OLV_DOMAIN_RESULT failures=(\d+) checks=(\d+)[ \t]*$",
                       re.MULTILINE)
# Current full-suite expectation of test_olv_domain.gd: the exact number of
# checks a complete run performs today. Raise it whenever checks are added, so
# a run that silently loses coverage fails here instead of passing quietly.
MIN_CHECKS = 175

# Host-side noise unrelated to this contract: a headless box has no audio
# device and may not have a readable root certificate store.
UNRELATED_ERRORS = (
    "Failed to read the root certificate store.",
    'Condition "status < 0" is true. Returning: ERR_CANT_OPEN',
)
FAILURE_MARKERS = ("ERROR:", "SCRIPT ERROR:", "REGRESSION:", "Parse Error:")

# Channels of the result parser itself. A missing field, a zero or regressed
# check count, a duplicate line and a mere mention of the marker must all be
# refused, so the parser cannot be satisfied by prose. Counts are derived from
# MIN_CHECKS so the self-test stays meaningful when the baseline is raised.
_OK_LINE = f"MAGIC_GI_OLV_DOMAIN_RESULT failures=0 checks={MIN_CHECKS}"
SELF_TEST_CASES = (
    (_OK_LINE + "\n", True),
    (f"noise\nMAGIC_GI_OLV_DOMAIN_RESULT failures=0 checks={MIN_CHECKS + 4883}\nmore noise\n", True),
    (_OK_LINE, True),
    (_OK_LINE + "\r\n", True),
    ("MAGIC_GI_OLV_DOMAIN_RESULT failures=0\n", False),
    ("MAGIC_GI_OLV_DOMAIN_RESULT checks=117\n", False),
    ("MAGIC_GI_OLV_DOMAIN_RESULT failures=0 checks=0\n", False),
    (f"MAGIC_GI_OLV_DOMAIN_RESULT failures=0 checks={MIN_CHECKS - 1}\n", False),
    (f"MAGIC_GI_OLV_DOMAIN_RESULT failures=3 checks={MIN_CHECKS}\n", False),
    (f"note: MAGIC_GI_OLV_DOMAIN_RESULT failures=0 checks={MIN_CHECKS}\n", False),
    (_OK_LINE + " extra\n", False),
    (_OK_LINE + " 8\n", False),
    (_OK_LINE + "\n" + _OK_LINE + "\n", False),
)


def _parse_result(text: str) -> tuple:
    """Return (failures, checks) from the single anchored result line.

    Raises ValueError for a missing, duplicated, non-zero-failure or
    below-baseline result, and for any spelling that is not a whole line.
    """
    # One defined line ending here, so a CRLF log cannot defeat the anchored
    # pattern by leaving a trailing carriage return on the result line.
    matches = RESULT_RE.findall(text.replace("\r\n", "\n"))
    if len(matches) != 1:
        raise ValueError(f"expected exactly one anchored result line, found {len(matches)}")
    failures, checks = int(matches[0][0]), int(matches[0][1])
    if failures != 0:
        raise ValueError(f"result line reports failures={failures}")
    if checks <= 0:
        raise ValueError("result line reports checks=0")
    if checks < MIN_CHECKS:
        raise ValueError(f"result line reports checks={checks}, below the {MIN_CHECKS} baseline")
    return failures, checks


def _self_test_parse() -> None:
    for text, accepted in SELF_TEST_CASES:
        try:
            _parse_result(text)
            ok = True
        except ValueError:
            ok = False
        if ok != accepted:
            raise SystemExit(f"Runner self-test failed for {text!r}: accepted={ok}, "
                             f"expected={accepted}")


def _scratch_root() -> Path:
    """Prefer a scratch root that already exists inside the repository.

    Existence is checked, never masked: a permission problem still surfaces
    from mkdtemp/copytree instead of being silently swallowed.
    """
    for candidate in (ROOT / "bin", ROOT / "Temp"):
        if candidate.is_dir():
            return candidate
    return Path(tempfile.gettempdir())


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--editor", type=Path, default=DEFAULT_EDITOR,
                        help=f"editor binary to run (default: {DEFAULT_EDITOR})")
    parser.add_argument("--work-dir", type=Path,
                        help="Scratch project directory to reuse instead of a new temporary one")
    parser.add_argument("--self-test", action="store_true",
                        help="Only exercise the result-line parser (no editor, no Godot)")
    args = parser.parse_args()

    _self_test_parse()
    print(f"PASS OLV domain runner result-parser self-test ({len(SELF_TEST_CASES)} channels)")
    if args.self_test:
        return 0

    editor = args.editor.resolve()
    if not editor.is_file():
        raise SystemExit(f"Editor binary not found: {editor}. Pass --editor <path>.")

    project = args.work_dir.resolve() if args.work_dir \
        else Path(tempfile.mkdtemp(prefix="olv-domain-", dir=_scratch_root()))
    addons = project / "addons"
    addons.mkdir(parents=True, exist_ok=True)
    target = addons / "feng-magic-gi"
    if target.exists():
        shutil.rmtree(target)
    shutil.copytree(ROOT / "misc/feng-addons/feng-magic-gi", target)
    (project / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="OLV domain CPU contract"\n',
        encoding="utf-8",
    )

    env = dict(os.environ)
    for name, leaf in (
        ("APPDATA", "config"),
        ("LOCALAPPDATA", "cache"),
        ("XDG_CONFIG_HOME", "config"),
        ("XDG_CACHE_HOME", "cache"),
        ("XDG_DATA_HOME", "data"),
    ):
        env[name] = str(project / leaf)
        (project / leaf).mkdir(exist_ok=True)

    command = [
        str(editor), "--headless", "--quit-after", "300", "--path", str(project),
        "--audio-driver", "Dummy", "--script", TEST_SCRIPT,
    ]
    log = project / "olv_domain.log"
    with log.open("wb") as output:
        result = subprocess.run(command, env=env, stdout=output, stderr=subprocess.STDOUT,
                                timeout=300)
    # Universal newlines normally normalise this already; be explicit so the
    # anchored result pattern has one defined line ending.
    text = log.read_text(encoding="utf-8", errors="replace").replace("\r\n", "\n")
    print(text, end="" if text.endswith("\n") else "\n")

    bad = [
        line for line in text.splitlines()
        if any(marker in line for marker in FAILURE_MARKERS)
        and not any(unrelated in line for unrelated in UNRELATED_ERRORS)
    ]
    leaks = [
        line for line in text.splitlines()
        if "ObjectDB instances were leaked" in line
        or "resources still in use at exit" in line
        or re.search(r"\b(leaked|still in use|not freed)\b", line, re.I)
    ]
    if result.returncode != 0:
        raise SystemExit(f"OLV domain contract failed (exit {result.returncode}); see {log}")
    try:
        failures, checks = _parse_result(text)
    except ValueError as error:
        raise SystemExit(f"OLV domain result line rejected: {error}; see {log}")
    if bad or leaks:
        raise SystemExit("\n".join((bad + leaks)[-20:]) + f"\nSee {log}")
    print(f"PASS OLV domain contract runner: failures={failures} checks={checks} {project}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
