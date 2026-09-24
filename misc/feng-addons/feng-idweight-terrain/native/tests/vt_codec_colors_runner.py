"""Storage-level codec check: a stored page must keep its colour."""

from fixture import run_script_test


def main() -> int:
    return run_script_test(
        fixture_prefix="terrain-vtcodec-colors-",
        script="vt_codec_colors.gd",
        marker="PASS stored pages keep their colour in every codec",
        project_name="VT codec colour tests",
        log_name="vtcodec_colors.log",
        prefixes=("VTCODEC_COLORS",),
        shots=False,
        timeout_run=600,
    )


if __name__ == "__main__":
    raise SystemExit(main())
