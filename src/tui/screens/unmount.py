"""
Enhancify Root Unmount Screen
Allows unmounting active Magisk / KernelSU / APatch bind mounts for patched apps.
"""

import subprocess
from typing import List

from rich.text import Text
from textual.app import ComposeResult
from textual.containers import Container, Horizontal, ScrollableContainer, Vertical
from textual.screen import Screen
from textual.widgets import Button, Footer, Label, ListItem, ListView

from src.environment import env
from src.tui.widgets.dialogs import ConfirmDialog, MessageDialog
from src.tui.widgets.header import CyberHeader
from src.utils import run_command


class UnmountScreen(Screen):
    """Root mode unmount manager screen."""

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
                yield Label("🔒 Unmount Root Patched Application", classes="card-title")
                yield Label("Select an active mounted application to unmount and remove boot scripts:", classes="card-desc")

                with Horizontal():
                    yield Button("🔙 Back [B]", id="btn-back", classes="btn-secondary")

                yield ListView(id="mounted-list")

        yield Footer()

    def on_mount(self) -> None:
        self.populate_mounted()

    def populate_mounted(self) -> None:
        m_list = self.query_one("#mounted-list", ListView)
        m_list.clear()

        code, out, _ = run_command(["su", "-c", "ls /data/local/tmp/enhancify 2>/dev/null"])
        mounted_pkgs = [l.replace(".apk", "").strip() for l in out.splitlines() if l.strip().endswith(".apk")]

        if not mounted_pkgs:
            m_list.append(ListItem(Label(Text("No mounted applications found in /data/local/tmp/enhancify.", style="dim"))))
            return

        for idx, pkg in enumerate(mounted_pkgs):
            txt = Text()
            txt.append("🔒 ", style="bold #ff4444")
            txt.append(f"{pkg:<30}", style="bold #ffffff")
            txt.append(" [Mounted]", style="#00ff7f")

            item = ListItem(Label(txt), id=f"mounted-{pkg}")
            m_list.append(item)

    def on_list_view_selected(self, event: ListView.Selected) -> None:
        item_id = event.item.id or ""
        if item_id.startswith("mounted-"):
            pkg = item_id[8:]
            self.confirm_unmount(pkg)

    def confirm_unmount(self, pkg: str) -> None:
        def handle_confirm(yes: bool) -> None:
            if yes:
                umount_script = env.workspace_dir / "system" / "umount.sh"
                if umount_script.exists():
                    cmd = ["su", "-mm", "-c", f"/system/bin/sh {umount_script} {pkg}"]
                    code, out, err = run_command(cmd, timeout=15)
                    self.populate_mounted()
                    if code == 0:
                        self.app.push_screen(MessageDialog("Unmounted", f"✓ {pkg} unmounted successfully!"))
                    else:
                        self.app.push_screen(MessageDialog("Error", f"Unmount failed: {err or out}"))

        self.app.push_screen(
            ConfirmDialog("Confirm Unmount", f"Are you sure you want to unmount {pkg}?", yes_label="Unmount", no_label="Cancel"),
            handle_confirm,
        )

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "btn-back":
            self.action_back()

    def action_back(self) -> None:
        self.app.pop_screen()
