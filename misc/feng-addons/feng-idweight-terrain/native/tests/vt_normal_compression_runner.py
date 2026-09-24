"""GPU regression for independent diffuse and signed-normal VT codecs."""

from fixture import run_script_test


def main() -> int:
    return run_script_test(
        fixture_prefix="terrain-vtnormal-compression-",
        project_name="VT normal compression tests",
        log_name="vtnormal_compression.log",
        script="vt_normal_compression.gd",
        marker="PASS GPU AVT/SVT diffuse and signed-normal compression preserve rendered normal and roughness",
        prefixes=("VT_NORMAL", "VT_ROUGHNESS"),
        resolution="320x240",
        shots=True,
        timeout_run=900,
    )


if __name__ == "__main__":
    raise SystemExit(main())
