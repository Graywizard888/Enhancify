"""
Enhancify Storage & Cleanup Manager Screen
Handles deletion of cached assets, temporary build files, patched output APKs,
and stock app backups to free up device storage.
"""

from rich.text import Text
from textual.app import ComposeResult
from textual.containers import Container, Horizontal, ScrollableContainer, Vertical
from textual.screen import Screen
from textual.widgets import Button, Footer, Label, Static

from src.assets import assets_mgr
from src.environment import env
from src.features import storage_ops
from src.tui.widgets.dialogs import ConfirmDialog, MessageDialog
from src.tui.widgets.header import CyberHeader


class StorageManagerScreen(Screen):
    """Storage and cleanup manager screen."""

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
                yield Label("🗑️ Storage & File Cleaner", classes="card-title")
                yield Label("Manage internal storage and workspace cache:", classes="card-desc")

                with Vertical():
                    yield Button("🗑️ Delete Internal Storage Patched APKs", id="btn-del-patched", classes="btn-danger")
                    yield Button("🗑️ Delete Terminal Stock / Build APKs", id="btn-del-terminal", classes="btn-danger")
                    yield Button("🗑️ Delete CLI & Patch Assets", id="btn-del-assets", classes="btn-danger")
                    yield Button("📦 Backup Stock Apps to Internal Storage", id="btn-backup-stock", classes="btn-primary")
                    yield Button("🔙 Back to Main Menu [B]", id="btn-back", classes="btn-secondary")

        yield Footer()

    def on_button_pressed(self, event: Button.Pressed) -> None:
        btn_id = event.button.id
        if btn_id == "btn-del-patched":
            self.confirm_delete_patched()
        elif btn_id == "btn-del-terminal":
            self.confirm_delete_terminal()
        elif btn_id == "btn-del-assets":
            self.confirm_delete_assets()
        elif btn_id == "btn-backup-stock":
            self.backup_stock()
        elif btn_id == "btn-back":
            self.action_back()

    def confirm_delete_patched(self) -> None:
        def handle_confirm(yes: bool) -> None:
            if yes:
                count = storage_ops.delete_patched_apks()
                self.app.push_screen(MessageDialog("Cleaned", f"Deleted {count} patched APKs from storage."))

        self.app.push_screen(
            ConfirmDialog("Confirm Deletion", "Are you sure you want to delete all Patched APKs from Internal Storage?", yes_label="Delete", no_label="Cancel"),
            handle_confirm,
        )

    def confirm_delete_terminal(self) -> None:
        def handle_confirm(yes: bool) -> None:
            if yes:
                count = storage_ops.delete_workspace_apps()
                self.app.push_screen(MessageDialog("Cleaned", f"Deleted {count} apps from workspace apps/ directory."))

        self.app.push_screen(
            ConfirmDialog("Confirm Deletion", "Delete all stock/downloaded APKs in the workspace?", yes_label="Delete", no_label="Cancel"),
            handle_confirm,
        )

    def confirm_delete_assets(self) -> None:
        def handle_confirm(yes: bool) -> None:
            if yes:
                assets_mgr.delete_assets()
                self.app.push_screen(MessageDialog("Cleaned", "All downloaded CLI jars and Patches bundles deleted."))

        self.app.push_screen(
            ConfirmDialog("Confirm Deletion", "Delete all CLI binaries and patches bundles in assets/?", yes_label="Delete", no_label="Cancel"),
            handle_confirm,
        )

    def backup_stock(self) -> None:
        count, msg = storage_ops.backup_stock_apps()
        self.app.push_screen(MessageDialog("Backup Result", msg))

    def action_back(self) -> None:
        self.app.pop_screen()
