"""
Enhancify Bundle Patcher Screen
Allows importing custom patch bundles from GitHub Raw URLs, Brosssh API, local JSON files,
or pre-saved bundle sources.
"""

from pathlib import Path
from typing import Dict, List, Optional

from rich.text import Text
from textual.app import ComposeResult
from textual.containers import Container, Horizontal, ScrollableContainer, Vertical
from textual.screen import Screen
from textual.widgets import Button, Footer, Label, ListItem, ListView

from src.environment import env
from src.features import bundle_mgr
from src.tui.screens.file_picker import FilePickerScreen
from src.tui.widgets.dialogs import InputDialog, MessageDialog
from src.tui.widgets.header import CyberHeader


class BundlePatcherScreen(Screen):
    """Bundle patcher management & import screen."""

    BINDINGS = [
        ("u", "action_import_url", "Import URL"),
        ("f", "action_import_file", "Import File"),
        ("b", "action_back", "Back"),
        ("escape", "action_back", "Back"),
    ]

    def compose(self) -> ComposeResult:
        has_root, has_rish, mode_label = env.check_privileges()
        _, _, net_status = env.check_network()

        yield CyberHeader(mode_label=mode_label, online_status=net_status)

        with ScrollableContainer(classes="container-box"):
            with Vertical(classes="card"):
                yield Label("📦 Bundle Patcher (Experimental)", classes="card-title")
                yield Label("Import standalone patch bundles from external URLs or JSON files:", classes="card-desc")

                with Horizontal():
                    yield Button("🌐 Import from URL [U]", id="btn-url", classes="btn-primary")
                    yield Button("📂 Import JSON File [F]", id="btn-file")
                    yield Button("🔙 Back [B]", id="btn-back", classes="btn-secondary")

                yield ListView(id="bundle-sources-list")

        yield Footer()

    def on_mount(self) -> None:
        self.populate_bundle_sources()

    def populate_bundle_sources(self) -> None:
        b_list = self.query_one("#bundle-sources-list", ListView)
        b_list.clear()

        sources = bundle_mgr.get_bundle_sources()
        if not sources:
            b_list.append(ListItem(Label(Text("No saved bundle sources. Click 'Import from URL' above.", style="dim"))))
            return

        for name, url in sources.items():
            txt = Text()
            txt.append("📦 ", style="bold #00ff7f")
            txt.append(f"{name:<20}", style="bold #ffffff")
            txt.append(f" ({url})", style="#00e5ff")

            item = ListItem(Label(txt), id=f"bundle-{name}")
            b_list.append(item)

    def on_button_pressed(self, event: Button.Pressed) -> None:
        btn_id = event.button.id
        if btn_id == "btn-url":
            self.action_import_url()
        elif btn_id == "btn-file":
            self.action_import_file()
        elif btn_id == "btn-back":
            self.action_back()

    def action_import_url(self) -> None:
        """Prompt for GitHub raw URL or Brosssh API URL."""
        def handle_url(res: Optional[str]) -> None:
            if not res or not res.strip():
                return
            url = res.strip()
            ok, msg, data = bundle_mgr.validate_and_fetch_bundle_url(url)
            if ok and data:
                name = url.split("/")[-1].replace(".json", "")
                bundle_mgr.save_bundle_source(name, url)
                self.populate_bundle_sources()
                self.app.push_screen(MessageDialog("Bundle Saved", f"✓ Source '{name}' saved successfully!"))
            else:
                self.app.push_screen(MessageDialog("Validation Error", msg))

        self.app.push_screen(
            InputDialog("Import Bundle URL", "Enter Bundle JSON URL (GitHub raw or Brosssh API):", placeholder="https://raw.githubusercontent.com/.../bundle.json"),
            handle_url,
        )

    def action_import_file(self) -> None:
        """Import bundle JSON from file picker."""
        def handle_file(file_path: Optional[Path]) -> None:
            if not file_path:
                return
            import json
            try:
                data = json.loads(file_path.read_text(encoding="utf-8"))
                if "version" in data and "download_url" in data:
                    self.app.push_screen(MessageDialog("Bundle Loaded", f"Loaded bundle v{data['version']} from:\n{file_path.name}"))
                else:
                    self.app.push_screen(MessageDialog("Invalid Bundle", "JSON missing 'version' or 'download_url'."))
            except Exception as e:
                self.app.push_screen(MessageDialog("Error", f"Failed to parse file: {e}"))

        self.app.push_screen(FilePickerScreen(allowed_exts={".json"}), handle_file)

    def action_back(self) -> None:
        self.app.pop_screen()
