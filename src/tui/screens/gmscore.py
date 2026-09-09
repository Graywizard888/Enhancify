"""
Enhancify GmsCore (MicroG) Downloader Screen
Fetches official GmsCore APKs (Wst_Xda, ReVanced, Rex) with release changelog
and one-click download. Saves to Internal Storage/Enhancify/Dependencies/.
"""

import shutil
import subprocess
from typing import Any, Dict, Optional

from rich.text import Text
from textual import work
from textual.app import ComposeResult
from textual.containers import Horizontal, ScrollableContainer, Vertical
from textual.screen import Screen
from textual.widgets import Button, Footer, Label, ListItem, ListView

from src.environment import env
from src.features import GMSCORE_PROVIDERS, GmsCoreProvider, gmscore_mgr
from src.tui.widgets.dialogs import DownloadProgressModal, MessageDialog, ProgressModal
from src.tui.widgets.header import CyberHeader
from src.utils import DownloadResult, format_size


class GmsCoreScreen(Screen):
    """GmsCore MicroG provider selection & downloader screen."""

    BINDINGS = [
        ("b", "back", "Back"),
        ("escape", "back", "Back"),
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
                yield Label(
                    "Choose a GmsCore build to view release notes and download.\n"
                    "Saved to: Internal Storage/Enhancify/Dependencies/",
                    classes="card-desc",
                )

                with Horizontal():
                    yield Button(
                        "⚡ Download Selected APK",
                        id="btn-download",
                        classes="btn-primary",
                        disabled=True,
                    )
                    yield Button("🔙 Back [B]", id="btn-back", classes="btn-secondary")

                yield ListView(id="gmscore-list")

            with Vertical(classes="card"):
                yield Label("📋 Release Changelog", classes="card-title")
                yield Label(
                    "Select a provider above to load its release details.",
                    id="changelog-label",
                    classes="card-desc",
                )

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

            item = ListItem(Label(txt))
            item.prov_idx = idx
            g_list.append(item)

    def on_list_view_selected(self, event: ListView.Selected) -> None:
        idx = getattr(event.item, "prov_idx", None)
        if idx is None and 0 <= event.index < len(GMSCORE_PROVIDERS):
            idx = event.index
        if idx is not None and 0 <= idx < len(GMSCORE_PROVIDERS):
            provider = GMSCORE_PROVIDERS[idx]
            self.load_provider_release(provider)

    def load_provider_release(self, provider: GmsCoreProvider) -> None:
        modal = ProgressModal(
            "Fetching Release", f"Fetching release details for {provider.name}..."
        )
        self.app.push_screen(modal)
        self.run_fetch_worker(modal, provider)

    @work(thread=True)
    def run_fetch_worker(self, modal: ProgressModal, provider: GmsCoreProvider) -> None:
        info = gmscore_mgr.fetch_provider_release(provider)
        self.app.call_from_thread(modal.safe_dismiss)

        if not info:
            self.app.call_from_thread(
                self.app.push_screen,
                MessageDialog(
                    "Error",
                    f"Failed to fetch release info for {provider.name}!\n"
                    "Check network / GitHub rate limits and retry.",
                ),
            )
            return

        self.selected_info = info

        def update_ui():
            try:
                sz_str = format_size(info["size"])
                status_str = " (Already Downloaded)" if info["is_downloaded"] else ""
                desc = (
                    f"Provider : {info['provider']}\n"
                    f"Version  : {info['tag']}{status_str}\n"
                    f"Size     : {sz_str}\n"
                    f"Type     : GmsCore (MicroG)\n"
                    f"File     : {info['filename']}\n"
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
        if info.get("is_downloaded") and info["target_path"].exists():
            if shutil.which("termux-open"):
                subprocess.run(
                    ["termux-open", "--view", str(info["target_path"])],
                    capture_output=True,
                )
            self.app.push_screen(
                MessageDialog(
                    "Already Downloaded",
                    f"✓ {info['provider']} GmsCore {info['tag']} already downloaded!\n"
                    f"Size: {format_size(info['size'])}\n\n"
                    f"Saved to:\n{info['target_path']}",
                )
            )
            return

        label = f"{info['provider']} GmsCore {info['tag']}"
        modal = DownloadProgressModal.for_dependency(
            label, info["size"], title="| Downloading GmsCore |"
        )
        self.app.push_screen(modal)
        self.run_download_worker(modal, info)

    @work(thread=True)
    def run_download_worker(
        self, modal: DownloadProgressModal, info: Dict[str, Any]
    ) -> None:
        try:
            result = gmscore_mgr.download_gmscore(
                info,
                progress_callback=modal.on_progress,
                cancel_event=modal.cancel_event,
            )
            self.app.call_from_thread(
                modal.safe_dismiss,
                "cancelled" if result == DownloadResult.CANCELLED else None,
            )

            if result == DownloadResult.CANCELLED:
                self.app.call_from_thread(
                    self.app.push_screen,
                    MessageDialog("Cancelled", "GmsCore download cancelled."),
                )
                return

            if result == DownloadResult.OK and info["target_path"].exists():
                if shutil.which("termux-open"):
                    subprocess.run(
                        ["termux-open", "--view", str(info["target_path"])],
                        capture_output=True,
                    )

                self.app.call_from_thread(
                    self.app.push_screen,
                    MessageDialog(
                        "Download Complete",
                        f"✓ {info['provider']} GmsCore downloaded successfully!\n"
                        f"Version: {info['tag']}\n"
                        f"Size: {format_size(info['size'])}\n"
                        f"Saved at: Internal Storage/Enhancify/Dependencies/{info['filename']}\n\n"
                        f"{info['target_path']}",
                    ),
                )
                info["is_downloaded"] = True
            else:
                self.app.call_from_thread(
                    self.app.push_screen,
                    MessageDialog("Download Failed", "Failed to download GmsCore APK!"),
                )
        except Exception as e:
            self.app.call_from_thread(modal.safe_dismiss)
            self.app.call_from_thread(
                self.app.push_screen,
                MessageDialog("Error", f"Error during download: {e}"),
            )

    def action_back(self) -> None:
        self.app.pop_screen()
