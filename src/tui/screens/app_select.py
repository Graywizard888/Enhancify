"""
Enhancify App Selection Screen
Displays supported apps for the active patch source, with search filtering and direct file import.
"""

from pathlib import Path
from typing import Any, Dict, List, Optional

from rich.text import Text
from textual import work
from textual.app import ComposeResult
from textual.containers import Container, Horizontal, ScrollableContainer, Vertical
from textual.screen import Screen
from textual.widgets import Button, Footer, Input, Label, ListItem, ListView

from src.antisplit import antisplit_mgr
from src.assets import AssetReleaseInfo, assets_mgr
from src.config import config
from src.environment import env
from src.tui.screens.file_picker import FilePickerScreen
from src.tui.widgets.dialogs import MessageDialog, ProgressModal
from src.tui.widgets.header import CyberHeader


class AppSelectScreen(Screen):
    """App selection screen with live search."""

    BINDINGS = [
        ("i", "action_import_file", "Import APK"),
        ("r", "action_refresh", "Refresh Apps"),
        ("b", "action_back", "Back"),
        ("escape", "action_back", "Back"),
    ]

    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.apps_data: List[Dict[str, Any]] = []
        self.filtered_apps: List[Dict[str, Any]] = []
        self.active_source = config.get("SOURCE", "Anddea")
        self.release_info: Optional[AssetReleaseInfo] = None

    def compose(self) -> ComposeResult:
        has_root, has_rish, mode_label = env.check_privileges()
        _, _, net_status = env.check_network()

        yield CyberHeader(mode_label=mode_label, online_status=net_status)

        with ScrollableContainer(classes="container-box"):
            with Vertical(classes="card"):
                yield Label("📱 Select Target Application", classes="card-title")
                yield Label("Choose an application to patch or import an APK from storage:", classes="card-desc")

                yield Input(placeholder="🔍 Search apps by name or package...", id="search-input")

                with Horizontal():
                    yield Button("📥 Import File [I]", id="btn-import", classes="btn-primary")
                    yield Button("🔄 Refresh [R]", id="btn-refresh")
                    yield Button("🔙 Back [B]", id="btn-back", classes="btn-secondary")

                yield ListView(id="apps-list")

        yield Footer()

    def on_mount(self) -> None:
        self.load_source_apps()

    def load_source_apps(self) -> None:
        """Ensure assets are downloaded and load supported apps."""
        modal = ProgressModal("Loading Assets", f"Fetching metadata for {self.active_source}...")
        self.app.push_screen(modal)
        self.run_assets_worker(modal)

    @work(thread=True)
    def run_assets_worker(self, modal: ProgressModal) -> None:
        try:
            rel = assets_mgr.fetch_source_release_info(self.active_source)
            if not rel:
                self.app.call_from_thread(modal.dismiss, None)
                self.app.call_from_thread(
                    self.app.push_screen,
                    MessageDialog("Error", f"Failed to fetch release info for {self.active_source}!")
                )
                return

            self.release_info = rel
            # Download binaries
            modal.update_message(f"Downloading {self.active_source} patches & CLI...")
            assets_mgr.download_assets(rel)

            # Detect capabilities
            cli_jar = assets_mgr.assets_dir / f"CLI-{rel.cli_version}.jar"
            assets_mgr.detect_cli_capabilities(cli_jar)

            # Load patches json
            modal.update_message("Parsing patches metadata...")
            patches_json = assets_mgr.load_or_fetch_patches_json(self.active_source, rel)

            if patches_json:
                # Extract apps list
                apps = []
                for entry in patches_json:
                    pname = entry.get("pkgName")
                    if pname:
                        # Format clean display name
                        clean_name = pname.split(".")[-1].capitalize()
                        if "youtube" in pname.lower():
                            clean_name = "YouTube" if "music" not in pname.lower() else "YouTube Music"
                        elif "twitter" in pname.lower() or "x" == clean_name.lower():
                            clean_name = "Twitter / X"
                        elif "reddit" in pname.lower():
                            clean_name = "Reddit"
                        elif "spotify" in pname.lower():
                            clean_name = "Spotify"

                        apkmirror_name = clean_name.lower().replace(" ", "-")

                        apps.append({
                            "pkgName": pname,
                            "appName": clean_name,
                            "apkmirrorAppName": apkmirror_name,
                            "versions": entry.get("versions", []),
                        })
                self.apps_data = sorted(apps, key=lambda x: x["appName"])
        finally:
            self.app.call_from_thread(modal.dismiss, None)
            self.app.call_from_thread(self.filter_and_display_apps)

    def filter_and_display_apps(self, query: str = "") -> None:
        """Filter app list by search text and render in ListView."""
        apps_list = self.query_one("#apps-list", ListView)
        apps_list.clear()

        q = query.strip().lower()
        self.filtered_apps = [
            a for a in self.apps_data
            if not q or q in a["appName"].lower() or q in a["pkgName"].lower()
        ]

        if not self.filtered_apps:
            apps_list.append(ListItem(Label(Text("No matching applications found.", style="dim"))))
            return

        for idx, a in enumerate(self.filtered_apps):
            txt = Text()
            txt.append("📱 ", style="bold #00ff7f")
            txt.append(f"{a['appName']:<22}", style="bold #ffffff")
            txt.append(f" [{a['pkgName']}]", style="#8b949e")

            item = ListItem(Label(txt), id=f"app-{idx}")
            apps_list.append(item)

    def on_input_changed(self, event: Input.Changed) -> None:
        if event.input.id == "search-input":
            self.filter_and_display_apps(event.value)

    def on_list_view_selected(self, event: ListView.Selected) -> None:
        item_id = event.item.id or ""
        if item_id.startswith("app-"):
            idx = int(item_id[4:])
            selected_app = self.filtered_apps[idx]
            # Navigate to VersionSelectScreen
            self.app.selected_app = selected_app
            self.app.push_screen("version_select_screen")

    def on_button_pressed(self, event: Button.Pressed) -> None:
        btn_id = event.button.id
        if btn_id == "btn-import":
            self.action_import_file()
        elif btn_id == "btn-refresh":
            self.action_refresh()
        elif btn_id == "btn-back":
            self.action_back()

    def action_import_file(self) -> None:
        """Open file picker to import an APK / bundle directly."""
        def handle_file(file_path: Optional[Path]) -> None:
            if not file_path:
                return

            meta = antisplit_mgr.extract_metadata(file_path)
            if not meta:
                self.app.push_screen(
                    MessageDialog("Import Error", f"Unable to extract metadata from:\n{file_path.name}")
                )
                return

            # Store imported app info on app
            self.app.selected_app = {
                "pkgName": meta.pkg_name,
                "appName": meta.app_name,
                "apkmirrorAppName": meta.app_name.lower(),
                "imported_file": meta.file_path,
                "version": meta.version_name,
                "extension": meta.extension,
            }
            # Go directly to patch selection
            self.app.push_screen("patch_select_screen")

        self.app.push_screen(FilePickerScreen(), handle_file)

    def action_refresh(self) -> None:
        self.load_source_apps()

    def action_back(self) -> None:
        self.app.pop_screen()
