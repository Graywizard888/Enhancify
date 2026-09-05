"""
Enhancify File Picker Screen
Touch and keyboard friendly file browser for importing APKs, bundles, and JSON files from storage.
"""

from pathlib import Path
from typing import List, Optional

from rich.text import Text
from textual.app import ComposeResult
from textual.containers import Container, Horizontal, ScrollableContainer, Vertical
from textual.screen import Screen
from textual.widgets import Button, Footer, Label, ListItem, ListView

from src.environment import env
from src.tui.widgets.header import CyberHeader
from src.utils import format_size


ALLOWED_EXTENSIONS = {".apk", ".apkm", ".xapk", ".apks", ".json"}


class FilePickerScreen(Screen[Optional[Path]]):
    """File browser screen."""

    BINDINGS = [
        ("u", "action_up", "Up Dir"),
        ("b", "action_cancel", "Cancel"),
        ("escape", "action_cancel", "Cancel"),
    ]

    def __init__(self, start_dir: Optional[Path] = None, allowed_exts: Optional[set] = None, **kwargs):
        super().__init__(**kwargs)
        # Determine valid start directory
        storage_shared = Path.home() / "storage" / "shared"
        sdcard = Path("/sdcard")

        if start_dir and start_dir.exists():
            self.current_dir = start_dir
        elif storage_shared.exists():
            self.current_dir = storage_shared
        elif sdcard.exists():
            self.current_dir = sdcard
        else:
            self.current_dir = Path.home()

        self.allowed_exts = allowed_exts or ALLOWED_EXTENSIONS

    def compose(self) -> ComposeResult:
        has_root, has_rish, mode_label = env.check_privileges()
        _, _, net_status = env.check_network()

        yield CyberHeader(mode_label=mode_label, online_status=net_status)

        with ScrollableContainer(classes="container-box"):
            with Vertical(classes="card"):
                yield Label("📂 Select File from Storage", classes="card-title")
                yield Label(f"Current Path: [bold #00e5ff]{self.current_dir}[/]", id="path-label", classes="card-desc")

                with Horizontal():
                    yield Button("⬆️ Up Directory [U]", id="btn-up")
                    yield Button("❌ Cancel [B]", id="btn-cancel", classes="btn-secondary")

                yield ListView(id="file-list")

        yield Footer()

    def on_mount(self) -> None:
        self.populate_directory()

    def populate_directory(self) -> None:
        """Populate ListView with entries from current_dir."""
        try:
            self.query_one("#path-label", Label).update(f"Current Path: [bold #00e5ff]{self.current_dir}[/]")
        except Exception:
            pass

        file_list = self.query_one("#file-list", ListView)
        file_list.clear()

        try:
            entries = sorted(list(self.current_dir.iterdir()), key=lambda x: (not x.is_dir(), x.name.lower()))
        except Exception:
            file_list.append(ListItem(Label(Text("❌ Permission denied or directory unreadable", style="red"))))
            return

        for p in entries:
            if p.name.startswith("."):
                continue

            if p.is_dir():
                txt = Text()
                txt.append("📁 ", style="bold #00e5ff")
                txt.append(f"{p.name}/", style="bold #ffffff")
                item = ListItem(Label(txt), id=f"dir-{p.name}")
                file_list.append(item)
            elif p.suffix.lower() in self.allowed_exts:
                txt = Text()
                txt.append("📦 ", style="bold #00ff7f")
                txt.append(f"{p.name:<30}", style="#e6edf3")
                try:
                    sz_str = format_size(p.stat().st_size)
                    txt.append(f" ({sz_str})", style="#8b949e")
                except Exception:
                    pass
                item = ListItem(Label(txt), id=f"file-{p.name}")
                file_list.append(item)

    def on_list_view_selected(self, event: ListView.Selected) -> None:
        item_id = event.item.id or ""
        if item_id.startswith("dir-"):
            dir_name = item_id[4:]
            next_dir = self.current_dir / dir_name
            if next_dir.is_dir():
                self.current_dir = next_dir
                self.populate_directory()
        elif item_id.startswith("file-"):
            file_name = item_id[5:]
            selected_file = self.current_dir / file_name
            self.dismiss(selected_file)

    def on_button_pressed(self, event: Button.Pressed) -> None:
        btn_id = event.button.id
        if btn_id == "btn-up":
            self.action_up()
        elif btn_id == "btn-cancel":
            self.action_cancel()

    def action_up(self) -> None:
        if self.current_dir.parent != self.current_dir:
            self.current_dir = self.current_dir.parent
            self.populate_directory()

    def action_cancel(self) -> None:
        self.dismiss(None)
