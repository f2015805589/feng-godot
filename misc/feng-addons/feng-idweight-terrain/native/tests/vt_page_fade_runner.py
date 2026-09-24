"""Page-arrival fade: a page that arrives must be a ramp, not a rectangular step."""

from fixture import run_script_test


def main() -> int:
    return run_script_test(
        fixture_prefix="terrain-vtpagefade-",
        script="vt_page_fade.gd",
        marker="PASS a page arrival publishes a ramp instead of a step",
        project_name="VT page fade tests",
        log_name="vtpagefade.log",
        prefixes=("VTPAGEFADE",),
        shots=False,
        timeout_run=900,
    )


if __name__ == "__main__":
    raise SystemExit(main())
