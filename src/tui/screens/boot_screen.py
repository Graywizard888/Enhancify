"""
Enhancify Rebranded Boot Screen
Replicates the classic bash boot sequence (modules/constants.sh):

    dialog --infobox "<ENHANCIFY_ART>
        Modifier     : Graywizard888
        Last Updated : <git date>
        Status       : <online status>
        Build Version: Enhanced V2.7.2
        Release      : <version>"

Shown on app start; auto-advances to the main menu (ESC to skip).
"""

from __future__ import annotations

import os
import subprocess
import threading
import time
from pathlib import Path
from typing import Optional

from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Vertical
from textual.screen import Screen
from textual.widgets import Label

from src.environment import env
from src.tui.widgets.gradient import GradientProgressBar

# Exact ASCII art from modules/constants.sh
ENHANCIFY_ART = (
    "   ____     __                 _ ___    \n"
    "  / __/__  / /  ___ ____  ____(_) _/_ __\n"
    " / _// _ \\/ _ \\/ _ `/ _ \\/ __/ / _/ // /\n"
    "/___/_//_/_//_/\\_,_/_//_/\\__/_/_/ \\_, / \n"
    "                                 /___/  "
)

MODIFIER = "Graywizard888"
MODIFIER_PHASE1 = "Graywizard"  # classic phase-1 infobox uses the short name
BUILD_VERSION = "Enhanced V2.7.2"

WORKSPACE = Path(__file__).resolve().parent.parent.parent.parent


def read_build_version() -> str:
    """Read VERSION from the workspace .info file (classic parity)."""
    try:
        info = WORKSPACE / ".info"
        if info.exists():
            for line in info.read_text(encoding="utf-8").splitlines():
                line = line.strip()
                if line.startswith("VERSION="):
                    return line.split("=", 1)[1].strip().strip("'\"")
    except Exception:
        pass
    return "Unknown"


def read_last_updated() -> str:
    """Last git commit date (classic parity), best-effort."""
    try:
        out = subprocess.run(
            [
                "git",
                "-C",
                str(WORKSPACE),
                "log",
                "-1",
                "--date=format:%b %d, %Y | %H:%M",
                "--pretty=format:%cd",
            ],
            capture_output=True,
            text=True,
            timeout=2,
        )
        if out.returncode == 0 and out.stdout.strip():
            return out.stdout.strip()
    except Exception:
        pass
    return "Unknown"


class BootScreen(Screen):
    """'Enhancify Rebranded' splash — auto-advances to the main menu.

    Two phases, exactly like the classic constants.sh infoboxes:

    phase 1 (first half):        phase 2 (second half):
    Modifier     : Graywizard    Modifier     : Graywizard888
    Last Updated : Checking...   Last Updated : <git date>
    Status       : Checking...   Status       : <online status>
                                  Build Version: Enhanced V2.7.2
                                  Release      : <version>
    """

    BINDINGS = [
        Binding("escape", "skip", "Skip", show=False),
    ]

    def __init__(self, duration: float | None = None, **kwargs):
        super().__init__(**kwargs)
        if duration is None:
            try:
                duration = float(os.environ.get("ENHANCIFY_BOOT_SECONDS", "3.0"))
            except ValueError:
                duration = 3.0
        self.boot_seconds = max(0.0, duration)
        self._done = False
        self._phase2 = False
        self._start_time = 0.0
        self._phase_split = 0.0
        self._boot_values: Optional[tuple] = None
        self._bar_timer = None
        self._phase_timer = None
        self._finish_timer = None

    # ------------------------------------------------------------- classic texts

    @staticmethod
    def _phase1_text() -> str:
        """Classic first infobox (constants.sh, verbatim)."""
        return (
            f"Modifier     : {MODIFIER_PHASE1}\n"
            "Last Updated : Checking...\n"
            "Status       : Checking..."
        )

    @staticmethod
    def _phase2_text(last_updated: str, net_status: str) -> str:
        """Classic second infobox (constants.sh, verbatim)."""
        return (
            f"Modifier     : {MODIFIER}\n"
            f"Last Updated : {last_updated}\n"
            f"Status       : {net_status}\n"
            f"Build Version: {BUILD_VERSION}\n"
            f"Release      : {read_build_version()}"
        )

    # --------------------------------------------------------------- lifecycle

    def compose(self) -> ComposeResult:
        # No blocking network check here — the classic shows 'Checking...'
        # while the checks run in the background.
        with Vertical(id="boot-screen"):
            yield Label(ENHANCIFY_ART, id="boot-art")
            yield Label("⚡ E N H A N C I F Y ⚡", id="boot-brand")
            yield Label("Enhancify Rebranded", id="boot-name")
            yield Label(self._phase1_text(), id="boot-info")
            yield GradientProgressBar(id="boot-bar", show_percentage=False)
            yield Label("Booting...   [ESC] to skip", id="boot-hint")

    def on_mount(self) -> None:
        self._start_time = time.time()
        self._phase_split = self.boot_seconds / 2
        try:
            self.query_one("#boot-bar", GradientProgressBar).set_fraction(0.0)
        except Exception:
            pass
        self._bar_timer = self.set_interval(0.05, self._tick)
        if self.boot_seconds > 0:
            self._phase_timer = self.set_timer(self._phase_split, self._maybe_enter_phase_2)
            self._finish_timer = self.set_timer(self.boot_seconds, self.action_skip)
        else:
            self.action_skip()
        # Background: git last-updated + network status (classic checks).
        threading.Thread(target=self._fetch_boot_info, daemon=True).start()

    def _tick(self) -> None:
        elapsed = time.time() - self._start_time
        frac = min(1.0, elapsed / self.boot_seconds) if self.boot_seconds > 0 else 1.0
        try:
            self.query_one("#boot-bar", GradientProgressBar).set_fraction(frac)
        except Exception:
            pass

    # --------------------------------------------------------- two-phase logic

    def _fetch_boot_info(self) -> None:
        last = read_last_updated()
        try:
            _, _, net_status = env.check_network()
        except Exception:
            net_status = "Unknown"

        def _apply() -> None:
            self._boot_values = (last, net_status)
            # Phase 2 may only start once the first half has elapsed
            # (classic: the second infobox is shown after `sleep 3`).
            if (
                not self._done
                and not self._phase2
                and time.time() - self._start_time >= self._phase_split
            ):
                self._enter_phase_2()

        try:
            self.app.call_from_thread(_apply)
        except Exception:
            try:
                _apply()
            except Exception:
                pass

    def _maybe_enter_phase_2(self) -> None:
        if self._boot_values is not None:
            self._enter_phase_2()

    def _enter_phase_2(self) -> None:
        if self._phase2 or self._done or self._boot_values is None:
            return
        self._phase2 = True
        last, net_status = self._boot_values
        try:
            self.query_one("#boot-info", Label).update(
                self._phase2_text(last, net_status)
            )
        except Exception:
            pass

    # ------------------------------------------------------------------- finish

    def action_skip(self) -> None:
        self._finish()

    def _finish(self) -> None:
        if self._done:
            return
        self._done = True
        for t in (self._bar_timer, self._phase_timer, self._finish_timer):
            try:
                if t is not None:
                    t.cancel()
            except Exception:
                pass
        try:
            self.app.on_boot_complete()
        except Exception:
            pass
