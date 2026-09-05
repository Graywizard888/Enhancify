"""
Enhancify System Specifications & Release Changelog Screen
Displays hardware and Android OS specs along with Enhancify GitHub release changelogs.
"""

from typing import Optional

import requests
from rich.text import Text
from textual import work
from textual.app import ComposeResult
from textual.containers import Container, Horizontal, ScrollableContainer, Vertical
from textual.screen import Screen
from textual.widgets import Button, Footer, Label, Static

from src.config import config
from src.environment import env
from src.tui.widgets.dialogs import ProgressModal
from src.tui.widgets.header import CyberHeader


class SpecsScreen(Screen):
    """System specifications and release notes viewer screen."""

    BINDINGS = [
        ("b", "action_back", "Back"),
        ("escape", "action_back", "Back"),
    ]

    def compose(self) -> ComposeResult:
        has_root, has_rish, mode_label = env.check_privileges()
        _, _, net_status = env.check_network()

        yield CyberHeader(mode_label=mode_label, online_status=net_status)

        with ScrollableContainer(classes="container-box"):
            with Vertical(classes="card"):
                yield Label("🤖 Device & Runtime Specifications", classes="card-title")

                specs = env.get_device_specs()
                java_ver, java_pkg = env.detect_java_version()

                specs_lines = [
                    f"• Device Brand      : {specs.device_brand}",
                    f"• Device Model      : {specs.device_name}",
                    f"• CPU Architecture  : {specs.arch}",
                    f"• Screen DPI        : {specs.dpi}",
                    f"• Android Version   : {specs.android_version} (SDK {specs.sdk_version})",
                    f"• Kernel Version    : {specs.kernel_version}",
                    f"• Total RAM         : {specs.total_ram}",
                    f"• Available RAM     : {specs.available_ram_mb} MB",
                    f"• Storage Info      : {specs.storage_info}",
                    f"• System Locale     : {specs.locale}",
                    f"• Java Runtime      : OpenJDK {java_ver} ({java_pkg})",
                    f"• Enhancify Version : {specs.enhancify_version}",
                ]
                yield Label("\n".join(specs_lines), classes="card-desc")

                with Horizontal():
                    yield Button("🔙 Back to Main Menu [B]", id="btn-back", classes="btn-primary")

            with Vertical(classes="card"):
                yield Label(f"📋 Enhancify {specs.enhancify_version} Changelog", classes="card-title")
                yield Label("Loading release notes from GitHub...", id="changelog-label", classes="card-desc")

        yield Footer()

    def on_mount(self) -> None:
        self.fetch_changelog()

    @work(thread=True)
    def fetch_changelog(self) -> None:
        version = env.get_version()
        repo = "Graywizard888/Enhancify"
        url = f"https://api.github.com/repos/{repo}/releases/tags/{version}"
        headers = {"User-Agent": "Enhancify"}

        tok = config.get_github_token()
        if tok:
            headers["Authorization"] = f"Bearer {tok}"

        changelog_text = "Changelog not available for this release."
        try:
            r = requests.get(url, headers=headers, timeout=5)
            if r.status_code == 200:
                data = r.json()
                body = data.get("body", "")
                if body:
                    changelog_text = body
        except Exception:
            pass

        def update_ui():
            try:
                self.query_one("#changelog-label", Label).update(changelog_text)
            except Exception:
                pass

        self.app.call_from_thread(update_ui)

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "btn-back":
            self.action_back()

    def action_back(self) -> None:
        self.app.pop_screen()
