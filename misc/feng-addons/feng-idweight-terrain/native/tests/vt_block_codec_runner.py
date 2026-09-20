"""Independent GPU encoder regression with engine BC decoding."""
from fixture import DEFAULT_EDITOR, run_script_test
if __name__ == "__main__":
    raise SystemExit(run_script_test(editor=DEFAULT_EDITOR, driver="d3d12",
        fixture_prefix="terrain-block-codec-", script="vt_block_codec.gd",
        marker="PASS GPU blocks preserve alpha indices, colour direction and signed normals",
        project_name="VT GPU block contracts", log_name="block_codec.log", prefixes=("VT_BLOCK",),
        extra_scripts=(("../src/shaders/bc_encode.glsl", "bc_encode_source.txt"),)))
