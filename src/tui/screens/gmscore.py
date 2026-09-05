"""
Enhancify GmsCore (MicroG) Downloader Screen
Fetches official GmsCore APKs (Wst_Xda, ReVanced, Rex) with release changelog and one-click download.
"""

import shutil
import subprocess
from typing import Any, Dict, List, Optional

from rich.text import Text
from textual import work
from textual.app import ComposeResult
from textual.containers import Container, Horizontal, ScrollableContainer, Vertical
from textual.screen import Screen
from textual.widgets import Button, Footer, Label, ListItem, ListView

from src.environment import env
from src.features import GMSCORE_PROVIDERS, GmsCoreProvider, gmscore_mgr
from src.tui.widgets.dialogs import MessageDialog, ProgressModal
from src.tui.widgets.header import CyberHeader
from src.utils import format_size


class GmsCoreScreen(Screen):
    """GmsCore MicroG provider selection & downloader screen."""

    BINDINGS = [
        ("b", "action_back", "Back"),
        ("escape", "action_back", "Back"),
    ]

    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.provider_releases: Dict[str, Dict[str, Any]] = {}
        self.selected_info: Optional[Dict[str, Any]] = None

    def compose(self) -> ComposeResult:
        has_root, has_rish, mode_label = env.check_privileges()
        _, _, net_status = env.check_network()

        yield CyberHeader(mode_label=mode_label, online_status=net_status)

        with ScrollableContainer(classes="container-box"):
            with Vertical(classes="card"):
                yield Label("🔌 Select GmsCore (MicroG) Provider", classes="card-title")
                yield Label("Choose a GmsCore build to view release notes and download:", classes="card-desc")

                with Horizontal():
                    yield Button("⚡ Download Selected APK", id="btn-download", classes="btn-primary", disabled=True)
                    yield Button("🔙 Back [B]", id="btn-back", classes="btn-secondary")

                yield ListView(id="gmscore-list")

            with Vertical(classes="card"):
                yield Label("📋 Release Changelog", classes="card-title")
                yield Label("Select a provider above to load its release details.", id="changelog-label", classes="card-desc")

        yield Footer()

    def on_mount(self) -> None:
        self.populate_providers()

    def populate_providers(self) -> None:
        """Populate list of GmsCore providers."""
        g_list = self.query_one("#gmscore-list", ListView)
        g_list.clear()

        for idx, p in enumerate(GMSCORE_PROVIDERS):
            txt = Text()
            txt.append("📦 ", style="bold #00ff7f")
            txt.append(f"{p.name:<25}", style="bold #ffffff")
            txt.append(f" ({p.repo})", style="#00e5ff")

            item = ListItem(Label(txt), id=f"gmsprov-{idx}")
            g_list.append(item)

    def on_list_view_selected(self, event: ListView.Selected) -> None:
        item_id = event.item.id or ""
        if item_id.startswith("gmsprov-"):
            idx = int(item_id[8:])
            provider = GMSCORE_PROVIDERS[idx]
            self.load_provider_release(provider)

    def load_provider_release(self, provider: GmsCoreProvider) -> None:
        modal = ProgressModal("Fetching Release", f"Fetching release details for {provider.name}...")
        self.app.push_screen(modal)
        self.run_fetch_worker(modal, provider)

    @work(thread=True)
    def run_fetch_worker(self, modal: ProgressModal, provider: GmsCoreProvider) -> None:
        info = gmscore_mgr.fetch_provider_release(provider)
        self.app.call_from_thread(modal.dismiss, None)

        if not info:
            self.app.call_from_thread(
                self.app.push_screen,
                MessageDialog("Error", f"Failed to fetch release info for {provider.name}!")
            )
            return

        self.selected_info = info

        def update_ui():
            try:
                sz_str = format_size(info["size"])
                status_str = " (Already Downloaded)" if info["is_downloaded"] else ""
                desc = (
                    f"Version : {info['tag']}{status_str}\n"
                    f"Size    : {sz_str}\n"
                    f"File    : {info['filename']}\n"
                    f"────────────────────────────────────────\n\n"
                    f"{info['changelog']}"
                )
                self.query_one("#changelog-label", Label).update(desc)
                self.query_one("#btn-download", Button).disabled = False
            except Exception:
                pass

        self.app.call_from_thread(update_ui)

    def on_button_pressed(self, event: Button.Pressed) -> None:
        btn_id = event.button.id
        if btn_id == "btn-download":
            self.download_selected_gmscore()
        elif btn_id == "btn-back":
            self.action_back()

    def download_selected_gmscore(self) -> None:
        if not self.selected_info:
            return

        info = self.selected_info
        modal = ProgressModal("Downloading GmsCore", f"Downloading {info['filename']}...")
        self.app.push_screen(modal)
        self.run_download_worker(modal, info)

    @work(thread=True)
    def run_download_worker(self, modal: ProgressModal, info: Dict[str, Any]) -> None:
        try:
            ok = gmscore_mgr.download_gmscore(
                info,
                progress_callback=lambda cur, tot, pct: modal.update_message(f"Downloading {info['filename']}: {pct}"),
            )
            self.app.call_from_thread(modal.dismiss, None)

            if ok and info["target_path"].exists():
                # Open with termux-open if available
                if shutil.which("termux-open"):
                    subprocess.run(["termux-open", "--view", str(info["target_path"])], capture_output=True)

                self.app.call_from_thread(
                    self.app.push_screen,
                    MessageDialog("Download Complete", f"✓ GmsCore downloaded successfully!\nSaved to:\n{info['target_path']}")
                )
            else:
                self.app.call_from_thread(
                    self.app.push_screen,
                    MessageDialog("Download Failed", "Failed to download GmsCore APK!")
                )
        except Exception as e:
            self.app.call_from_thread(modal.dismiss, None)
            self.app.call_from_thread(
                self.app.push_screen,
                MessageDialog("Error", f"Error during download: {e}")
            )

    def action_back(self) -> None:
        self.app.pop_screen()
