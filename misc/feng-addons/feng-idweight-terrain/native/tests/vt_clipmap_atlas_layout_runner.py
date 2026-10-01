"""Native quadtree layout: disjoint, bounded rectangles with full slot coverage."""
from fixture import runner_parser, run_script_test


def main() -> int:
    args = runner_parser().parse_args()
    return run_script_test(
        fixture_prefix="terrain-vtatlaslayout-",
        project_name="Clipmap atlas layout regression",
        log_name="vtatlaslayout.log",
        script="vt_clipmap_atlas_layout.gd",
        marker="PASS clipmap atlas layout",
        prefixes=("VT_ATLAS_LAYOUT",),
        editor=args.editor,
        driver=args.driver,
        resolution="320x240",
        timeout_import=180,
        timeout_run=180,
    )


if __name__ == "__main__":
    raise SystemExit(main())
