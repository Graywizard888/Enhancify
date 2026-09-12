"""
Enhancify Cyber Status Bar
Replicates the classic bash main-menu status block:

    Initiated Mode : <PRIVILEGE_STATUS>  ⚙️
    Status         : <ONLINE_STATUS>     🌐
    Arch           : <ARCH>              🤖

    Navigate with [↑] [↓] [←] [→]

Rendered as fixed stacked lines (like the classic infobox) so it always
occupies the same small height regardless of terminal width — the main
menu must stay usable on an 80x24 Termux session.
"""

from __future__ import annotations

from textual.app import ComposeResult
from textual.containers import Vertical
from textual.widget import Widget
from textual.widgets import Label

from src.environment import env


class CyberStatusBar(Widget):
    """Top status strip: classic Initiated Mode / Status / Arch + nav hint."""

    DEFAULT_CSS = """
    CyberStatusBar {
        /* not docked: the main menu composes it right below the docked
           CyberHeader, so both stay visible (two dock:top widgets
           overlap and squash each other in Textual 8.x) */
        height: auto;
        background: #0b1015;
        border-bottom: solid #30363d;
        padding: 0 1;
    }
    #status-bar-rows {
        layout: vertical;
        height: auto;
        margin-bottom: 0;
    }
    .status-line {
        height: auto;
    }
    .status-nav-hint {
        color: #8b949e;
        margin-top: 1;
        text-style: italic;
        height: auto;
    }
    """

    def __init__(
        self,
        mode_label: str = "Non-privilege Mode",
        online_status: str = "Online",
        arch: str = "",
        nav_hint: bool = True,
        **kwargs,
    ):
        super().__init__(**kwargs)
        self.mode_label = mode_label
        self.online_status = online_status
        self.arch = arch or env.get_arch()
        self.nav_hint = nav_hint

    KEY_WIDTH = 14  # len("Initiated Mode") — pads the key column

    def _rows(self):
        """Classic-aligned (key, icon, value, color, classes) tuples."""
        yield ("Initiated Mode", "⚙️", self.mode_label, "#00ff7f", "status-line line-mode")
        yield ("Status", "🌐", self.online_status, "#00e5ff", "status-line line-status")
        yield ("Arch", "🤖", self.arch, "#ffd700", "status-line line-arch")

    def compose(self) -> ComposeResult:
        with Vertical(id="status-bar-rows"):
            for key, icon, value, color, classes in self._rows():
                # Emojis render as ~2 cells; the classic block pads the key
                # column so the colons line up.
                line = f"{icon} {key.ljust(self.KEY_WIDTH)} : {value}"
                yield Label(
                    f"[{color}]{line}[/]",
                    classes=classes,
                )
        if self.nav_hint:
            yield Label(
                "Navigate with [↑] [↓] [←] [→]   ·   Select with [ENTER / SPACE]",
                classes="status-nav-hint",
            )

    def update_status(self, mode_label: str, online_status: str, arch: str = "") -> None:
        """Refresh the status lines dynamically."""
        self.mode_label = mode_label
        self.online_status = online_status
        if arch:
            self.arch = arch
        self.refresh(recompose=True)
