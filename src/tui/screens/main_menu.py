"""
Enhancify Main Menu / Dashboard Screen
Provides navigation to all primary Enhancify features with cybernetic styling and hotkeys.
"""

from rich.text import Text
from textual.app import ComposeResult
from textual.containers import Container, Grid, Horizontal, ScrollableContainer, Vertical
from textual.screen import Screen
from textual.widgets import Button, Footer, Label, Static

from src.config import config
from src.environment import env
from src.tui.widgets.header import CyberHeader


class MainMenuScreen(Screen):
    """Main menu dashboard for Enhancify."""

    BINDINGS = [
        ("p", "patch_app", "Patch App"),
        ("s", "change_source", "Change Source"),
        ("t", "themes", "Themes"),
        ("b", "bundle_patcher", "Bundle Patcher"),
        ("c", "settings", "Settings"),
        ("g", "fetch_dependency", "Fetch Dependency"),
        ("d", "storage", "Storage"),
        ("i", "specs", "Specs"),
        ("q", "quit", "Exit"),
    ]

    def compose(self) -> ComposeResult:
        has_root, has_rish, mode_label = env.check_privileges()
        _, _, net_status = env.check_network()

        yield CyberHeader(mode_label=mode_label, online_status=net_status)

        with ScrollableContainer(classes="container-box"):
            with Vertical(classes="card"):
                yield Label("🔥 Quick Actions", classes="card-title")
                yield Label("Select an action below or use keyboard shortcuts:", classes="card-desc")

                with Vertical():
                    yield Button("🚀 Patch App  [P]", id="btn-patch", classes="btn-primary")
                    yield Button("📝 Change Source  [S]", id="btn-source")
                    yield Button("🎨 UI Themes  [T]", id="btn-themes")
                    yield Button("📦 Bundle Patcher (Experimental)  [B]", id="btn-bundle")
                    yield Button("⚙️  Configure & Settings  [C]", id="btn-settings")
                    yield Button("🔌 Fetch Dependency  [G]", id="btn-dependency")
                    yield Button("🗑️  Storage Manager  [D]", id="btn-storage")
                    yield Button("📋 Specs & Changelog  [I]", id="btn-specs")

                    if has_root:
                        yield Button("🔒 Unmount Patched App", id="btn-unmount", classes="btn-danger")

                    yield Button("🚪 Exit Enhancify  [Q]", id="btn-exit", classes="btn-danger")

        yield Footer()

    def on_button_pressed(self, event: Button.Pressed) -> None:
        btn_id = event.button.id
        if btn_id == "btn-patch":
            self.action_patch_app()
        elif btn_id == "btn-source":
            self.action_change_source()
        elif btn_id == "btn-themes":
            self.action_themes()
        elif btn_id == "btn-bundle":
            self.action_bundle_patcher()
        elif btn_id == "btn-settings":
            self.action_settings()
        elif btn_id == "btn-dependency":
            self.action_fetch_dependency()
        elif btn_id == "btn-storage":
            self.action_storage()
        elif btn_id == "btn-specs":
            self.action_specs()
        elif btn_id == "btn-unmount":
            self.app.push_screen("unmount_screen")
        elif btn_id == "btn-exit":
            self.action_quit()

    def action_patch_app(self) -> None:
        from src.tui.screens.source_select import SourceSelectScreen
        self.app.push_screen(SourceSelectScreen(is_patch_flow=True))

    def action_change_source(self) -> None:
        from src.tui.screens.source_select import SourceSelectScreen
        self.app.push_screen(SourceSelectScreen(is_patch_flow=False))

    def action_themes(self) -> None:
        self.app.push_screen("theme_select_screen")

    def action_bundle_patcher(self) -> None:
        self.app.push_screen("bundle_patcher_screen")

    def action_settings(self) -> None:
        self.app.push_screen("settings_screen")

    def action_fetch_dependency(self) -> None:
        self.app.push_screen("dependency_select_screen")

    def action_storage(self) -> None:
        self.app.push_screen("storage_mgr_screen")

    def action_specs(self) -> None:
        self.app.push_screen("specs_screen")

    def action_quit(self) -> None:
        self.app.exit()
