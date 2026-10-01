"""Source/native C# interop regressions. This is not a C# compilation test.

Run with Python alone when the optional .NET editor/runtime is unavailable.
Defaults must distinguish an omitted nullable value from an explicitly supplied
zero value; comparing to Zero would incorrectly erase that authored value.
"""

import re
import unittest
from pathlib import Path


ADDON = Path(__file__).resolve().parents[2]
CSHARP = ADDON / "csharp"
NATIVE = ADDON / "native/src"


def body(path: Path) -> str:
    return re.sub(r"\s+", " ", path.read_text(encoding="utf-8"))


class WrapperContractTests(unittest.TestCase):
    def test_bind_checks_actual_class_against_expected_parent(self):
        wrappers = list(CSHARP.glob("Terrain3D*.cs"))
        self.assertEqual(len(wrappers), 11)
        for wrapper in wrappers:
            with self.subTest(wrapper=wrapper.name):
                source = body(wrapper)
                self.assertIn("ClassDB.IsParentClass(currentObjectClassName, expectedType.Name)", source)
                self.assertNotIn("ClassDB.IsParentClass(expectedType.Name, currentObjectClassName)", source)

    def test_omitted_transform_preserves_native_identity(self):
        source = body(CSHARP / "Terrain3DInstancer.cs")
        native = body(NATIVE / "terrain_3d_instancer.cpp")
        self.assertIn("Transform3D? transform = null", source)
        self.assertIn("[meshId, multimesh, transform ?? Transform3D.Identity, update]", source)
        self.assertIn("&Terrain3DInstancer::add_multimesh, DEFVAL(Transform3D()), DEFVAL(true)", native)

    def test_omitted_region_means_all_regions_not_origin(self):
        for filename, method, call, native_filename, native_method in [
            ("Terrain3DCollision.cs", "Update(Vector2I? regionLocation = null", "[regionLocation ?? new Vector2I(int.MaxValue, int.MaxValue), rebuild]", "terrain_3d_collision.cpp", "Terrain3DCollision::update, DEFVAL(V2I_MAX)"),
            ("Terrain3DInstancer.cs", "UpdateMmis(long meshId = -1, Vector2I? regionLocation = null", "[meshId, regionLocation ?? new Vector2I(int.MaxValue, int.MaxValue), rebuildAll]", "terrain_3d_instancer.cpp", "Terrain3DInstancer::update_mmis, DEFVAL(-1), DEFVAL(V2I_MAX)"),
        ]:
            with self.subTest(wrapper=filename):
                source = body(CSHARP / filename)
                self.assertIn(method, source)
                self.assertIn(call, source)
                self.assertIn(native_method, body(NATIVE / native_filename))
        self.assertIn("V2I_MAX{ INT32_MAX, INT32_MAX }", body(NATIVE / "constants.h"))

    def test_thumbnail_sizes_match_native_defaults(self):
        assets = body(CSHARP / "Terrain3DAssets.cs")
        utility = body(CSHARP / "Terrain3DUtil.cs")
        self.assertIn("CreateMeshThumbnails(long id = -1, Vector2I? size = null", assets)
        self.assertIn("[id, size ?? new Vector2I(512, 512), force]", assets)
        self.assertIn("&Terrain3DAssets::create_mesh_thumbnails, DEFVAL(-1), DEFVAL(V2I(512))", body(NATIVE / "terrain_3d_assets.cpp"))
        self.assertIn("GetThumbnail(Image image, Vector2I? size = null)", utility)
        self.assertIn("[image, size ?? new Vector2I(256, 256)]", utility)
        self.assertIn("&Terrain3DUtil::get_thumbnail, DEFVAL(V2I(256))", body(NATIVE / "terrain_3d_util.cpp"))

    def test_r16_omitted_height_range_preserves_signal(self):
        source = body(CSHARP / "Terrain3DUtil.cs")
        self.assertIn("Vector2? r16HeightRange = null", source)
        self.assertIn("[fileName, cacheMode, r16HeightRange ?? new Vector2(0, 255), r16Size]", source)
        self.assertIn("DEFVAL(Vector2(0.f, 255.f))", body(NATIVE / "terrain_3d_util.cpp"))
        # Explicit zero ranges and zero dimensions still pass through `??`;
        # they must never be treated as an omitted argument by value tests.
        self.assertNotRegex(source, r"(?:r16HeightRange|size)\s*==")

    def test_shader_parameter_getter_returns_native_variant(self):
        source = body(CSHARP / "Terrain3DMaterial.cs")
        self.assertIn("public new Variant GetShaderParam(StringName name) => Call(GDExtensionMethodName.GetShaderParam, [name]);", source)
        self.assertIn("Variant get_shader_param(const StringName &p_name) const;", body(NATIVE / "terrain_3d_material.h"))
        self.assertIn("&Terrain3DMaterial::get_shader_param", body(NATIVE / "terrain_3d_material_reflect.cpp"))


if __name__ == "__main__":
    unittest.main()
