"""Editor paint regression: every tool/operation pair writes the right map."""

from fixture import run_script_test


def main() -> int:
    return run_script_test(
        fixture_prefix="terrain-paint-",
        project_name="Editor paint tests",
        log_name="paint.log",
        script="editor_paint.gd",
        marker="PASS editor paint",
        resolution="480x480",
        shots=False,
        prefixes=("PAINT",),
    )


if __name__ == "__main__":
    raise SystemExit(main())
