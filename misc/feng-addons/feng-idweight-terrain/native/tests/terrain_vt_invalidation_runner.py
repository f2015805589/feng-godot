"""Headless edit invalidation, including diagnostic pages without PageRecords."""
from pathlib import Path
from fixture import runner_parser, run_script_test

if __name__ == "__main__":
    parser = runner_parser()
    parser.add_argument("--native-library", type=Path)
    args = parser.parse_args()
    raise SystemExit(run_script_test(editor=args.editor, driver=args.driver,
        native_library=args.native_library, headless=True, timeout_run=10,
        fixture_prefix="terrain-invalidation-", project_name="VT invalidation bounds",
        log_name="invalidation.log", script="terrain_vt_invalidation.gd",
        marker="PASS resident-bounded VT invalidation", prefixes=("INVALIDATION_USEC",), forbidden=("leaked",)))
