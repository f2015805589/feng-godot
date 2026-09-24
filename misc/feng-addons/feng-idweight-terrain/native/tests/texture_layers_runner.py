"""Texture array, material and slope regression with an isolated physical addon copy.

This is the runner for texture_layers.gd, which renders the terrain off-screen and
reads the frame back, so it needs a real graphics driver.
"""
from fixture import run_script_test

MARKER = "PASS height/ID/weight/slope debug shaders"

if __name__ == "__main__":
    raise SystemExit(run_script_test(
        fixture_prefix="feng-texlayers-",
        project_name="Texture layer tests",
        log_name="texlayers.log",
        script="texture_layers.gd",
        marker=MARKER,
        prefixes=("SLOPE",),
        resolution="320x240",
        shots=True,
        timeout_import=180,
        timeout_run=300,
    ))
