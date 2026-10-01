#!/usr/bin/env python3
"""Focused CPU/source guards; GPU counterpart: frp_exposure_history.gd.

Run: python3 misc/scripts/tests/frp_exposure_math.py
These checks do not substitute for the native GPU and save/load regressions.
"""
import argparse
import math
import sys
from pathlib import Path
import unittest

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parents[3])
args, unittest_args = parser.parse_known_args()
ROOT = args.source_root.resolve()
ADDON = ROOT / "misc/feng-addons/feng-render-pipeline"


def adapted_ev(old, target, speed, dt, bounded=True):
    difference = target - old
    slope = (1.0 / 60.0) / ((1.0 - 2.0 ** (-speed / 60.0)) * (1.5 / speed))
    weight = (1.0 - 2.0 ** (-dt * speed)) * slope
    if bounded:
        weight = min(1.0, max(0.0, weight))
    if abs(difference) > 1.5:
        return old + math.copysign(min(abs(difference), dt * speed), difference)
    return old + difference * weight


class ExposureTests(unittest.TestCase):
    def test_reproduces_unbounded_long_frame_overshoot(self):
        self.assertGreater(adapted_ev(0.0, 1.0, 100.0, 0.25, False), 1.0)
        self.assertLess(adapted_ev(1.0, 0.0, 100.0, 0.25, False), 0.0)

    def test_adaptation_monotonic_for_both_directions_and_long_frames(self):
        for old in (-10.0, 0.0, 10.0, 20.0):
            for difference in (-20, -1.5, -1.0, -0.01, 0, 0.01, 1.0, 1.5, 20):
                target = old + difference
                for speed in (0.001, 1.0, 3.0, 10.0, 100.0, 1000.0):
                    for dt in (0.0, 1 / 240, 1 / 60, 0.25, 1.0, 60.0):
                        result = adapted_ev(old, target, speed, dt)
                        self.assertTrue(math.isfinite(result))
                        self.assertGreaterEqual(result, min(old, target) - 1e-12)
                        self.assertLessEqual(result, max(old, target) + 1e-12)
        shader = (ADDON / "library/eye-adaptation/eye_adaptation.glsl").read_text()
        self.assertIn("float exponential_weight = clamp(", shader)
        self.assertIn("log_old + log_diff * exponential_weight", shader)

    def test_history_rebase_preserves_chromaticity(self):
        for history_exposure in (1e-6, 0.01, 1, 1000):
            for current_exposure in (1e-6, 0.01, 1, 1000):
                for channel in (0.01, 0.2, 1, 100):
                    history = channel * history_exposure
                    self.assertAlmostEqual(history * (current_exposure / history_exposure),
                                           channel * current_exposure, places=8)
        shader = (ROOT / "servers/rendering/renderer_rd/shaders/effects/taa_resolve.glsl").read_text()
        rebase = shader.index("color_history *= params.history_exposure_ratio;")
        self.assertLess(rebase, shader.index("color_history = clip_history_3x3", rebase))
        self.assertLess(rebase, shader.index("color_history = reinhard(", rebase))

    def test_shared_taa_callers_keep_identity_ratio(self):
        header = (ROOT / "servers/rendering/renderer_rd/effects/taa.h").read_text()
        self.assertIn("p_history_exposure_ratio = 1.0f", header)
        native = (ROOT / "servers/rendering/renderer_rd/frp_clustered/render_frp_clustered.cpp").read_text()
        self.assertIn("current_pre_exposure / rb_data->taa_history_pre_exposure", native)
        self.assertIn("rb_data->taa_history_pre_exposure = current_pre_exposure", native)

    def test_history_lifetime_and_toggle_guards(self):
        native = (ROOT / "servers/rendering/renderer_rd/frp_clustered/render_frp_clustered.cpp").read_text()
        header = (ROOT / "servers/rendering/renderer_rd/frp_clustered/render_frp_clustered.h").read_text()
        self.assertNotIn("HashMap<ObjectID, float>", header)
        self.assertIn("pre_exposure = std::make_shared<float>(1.0f)", native)
        self.assertIn("rb_data->pre_exposure_enabled != pre_exposure_enabled", native)
        self.assertIn("rb_data->exposure_compositor != p_render_data->compositor", native)
        self.assertIn('if (!using_taa && rb->has_texture(SNAME("taa"), SNAME("history")))', native)
        self.assertIn('p_view == 0 && Math::is_finite(p_exposure)', native)
        self.assertIn('history = rb_data.is_valid() ? rb_data->pre_exposure', native)

    def test_nonfinite_history_and_positive_overflow_guards(self):
        taa = (ROOT / "servers/rendering/renderer_rd/shaders/effects/taa_resolve.glsl").read_text()
        validity = taa.index("valid_history = !any(isnan(result)) && !any(isinf(result));")
        self.assertLess(validity, taa.index("return max(result, 0.0f);", validity))
        self.assertIn("color_history = color_input;", taa)
        self.assertIn("mix(color, vec3(0.0), isnan(color))", taa)
        self.assertIn("mix(color, clamp(color, vec3(0.0), vec3(65504.0)), isinf(color))", taa)
        histogram = (ADDON / "library/eye-adaptation/eye_adaptation_histogram.glsl").read_text()
        self.assertIn("if (any(isnan(color)))", histogram)
        self.assertIn("positive_overflow ? float(NUM_BINS - 1) : 0.0", histogram)

    def test_fresh_defaults_and_serialized_opt_out_coverage(self):
        renderer = (ADDON / "renderer.gd").read_text()
        seed = renderer.split("func _default_seed_list()", 1)[1].split("\nfunc ", 1)[0]
        self.assertNotIn("enabled = false", seed)
        manifest = (ADDON / "pipeline/library_manager.gd").read_text()
        self.assertIn('"name": "Color Grade", "default_enabled": true', manifest)
        self.assertIn('"name": "Debug Buffers", "default_enabled": false', manifest)
        self.assertIn('parameters = Vector4(1, 1, 1, 1)', (ADDON / "library/color-grade/color_grade.tres").read_text())
        tests = (ROOT / "misc/scripts/tests/frp_passes.gd").read_text()
        self.assertIn('loading must preserve deliberately disabled Color Grade', tests)
        self.assertIn('loading must preserve deliberately disabled TAA', tests)


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0], *unittest_args], verbosity=2)
