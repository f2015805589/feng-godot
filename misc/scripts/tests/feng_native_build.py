"""Check native addon target names and isolated build options without a compiler."""

import unittest
from pathlib import Path
from types import SimpleNamespace

ADDONS = Path(__file__).resolve().parents[2] / "feng-addons"


class Environment(dict):
    def Clone(self):
        return Environment(self)

    def Append(self, **values):
        for key, value in values.items():
            self[key] = self.get(key, []) + value

    def GodotCPPDocData(self, target, source):
        return target

    def SharedLibrary(self, target, source):
        return self, target, source


class NativeBuildTest(unittest.TestCase):
    def test_variants(self):
        for addon in ("feng-idweight-terrain", "feng-renderdoc-capture", "feng-lightmap-mc"):
            native = ADDONS / addon / "native"
            for platform, suffix, mingw in (
                ("linux", ".so", False),
                ("windows", ".dll", False),
                ("windows", ".dll", True),
                ("macos", ".dylib", False),
            ):
                for target in ("editor", "template_debug", "template_release"):
                    with self.subTest(addon=addon, platform=platform, target=target, mingw=mingw):
                        bindings = Environment(
                            platform=platform,
                            target=target,
                            arch="x86_64",
                            SHLIBSUFFIX=suffix,
                            ARCOM="ar $SOURCES",
                            use_mingw=mingw,
                        )
                        result = []

                        def script(path, exports):
                            scope = dict(
                                exports,
                                Import=lambda *args: None,
                                Dir=lambda path: SimpleNamespace(abspath=str(native)),
                                SConscript=lambda path: bindings,
                                Glob=lambda path: [path],
                                Default=result.append,
                            )
                            source = (native / path).resolve()
                            exec(compile(source.read_text(), str(source), "exec"), scope)

                        source = native / "SConstruct"
                        exec(compile(source.read_text(), str(source), "exec"), {"SConscript": script})
                        env, output, sources = result[0]
                        variant = "release" if target == "template_release" else "debug"
                        name = f"{addon}.{platform}.{variant}"
                        expected = f"lib{name}.framework/{name}" if platform == "macos" else f"lib{name}.x86_64{suffix}"
                        self.assertEqual(Path(output), ADDONS / addon / "bin" / expected)
                        self.assertEqual(
                            env["LIBS"], ["dl"] if addon == "feng-renderdoc-capture" and platform == "linux" else []
                        )
                        self.assertEqual(
                            len(sources), 2 if addon != "feng-lightmap-mc" and target != "template_release" else 1
                        )
                        self.assertNotIn("CXXFLAGS", bindings)
                        self.assertEqual(
                            env.get("CXXFLAGS", []),
                            ["/EHsc" if platform == "windows" and not mingw else "-fexceptions"]
                            if addon == "feng-lightmap-mc"
                            else [],
                        )
                        self.assertEqual("TEMPFILE" in env["ARCOM"], platform == "linux")


if __name__ == "__main__":
    unittest.main()
