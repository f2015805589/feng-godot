"""GPU regression: the compressed page arrays must render the same material."""

from fixture import run_script_test


def main() -> int:
    return run_script_test(
        fixture_prefix="terrain-vtcompress-render-",
        script="vt_compressed_render.gd",
        marker="PASS compressed material pages render and keep the production rate",
        project_name="VT compressed render tests",
        log_name="vtcompress_render.log",
        prefixes=("VTCOMPRESS_RENDER",),
        shots=True,
        timeout_run=600,
    )


if __name__ == "__main__":
    raise SystemExit(main())
