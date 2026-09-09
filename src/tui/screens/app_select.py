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
from src.tui.widgets.dialogs import (
    DownloadProgressModal,
    MessageDialog,
    ParseProgressModal,
    ProgressModal,
)
from src.tui.widgets.header import CyberHeader
from src.utils import DownloadResult


class AppSelectScreen(Screen):
    """App selection screen with live search."""

    BINDINGS = [
        ("i", "import_file", "Import APK"),
        ("r", "refresh", "Refresh Apps"),
        ("b", "back", "Back"),
        ("escape", "back", "Back"),
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
        self.active_source = config.get("SOURCE", "Anddea")
        self.load_source_apps()

    def load_source_apps(self) -> None:
        """Ensure assets are downloaded and load supported apps."""
        # Phase 1: lightweight fetch of release metadata
        modal = ProgressModal(
            "Loading Assets", f"Fetching metadata for {self.active_source}..."
        )
        self.app.push_screen(modal)
        self.run_assets_worker(modal)

    @work(thread=True)
    def run_assets_worker(self, modal: ProgressModal) -> None:
        cancelled = False
        try:
            rel = assets_mgr.fetch_source_release_info(self.active_source)
            if not rel:
                self.app.call_from_thread(modal.safe_dismiss)
                self.app.call_from_thread(
                    self.app.push_screen,
                    MessageDialog(
                        "Error",
                        f"Failed to fetch release info for {self.active_source}!",
                    ),
                )
                return

            self.release_info = rel
            self.app.call_from_thread(modal.safe_dismiss)

            # Phase 2: download CLI + Patches with original gauge texts + cancel
            pending = []
            cli_label = f"CLI-{rel.cli_version}.jar"
            patches_label = f"Patches-{rel.patches_version}.{rel.patches_ext}"
            cli_path = assets_mgr.assets_dir / cli_label
            patches_path = (
                assets_mgr.assets_dir
                / rel.source_name
                / patches_label
            )
            need_cli = not (
                cli_path.exists()
                and (rel.cli_size <= 0 or cli_path.stat().st_size == rel.cli_size)
            ) and not assets_mgr.get_cached_cli(rel.source_name, rel.cli_version, cli_path)
            # get_cached_cli may have just populated cli_path
            if cli_path.exists() and (rel.cli_size <= 0 or cli_path.stat().st_size == rel.cli_size):
                need_cli = False
            need_patches = not (
                patches_path.exists()
                and (rel.patches_size <= 0 or patches_path.stat().st_size == rel.patches_size)
            )
            if need_cli:
                pending.append((cli_label, rel.cli_size))
            if need_patches:
                pending.append((patches_label, rel.patches_size))

            dl_result = DownloadResult.OK
            if pending:
                total_sz = sum(s for _, s in pending if s > 0)
                if len(pending) > 1:
                    dl_modal = DownloadProgressModal.for_assets_batch(
                        len(pending), total_sz, accelerated=True
                    )
                else:
                    dl_modal = DownloadProgressModal.for_asset_file(
                        pending[0][0], pending[0][1]
                    )

                # Push download modal on UI thread and wait briefly for mount
                ready = __import__("threading").Event()

                def _push():
                    self.app.push_screen(dl_modal)
                    ready.set()

                self.app.call_from_thread(_push)
                ready.wait(timeout=2.0)

                def on_file_start(label: str, size: int) -> None:
                    dl_modal.switch_to_asset_file(label, size)

                def on_prog(label: str, cur: int, tot: int, pct: str) -> None:
                    dl_modal.on_progress(cur, tot, pct)

                dl_result = assets_mgr.download_assets(
                    rel,
                    progress_callback=on_prog,
                    cancel_event=dl_modal.cancel_event,
                    file_start_callback=on_file_start,
                )
                self.app.call_from_thread(
                    dl_modal.safe_dismiss,
                    "cancelled" if dl_result == DownloadResult.CANCELLED else None,
                )
                if dl_result == DownloadResult.CANCELLED:
                    cancelled = True
                    self.app.call_from_thread(
                        self.app.push_screen,
                        MessageDialog("Cancelled", "Asset download cancelled."),
                    )
                    return
                if dl_result != DownloadResult.OK:
                    self.app.call_from_thread(
                        self.app.push_screen,
                        MessageDialog(
                            "Download Failed",
                            "Unable to download CLI / Patches completely.\n\n"
                            "Retry or change your Network.",
                        ),
                    )
                    return

            # Detect capabilities
            cli_jar = assets_mgr.assets_dir / f"CLI-{rel.cli_version}.jar"
            assets_mgr.detect_cli_capabilities(cli_jar)

            # Phase 3: parse patches list (API or CLI) with gradient spinner
            parse_modal = ParseProgressModal(self.active_source, from_cli=True)
            ready2 = __import__("threading").Event()

            def _push_parse():
                self.app.push_screen(parse_modal)
                ready2.set()

            self.app.call_from_thread(_push_parse)
            ready2.wait(timeout=2.0)

            def phase_cb(phase: str) -> None:
                if phase == "api":
                    parse_modal.set_phase_api()
                else:
                    parse_modal.set_phase_cli()

            patches_json = assets_mgr.load_or_fetch_patches_json(
                self.active_source,
                rel,
                progress_callback=lambda msg: parse_modal.update_message(msg),
                parse_progress_callback=parse_modal.on_parse_progress,
                cancel_event=parse_modal.cancel_event,
                phase_callback=phase_cb,
            )
            was_cancel = parse_modal.was_cancelled
            self.app.call_from_thread(
                parse_modal.safe_dismiss,
                "cancelled" if was_cancel else None,
            )
            if was_cancel:
                cancelled = True
                self.app.call_from_thread(
                    self.app.push_screen,
                    MessageDialog("Cancelled", "Patches list generation cancelled."),
                )
                return

            if patches_json:
                apps = []
                for entry in patches_json:
                    pname = entry.get("pkgName")
                    if pname:
                        clean_name = pname.split(".")[-1].capitalize()
                        pl = pname.lower()
                        if "youtube" in pl:
                            clean_name = (
                                "YouTube" if "music" not in pl else "YouTube Music"
                            )
                        elif "twitter" in pl or clean_name.lower() == "x":
                            clean_name = "Twitter / X"
                        elif "reddit" in pl:
                            clean_name = "Reddit"
                        elif "spotify" in pl:
                            clean_name = "Spotify"

                        apkmirror_name = clean_name.lower().replace(" ", "-")
                        apps.append(
                            {
                                "pkgName": pname,
                                "appName": clean_name,
                                "apkmirrorAppName": apkmirror_name,
                                "versions": entry.get("versions", []),
                            }
                        )
                self.apps_data = sorted(apps, key=lambda x: x["appName"])
        except Exception as e:
            try:
                self.app.call_from_thread(modal.safe_dismiss)
            except Exception:
                pass
            self.app.call_from_thread(
                self.app.push_screen,
                MessageDialog("Error", f"Asset load failed: {e}"),
            )
        finally:
            if not cancelled:
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

            item = ListItem(Label(txt))
            item.app_idx = idx
            apps_list.append(item)

    def on_input_changed(self, event: Input.Changed) -> None:
        if event.input.id == "search-input":
            self.filter_and_display_apps(event.value)

    def on_list_view_selected(self, event: ListView.Selected) -> None:
        idx = getattr(event.item, "app_idx", None)
        if idx is None and 0 <= event.index < len(self.filtered_apps):
            idx = event.index
        if idx is not None and 0 <= idx < len(self.filtered_apps):
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
