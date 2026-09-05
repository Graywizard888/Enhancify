"""
Enhancify Version Selection & Downloader Screen
Fetches available APKMirror versions for the chosen app, tags recommended & installed versions,
and downloads the chosen APK or APKM bundle before proceeding to patch selection.
"""

from pathlib import Path
from typing import Any, Dict, List, Optional

from rich.text import Text
from textual import work
from textual.app import ComposeResult
from textual.containers import Container, Horizontal, ScrollableContainer, Vertical
from textual.screen import Screen
from textual.widgets import Button, Footer, Label, ListItem, ListView

from src.antisplit import antisplit_mgr
from src.apkmirror import ScrapedVersion, apkmirror_scraper
from src.config import config
from src.environment import env
from src.tui.widgets.dialogs import MessageDialog, ProgressModal
from src.tui.widgets.header import CyberHeader


class VersionSelectScreen(Screen):
    """Screen for selecting app version to download."""

    BINDINGS = [
        ("a", "action_auto_select", "Auto Recommended"),
        ("r", "action_refresh", "Refresh List"),
        ("b", "action_back", "Back"),
        ("escape", "action_back", "Back"),
    ]

    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.versions_list: List[ScrapedVersion] = []

    def compose(self) -> ComposeResult:
        has_root, has_rish, mode_label = env.check_privileges()
        _, _, net_status = env.check_network()

        app_info = getattr(self.app, "selected_app", {})
        app_name = app_info.get("appName", "App")

        yield CyberHeader(mode_label=mode_label, online_status=net_status)

        with ScrollableContainer(classes="container-box"):
            with Vertical(classes="card"):
                yield Label(f"📦 Select Version for [bold #00ff7f]{app_name}[/]", classes="card-title")
                yield Label("Select a version from APKMirror. [RECOMMENDED] versions are tested by patch developers:", classes="card-desc")

                with Horizontal():
                    yield Button("⚡ Auto Recommended [A]", id="btn-auto", classes="btn-primary")
                    yield Button("🔄 Refresh List [R]", id="btn-refresh")
                    yield Button("🔙 Back [B]", id="btn-back", classes="btn-secondary")

                yield ListView(id="versions-list")

        yield Footer()

    def on_mount(self) -> None:
        self.load_versions()

    def load_versions(self, force_refresh: bool = False) -> None:
        """Fetch version list."""
        app_info = getattr(self.app, "selected_app", {})
        app_name = app_info.get("appName", "")
        apkmirror_name = app_info.get("apkmirrorAppName", app_name.lower())
        supported = app_info.get("versions", [])

        modal = ProgressModal("Loading Versions", f"Fetching versions for {app_name} from APKMirror...")
        self.app.push_screen(modal)
        self.run_versions_worker(modal, apkmirror_name, supported, force_refresh)

    @work(thread=True)
    def run_versions_worker(
        self,
        modal: ProgressModal,
        apkmirror_name: str,
        supported: List[str],
        force_refresh: bool,
    ) -> None:
        try:
            versions = apkmirror_scraper.fetch_versions_list(
                apkmirror_name,
                supported_versions=supported,
                force_refresh=force_refresh,
            )
            self.versions_list = versions
        finally:
            self.app.call_from_thread(modal.dismiss, None)
            self.app.call_from_thread(self.populate_versions_list)

    def populate_versions_list(self) -> None:
        """Populate the ListView with versions."""
        v_list = self.query_one("#versions-list", ListView)
        v_list.clear()

        if not self.versions_list:
            v_list.append(ListItem(Label(Text("No versions found. Check internet connection or APKMirror name.", style="red"))))
            return

        for idx, v in enumerate(self.versions_list):
            txt = Text()
            txt.append("📌 ", style="bold #00ff7f")
            txt.append(f"{v.version:<20}", style="bold #ffffff")

            if v.tag == "[RECOMMENDED]":
                txt.append(" [RECOMMENDED]", style="bold #00ff7f")
            elif v.tag == "[INSTALLED]":
                txt.append(" [INSTALLED]", style="bold #00e5ff")
            elif v.tag == "[BETA]":
                txt.append(" [BETA]", style="#ffd700")
            elif v.tag == "[ALPHA]":
                txt.append(" [ALPHA]", style="#ff4444")
            else:
                txt.append(" [STABLE]", style="#8b949e")

            item = ListItem(Label(txt), id=f"ver-{idx}")
            v_list.append(item)

    def on_list_view_selected(self, event: ListView.Selected) -> None:
        item_id = event.item.id or ""
        if item_id.startswith("ver-"):
            idx = int(item_id[4:])
            selected_v = self.versions_list[idx]
            self.download_and_proceed(selected_v)

    def download_and_proceed(self, selected_version: ScrapedVersion) -> None:
        """Download APK / APKM from APKMirror, process antisplit, and proceed to patch screen."""
        app_info = getattr(self.app, "selected_app", {})
        app_name = app_info.get("appName", "")

        modal = ProgressModal("Downloading App", f"Scraping download link for {app_name} {selected_version.version}...")
        self.app.push_screen(modal)
        self.run_download_worker(modal, selected_version)

    @work(thread=True)
    def run_download_worker(self, modal: ProgressModal, selected_version: ScrapedVersion) -> None:
        app_info = getattr(self.app, "selected_app", {})
        app_name = app_info.get("appName", "")

        try:
            # 1. Scrape link
            dl_info = apkmirror_scraper.scrape_download_link(selected_version.url)
            if not dl_info:
                self.app.call_from_thread(modal.dismiss, None)
                self.app.call_from_thread(
                    self.app.push_screen,
                    MessageDialog("Download Error", f"Failed to scrape download link for {selected_version.version}!")
                )
                return

            dl_url, app_format, size_bytes, ext = dl_info

            # 2. Download file
            modal.update_message(f"Downloading {app_name} {selected_version.version} ({ext.upper()})...")

            downloaded_file = apkmirror_scraper.download_app(
                app_name, selected_version.version, dl_url, ext, size_bytes
            )

            if not downloaded_file or not downloaded_file.exists():
                self.app.call_from_thread(modal.dismiss, None)
                self.app.call_from_thread(
                    self.app.push_screen,
                    MessageDialog("Download Failed", "Unable to complete file download!")
                )
                return

            # 3. Antisplit or optimize native libs
            target_apk = downloaded_file.parent / f"{selected_version.version}.apk"

            if ext == "apkm":
                modal.update_message("Merging APKM bundle splits with APKEditor...")
                ok = antisplit_mgr.antisplit_apkm(downloaded_file, target_apk)
                if not ok:
                    self.app.call_from_thread(modal.dismiss, None)
                    self.app.call_from_thread(
                        self.app.push_screen,
                        MessageDialog("Merge Error", "Failed to merge APKM splits!")
                    )
                    return
            elif ext == "apk" and config.is_on("OPTIMIZE_LIBS"):
                modal.update_message("Optimizing native libraries for device architecture...")
                antisplit_mgr.optimize_native_libs(downloaded_file)

            # Update selected_app state
            self.app.selected_app["version"] = selected_version.version
            self.app.selected_app["apk_path"] = target_apk if target_apk.exists() else downloaded_file

            self.app.call_from_thread(modal.dismiss, None)
            self.app.call_from_thread(self.app.push_screen, "patch_select_screen")
        except Exception as e:
            self.app.call_from_thread(modal.dismiss, None)
            self.app.call_from_thread(
                self.app.push_screen,
                MessageDialog("Error", f"Error during download process: {e}")
            )

    def on_button_pressed(self, event: Button.Pressed) -> None:
        btn_id = event.button.id
        if btn_id == "btn-auto":
            self.action_auto_select()
        elif btn_id == "btn-refresh":
            self.action_refresh()
        elif btn_id == "btn-back":
            self.action_back()

    def action_auto_select(self) -> None:
        """Find first recommended version and select it."""
        for v in self.versions_list:
            if v.tag == "[RECOMMENDED]":
                self.download_and_proceed(v)
                return
        if self.versions_list:
            self.download_and_proceed(self.versions_list[0])

    def action_refresh(self) -> None:
        self.load_versions(force_refresh=True)

    def action_back(self) -> None:
        self.app.pop_screen()
