"""
Gradient progress bar and spinner widgets for download / parse UIs.
"""

from __future__ import annotations

from typing import List, Optional, Tuple

from rich.style import Style
from rich.text import Text
from textual.reactive import reactive
from textual.widget import Widget


def _hex_to_rgb(h: str) -> Tuple[int, int, int]:
    h = h.lstrip("#")
    if len(h) == 3:
        h = "".join(c * 2 for c in h)
    return int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)


def _rgb_to_hex(r: int, g: int, b: int) -> str:
    return f"#{r:02x}{g:02x}{b:02x}"


def lerp_color(c1: str, c2: str, t: float) -> str:
    """Linear interpolate two hex colors. t in [0, 1]."""
    t = max(0.0, min(1.0, t))
    r1, g1, b1 = _hex_to_rgb(c1)
    r2, g2, b2 = _hex_to_rgb(c2)
    return _rgb_to_hex(
        int(r1 + (r2 - r1) * t),
        int(g1 + (g2 - g1) * t),
        int(b1 + (b2 - b1) * t),
    )


def multi_lerp(stops: List[str], t: float) -> str:
    """Interpolate across multiple color stops."""
    if not stops:
        return "#00ff7f"
    if len(stops) == 1 or t <= 0:
        return stops[0]
    if t >= 1:
        return stops[-1]
    seg = 1.0 / (len(stops) - 1)
    idx = min(int(t / seg), len(stops) - 2)
    local = (t - idx * seg) / seg
    return lerp_color(stops[idx], stops[idx + 1], local)


# Default cyber-green gradient (theme can override via widget props)
DEFAULT_GRADIENT = ["#00ff7f", "#00e5ff", "#7c4dff"]
DEFAULT_TRACK = "#1a2332"
DEFAULT_SPINNER_STOPS = ["#00ff7f", "#00e5ff", "#ff007f", "#7c4dff", "#00ff7f"]


class GradientProgressBar(Widget):
    """Horizontal progress bar with a multi-stop color gradient fill."""

    DEFAULT_CSS = """
    GradientProgressBar {
        height: 1;
        width: 1fr;
        margin: 1 0;
    }
    """

    progress = reactive(0.0)  # 0.0 .. 1.0
    show_percentage = reactive(True)

    def __init__(
        self,
        *,
        gradient: Optional[List[str]] = None,
        track_color: str = DEFAULT_TRACK,
        show_percentage: bool = True,
        id: Optional[str] = None,
        classes: Optional[str] = None,
    ):
        super().__init__(id=id, classes=classes)
        self.gradient = list(gradient or DEFAULT_GRADIENT)
        self.track_color = track_color
        self.show_percentage = show_percentage

    def set_progress(self, current: int, total: int) -> None:
        if total <= 0:
            self.progress = 0.0
        else:
            self.progress = max(0.0, min(1.0, current / total))

    def set_fraction(self, fraction: float) -> None:
        self.progress = max(0.0, min(1.0, fraction))

    def render(self) -> Text:
        width = max(10, self.size.width or 40)
        pct_w = 5 if self.show_percentage else 0
        bar_w = max(4, width - pct_w - (1 if pct_w else 0))
        filled = int(round(self.progress * bar_w))
        filled = max(0, min(bar_w, filled))

        out = Text()
        for i in range(bar_w):
            if i < filled:
                t = i / max(1, bar_w - 1)
                color = multi_lerp(self.gradient, t)
                out.append("█", style=Style(color=color, bold=True))
            else:
                out.append("░", style=Style(color=self.track_color))

        if self.show_percentage:
            pct = int(round(self.progress * 100))
            out.append(f" {pct:3d}%", style=Style(color="#c9d1d9", bold=True))
        return out


class GradientSpinner(Widget):
    """Animated braille/block spinner with cycling gradient colors."""

    DEFAULT_CSS = """
    GradientSpinner {
        height: 1;
        width: 1fr;
        content-align: center middle;
        margin: 1 0;
    }
    """

    FRAME_CHARS = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    BAR_CHARS = ["▏", "▎", "▍", "▌", "▋", "▊", "▉", "█", "▉", "▊", "▋", "▌", "▍", "▎"]

    _frame = reactive(0)
    label = reactive("")

    def __init__(
        self,
        label: str = "",
        *,
        gradient: Optional[List[str]] = None,
        id: Optional[str] = None,
        classes: Optional[str] = None,
    ):
        super().__init__(id=id, classes=classes)
        self.label = label
        self.gradient = list(gradient or DEFAULT_SPINNER_STOPS)
        self._timer = None

    def on_mount(self) -> None:
        self._timer = self.set_interval(0.08, self._tick)

    def _tick(self) -> None:
        self._frame = (self._frame + 1) % (len(self.FRAME_CHARS) * 4)

    def set_label(self, text: str) -> None:
        self.label = text

    def render(self) -> Text:
        # Build a short sweeping gradient bar + spinner glyph
        n = 12
        phase = self._frame
        out = Text()
        spin = self.FRAME_CHARS[phase % len(self.FRAME_CHARS)]
        spin_color = multi_lerp(self.gradient, (phase % 20) / 20.0)
        out.append(f"{spin} ", style=Style(color=spin_color, bold=True))

        for i in range(n):
            # Moving highlight wave
            wave = ((i + phase) % n) / max(1, n - 1)
            color = multi_lerp(self.gradient, wave)
            ch = self.BAR_CHARS[(i + phase) % len(self.BAR_CHARS)]
            out.append(ch, style=Style(color=color, bold=True))

        if self.label:
            out.append("  ")
            out.append(self.label, style=Style(color="#c9d1d9"))
        return out
