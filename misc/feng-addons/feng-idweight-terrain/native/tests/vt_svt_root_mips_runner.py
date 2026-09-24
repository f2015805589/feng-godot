"""VT setting scope regression: a demand-side setting must not rebuild the shared pool."""

from fixture import run_script_test


def main() -> int:
    return run_script_test(
        fixture_prefix="terrain-vt-root-mips-",
        project_name="VT root mips tests",
        log_name="vt_svt_root_mips.log",
        script="vt_svt_root_mips.gd",
        marker="PASS a demand-side setting leaves the shared pool alone",
        resolution="320x240",
        shots=False,
        prefixes=("INSTANCER",),
    )


if __name__ == "__main__":
    raise SystemExit(main())
