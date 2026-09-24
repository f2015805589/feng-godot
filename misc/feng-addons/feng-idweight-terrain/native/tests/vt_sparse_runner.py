"""Far-field sparse virtual texture regression: world page grid, borders, mip chain."""

from fixture import run_script_test


def main() -> int:
    return run_script_test(
        fixture_prefix="terrain-vtsvt-",
        project_name="Sparse VT tests",
        log_name="vtsvt.log",
        script="vt_sparse.gd",
        marker="PASS sparse virtual texture far field",
        resolution="320x240",
        shots=False,
        prefixes=('VTSVT',),
    )


if __name__ == "__main__":
    raise SystemExit(main())
