"""
Enhancify Fetch Dependency Screen
Mirrors bash Fetch_Dependency menu: choose GmsCore or PotHelper.
"""

from textual.app import ComposeResult
from textual.containers import ScrollableContainer, Vertical
from textual.screen import Screen
from textual.widgets import Button, Footer, Label

from src.environment import env
from src.tui.widgets.header import CyberHeader


class DependencySelectScreen(Screen):
    """Top-level dependency picker (GmsCore / PotHelper)."""

    BINDINGS = [
        ("g", "gmscore", "GmsCore"),
        ("h", "pothelper", "PotHelper"),
        ("b", "back", "Back"),
        ("escape", "back", "Back"),
    ]

    def compose(self) -> ComposeResult:
        has_root, has_rish, mode_label = env.check_privileges()
        _, _, net_status = env.check_network()

        yield CyberHeader(mode_label=mode_label, online_status=net_status)

        with ScrollableContainer(classes="container-box"):
            with Vertical(classes="card"):
                yield Label("🔌 Fetch Dependency", classes="card-title")
                yield Label(
                    "Select a dependency to fetch (matches classic Fetch Dependency menu):",
                    classes="card-desc",
                )

                with Vertical():
                    yield Button(
                        "📱 Fetch GmsCore (MicroG)  [G]",
                        id="btn-fetch-gmscore",
                        classes="btn-primary",
                    )
                    yield Button(
                        "🛠️  Fetch PotHelper  [H]",
                        id="btn-fetch-pothelper",
                    )
                    yield Button("🔙 Back [B]", id="btn-back", classes="btn-secondary")

        yield Footer()

    def on_button_pressed(self, event: Button.Pressed) -> None:
        btn_id = event.button.id
        if btn_id == "btn-fetch-gmscore":
            self.action_gmscore()
        elif btn_id == "btn-fetch-pothelper":
            self.action_pothelper()
        elif btn_id == "btn-back":
            self.action_back()

    def action_gmscore(self) -> None:
        self.app.push_screen("gmscore_screen")

    def action_pothelper(self) -> None:
        self.app.push_screen("pothelper_screen")

    def action_back(self) -> None:
        self.app.pop_screen()
