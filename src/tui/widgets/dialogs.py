"""
Enhancify Reusable Modal Dialog Widgets
Provides Confirm, Message, Input, Progress, Download, and Parse modals
with cybernetic styling, gradient bars/spinners, and cancel support.
"""

from __future__ import annotations

import threading
from typing import Any, Callable, List, Optional, Tuple

from rich.text import Text
from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical
from textual.screen import ModalScreen
from textual.widgets import Button, Input, Label, LoadingIndicator, Static

from src.tui.widgets.gradient import GradientProgressBar, GradientSpinner
from src.utils import format_size


def _ui_call(screen: ModalScreen, fn: Callable[[], None]) -> None:
    """Run fn on the Textual app thread.

    Textual ≥0.4x / 8.x raises if call_from_thread is used from the app thread
    itself (e.g. pilot tests, or UI-side progress ticks). Detect that and call
    directly instead.
    """
    app = getattr(screen, "app", None)
    if app is None:
        try:
            fn()
        except Exception:
            pass
        return
    try:
        # _thread_id is set by Textual App; compare to current thread
        app_tid = getattr(app, "_thread_id", None)
        if app_tid is None or app_tid == threading.get_ident():
            fn()
        else:
            app.call_from_thread(fn)
    except RuntimeError:
        # Fallback if Textual still rejects call_from_thread
        try:
            fn()
        except Exception:
            pass
    except Exception:
        try:
            fn()
        except Exception:
            pass


class MessageDialog(ModalScreen[None]):
    """Modal dialog displaying a message with an OK button."""

    def __init__(self, title: str, message: str, **kwargs):
        super().__init__(**kwargs)
        self.dialog_title = title
        self.message = message

    def compose(self) -> ComposeResult:
        with Vertical(classes="dialog-box"):
            yield Label(self.dialog_title, classes="dialog-title")
            yield Label(self.message, classes="dialog-message")
            with Horizontal(classes="dialog-buttons"):
                yield Button("OK", id="btn-ok", classes="btn-primary")

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "btn-ok":
            self.dismiss(None)


class ConfirmDialog(ModalScreen[bool]):
    """Modal dialog asking for user confirmation (Yes / No)."""

    def __init__(
        self,
        title: str,
        message: str,
        yes_label: str = "Yes",
        no_label: str = "No",
        **kwargs,
    ):
        super().__init__(**kwargs)
        self.dialog_title = title
        self.message = message
        self.yes_label = yes_label
        self.no_label = no_label

    def compose(self) -> ComposeResult:
        with Vertical(classes="dialog-box"):
            yield Label(self.dialog_title, classes="dialog-title")
            yield Label(self.message, classes="dialog-message")
            with Horizontal(classes="dialog-buttons"):
                yield Button(self.yes_label, id="btn-yes", classes="btn-primary")
                yield Button(self.no_label, id="btn-no", classes="btn-secondary")

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "btn-yes":
            self.dismiss(True)
        else:
            self.dismiss(False)


class InputDialog(ModalScreen[Optional[str]]):
    """Modal dialog with a single-line text input field."""

    def __init__(
        self,
        title: str,
        prompt: str,
        initial_value: str = "",
        placeholder: str = "",
        password: bool = False,
        **kwargs,
    ):
        super().__init__(**kwargs)
        self.dialog_title = title
        self.prompt = prompt
        self.initial_value = initial_value
        self.placeholder = placeholder
        self.password = password

    def compose(self) -> ComposeResult:
        with Vertical(classes="dialog-box"):
            yield Label(self.dialog_title, classes="dialog-title")
            yield Label(self.prompt, classes="dialog-message")
            yield Input(
                value=self.initial_value,
                placeholder=self.placeholder,
                password=self.password,
                id="dialog-input",
            )
            with Horizontal(classes="dialog-buttons"):
                yield Button("Submit", id="btn-submit", classes="btn-primary")
                yield Button("Cancel", id="btn-cancel", classes="btn-secondary")

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "btn-submit":
            inp = self.query_one("#dialog-input", Input)
            self.dismiss(inp.value)
        else:
            self.dismiss(None)


class ProgressModal(ModalScreen[None]):
    """Modal displaying an active operation with status message and spinner."""

    def __init__(self, title: str, message: str = "Please wait...", **kwargs):
        super().__init__(**kwargs)
        self.dialog_title = title
        self.message = message

    def compose(self) -> ComposeResult:
        with Vertical(classes="dialog-box"):
            yield Label(self.dialog_title, classes="dialog-title")
            yield Label(self.message, id="progress-msg", classes="dialog-message")
            yield LoadingIndicator()

    def update_message(self, new_msg: str) -> None:
        """Update progress message safely across threads."""

        def _apply() -> None:
            try:
                self.query_one("#progress-msg", Label).update(new_msg)
            except Exception:
                pass

        _ui_call(self, _apply)

    def safe_dismiss(self) -> None:
        """Safely dismiss this modal screen."""
        try:
            if self.is_mounted:
                self.dismiss(None)
            elif self.app and self in self.app.screen_stack:
                self.app.pop_screen()
        except Exception:
            pass


# ---------------------------------------------------------------------------
# Download progress modal — original bash gauge texts + gradient bar + cancel
# ---------------------------------------------------------------------------

def _size_line(size: int) -> str:
    if size <= 0:
        return "Unavailable"
    return format_size(size)


class DownloadProgressModal(ModalScreen[Optional[str]]):
    """
    Download UI matching classic dialog --gauge texts.

    Result: None on success/auto-dismiss, "cancelled" if user cancelled.
    """

    BINDINGS = [
        Binding("escape", "cancel", "Cancel", show=False),
    ]

    def __init__(
        self,
        title: str = "| Downloading Assets |",
        body: str = "Downloading...",
        *,
        total_size: int = 0,
        allow_cancel: bool = True,
        **kwargs,
    ):
        super().__init__(**kwargs)
        self.dialog_title = title
        self._body = body
        self.total_size = total_size
        self.allow_cancel = allow_cancel
        self.cancel_event = threading.Event()
        self._cancelled = False
        self._current = 0
        self._detail = ""

    # ----- factory helpers (bash-parity copy) -----

    @classmethod
    def for_asset_file(cls, label: str, size: int = 0) -> "DownloadProgressModal":
        """Sequential asset download (CLI / Patches) — bash downloadSequentialWget."""
        body = (
            f"File    : {label}\n"
            f"Size    : {_size_line(size)}\n"
            f"\n"
            f"Downloading..."
        )
        return cls(title="| Downloading Assets |", body=body, total_size=size)

    @classmethod
    def for_assets_batch(
        cls,
        file_count: int,
        total_size: int = 0,
        accelerated: bool = True,
    ) -> "DownloadProgressModal":
        """Multi-file assets header — bash downloadBatchAria2c mixedgauge."""
        total_disp = format_size(total_size) if total_size > 0 else "unknown"
        accel = " | Accelerated: 8 parts each" if accelerated else ""
        body = (
            f"\n"
            f"Downloading {file_count} file(s) simultaneously\n"
            f"Total: {total_disp}{accel}\n"
        )
        return cls(title="| Downloading Assets |", body=body, total_size=total_size)

    @classmethod
    def for_app_scrape(cls, app_name: str, version: str) -> "DownloadProgressModal":
        """APKMirror link scrape — bash fetchDownloadURL gauge."""
        body = (
            f"App    : {app_name}\n"
            f"Version: {version}\n"
            f"\n"
            f"Scraping Download Link..."
        )
        return cls(title="| Downloading App |", body=body, total_size=0, allow_cancel=True)

    @classmethod
    def for_app_file(
        cls, app_name: str, version: str, ext: str, size: int = 0
    ) -> "DownloadProgressModal":
        """App APK/APKM download — bash downloadAppFile gauge."""
        body = (
            f"File: {app_name}-{version}.{ext}\n"
            f"Size: {_size_line(size)}\n"
            f"\n"
            f"Downloading..."
        )
        return cls(title="| Downloading App |", body=body, total_size=size)

    @classmethod
    def for_dependency(
        cls, label: str, size: int = 0, title: str = "| Fetch Dependency |"
    ) -> "DownloadProgressModal":
        """GmsCore / PotHelper download — same sequential gauge style."""
        body = (
            f"File    : {label}\n"
            f"Size    : {_size_line(size)}\n"
            f"\n"
            f"Downloading..."
        )
        return cls(title=title, body=body, total_size=size)

    def compose(self) -> ComposeResult:
        with Vertical(classes="dialog-box download-dialog"):
            yield Label(self.dialog_title, classes="dialog-title")
            yield Label(self._body, id="dl-body", classes="dialog-message download-meta")
            yield GradientProgressBar(id="dl-bar")
            yield Label("", id="dl-detail", classes="download-detail")
            if self.allow_cancel:
                with Horizontal(classes="dialog-buttons download-cancel-row"):
                    yield Button("Cancel", id="btn-cancel", classes="btn-danger")

    def on_mount(self) -> None:
        try:
            bar = self.query_one("#dl-bar", GradientProgressBar)
            bar.set_fraction(0.0)
        except Exception:
            pass

    def set_body(self, body: str, total_size: int = -1) -> None:
        """Replace body text (e.g. scrape → download). Thread-safe."""
        self._body = body
        if total_size >= 0:
            self.total_size = total_size

        def _apply() -> None:
            try:
                self.query_one("#dl-body", Label).update(body)
            except Exception:
                pass

        _ui_call(self, _apply)

    def switch_to_app_download(
        self, app_name: str, version: str, ext: str, size: int
    ) -> None:
        body = (
            f"File: {app_name}-{version}.{ext}\n"
            f"Size: {_size_line(size)}\n"
            f"\n"
            f"Downloading..."
        )
        self.set_body(body, total_size=size)

    def switch_to_asset_file(self, label: str, size: int) -> None:
        body = (
            f"File    : {label}\n"
            f"Size    : {_size_line(size)}\n"
            f"\n"
            f"Downloading..."
        )
        self.set_body(body, total_size=size)

    def on_progress(self, current: int, total: int, pct: str = "") -> None:
        """Progress callback compatible with download_file(..., progress_callback=)."""
        self._current = current
        if total > 0:
            self.total_size = total
        detail = ""
        if self.total_size > 0:
            detail = f"{format_size(current)} / {format_size(self.total_size)}"
            if pct:
                detail = f"{detail}  ·  {pct}"
        elif pct:
            detail = pct
        self._detail = detail

        def _apply() -> None:
            try:
                bar = self.query_one("#dl-bar", GradientProgressBar)
                if self.total_size > 0:
                    bar.set_progress(current, self.total_size)
                elif pct.endswith("%"):
                    try:
                        bar.set_fraction(int(pct.rstrip("%")) / 100.0)
                    except ValueError:
                        pass
                self.query_one("#dl-detail", Label).update(detail)
            except Exception:
                pass

        _ui_call(self, _apply)

    def update_message(self, new_msg: str) -> None:
        """Compatibility shim used by older callers — appends as detail line."""

        def _apply() -> None:
            try:
                self.query_one("#dl-detail", Label).update(new_msg)
            except Exception:
                pass

        _ui_call(self, _apply)

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "btn-cancel":
            self.action_cancel()

    def action_cancel(self) -> None:
        if self._cancelled or not self.allow_cancel:
            return
        self._cancelled = True
        self.cancel_event.set()

        def _apply():
            try:
                btn = self.query_one("#btn-cancel", Button)
                btn.disabled = True
                btn.label = "Cancelling..."
                self.query_one("#dl-detail", Label).update("Cancelling download...")
            except Exception:
                pass

        try:
            _apply()
        except Exception:
            pass

    @property
    def was_cancelled(self) -> bool:
        return self._cancelled or self.cancel_event.is_set()

    def safe_dismiss(self, result: Optional[str] = None) -> None:
        try:
            if self.is_mounted:
                if result is None and self.was_cancelled:
                    result = "cancelled"
                self.dismiss(result)
            elif self.app and self in self.app.screen_stack:
                self.app.pop_screen()
        except Exception:
            pass


# ---------------------------------------------------------------------------
# Parse / generate patches list — bash parseJsonFromCLI gauge + gradient spinner
# ---------------------------------------------------------------------------

class ParseProgressModal(ModalScreen[Optional[str]]):
    """
    Shown while generating patches list from CLI output / API.

    Original bash text (modules/json/parse.sh):
      Please Wait!!
      Parsing JSON file for $SOURCE patches from CLI Output.
      This might take some time.
    """

    BINDINGS = [
        Binding("escape", "cancel", "Cancel", show=False),
    ]

    def __init__(
        self,
        source_name: str = "",
        *,
        from_cli: bool = True,
        allow_cancel: bool = True,
        **kwargs,
    ):
        super().__init__(**kwargs)
        self.source_name = source_name or "source"
        self.from_cli = from_cli
        self.allow_cancel = allow_cancel
        self.cancel_event = threading.Event()
        self._cancelled = False
        if from_cli:
            # Exact bash wording
            self._body = (
                f"Please Wait!!\n"
                f"Parsing JSON file for {self.source_name} patches from CLI Output.\n"
                f"This might take some time."
            )
            self.dialog_title = "| Parsing Patches |"
        else:
            self._body = (
                f"Please Wait!!\n"
                f"Parsing JSON file for {self.source_name} patches from API."
            )
            self.dialog_title = "| Parsing Patches |"

    def compose(self) -> ComposeResult:
        with Vertical(classes="dialog-box download-dialog"):
            yield Label(self.dialog_title, classes="dialog-title")
            yield Label(self._body, id="parse-body", classes="dialog-message download-meta")
            # Both widgets exist; visibility toggled by phase (API=spinner, CLI=bar)
            yield GradientSpinner(id="parse-spinner", label="Working...")
            yield GradientProgressBar(id="parse-bar")
            yield Label("", id="parse-detail", classes="download-detail")
            if self.allow_cancel:
                with Horizontal(classes="dialog-buttons download-cancel-row"):
                    yield Button("Cancel", id="btn-cancel", classes="btn-danger")

    def on_mount(self) -> None:
        # Apply initial phase visibility (API → spinner only, CLI → bar only)
        self._apply_phase_visibility(self.from_cli)

    def set_phase_cli(self) -> None:
        """CLI list-patches parse — progress bar only (no spinner)."""
        self.from_cli = True
        body = (
            f"Please Wait!!\n"
            f"Parsing JSON file for {self.source_name} patches from CLI Output.\n"
            f"This might take some time."
        )
        self._update_body(body)
        self._apply_phase_visibility(from_cli=True)

    def set_phase_api(self) -> None:
        """API JSON parse — gradient spinner only (no progress bar)."""
        self.from_cli = False
        body = (
            f"Please Wait!!\n"
            f"Parsing JSON file for {self.source_name} patches from API."
        )
        self._update_body(body)
        self._apply_phase_visibility(from_cli=False)

    def _apply_phase_visibility(self, from_cli: bool) -> None:
        """API → spinner only; CLI → progress bar only."""

        def _apply() -> None:
            try:
                spin = self.query_one("#parse-spinner", GradientSpinner)
                bar = self.query_one("#parse-bar", GradientProgressBar)
                if from_cli:
                    # CLI: progress bar only
                    spin.display = False
                    bar.display = True
                    bar.set_fraction(0.0)
                    spin.set_label("")
                else:
                    # API: spinner only
                    spin.display = True
                    bar.display = False
                    spin.set_label("Working...")
                    bar.set_fraction(0.0)
            except Exception:
                pass

        _ui_call(self, _apply)

    def _update_body(self, body: str) -> None:
        def _apply() -> None:
            try:
                self.query_one("#parse-body", Label).update(body)
            except Exception:
                pass

        _ui_call(self, _apply)

    def on_parse_progress(self, current: int, total: int) -> None:
        """CLI only — update gradient progress bar while walking list-patches blocks."""

        def _apply() -> None:
            try:
                # Ensure CLI mode visuals (bar only)
                spin = self.query_one("#parse-spinner", GradientSpinner)
                bar = self.query_one("#parse-bar", GradientProgressBar)
                spin.display = False
                bar.display = True
                if total > 0:
                    bar.set_progress(current, total)
                    pct = int(current * 100 / total)
                    self.query_one("#parse-detail", Label).update(
                        f"Building patches list...  {current}/{total}  ({pct}%)"
                    )
                else:
                    self.query_one("#parse-detail", Label).update(
                        "Building patches list from CLI output..."
                    )
            except Exception:
                pass

        _ui_call(self, _apply)

    def update_message(self, new_msg: str) -> None:
        def _apply() -> None:
            try:
                self.query_one("#parse-detail", Label).update(new_msg)
                # Only touch spinner label in API mode
                if not self.from_cli:
                    spin = self.query_one("#parse-spinner", GradientSpinner)
                    if spin.display:
                        spin.set_label(new_msg[:40] if new_msg else "Working...")
            except Exception:
                pass

        _ui_call(self, _apply)

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "btn-cancel":
            self.action_cancel()

    def action_cancel(self) -> None:
        if self._cancelled or not self.allow_cancel:
            return
        self._cancelled = True
        self.cancel_event.set()

        def _apply():
            try:
                btn = self.query_one("#btn-cancel", Button)
                btn.disabled = True
                btn.label = "Cancelling..."
                self.query_one("#parse-detail", Label).update("Cancelling...")
            except Exception:
                pass

        try:
            _apply()
        except Exception:
            pass

    @property
    def was_cancelled(self) -> bool:
        return self._cancelled or self.cancel_event.is_set()

    def safe_dismiss(self, result: Optional[str] = None) -> None:
        try:
            if self.is_mounted:
                if result is None and self.was_cancelled:
                    result = "cancelled"
                self.dismiss(result)
            elif self.app and self in self.app.screen_stack:
                self.app.pop_screen()
        except Exception:
            pass
