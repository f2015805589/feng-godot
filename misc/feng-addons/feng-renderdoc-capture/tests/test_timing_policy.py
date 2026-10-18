"""Check the D3D12 timing prerequisite without accessing GPU counters."""

import importlib.util
from pathlib import Path
import sys
import unittest
from unittest.mock import MagicMock, patch


SPEC = importlib.util.spec_from_file_location(
    "renderdoc_view", Path(__file__).resolve().parents[1] / "src/renderdoc_view.py"
)
VIEW = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VIEW)


class TimingPolicyTests(unittest.TestCase):
    def test_d3d12_is_blocked_until_developer_mode_is_confirmed(self):
        with patch.object(sys, "platform", "win32"):
            for state in (False, None):
                with self.subTest(state=state), patch.object(VIEW, "developer_mode_enabled", return_value=state):
                    self.assertIn("Developer Mode", VIEW.timing_block_reason(True))
            with patch.object(VIEW, "developer_mode_enabled", return_value=True):
                self.assertEqual(VIEW.timing_block_reason(True), "")

    def test_other_graphics_apis_do_not_depend_on_windows_policy(self):
        with patch.object(VIEW, "developer_mode_enabled", side_effect=AssertionError("unexpected registry access")):
            self.assertEqual(VIEW.timing_block_reason(False), "")
            with patch.object(sys, "platform", "linux"):
                self.assertEqual(VIEW.timing_block_reason(True), "")

    def test_local_registry_does_not_authorize_a_remote_replay(self):
        with patch.object(sys, "platform", "win32"), patch.object(
            VIEW, "developer_mode_enabled", side_effect=AssertionError("wrong machine")
        ):
            self.assertEqual(VIEW.timing_block_reason(True, remote_replay=True), "")

    def test_registry_uses_the_64_bit_machine_setting(self):
        registry = MagicMock()
        registry.QueryValueEx.return_value = (1, 4)
        with patch.object(sys, "platform", "win32"), patch.dict(sys.modules, {"winreg": registry}):
            self.assertTrue(VIEW.developer_mode_enabled())
        registry.OpenKey.assert_called_once_with(
            registry.HKEY_LOCAL_MACHINE,
            r"SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock",
            0,
            registry.KEY_READ | registry.KEY_WOW64_64KEY,
        )

    def test_missing_or_unreadable_registry_never_authorizes_timing(self):
        for error, expected in ((FileNotFoundError(), False), (PermissionError(), None)):
            registry = MagicMock()
            registry.OpenKey.side_effect = error
            with self.subTest(error=type(error).__name__), patch.object(sys, "platform", "win32"), patch.dict(
                sys.modules, {"winreg": registry}
            ):
                self.assertIs(VIEW.developer_mode_enabled(), expected)


if __name__ == "__main__":
    unittest.main()
