"""
Integration tests for Fetch Dependency (GmsCore + PotHelper) Python TUI backend & screens.
Uses mocked GitHub API + download so tests run offline and stay deterministic.
"""

from __future__ import annotations

import asyncio
import json
import shutil
import tempfile
import unittest
from pathlib import Path
from typing import Any, Dict, List, Optional
from unittest import mock

from src.features import (
    DEPENDENCIES_SUBDIR,
    GMSCORE_PROVIDERS,
    GmsCoreManager,
    PotHelperManager,
    _first_apk_asset,
    _normalize_release_payload,
)


def _fake_release(
    tag: str,
    apk_name: str,
    size: int = 12345,
    body: str = "## Changes\n- fix stuff",
    extra_assets: Optional[List[Dict[str, Any]]] = None,
) -> Dict[str, Any]:
    assets = list(extra_assets or [])
    assets.append(
        {
            "name": apk_name,
            "browser_download_url": f"https://example.com/download/{apk_name}",
            "size": size,
        }
    )
    return {"tag_name": tag, "body": body, "assets": assets}


class MockResponse:
    def __init__(self, payload: Any, status_code: int = 200):
        self._payload = payload
        self.status_code = status_code

    def json(self):
        return self._payload


class TestReleaseHelpers(unittest.TestCase):
    def test_normalize_list_takes_first(self):
        data = [_fake_release("v2", "a.apk"), _fake_release("v1", "b.apk")]
        out = _normalize_release_payload(data)
        self.assertEqual(out["tag_name"], "v2")

    def test_normalize_single_object(self):
        out = _normalize_release_payload(_fake_release("v9", "x.apk"))
        self.assertEqual(out["tag_name"], "v9")

    def test_normalize_empty_and_invalid(self):
        self.assertIsNone(_normalize_release_payload([]))
        self.assertIsNone(_normalize_release_payload(None))
        self.assertIsNone(_normalize_release_payload("nope"))

    def test_first_apk_skips_non_apk(self):
        release = _fake_release(
            "v1",
            "app.apk",
            size=50,
            extra_assets=[{"name": "README.md", "browser_download_url": "http://x", "size": 1}],
        )
        # extra asset is first; apk still found
        url, size, name = _first_apk_asset(release)
        self.assertEqual(name, "app.apk")
        self.assertEqual(size, 50)
        self.assertTrue(url.endswith("app.apk"))

    def test_first_apk_rejects_zero_size(self):
        release = {
            "assets": [
                {"name": "bad.apk", "browser_download_url": "http://x", "size": 0},
            ]
        }
        self.assertIsNone(_first_apk_asset(release))


class TestGmsCoreManager(unittest.TestCase):
    def setUp(self):
        self.temp = Path(tempfile.mkdtemp())
        self.mgr = GmsCoreManager(self.temp)

    def tearDown(self):
        shutil.rmtree(self.temp, ignore_errors=True)

    def test_storage_is_dependencies(self):
        expected = self.temp / "storage" / DEPENDENCIES_SUBDIR
        self.assertEqual(self.mgr.storage_dir, expected)
        self.assertTrue(expected.is_dir())

    def test_fetch_provider_release_from_list(self):
        provider = GMSCORE_PROVIDERS[0]
        payload = [
            _fake_release("v0.3.1.4.240913", "microg.apk", size=999),
            _fake_release("v0.2.0", "old.apk", size=100),
        ]

        with mock.patch("src.features.requests.get", return_value=MockResponse(payload)) as get:
            info = self.mgr.fetch_provider_release(provider)

        self.assertIsNotNone(info)
        self.assertEqual(info["kind"], "gmscore")
        self.assertEqual(info["provider"], "Wst_Xda")
        self.assertEqual(info["tag"], "v0.3.1.4.240913")
        self.assertEqual(info["size"], 999)
        self.assertEqual(info["filename"], "Wst_Xda-v0.3.1.4.240913.apk")
        self.assertEqual(info["target_path"], self.mgr.storage_dir / info["filename"])
        self.assertFalse(info["is_downloaded"])
        self.assertIn("fix stuff", info["changelog"])
        get.assert_called_once()
        called_url = get.call_args[0][0]
        self.assertEqual(called_url, f"https://api.github.com/repos/{provider.repo}/releases")
        self.assertNotIn("/latest", called_url)

    def test_fetch_provider_release_from_object(self):
        provider = GMSCORE_PROVIDERS[1]
        payload = _fake_release("1.0.0-rc", "revanced.apk", size=42)
        with mock.patch("src.features.requests.get", return_value=MockResponse(payload)):
            info = self.mgr.fetch_provider_release(provider)
        self.assertIsNotNone(info)
        self.assertEqual(info["provider"], "ReVanced")
        self.assertEqual(info["tag"], "1.0.0-rc")
        self.assertEqual(info["filename"], "ReVanced-1.0.0-rc.apk")

    def test_fetch_cleans_tag_characters(self):
        provider = GMSCORE_PROVIDERS[2]
        payload = _fake_release("v1.2.3 (build)", "rex.apk", size=10)
        with mock.patch("src.features.requests.get", return_value=MockResponse(payload)):
            info = self.mgr.fetch_provider_release(provider)
        self.assertEqual(info["tag"], "v1.2.3build")
        self.assertEqual(info["filename"], "Rex-v1.2.3build.apk")

    def test_fetch_http_error(self):
        with mock.patch("src.features.requests.get", return_value=MockResponse({}, status_code=403)):
            self.assertIsNone(self.mgr.fetch_provider_release(GMSCORE_PROVIDERS[0]))

    def test_fetch_no_apk_asset(self):
        payload = [{"tag_name": "v1", "body": "", "assets": [{"name": "src.zip", "browser_download_url": "http://z", "size": 9}]}]
        with mock.patch("src.features.requests.get", return_value=MockResponse(payload)):
            self.assertIsNone(self.mgr.fetch_provider_release(GMSCORE_PROVIDERS[0]))

    def test_fetch_empty_tag(self):
        payload = [{"tag_name": "", "body": "", "assets": [{"name": "a.apk", "browser_download_url": "http://a", "size": 1}]}]
        with mock.patch("src.features.requests.get", return_value=MockResponse(payload)):
            self.assertIsNone(self.mgr.fetch_provider_release(GMSCORE_PROVIDERS[0]))

    def test_is_downloaded_flag(self):
        provider = GMSCORE_PROVIDERS[0]
        size = 777
        payload = [_fake_release("v9", "x.apk", size=size)]
        with mock.patch("src.features.requests.get", return_value=MockResponse(payload)):
            info = self.mgr.fetch_provider_release(provider)
        # create matching file
        info["target_path"].write_bytes(b"x" * size)
        with mock.patch("src.features.requests.get", return_value=MockResponse(payload)):
            info2 = self.mgr.fetch_provider_release(provider)
        self.assertTrue(info2["is_downloaded"])

    def test_download_writes_and_cleans_old_provider_apks(self):
        provider = GMSCORE_PROVIDERS[0]
        old = self.mgr.storage_dir / "Wst_Xda-old.apk"
        other = self.mgr.storage_dir / "Rex-keep.apk"
        old.write_bytes(b"old")
        other.write_bytes(b"keep")

        info = {
            "provider": "Wst_Xda",
            "url": "https://example.com/file.apk",
            "size": 5,
            "target_path": self.mgr.storage_dir / "Wst_Xda-new.apk",
            "filename": "Wst_Xda-new.apk",
        }

        def fake_download(url, path, expected_size=0, progress_callback=None, headers=None):
            Path(path).write_bytes(b"hello")
            if progress_callback:
                progress_callback(5, 5, "100%")
            return True

        with mock.patch("src.features.download_file_ex", side_effect=fake_download) as dl:
            from src.utils import DownloadResult
            # fake_download returns True; wrap via side_effect that returns OK
            def fake_ex(*a, **k):
                fake_download(*a, **{kk: vv for kk, vv in k.items() if kk != "cancel_event"})
                return DownloadResult.OK
            dl.side_effect = fake_ex
            ok = self.mgr.download_gmscore(info)

        self.assertEqual(ok.value if hasattr(ok, "value") else ok, "ok")
        self.assertTrue(info["target_path"].exists())
        self.assertFalse(old.exists(), "old provider apk should be removed")
        self.assertTrue(other.exists(), "other provider apk must be kept")
        dl.assert_called_once()


class TestPotHelperManager(unittest.TestCase):
    def setUp(self):
        self.temp = Path(tempfile.mkdtemp())
        self.mgr = PotHelperManager(self.temp)

    def tearDown(self):
        shutil.rmtree(self.temp, ignore_errors=True)

    def test_repo_constant(self):
        self.assertEqual(PotHelperManager.REPO, "MorpheApp/PotHelper")
        self.assertEqual(self.mgr.storage_dir, self.temp / "storage" / "Dependencies")

    def test_fetch_release_keeps_upstream_filename(self):
        payload = [
            _fake_release("0.1.2", "pot-helper-0.1.2.apk", size=2048, body="Pot changelog"),
        ]
        with mock.patch("src.features.requests.get", return_value=MockResponse(payload)) as get:
            info = self.mgr.fetch_release()

        self.assertIsNotNone(info)
        self.assertEqual(info["kind"], "pothelper")
        self.assertEqual(info["provider"], "PotHelper")
        self.assertEqual(info["tag"], "0.1.2")
        self.assertEqual(info["filename"], "pot-helper-0.1.2.apk")  # bash keeps asset name
        self.assertEqual(info["size"], 2048)
        self.assertIn("Pot changelog", info["changelog"])
        called_url = get.call_args[0][0]
        self.assertEqual(called_url, "https://api.github.com/repos/MorpheApp/PotHelper/releases")

    def test_fetch_failure_paths(self):
        with mock.patch("src.features.requests.get", return_value=MockResponse({}, status_code=500)):
            self.assertIsNone(self.mgr.fetch_release())
        with mock.patch("src.features.requests.get", side_effect=Exception("network down")):
            self.assertIsNone(self.mgr.fetch_release())

    def test_download_cleans_old_pot_helper_apks(self):
        old = self.mgr.storage_dir / "pot-helper-0.0.1.apk"
        old.write_bytes(b"old")
        keep = self.mgr.storage_dir / "Wst_Xda-v1.apk"
        keep.write_bytes(b"gms")

        info = {
            "url": "https://example.com/pot.apk",
            "size": 4,
            "target_path": self.mgr.storage_dir / "pot-helper-0.2.0.apk",
            "filename": "pot-helper-0.2.0.apk",
        }

        def fake_download(url, path, expected_size=0, progress_callback=None, headers=None):
            Path(path).write_bytes(b"new!")
            return True

        from src.utils import DownloadResult

        def fake_ex(*a, **k):
            fake_download(*a, **{kk: vv for kk, vv in k.items() if kk != "cancel_event"})
            return DownloadResult.OK

        with mock.patch("src.features.download_file_ex", side_effect=fake_ex):
            ok = self.mgr.download(info)

        self.assertEqual(ok, DownloadResult.OK)
        self.assertTrue(info["target_path"].exists())
        self.assertFalse(old.exists())
        self.assertTrue(keep.exists())


class TestTuiScreens(unittest.TestCase):
    """Mount dependency-related screens under multiple resolutions."""

    def test_screens_registered(self):
        from src.tui.app import EnhancifyApp

        for key in (
            "dependency_select_screen",
            "gmscore_screen",
            "pothelper_screen",
            "main_menu_screen",
        ):
            self.assertIn(key, EnhancifyApp.SCREENS)

    def test_main_menu_button_and_binding(self):
        from src.tui.screens.main_menu import MainMenuScreen

        binding_actions = {b.action if hasattr(b, "action") else b[1] for b in MainMenuScreen.BINDINGS}
        # BINDINGS is list of tuples (key, action, description)
        actions = {b[1] for b in MainMenuScreen.BINDINGS}
        self.assertIn("fetch_dependency", actions)
        self.assertNotIn("gmscore", actions)

    def test_mount_dependency_flow_screens(self):
        async def _run():
            from src.tui.app import EnhancifyApp

            app = EnhancifyApp()
            async with app.run_test(size=(100, 30)) as pilot:
                assert app.screen is not None

                # Main menu should expose Fetch Dependency button
                btn = app.screen.query_one("#btn-dependency")
                assert btn is not None
                label = str(btn.label)
                assert "Fetch Dependency" in label

                # Push dependency select
                app.push_screen("dependency_select_screen")
                await pilot.pause(0.05)
                screen = app.screen
                assert screen.query_one("#btn-fetch-gmscore") is not None
                assert screen.query_one("#btn-fetch-pothelper") is not None
                assert "Fetch Dependency" in str(screen.query_one(".card-title").render())

                # GmsCore screen
                app.push_screen("gmscore_screen")
                await pilot.pause(0.05)
                gms = app.screen
                assert gms.query_one("#gmscore-list") is not None
                assert gms.query_one("#btn-download") is not None
                # Providers should be populated
                items = list(gms.query_one("#gmscore-list").children)
                assert len(items) == len(GMSCORE_PROVIDERS)
                app.pop_screen()
                await pilot.pause(0.02)

                # PotHelper screen
                app.push_screen("pothelper_screen")
                await pilot.pause(0.05)
                pot = app.screen
                assert pot.query_one("#btn-fetch") is not None
                assert pot.query_one("#btn-download") is not None
                assert pot.query_one("#changelog-label") is not None
                app.pop_screen()
                await pilot.pause(0.02)

                app.pop_screen()  # back to main
                await pilot.pause(0.02)

        asyncio.get_event_loop().run_until_complete(_run())

    def test_multi_resolution_smoke(self):
        async def _run():
            from src.tui.app import EnhancifyApp

            resolutions = [(80, 24), (40, 25), (100, 30), (120, 40)]
            screens = [
                "dependency_select_screen",
                "gmscore_screen",
                "pothelper_screen",
            ]
            for cols, rows in resolutions:
                app = EnhancifyApp()
                async with app.run_test(size=(cols, rows)) as pilot:
                    assert app.screen is not None
                    for sname in screens:
                        app.push_screen(sname)
                        await pilot.pause(0.03)
                        assert app.screen is not None, f"{sname} failed at {cols}x{rows}"
                        app.pop_screen()
                        await pilot.pause(0.02)

        asyncio.get_event_loop().run_until_complete(_run())

    def test_navigate_main_menu_to_dependency_via_action(self):
        async def _run():
            from src.tui.app import EnhancifyApp
            from src.tui.screens.dependency_select import DependencySelectScreen

            app = EnhancifyApp()
            async with app.run_test(size=(100, 30)) as pilot:
                app.screen.action_fetch_dependency()
                await pilot.pause(0.05)
                self.assertIsInstance(app.screen, DependencySelectScreen)

        asyncio.get_event_loop().run_until_complete(_run())


class TestEndToEndMockedDownload(unittest.TestCase):
    """Full fetch → download → is_downloaded path with mocked HTTP (no real CDN needed)."""

    def test_gmscore_full_pipeline(self):
        temp = Path(tempfile.mkdtemp())
        try:
            mgr = GmsCoreManager(temp)
            provider = GMSCORE_PROVIDERS[0]
            size = 64
            payload = [
                _fake_release("v9.9.9", "microg.apk", size=size, body="changelog body"),
            ]

            with mock.patch("src.features.requests.get", return_value=MockResponse(payload)):
                info = mgr.fetch_provider_release(provider)

            self.assertIsNotNone(info)
            self.assertEqual(info["filename"], "Wst_Xda-v9.9.9.apk")
            self.assertFalse(info["is_downloaded"])

            progress = []

            def fake_dl(url, path, expected_size=0, progress_callback=None, headers=None):
                self.assertEqual(url, info["url"])
                self.assertEqual(Path(path), info["target_path"])
                Path(path).write_bytes(b"A" * size)
                if progress_callback:
                    progress_callback(size, size, "100%")
                return True

            from src.utils import DownloadResult

            def fake_ex(url, path, expected_size=0, progress_callback=None, headers=None, cancel_event=None):
                fake_dl(url, path, expected_size, progress_callback, headers)
                return DownloadResult.OK

            with mock.patch("src.features.download_file_ex", side_effect=fake_ex):
                ok = mgr.download_gmscore(info, progress_callback=lambda c, t, p: progress.append(p))

            self.assertEqual(ok, DownloadResult.OK)
            self.assertTrue(info["target_path"].exists())
            self.assertEqual(info["target_path"].stat().st_size, size)
            self.assertEqual(progress, ["100%"])

            with mock.patch("src.features.requests.get", return_value=MockResponse(payload)):
                info2 = mgr.fetch_provider_release(provider)
            self.assertTrue(info2["is_downloaded"])
        finally:
            shutil.rmtree(temp, ignore_errors=True)

    def test_pothelper_full_pipeline(self):
        temp = Path(tempfile.mkdtemp())
        try:
            mgr = PotHelperManager(temp)
            size = 128
            payload = [_fake_release("v2.0.0", "pot-helper-2.0.0.apk", size=size)]

            with mock.patch("src.features.requests.get", return_value=MockResponse(payload)):
                info = mgr.fetch_release()

            self.assertIsNotNone(info)
            self.assertEqual(info["filename"], "pot-helper-2.0.0.apk")

            # stale build should be cleaned
            stale = mgr.storage_dir / "pot-helper-1.0.0.apk"
            stale.write_bytes(b"old")

            def fake_dl(url, path, expected_size=0, progress_callback=None, headers=None):
                Path(path).write_bytes(b"B" * size)
                return True

            from src.utils import DownloadResult

            def fake_ex(url, path, expected_size=0, progress_callback=None, headers=None, cancel_event=None):
                fake_dl(url, path, expected_size, progress_callback, headers)
                return DownloadResult.OK

            with mock.patch("src.features.download_file_ex", side_effect=fake_ex):
                ok = mgr.download(info)

            self.assertEqual(ok, DownloadResult.OK)
            self.assertTrue(info["target_path"].exists())
            self.assertFalse(stale.exists())
            self.assertEqual(info["target_path"].read_bytes(), b"B" * size)

            with mock.patch("src.features.requests.get", return_value=MockResponse(payload)):
                info2 = mgr.fetch_release()
            self.assertTrue(info2["is_downloaded"])
        finally:
            shutil.rmtree(temp, ignore_errors=True)


class TestLiveGithubOptional(unittest.TestCase):
    """Best-effort live API check — skipped automatically if GitHub is unreachable."""

    def test_live_fetch_pothelper_and_gmscore(self):
        import requests

        def _try_get(url):
            try:
                return requests.get(url, timeout=8)
            except requests.exceptions.SSLError:
                # Sandbox may lack CA bundle — still useful to validate API parsing
                return requests.get(url, timeout=8, verify=False)

        try:
            r = _try_get("https://api.github.com/rate_limit")
            if r.status_code != 200:
                self.skipTest(f"GitHub rate_limit HTTP {r.status_code}")
            remaining = r.json().get("resources", {}).get("core", {}).get("remaining", 0)
            if remaining < 3:
                self.skipTest(f"GitHub rate limited (remaining={remaining})")
        except Exception as e:
            self.skipTest(f"No GitHub access: {e}")

        # Patch managers' requests to tolerate sandbox SSL if needed
        _orig = __import__("src.features", fromlist=["requests"]).requests.get

        def _patched_get(*a, **k):
            try:
                return _orig(*a, **k)
            except Exception:
                k = dict(k)
                k["verify"] = False
                return _orig(*a, **k)

        temp = Path(tempfile.mkdtemp())
        try:
            with mock.patch("src.features.requests.get", side_effect=_patched_get):
                gm = GmsCoreManager(temp)
                ph = PotHelperManager(temp)

                info_g = gm.fetch_provider_release(GMSCORE_PROVIDERS[0])
                self.assertIsNotNone(info_g, "Live GmsCore fetch returned None")
                self.assertTrue(info_g["url"].startswith("https://"))
                self.assertTrue(info_g["filename"].endswith(".apk"))
                self.assertGreater(info_g["size"], 0)
                self.assertEqual(info_g["target_path"].parent.name, "Dependencies")

                info_p = ph.fetch_release()
                self.assertIsNotNone(info_p, "Live PotHelper fetch returned None")
                self.assertTrue(info_p["url"].startswith("https://"))
                self.assertTrue(info_p["filename"].endswith(".apk"))
                self.assertGreater(info_p["size"], 0)
                self.assertEqual(info_p["provider"], "PotHelper")
                self.assertEqual(info_p["target_path"].parent.name, "Dependencies")
        finally:
            shutil.rmtree(temp, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
