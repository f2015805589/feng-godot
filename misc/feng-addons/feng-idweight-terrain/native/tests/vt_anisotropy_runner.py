"""GPU regression for AVT anisotropic mip selection at a grazing view."""

from fixture import run_script_test


def main() -> int:
    return run_script_test(
        fixture_prefix="terrain-vtaniso-",
        project_name="VT anisotropic footprint tests",
        log_name="vtanisotropy.log",
        script="vt_anisotropy.gd",
        marker="PASS AVT anisotropic footprint keeps the fine page at grazing angles",
        prefixes=("VT_ANISO",),
        extra_scripts=(("vt_adaptive.gd", "vt_adaptive_base.gd"),),
        resolution="320x240",
        shots=True,
        timeout_run=300,
    )


if __name__ == "__main__":
    raise SystemExit(main())
