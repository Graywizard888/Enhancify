"""
Unit & Integration Test Suite for Enhancify Python Core and TUI
"""

import os
import shutil
import tempfile
import unittest
from pathlib import Path

from src.antisplit import AntiSplitManager
from src.config import ConfigManager
from src.environment import Environment
from src.features import BundlePatcherManager, KeystoreManager, StorageOperations
from src.patches import PatchesManager
from src.sources import SourcesManager
from src.theme import THEMES, get_current_theme, set_current_theme


class TestEnhancifyCore(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.mkdtemp()
        self.workspace = Path(self.temp_dir)
        # Create dummy sources.json
        (self.workspace / "sources.json").write_text('[{"source": "TestSrc", "repository": "test/repo"}]')
        (self.workspace / ".info").write_text("VERSION='v6.2.4'")

    def tearDown(self):
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def test_config_manager(self):
        cfg = ConfigManager(self.workspace)
        self.assertEqual(cfg.get("SOURCE"), "Anddea")
        cfg.set("SOURCE", "ReVanced")
        self.assertEqual(cfg.get("SOURCE"), "ReVanced")

        # Reload from disk
        cfg2 = ConfigManager(self.workspace)
        self.assertEqual(cfg2.get("SOURCE"), "ReVanced")

        # Test toggle
        self.assertFalse(cfg.is_on("USE_PRE_RELEASE"))
        cfg.toggle("USE_PRE_RELEASE")
        self.assertTrue(cfg.is_on("USE_PRE_RELEASE"))

        # Test token
        self.assertIsNone(cfg.get_github_token())
        cfg.set_github_token("ghp_test1234567890")
        self.assertEqual(cfg.get_github_token(), "ghp_test1234567890")
        cfg.delete_github_token()
        self.assertIsNone(cfg.get_github_token())

        # Test apkmirror page limit
        self.assertEqual(cfg.get_apkmirror_page_limit(), 5)
        cfg.set_apkmirror_page_limit(8)
        self.assertEqual(cfg.get_apkmirror_page_limit(), 8)

    def test_environment_detector(self):
        env_test = Environment(self.workspace)
        self.assertEqual(env_test.get_version(), "v6.2.4")
        specs = env_test.get_device_specs()
        self.assertIsNotNone(specs.arch)
        self.assertIsNotNone(specs.dpi)
        self.assertEqual(specs.enhancify_version, "v6.2.4")

    def test_sources_manager(self):
        sm = SourcesManager(self.workspace)
        all_s = sm.get_all_sources()
        self.assertEqual(len(all_s), 1)
        self.assertEqual(all_s[0].source, "TestSrc")

        # Add custom source
        ok, msg = sm.add_custom_source("MyCustom", "user/repo", "https://example.com/p.json")
        self.assertTrue(ok)
        self.assertEqual(len(sm.get_all_sources()), 2)

        # Delete custom source
        ok, msg = sm.delete_custom_source("MyCustom")
        self.assertTrue(ok)
        self.assertEqual(len(sm.get_all_sources()), 1)

    def test_patches_manager(self):
        pm = PatchesManager(self.workspace)
        saved = pm.load_saved_patches("TestSrc")
        self.assertEqual(len(saved), 0)

        # Save dummy patch selection
        ok = pm.save_pkg_selection(
            "TestSrc",
            "com.example.app",
            {"PatchA", "PatchB"},
            [{"patchName": "PatchA", "key": "k1", "value": "v1"}],
        )
        self.assertTrue(ok)

        enabled = pm.get_enabled_patches_for_pkg("TestSrc", "com.example.app", [])
        self.assertIn("PatchA", enabled)
        self.assertIn("PatchB", enabled)

    def test_antisplit_dpi(self):
        am = AntiSplitManager(self.workspace)
        bucket = am.get_closest_dpi_bucket()
        self.assertIn(bucket, ["ldpi", "mdpi", "hdpi", "xhdpi", "xxhdpi", "xxxhdpi", "nodpi"])

    def test_bundle_manager(self):
        bm = BundlePatcherManager(self.workspace)
        self.assertEqual(len(bm.get_bundle_sources()), 0)
        bm.save_bundle_source("brosssh", "https://example.com/brosssh.json")
        sources = bm.get_bundle_sources()
        self.assertIn("brosssh", sources)

    def test_storage_ops(self):
        so = StorageOperations(self.workspace)
        # Create dummy apps and patched dirs
        (self.workspace / "apps" / "YouTube").mkdir(parents=True)
        (self.workspace / "apps" / "YouTube" / "stock.apk").write_text("dummy apk")
        self.assertEqual(so.delete_workspace_apps(), 1)

    def test_theme_manager(self):
        self.assertGreaterEqual(len(THEMES), 8)
        cur = get_current_theme()
        self.assertIsNotNone(cur)

        # Switch theme to cyberpunk_neon
        ok = set_current_theme("cyberpunk_neon")
        self.assertTrue(ok)
        new_theme = get_current_theme()
        self.assertEqual(new_theme.id, "cyberpunk_neon")
        self.assertEqual(new_theme.name, "Cyberpunk Neon")

        # Reset back to cyber_green
        set_current_theme("cyber_green")
        self.assertEqual(get_current_theme().id, "cyber_green")


if __name__ == "__main__":
    unittest.main()
