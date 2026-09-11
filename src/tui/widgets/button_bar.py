"""
Enhancify Responsive Button Bar
A Horizontal/Vertical hybrid container that never lets buttons overflow
beyond the visible display.

On wide terminals buttons sit side-by-side (classic Horizontal row).
On narrow terminals (Termux portrait phones, small windows) the bar
automatically stacks buttons vertically so every button stays fully
visible and reachable.

Width detection honours the user's request to use `tput cols`:
  1. `tput cols` subprocess (most accurate on Termux / real terminals)
  2. Textual app/console size (accurate inside run_test / pilots)
  3. shutil.get_terminal_size() fallback
  4. $COLUMNS env var / sane default
"""

from __future__ import annotations

import os
import shutil
import subprocess
from typing import List, Optional

from textual.app import ComposeResult
from textual.containers import Container
from textual.widgets import Button

# Minimum columns required to keep a horizontal row. Below this we stack.
# Accounts for card padding + borders. Termux phones are often 40-80 cols.
STACK_THRESHOLD_COLS = 78

# Per-button chrome: borders (2) + padding (2) + margin (1) + safety.
_BUTTON_CHROME = 7


def get_terminal_cols(default: int = 80) -> int:
    """Return current terminal width in columns.

    Tries `tput cols` first (per user request), then Textual-agnostic
    fallbacks. Never raises — always returns a positive int.
    """
    # 1. tput cols (requested explicitly; works on Termux + Linux)
    try:
        proc = subprocess.run(
            ["tput", "cols"],
            capture_output=True,
            text=True,
            timeout=2,
        )
        if proc.returncode == 0 and proc.stdout.strip().isdigit():
            cols = int(proc.stdout.strip())
            if cols > 0:
                return cols
    except Exception:
        pass

    # 2. shutil (reads $COLUMNS / ioctl)
    try:
        cols = shutil.get_terminal_size(fallback=(default, 24)).columns
        if cols and cols > 0:
            return int(cols)
    except Exception:
        pass

    # 3. $COLUMNS env
    try:
        cols = int(os.environ.get("COLUMNS", "") or 0)
        if cols > 0:
            return cols
    except Exception:
        pass

    return default


def estimate_row_width(labels: List[str]) -> int:
    """Estimate horizontal width needed for a row of buttons."""
    total = 0
    for label in labels:
        # Button label width + chrome. Wide chars (emoji) count ~2 cells;
        # len() undercounts them, so add a small per-button safety margin.
        total += len(label) + _BUTTON_CHROME + 2
    return total


class ButtonBar(Container):
    """Responsive button container — horizontal when it fits, stacked when not.

    Usage: replace `with Horizontal():` button rows with `with ButtonBar():`.
    The bar re-evaluates on mount and on every resize so rotating a phone or
    resizing a window instantly re-flows the buttons.
    """

    DEFAULT_CSS = """
    ButtonBar {
        layout: horizontal;
        height: auto;
        width: 1fr;
        margin-bottom: 1;
    }
    ButtonBar.stacked {
        layout: vertical;
    }
    ButtonBar.stacked Button {
        width: 1fr;
        min-width: 0;
        margin-right: 0;
    }
    ButtonBar Button {
        width: auto;
        min-width: 0;
    }
    /* Header badges are Labels — stack them too on narrow screens. */
    ButtonBar.stacked Label {
        width: auto;
        margin-bottom: 0;
    }
    """

    def __init__(
        self,
        *args,
        stack_threshold: int = STACK_THRESHOLD_COLS,
        **kwargs,
    ):
        super().__init__(*args, **kwargs)
        self.stack_threshold = stack_threshold
        self.add_class("btn-bar")

    def on_mount(self) -> None:
        self._apply_layout()
        # Re-check after children mount (sizes settle one tick later).
        self.set_timer(0.05, self._apply_layout)

    def on_resize(self, event) -> None:  # noqa: ANN001 - Textual event type
        self._apply_layout()

    def _available_cols(self) -> int:
        """Best-effort visible width for this bar.

        Priority: own laid-out width (correct inside narrow dialogs) >
        parent width > app/console width > `tput cols` fallback.
        """
        # Own size once laid out — most accurate (dialogs are narrower
        # than the full terminal, so app width alone would misjudge).
        try:
            w = int(self.size.width or 0)
            if w > 0:
                return w
        except Exception:
            pass
        try:
            parent = getattr(self, "parent", None)
            if parent is not None:
                w = int(getattr(getattr(parent, "size", None), "width", 0) or 0)
                if w > 0:
                    return w
        except Exception:
            pass
        # Live Textual sizes (correct inside pilots / tests).
        try:
            app = getattr(self, "app", None)
            if app is not None:
                try:
                    w = int(getattr(app.console.size, "width", 0) or 0)
                    if w > 0:
                        return w
                except Exception:
                    pass
                try:
                    w = int(getattr(app.size, "width", 0) or 0)
                    if w > 0:
                        return w
                except Exception:
                    pass
        except Exception:
            pass
        # Fall back to tput cols / terminal size.
        return get_terminal_cols()

    def _apply_layout(self) -> None:
        try:
            cols = self._available_cols()
            # Card/dialog chrome: container padding + borders.
            usable = max(10, cols - 2)
            labels: List[str] = []
            try:
                labels = [str(b.label) for b in self.query(Button)]
                if not labels:
                    # Header badge rows contain Labels instead of Buttons.
                    from textual.widgets import Label as _Label

                    labels = [str(b.content) for b in self.query(_Label)]
            except Exception:
                labels = []
            needed = estimate_row_width(labels) if labels else 0

            should_stack = (
                cols <= self.stack_threshold
                or (needed > 0 and needed > usable)
            )
            if should_stack:
                self.add_class("stacked")
            else:
                self.remove_class("stacked")
        except Exception:
            pass


__all__ = ["ButtonBar", "get_terminal_cols", "estimate_row_width", "STACK_THRESHOLD_COLS"]
