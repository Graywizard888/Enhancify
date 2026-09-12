"""
Tests for the new Enhancify Rebranded TUI features:

 1. Long-press a patch row -> small centred PatchDescriptionDialog (Confirm)
 2. Patch list merges universal + app-specific entries (no missing patches)
 3. Asset fetch shows the '| Changelog |' dialog (Download / Back) BEFORE
    any download starts
 4. Configure screen: category buttons -> small centred dialogs
    (Appearance & Themes, Configuration Modules, Features Toggles,
    Rish Installer Flags)
 5. Feature / Optimization + Rish flag options are animated custom switches
    with a Save button (changes apply only on Save)
 6. 'Enhancify Rebranded' boot screen on start
 7. Main-menu status bar (Initiated Mode / Status / Arch)
 8. aria2c as downloader => CLI + Patches download simultaneously with
    per-file mixed-gauge rows
"""

from __future__ import annotations

import asyncio
import json
import os
import shutil
import stat
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

from src.assets import AssetReleaseInfo, AssetsManager
from src.config import config
from src.utils import DownloadResult, download_files_parallel


def _run_async(coro):
    loop = asyncio.new_event_loop()
    try:
        return loop.run_until_complete(coro)
    finally:
        loop.close()


async def _wait_for(pred, pilot, timeout: float = 15.0):
    """Poll until pred() is true, then settle so child widgets finish mounting."""
    elapsed = 0.0
    step = 0.02
    while elapsed < timeout:
        if pred():
            await pilot.pause(0.15)
            return True
        await pilot.pause(step)
        elapsed += step
    return False


class ConfigGuard:
    """Snapshot/restore the in-memory + on-disk config around a test."""

    def __enter__(self):
        self.snapshot = dict(config.settings)
        return self

    def __exit__(self, *exc):
        config.settings = self.snapshot
        try:
            config.save_config()
        except Exception:
            pass
        return False


class TestBootScreen(unittest.TestCase):
    """Feature 6: 'Enhancify Rebranded' boot screen + status bar (feature 7)."""

    def test_boot_screen_renders_and_advances(self):
        from src.environment import env
        from src.tui.app import EnhancifyApp
        from src.tui.screens.boot_screen import BootScreen
        from src.tui.screens.main_menu import MainMenuScreen
        from src.tui.widgets.status_bar import CyberStatusBar

        # Long enough to inspect both phases, then it auto-advances.
        os.environ["ENHANCIFY_BOOT_SECONDS"] = "1.0"

        async def _run():
            app = EnhancifyApp()
            # Deterministic network status for the classic infobox.
            with mock.patch.object(env, "check_network", return_value=(True, True, "Online")):
                async with app.run_test(size=(100, 30)) as pilot:
                    # Boot screen is first
                    for _ in range(200):
                        if isinstance(app.screen, BootScreen):
                            break
                        await pilot.pause(0.02)
                    self.assertIsInstance(app.screen, BootScreen)
                    art = str(app.screen.query_one("#boot-art").render())
                    self.assertIn("____", art)
                    self.assertIn("_//_", art)
                    name = str(app.screen.query_one("#boot-name").render())
                    self.assertIn("Enhancify Rebranded", name)

                    # Phase 1: classic "Checking..." infobox (no Build/Release yet)
                    info = str(app.screen.query_one("#boot-info").render())
                    self.assertIn("Modifier     : Graywizard", info)
                    self.assertIn("Last Updated : Checking...", info)
                    self.assertIn("Status       : Checking...", info)
                    self.assertNotIn("Build Version", info)

                    # Phase 2: full classic infobox once checks finish
                    for _ in range(300):
                        if "Build Version" in str(app.screen.query_one("#boot-info").render()):
                            break
                        await pilot.pause(0.02)
                    info = str(app.screen.query_one("#boot-info").render())
                    self.assertIn("Modifier     : Graywizard888", info)
                    self.assertIn("Last Updated :", info)
                    self.assertIn("Status       : Online", info)
                    self.assertIn("Build Version: Enhanced V2.7.2", info)
                    self.assertIn("Release      :", info)

                    # Auto-advance to the main menu
                    for _ in range(300):
                        if isinstance(app.screen, MainMenuScreen):
                            break
                        await pilot.pause(0.02)
                    self.assertIsInstance(app.screen, MainMenuScreen)

                    # Feature 7: classic status block on top of the main menu
                    bar = app.screen.query_one(CyberStatusBar)
                    for _ in range(100):
                        if bar.query("Label.status-line"):
                            break
                        await pilot.pause(0.05)
                    joined = "\n".join(
                        str(l.render()) for l in bar.query("Label.status-line")
                    )
                    self.assertIn("Initiated Mode :", joined)
                    self.assertIn("Status         :", joined)
                    self.assertIn("Arch           :", joined)

        _run_async(_run())

    def test_boot_skip_with_escape(self):
        from src.tui.app import EnhancifyApp
        from src.tui.screens.main_menu import MainMenuScreen

        os.environ["ENHANCIFY_BOOT_SECONDS"] = "10"  # long boot — must be skippable

        async def _run():
            app = EnhancifyApp()
            async with app.run_test(size=(100, 30)) as pilot:
                for _ in range(100):
                    if hasattr(app.screen, "query_one"):
                        app.screen.query_one("#boot-art")
                        break
                    await pilot.pause(0.02)
                await pilot.press("escape")
                for _ in range(100):
                    if isinstance(app.screen, MainMenuScreen):
                        break
                    await pilot.pause(0.02)
                self.assertIsInstance(app.screen, MainMenuScreen)

        _run_async(_run())


META_FOR_TESTS = [
    {
        "pkgName": None,
        "versions": [],
        "patches": {"recommended": ["universal_patch_a"], "optional": []},
        "options": [],
        "descriptions": {"universal_patch_a": "Universal helper patch from the null entry."},
    },
    {
        "pkgName": "com.test.app",
        "versions": ["1.0.0"],
        "patches": {
            "recommended": ["app_rec_patch"],
            "optional": ["app_opt_patch"],
        },
        "options": [],
        "descriptions": {
            "app_rec_patch": "App recommended patch.",
            "app_opt_patch": "Optional app patch.",
        },
    },
]


class PatchMetaGuard:
    """Write a Patches-*.json next to the default assets dir, clean after."""

    def __init__(self, filename: str = "Patches-testver.json"):
        from src.assets import assets_mgr

        self.filename = filename
        self.path = assets_mgr.assets_dir / "Anddea" / filename
        self.path.parent.mkdir(parents=True, exist_ok=True)

    def __enter__(self):
        self.path.write_text(json.dumps(META_FOR_TESTS), encoding="utf-8")
        return self.path

    def __exit__(self, *exc):
        self.path.unlink(missing_ok=True)
        return False


class TestPatchLongPressAndMerge(unittest.TestCase):
    """Features 1 + 2: long-press description dialog and full patch list."""

    def test_long_press_opens_description_dialog_and_merges_entries(self):
        from src.tui.app import EnhancifyApp
        from src.tui.screens.main_menu import MainMenuScreen
        from src.tui.screens.patch_select import PatchSelectScreen
        from src.tui.widgets.dialogs import PatchDescriptionDialog
        from textual.widgets import Button, Label, ListView

        os.environ["ENHANCIFY_BOOT_SECONDS"] = "0.05"

        async def _run():
            app = EnhancifyApp()
            async with app.run_test(size=(100, 40)) as pilot:
                # wait for main menu (boot)
                for _ in range(300):
                    if isinstance(app.screen, MainMenuScreen):
                        break
                    await pilot.pause(0.02)
                self.assertIsInstance(app.screen, MainMenuScreen)

                app.selected_app = {"pkgName": "com.test.app", "appName": "TestApp"}
                with PatchMetaGuard():
                    app.push_screen("patch_select_screen")
                    # wait for the list to fill
                    screen: PatchSelectScreen = None  # type: ignore[assignment]
                    for _ in range(300):
                        if isinstance(app.screen, PatchSelectScreen):
                            screen = app.screen
                            if screen.all_patches:
                                break
                        await pilot.pause(0.02)
                    self.assertIsNotNone(screen, "patch select screen not mounted")
                    await pilot.pause(0.2)

                    # ---- Feature 2: patches from BOTH entries are present
                    names = {p["name"] for p in screen.all_patches}
                    self.assertIn("universal_patch_a", names)  # from pkgName: null entry
                    self.assertIn("app_rec_patch", names)
                    self.assertIn("app_opt_patch", names)
                    self.assertEqual(len(names), 3)

                    # default enabled = recommended of both entries
                    self.assertIn("universal_patch_a", screen.enabled_patches)
                    self.assertIn("app_rec_patch", screen.enabled_patches)
                    self.assertNotIn("app_opt_patch", screen.enabled_patches)

                    # ---- Feature 1: long-press on 'app_opt_patch' row
                    p_list = screen.query_one("#patches-list", ListView)
                    target = None
                    for item in p_list.children:
                        if getattr(item, "patch_name", None) == "app_opt_patch":
                            target = item
                            break
                    self.assertIsNotNone(target, "app_opt_patch row missing from list")
                    await pilot.pause(0.1)

                    enabled_before = set(screen.enabled_patches)
                    # Press on the item's first (visible) row.
                    press_offset = (3, 0)

                    await pilot.mouse_down(target, offset=press_offset)
                    # hold longer than LONG_PRESS_SECONDS (0.55)
                    for _ in range(40):
                        if isinstance(app.screen, PatchDescriptionDialog):
                            break
                        await pilot.pause(0.05)
                    await pilot.mouse_up(target, offset=press_offset)

                    self.assertIsInstance(
                        app.screen, PatchDescriptionDialog, "long-press did not open dialog"
                    )
                    dlg = app.screen
                    title = str(dlg.query_one(".dialog-title").render())
                    self.assertIn("Patch Details", title)
                    name_lbl = str(dlg.query_one("#patch-dialog-name").render())
                    self.assertIn("app_opt_patch", name_lbl)
                    desc = str(dlg.query_one(".desc-text").render())
                    self.assertIn("Optional app patch.", desc)
                    self.assertIn("Confirm", str(dlg.query_one("#btn-confirm").label))

                    # Confirm closes the dialog and must NOT toggle the patch
                    await pilot.click("#btn-confirm")
                    await pilot.pause(0.1)
                    self.assertIsInstance(app.screen, PatchSelectScreen)
                    self.assertEqual(screen.enabled_patches, enabled_before)

                    # A regular single click still toggles (pilot.click posts
                    # the full MouseDown/MouseUp/Click sequence)
                    for item in p_list.children:
                        if getattr(item, "patch_name", None) == "app_opt_patch":
                            target = item
                            break
                    await pilot.pause(0.1)
                    target._long_press_fired = False  # (pilot posts no trailing Click)
                    await pilot.click(target, offset=(3, 0))
                    await pilot.pause(0.1)
                    self.assertIn("app_opt_patch", screen.enabled_patches)

        with PatchMetaGuard():
            _run_async(_run())


class TestChangelogBeforeDownload(unittest.TestCase):
    """Feature 3: changelog dialog with Download/Back before asset download."""

    def _fake_rel(self) -> AssetReleaseInfo:
        return AssetReleaseInfo(
            source_name="TestSrc",
            patches_version="v9.9.9",
            patches_ext="jar",
            patches_url="https://example.invalid/patches.jar",
            patches_size=123,
            cli_version="v8.8.8",
            cli_url="https://example.invalid/cli.jar",
            cli_size=45,
            json_url="",
            changelog="## v9.9.9\n- Fixed thingy\n- Added widget",
        )

    def test_back_aborts_and_download_proceeds(self):
        from src.tui.app import EnhancifyApp
        from src.tui.screens.app_select import AppSelectScreen
        from src.tui.screens.main_menu import MainMenuScreen
        from src.tui.widgets.dialogs import ChangelogDialog
        from textual.widgets import ListView

        from src.assets import assets_mgr

        os.environ["ENHANCIFY_BOOT_SECONDS"] = "0.05"
        patches_json = [
            {
                "pkgName": "com.example.one",
                "versions": ["1"],
                "patches": {"recommended": ["p1"], "optional": []},
                "options": [],
                "descriptions": {"p1": "d"},
            }
        ]

        async def _run():
            app = EnhancifyApp()
            async with app.run_test(size=(100, 30)) as pilot:
                for _ in range(300):
                    if isinstance(app.screen, MainMenuScreen):
                        break
                    await pilot.pause(0.02)
                self.assertIsInstance(app.screen, MainMenuScreen)

                with mock.patch.object(
                    assets_mgr, "fetch_source_release_info", return_value=self._fake_rel()
                ), mock.patch.object(
                    assets_mgr, "download_assets", return_value=DownloadResult.OK
                ), mock.patch.object(
                    assets_mgr, "detect_cli_capabilities", return_value={}
                ), mock.patch.object(
                    assets_mgr, "load_or_fetch_patches_json", return_value=patches_json
                ):
                    # ---------- BACK button: aborts the fetch
                    app.push_screen("app_select_screen")
                    self.assertTrue(
                        await _wait_for(lambda: isinstance(app.screen, ChangelogDialog), pilot),
                        "changelog dialog did not appear",
                    )
                    dlg = app.screen
                    meta = str(dlg.query_one(".changelog-meta").render())
                    self.assertIn("SOURCE  : TestSrc", meta)
                    self.assertIn("Patches : Patches-v9.9.9.jar", meta)
                    self.assertIn("Size    :", meta)
                    body = str(dlg.query_one(".desc-text").render())
                    self.assertIn("Fixed thingy", body)
                    self.assertIn("Download", str(dlg.query_one("#btn-download").label))
                    self.assertIn("Back", str(dlg.query_one("#btn-back").label))

                    await pilot.click("#btn-back")
                    await pilot.pause(0.2)
                    # Back pops the app-select screen entirely
                    self.assertIsInstance(app.screen, MainMenuScreen)

                    # ---------- DOWNLOAD button: proceeds to download + parse
                    app.push_screen("app_select_screen")
                    self.assertTrue(
                        await _wait_for(lambda: isinstance(app.screen, ChangelogDialog), pilot)
                    )
                    await pilot.click("#btn-download")
                    # Wait for the app list to populate (parse phase done)
                    for _ in range(600):
                        if isinstance(app.screen, AppSelectScreen):
                            s = app.screen
                            if s.apps_data:
                                break
                        await pilot.pause(0.02)
                    self.assertIsInstance(app.screen, AppSelectScreen)
                    self.assertTrue(app.screen.apps_data, "app list not populated")
                    p_list = app.screen.query_one("#apps-list", ListView)
                    self.assertGreaterEqual(len(list(p_list.children)), 1)

        _run_async(_run())


class TestConfigureDialogs(unittest.TestCase):
    """Features 4 + 5: Configure category buttons and animated switches + Save."""

    def test_categories_and_toggle_save(self):
        from src.tui.app import EnhancifyApp
        from src.tui.screens.main_menu import MainMenuScreen
        from src.tui.screens.settings import TOGGLE_KEYS, RISH_FLAGS, SettingsScreen
        from src.tui.widgets.dialogs import (
            AppearanceDialog,
            ConfigModulesDialog,
            ToggleSwitchDialog,
        )
        from src.tui.widgets.switch import CyberSwitch

        os.environ["ENHANCIFY_BOOT_SECONDS"] = "0.05"

        async def _run():
            app = EnhancifyApp()
            async with app.run_test(size=(100, 40)) as pilot:
                for _ in range(300):
                    if isinstance(app.screen, MainMenuScreen):
                        break
                    await pilot.pause(0.02)

                app.push_screen("settings_screen")
                self.assertTrue(
                    await _wait_for(lambda: isinstance(app.screen, SettingsScreen), pilot)
                )
                screen = app.screen

                # The four category buttons
                for btn_id in ("#cat-appearance", "#cat-modules", "#cat-features", "#cat-rish"):
                    self.assertIsNotNone(screen.query_one(btn_id), f"missing {btn_id}")

                # ---- Appearance & Themes dialog
                await pilot.click("#cat-appearance")
                self.assertTrue(
                    await _wait_for(lambda: isinstance(app.screen, AppearanceDialog), pilot)
                )
                self.assertIsNotNone(app.screen.query_one("#btn-switch"))
                await pilot.click("#btn-close")
                await pilot.pause(0.1)

                # ---- Configuration Modules dialog
                await pilot.click("#cat-modules")
                self.assertTrue(
                    await _wait_for(lambda: isinstance(app.screen, ConfigModulesDialog), pilot)
                )
                self.assertEqual(len(list(app.screen.query("Button"))), 7)  # 6 + Close
                await pilot.click("#btn-close")
                await pilot.pause(0.1)

                # ---- Features Toggles dialog: 10 animated switches + Save
                with ConfigGuard():
                    # make the first toggle predictable
                    first_key, _t, _d = TOGGLE_KEYS[0]
                    config.set(first_key, "off")

                    await pilot.click("#cat-features")
                    self.assertTrue(
                        await _wait_for(lambda: isinstance(app.screen, ToggleSwitchDialog), pilot)
                    )
                    dlg = app.screen
                    switches = list(dlg.query(CyberSwitch))
                    self.assertEqual(len(switches), len(TOGGLE_KEYS))
                    self.assertFalse(switches[0].value)

                    # Toggle it via the animated switch API
                    switches[0].toggle()
                    self.assertTrue(switches[0].value)
                    await pilot.pause(0.4)  # let the knob animation finish
                    self.assertGreaterEqual(switches[0]._anim, 0.99)

                    # Save applies the change
                    await pilot.click("#btn-save")
                    await pilot.pause(0.2)
                    self.assertIsInstance(app.screen, SettingsScreen)
                    self.assertTrue(config.is_on(first_key))

                    # ---- Cancel: staged change is NOT saved
                    second_key, _t, _d = TOGGLE_KEYS[1]
                    before = config.is_on(second_key)
                    await pilot.click("#cat-features")
                    self.assertTrue(
                        await _wait_for(lambda: isinstance(app.screen, ToggleSwitchDialog), pilot)
                    )
                    dlg = app.screen
                    switches = list(dlg.query(CyberSwitch))
                    switches[1].toggle()
                    await pilot.click("#btn-cancel")
                    await pilot.pause(0.2)
                    self.assertEqual(config.is_on(second_key), before)

                # ---- Rish Flags dialog: 3 switches
                with ConfigGuard():
                    await pilot.click("#cat-rish")
                    self.assertTrue(
                        await _wait_for(lambda: isinstance(app.screen, ToggleSwitchDialog), pilot)
                    )
                    switches = list(app.screen.query(CyberSwitch))
                    self.assertEqual(len(switches), len(RISH_FLAGS))
                    keys = {sw.switch_key for sw in switches}
                    self.assertEqual(keys, {k for k, _t, _d in RISH_FLAGS})
                    # Save with a change
                    target_key = RISH_FLAGS[0][0]
                    want = not config.is_on(target_key)
                    for sw in switches:
                        if sw.switch_key == target_key:
                            if sw.value != want:
                                sw.toggle()
                    await pilot.click("#btn-save")
                    await pilot.pause(0.2)
                    self.assertEqual(config.is_on(target_key), want)

        _run_async(_run())

    def test_cyber_switch_animation_states(self):
        from src.tui.widgets.switch import CyberSwitch

        sw = CyberSwitch("Test", "desc", switch_key="K", initial=False)
        self.assertFalse(sw.value)
        self.assertAlmostEqual(sw._anim, 0.0)
        sw.toggle()
        self.assertTrue(sw.value)
        # animation target is ON (without a running message pump the knob
        # jumps straight to the target; the UI test verifies the animation)
        self.assertEqual(sw._anim_to, 1.0)
        self.assertGreaterEqual(sw._anim, 0.99)
        sw.toggle()
        self.assertFalse(sw.value)
        self.assertEqual(sw._anim_to, 0.0)
        self.assertLessEqual(sw._anim, 0.01)


class FakeAria2cGuard:
    """Put a fake 'aria2c' executable on PATH (writes N bytes, prints progress)."""

    def __init__(self, size: int = 100, sleep: float = 0.4):
        self.size = size
        self.sleep = sleep
        self.dir = Path(tempfile.mkdtemp(prefix="fake_aria2c_"))
        self.prev_path = None

    def __enter__(self):
        script = self.dir / "aria2c"
        script.write_text(
            "#!/usr/bin/env bash\n"
            "dir=\"\"\n"
            "out=\"\"\n"
            "for a in \"$@\"; do\n"
            "  case \"$a\" in\n"
            "    --dir=*) dir=\"${a#--dir=*}\";;\n"
            "    --out=*) out=\"${a#--out=*}\";;\n"
            "  esac\n"
            "done\n"
            f"echo \"[#0000001 0B/{self.size}B(0%) 0B/s]\"\n"
            f"sleep {self.sleep}\n"
            f"head -c {self.size} /dev/zero > \"$dir/$out\" 2>/dev/null\n"
            f"echo \"[#0000001 {self.size // 2}B/{self.size}B(50%) 10B/s]\"\n"
            f"sleep {self.sleep / 2}\n"
            f"echo \"[#0000001 {self.size}B/{self.size}B(100%) 10B/s]\"\n",
            encoding="utf-8",
        )
        script.chmod(script.stat().st_mode | stat.S_IEXEC)
        self.prev_path = os.environ.get("PATH", "")
        os.environ["PATH"] = f"{self.dir}{os.pathsep}{self.prev_path}"
        return self

    def __exit__(self, *exc):
        os.environ["PATH"] = self.prev_path
        shutil.rmtree(self.dir, ignore_errors=True)
        return False


class TestParallelAria2cDownload(unittest.TestCase):
    """Feature 8: aria2c downloads CLI + Patches at the same time."""

    def test_download_files_parallel_both_ok(self):
        with FakeAria2cGuard(size=100) as fake:
            self.assertIsNotNone(shutil.which("aria2c"))
            tmp = Path(tempfile.mkdtemp())
            jobs = [
                ("https://x/cli.jar", tmp / "cli.jar", 100),
                ("https://x/patches.jar", tmp / "patches.jar", 100),
            ]
            labels = ["cli.jar", "patches.jar"]
            progress = []
            results = download_files_parallel(
                jobs,
                labels,
                progress_callback=lambda lb, c, t, p: progress.append((lb, c, t, p)),
            )
            self.assertEqual(results["cli.jar"], DownloadResult.OK)
            self.assertEqual(results["patches.jar"], DownloadResult.OK)
            self.assertTrue((tmp / "cli.jar").exists())
            self.assertTrue((tmp / "patches.jar").exists())
            # BOTH files reported progress (simultaneous gauges)
            self.assertIn("cli.jar", {p[0] for p in progress})
            self.assertIn("patches.jar", {p[0] for p in progress})
            shutil.rmtree(tmp, ignore_errors=True)

    def test_download_files_parallel_cancel(self):
        with FakeAria2cGuard(size=100, sleep=0.6):
            tmp = Path(tempfile.mkdtemp())
            jobs = [
                ("https://x/cli.jar", tmp / "cli.jar", 100),
                ("https://x/patches.jar", tmp / "patches.jar", 100),
            ]
            ev = threading.Event()

            def cancel_later():
                time.sleep(0.2)
                ev.set()

            t = threading.Thread(target=cancel_later, daemon=True)
            t.start()
            results = download_files_parallel(jobs, ["a", "b"], cancel_event=ev)
            t.join()
            self.assertEqual(results["a"], DownloadResult.CANCELLED)
            self.assertEqual(results["b"], DownloadResult.CANCELLED)
            shutil.rmtree(tmp, ignore_errors=True)

    def test_pre_cancelled(self):
        ev = threading.Event()
        ev.set()
        results = download_files_parallel(
            [("https://x/a", Path(tempfile.mkdtemp()) / "a", 10)], ["a"], cancel_event=ev
        )
        self.assertEqual(results["a"], DownloadResult.CANCELLED)

    def test_assets_download_parallel_cli_and_patches(self):
        """assets.download_assets with aria2c => both files, both gauges."""
        with ConfigGuard():
            config.set("DISABLE_NETWORK_ACCELERATION", "off")
        with FakeAria2cGuard(size=100):
            with ConfigGuard(), tempfile.TemporaryDirectory() as td:
                mgr = AssetsManager(workspace_dir=Path(td))
                info = AssetReleaseInfo(
                    source_name="TestSrc",
                    patches_version="v1",
                    patches_ext="jar",
                    patches_url="https://x/p.jar",
                    patches_size=100,
                    cli_version="v2",
                    cli_url="https://x/c.jar",
                    cli_size=100,
                )
                progress = []
                started = []

                t0 = time.time()
                result = mgr.download_assets(
                    info,
                    progress_callback=lambda lb, c, t, p: progress.append((lb, c, t, p)),
                    file_start_callback=lambda lb, sz: started.append(lb),
                )
                elapsed = time.time() - t0

                self.assertEqual(result, DownloadResult.OK)
                self.assertTrue((mgr.assets_dir / "CLI-v2.jar").exists())
                self.assertTrue(
                    (mgr.assets_dir / "TestSrc" / "Patches-v1.jar").exists()
                )
                # Both files were registered for the mixed-gauge UI
                self.assertIn("CLI-v2.jar", started)
                self.assertIn("Patches-v1.jar", started)
                # Both files streamed progress at the same time
                self.assertIn("CLI-v2.jar", {p[0] for p in progress})
                self.assertIn("Patches-v1.jar", {p[0] for p in progress})
                # Fake aria2c sleeps 0.4s+0.2s sequentially per file; running
                # simultaneously should be faster than 2x the sequential time.
                self.assertLess(elapsed, 1.2)


class TestBatchModalUI(unittest.TestCase):
    """The download modal renders per-file mixed-gauge rows (aria2c batch)."""

    def test_batch_rows_render(self):
        from src.tui.app import EnhancifyApp
        from src.tui.screens.main_menu import MainMenuScreen
        from src.tui.widgets.dialogs import DownloadProgressModal
        from src.tui.widgets.gradient import GradientProgressBar
        from textual.widgets import Label

        os.environ["ENHANCIFY_BOOT_SECONDS"] = "0.05"

        async def _run():
            app = EnhancifyApp()
            async with app.run_test(size=(100, 30)) as pilot:
                for _ in range(300):
                    if isinstance(app.screen, MainMenuScreen):
                        break
                    await pilot.pause(0.02)

                modal = DownloadProgressModal.for_assets_batch(
                    2,
                    145,
                    accelerated=True,
                    files=[("CLI-v2.jar", 45), ("Patches-v1.jar", 100)],
                )
                self.assertTrue(modal._batch)
                self.assertIn("Downloading 2 file(s) simultaneously", modal._body)
                self.assertIn("Accelerated: 8 parts each", modal._body)

                app.push_screen(modal)
                await pilot.pause(0.2)

                modal.on_file_progress("CLI-v2.jar", 22, 45, "48%")
                modal.on_file_progress("Patches-v1.jar", 50, 100, "50%")
                await pilot.pause(0.1)

                rows = str(modal.query_one("#dl-rows", Label).render())
                self.assertIn("CLI-v2.jar", rows)
                self.assertIn("Patches-v1.jar", rows)
                self.assertIn("48%", rows)
                self.assertIn("50%", rows)

                # overall bar = size weighted average ~ (22+50)/(45+100)
                bar = modal.query_one("#dl-bar", GradientProgressBar)
                self.assertAlmostEqual(bar.progress, (22 + 50) / 145, delta=0.02)

                modal.mark_batch_file_done("CLI-v2.jar", ok=True)
                await pilot.pause(0.1)
                rows = str(modal.query_one("#dl-rows", Label).render())
                self.assertIn("complete", rows)

        _run_async(_run())


if __name__ == "__main__":
    unittest.main()
