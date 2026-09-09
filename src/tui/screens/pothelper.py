"""
Enhancify PotHelper Downloader Screen
Fetches MorpheApp/PotHelper APK with release changelog and one-click download.
Saves to Internal Storage/Enhancify/Dependencies/ (bash parity).
"""

import shutil
import subprocess
from typing import Any, Dict, Optional

from textual import work
from textual.app import ComposeResult
from textual.containers import Horizontal, ScrollableContainer, Vertical
from textual.screen import Screen
from textual.widgets import Button, Footer, Label

from src.environment import env
from src.features import pothelper_mgr
from src.tui.widgets.dialogs import DownloadProgressModal, MessageDialog, ProgressModal
from src.tui.widgets.header import CyberHeader
from src.utils import DownloadResult, format_size


class PotHelperScreen(Screen):
    """PotHelper release viewer & downloader screen."""

    BINDINGS = [
        ("d", "download", "Download"),
        ("b", "back", "Back"),
        ("escape", "back", "Back"),
    ]

    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.selected_info: Optional[Dict[str, Any]] = None

    def compose(self) -> ComposeResult:
        has_root, has_rish, mode_label = env.check_privileges()
        _, _, net_status = env.check_network()

        yield CyberHeader(mode_label=mode_label, online_status=net_status)

        with ScrollableContainer(classes="container-box"):
            with Vertical(classes="card"):
                yield Label("🛠️  Fetch PotHelper", classes="card-title")
                yield Label(
                    "Download the latest PotHelper APK (MorpheApp/PotHelper).\n"
                    "Saved to: Internal Storage/Enhancify/Dependencies/",
                    classes="card-desc",
                )

                with Horizontal():
                    yield Button(
                        "🔄 Fetch Release Info",
                        id="btn-fetch",
                        classes="btn-primary",
                    )
                    yield Button(
                        "⚡ Download APK  [D]",
                        id="btn-download",
                        classes="btn-primary",
                        disabled=True,
                    )
                    yield Button("🔙 Back [B]", id="btn-back", classes="btn-secondary")

            with Vertical(classes="card"):
                yield Label("📋 Release Changelog", classes="card-title")
                yield Label(
                    "Tap 'Fetch Release Info' to load the latest PotHelper release.",
                    id="changelog-label",
                    classes="card-desc",
                )

        yield Footer()

    def on_button_pressed(self, event: Button.Pressed) -> None:
        btn_id = event.button.id
        if btn_id == "btn-fetch":
            self.fetch_release()
        elif btn_id == "btn-download":
            self.action_download()
        elif btn_id == "btn-back":
            self.action_back()

    def fetch_release(self) -> None:
        modal = ProgressModal("Fetching Release", "Fetching PotHelper release details...")
        self.app.push_screen(modal)
        self.run_fetch_worker(modal)

    @work(thread=True)
    def run_fetch_worker(self, modal: ProgressModal) -> None:
        info = pothelper_mgr.fetch_release()
        self.app.call_from_thread(modal.safe_dismiss)

        if not info:
            self.app.call_from_thread(
                self.app.push_screen,
                MessageDialog(
                    "Error",
                    "Failed to fetch PotHelper release info!\n"
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
                    f"Provider : PotHelper\n"
                    f"Version  : {info['tag']}{status_str}\n"
                    f"Size     : {sz_str}\n"
                    f"Type     : PotHelper APK\n"
                    f"File     : {info['filename']}\n"
                    f"────────────────────────────────────────\n\n"
                    f"{info['changelog']}"
                )
                self.query_one("#changelog-label", Label).update(desc)
                self.query_one("#btn-download", Button).disabled = False
            except Exception:
                pass

        self.app.call_from_thread(update_ui)

    def action_download(self) -> None:
        if not self.selected_info:
            self.fetch_release()
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
                    f"✓ PotHelper {info['tag']} already downloaded!\n"
                    f"Size: {format_size(info['size'])}\n\n"
                    f"Saved to:\n{info['target_path']}",
                )
            )
            return

        modal = DownloadProgressModal.for_dependency(
            info["filename"], info["size"], title="| Downloading PotHelper |"
        )
        self.app.push_screen(modal)
        self.run_download_worker(modal, info)

    @work(thread=True)
    def run_download_worker(
        self, modal: DownloadProgressModal, info: Dict[str, Any]
    ) -> None:
        try:
            result = pothelper_mgr.download(
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
                    MessageDialog("Cancelled", "PotHelper download cancelled."),
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
                        f"✓ PotHelper downloaded successfully!\n"
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
                    MessageDialog("Download Failed", "Failed to download PotHelper APK!"),
                )
        except Exception as e:
            self.app.call_from_thread(modal.safe_dismiss)
            self.app.call_from_thread(
                self.app.push_screen,
                MessageDialog("Error", f"Error during download: {e}"),
            )

    def action_back(self) -> None:
        self.app.pop_screen()
