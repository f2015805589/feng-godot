"""Headless subscription ownership and incremental map-update contracts."""
from pathlib import Path
from fixture import runner_parser, run_script_test


def main() -> int:
    parser = runner_parser()
    parser.add_argument("--native-library", type=Path)
    parser.add_argument("--probe-absent-slot", action="store_true", help="exercise the baseline abort path")
    args = parser.parse_args()
    return run_script_test(
        editor=args.editor, driver=args.driver, native_library=args.native_library, headless=True,
        fixture_prefix="terrain-resource-contracts-", project_name="Terrain resource contracts",
        log_name="contracts.log", script="terrain_resource_contracts.gd",
        marker="PASS terrain resource ownership and map dirtiness", forbidden=("leaked",),
        prefixes=("VARIANT",),
        env={"TERRAIN_TEST_ABSENT_SLOT": "1" if args.probe_absent_slot else "0"})


if __name__ == "__main__":
    raise SystemExit(main())
