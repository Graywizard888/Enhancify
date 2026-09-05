"""
Enhancify Theme Selector Screen
Allows users to browse and switch between 8 handcrafted color themes with live preview.
"""

from rich.text import Text
from textual.app import ComposeResult
from textual.containers import Container, Horizontal, ScrollableContainer, Vertical
from textual.screen import Screen
from textual.widgets import Button, Footer, Label, ListItem, ListView

from src.environment import env
from src.theme import THEMES, get_current_theme, set_current_theme
from src.tui.widgets.dialogs import MessageDialog
from src.tui.widgets.header import CyberHeader


class ThemeSelectScreen(Screen):
    """Screen for selecting and previewing UI color themes."""

    BINDINGS = [
        ("b", "action_back", "Back"),
        ("escape", "action_back", "Back"),
    ]

    def compose(self) -> ComposeResult:
        has_root, has_rish, mode_label = env.check_privileges()
        _, _, net_status = env.check_network()

        cur_theme = get_current_theme()

        yield CyberHeader(mode_label=mode_label, online_status=net_status)

        with ScrollableContainer(classes="container-box"):
            with Vertical(classes="card"):
                yield Label("🎨 Personalize Enhancify Theme", classes="card-title")
                yield Label(f"Current Theme: [bold {cur_theme.primary_color}]{cur_theme.name}[/]", id="active-theme-label", classes="card-desc")

                with Horizontal():
                    yield Button("🔙 Back to Settings [B]", id="btn-back", classes="btn-secondary")

                yield ListView(id="themes-list")

        yield Footer()

    def on_mount(self) -> None:
        self.populate_themes()

    def populate_themes(self) -> None:
        t_list = self.query_one("#themes-list", ListView)
        t_list.clear()

        cur_theme = get_current_theme()

        for idx, th in enumerate(THEMES):
            is_active = (th.id == cur_theme.id)

            txt = Text()
            if is_active:
                txt.append("● ", style=f"bold {th.primary_color}")
            else:
                txt.append("○ ", style="dim")

            # Color palette swatches
            for color in th.preview_palette:
                txt.append("■ ", style=f"bold {color}")

            txt.append(f" {th.name:<22}", style=f"bold {th.primary_color}" if is_active else "bold #ffffff")
            txt.append(f" — {th.description}", style="#8b949e")

            item = ListItem(Label(txt), id=f"theme-{th.id}")
            t_list.append(item)

    def on_list_view_selected(self, event: ListView.Selected) -> None:
        item_id = event.item.id or ""
        if item_id.startswith("theme-"):
            theme_id = item_id[6:]
            set_current_theme(theme_id)
            # Switch theme live on app
            if hasattr(self.app, "apply_theme"):
                self.app.apply_theme(theme_id)

            cur_theme = get_current_theme()
            try:
                self.query_one("#active-theme-label", Label).update(
                    f"Current Theme: [bold {cur_theme.primary_color}]{cur_theme.name}[/]"
                )
            except Exception:
                pass

            self.populate_themes()
            self.app.push_screen(
                MessageDialog("Theme Applied", f"✓ Switched theme to: {cur_theme.name}")
            )

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "btn-back":
            self.action_back()

    def action_back(self) -> None:
        self.app.pop_screen()
