"""
Enhancify Reusable Modal Dialog Widgets
Provides Confirm, Message, Input, Progress, Download, and Parse modals
with cybernetic styling, gradient bars/spinners, and cancel support.
"""

from __future__ import annotations

import threading
from typing import Any, Callable, Dict, List, Optional, Tuple

from rich.text import Text
from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.screen import ModalScreen
from textual.widgets import Button, Input, Label, LoadingIndicator, Static
from src.tui.widgets.button_bar import ButtonBar

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
            with ButtonBar(classes="dialog-buttons"):
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
            with ButtonBar(classes="dialog-buttons"):
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
            with ButtonBar(classes="dialog-buttons"):
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
        self._batch: Optional[Dict[str, Dict[str, Any]]] = None
        self._batch_accel = False

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
        files: Optional[List[Tuple[str, int]]] = None,
    ) -> "DownloadProgressModal":
        """Multi-file assets header — bash downloadBatchAria2c mixedgauge.

        ``files`` (label, size) enables the per-file mixed-gauge rows shown
        while aria2c downloads the CLI + Patches simultaneously.
        """
        total_disp = format_size(total_size) if total_size > 0 else "unknown"
        accel = " | Accelerated: 8 parts each" if accelerated else ""
        body = (
            f"\n"
            f"Downloading {file_count} file(s) simultaneously\n"
            f"Total: {total_disp}{accel}\n"
        )
        modal = cls(title="| Downloading Assets |", body=body, total_size=total_size)
        if files:
            modal._batch: Dict[str, Dict[str, Any]] = {}
            for label, size in files:
                modal._batch[label] = {
                    "size": size,
                    "cur": 0,
                    "pct": 0,
                    "done": False,
                    "failed": False,
                    "started": False,
                }
            modal._batch_accel = accelerated
        else:
            modal._batch = None
            modal._batch_accel = accelerated
        return modal

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
            if self._batch:
                yield Label("", id="dl-rows", classes="download-detail batch-rows")
            yield GradientProgressBar(id="dl-bar")
            yield Label("", id="dl-detail", classes="download-detail")
            if self.allow_cancel:
                with ButtonBar(classes="dialog-buttons download-cancel-row"):
                    yield Button("Cancel", id="btn-cancel", classes="btn-danger")

    def on_mount(self) -> None:
        try:
            bar = self.query_one("#dl-bar", GradientProgressBar)
            bar.set_fraction(0.0)
        except Exception:
            pass
        if self._batch:
            self._render_batch()

    # ------------------------------------------------------- batch (aria2c)

    def register_batch_file(self, label: str, size: int = 0) -> None:
        """Mark a batch file as started (aria2c fired up for it)."""
        if not self._batch:
            return
        entry = self._batch.setdefault(
            label,
            {"size": 0, "cur": 0, "pct": 0, "done": False, "failed": False, "started": False},
        )
        entry["started"] = True
        if size > 0:
            entry["size"] = size

    def on_file_progress(self, label: str, cur: int, total: int, pct: str = "") -> None:
        """Per-file progress for the simultaneous aria2c mixed-gauge view."""
        entry = self._batch.get(label) if self._batch else None
        if entry is None:
            return
        entry["started"] = True
        if total > 0:
            entry["size"] = total
            entry["cur"] = min(cur, total)
            entry["pct"] = int(cur * 100 / total)
        elif pct:
            pct_num = "".join(c for c in pct if c.isdigit())
            entry["pct"] = int(pct_num) if pct_num else entry["pct"]
        self._render_batch()

    def mark_batch_file_done(self, label: str, ok: bool = True) -> None:
        if not self._batch or label not in self._batch:
            return
        self._batch[label]["done"] = True
        self._batch[label]["failed"] = not ok
        self._batch[label]["pct"] = 100 if ok else self._batch[label]["pct"]
        self._render_batch()

    def _render_batch(self) -> None:
        """Render the per-file mixed-gauge rows + overall gradient bar."""

        def _apply() -> None:
            try:
                rows = self.query_one("#dl-rows", Label)
            except Exception:
                return
            lines: List[str] = []
            total_cur = 0
            total_known = 0
            for label, info in self._batch.items():  # type: ignore[union-attr]
                size = info.get("size", 0)
                if info.get("done"):
                    mark = "✔" if not info.get("failed") else "✖"
                    color = "#00ff7f" if not info.get("failed") else "#ff4444"
                    lines.append(
                        f"[bold {color}]{mark}[/] {label} — "
                        f"{'complete' if not info.get('failed') else 'failed'}"
                    )
                    continue
                if not info.get("started"):
                    lines.append(f"[dim]⏳ {label} — waiting...[/]")
                    continue
                if size > 0:
                    total_cur += info.get("cur", 0)
                    total_known += size
                    frac = max(0.0, min(1.0, info.get("cur", 0) / size))
                    pct_s = str(int(frac * 100))
                    size_s = format_size(size)
                else:
                    frac = info.get("pct", 0) / 100.0
                    pct_s = str(info.get("pct", 0))
                    size_s = "unknown"
                # mini 18-cell bar
                mini_w = 18
                filled = int(round(frac * mini_w))
                bar = "█" * filled + "░" * (mini_w - filled)
                lines.append(
                    f"⬇ [bold]{label}[/] [dim]({size_s})[/]  "
                    f"[#00e5ff]{bar}[/] [bold]{pct_s}%[/]"
                )
            if lines:
                rows.update("\n".join(lines))
            # overall bar = size-weighted average of known files
            if total_known > 0:
                try:
                    bar = self.query_one("#dl-bar", GradientProgressBar)
                    bar.set_fraction(max(0.0, min(1.0, total_cur / total_known)))
                except Exception:
                    pass

        _ui_call(self, _apply)

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
                with ButtonBar(classes="dialog-buttons download-cancel-row"):
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


# ---------------------------------------------------------------------------
# Patch Description dialog — long-press on a patch (small centred + Confirm)
# ---------------------------------------------------------------------------

class PatchDescriptionDialog(ModalScreen[None]):
    """Small centred modal showing a patch's full description + Confirm."""

    BINDINGS = [
        Binding("escape", "close", "Close", show=False),
    ]

    def __init__(
        self,
        patch_name: str,
        description: str,
        recommended: bool = False,
        **kwargs,
    ):
        super().__init__(**kwargs)
        self.patch_name = patch_name
        self.description = description or "No description available."
        self.recommended = recommended

    def compose(self) -> ComposeResult:
        name_style = "bold #00ff7f"
        badge = "  [RECOMMENDED]" if self.recommended else ""
        with Vertical(classes="dialog-box small-dialog"):
            yield Label("| Patch Details |", classes="dialog-title")
            yield Label(f"[{name_style}]{self.patch_name}[/]{badge}", id="patch-dialog-name")
            with VerticalScroll(id="patch-desc-scroll", classes="desc-scroll"):
                yield Label(self.description, classes="dialog-message desc-text")
            with ButtonBar(classes="dialog-buttons"):
                yield Button("Confirm", id="btn-confirm", classes="btn-primary")

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "btn-confirm":
            self.dismiss(None)

    def action_close(self) -> None:
        self.dismiss(None)


# ---------------------------------------------------------------------------
# Changelog dialog — asset fetch release notes (Download / Back)
# ---------------------------------------------------------------------------

class ChangelogDialog(ModalScreen[Optional[bool]]):
    """
    Classic `| Changelog |` parity — shown before downloading assets.

    Result: True → proceed with download, False/None → user pressed Back.
    """

    BINDINGS = [
        Binding("escape", "back", "Back", show=False),
    ]

    def __init__(
        self,
        source_name: str,
        patches_label: str,
        size_bytes: int,
        changelog: str,
        confirm_label: str = "⬇ Download",
        back_label: str = "🔙 Back",
        **kwargs,
    ):
        super().__init__(**kwargs)
        self.source_name = source_name
        self.patches_label = patches_label
        self.size_bytes = size_bytes
        self.changelog = (changelog or "").strip()
        self.confirm_label = confirm_label
        self.back_label = back_label

    def _meta_text(self) -> str:
        size_disp = format_size(self.size_bytes) if self.size_bytes > 0 else "Unavailable"
        return (
            f" SOURCE  : {self.source_name}\n"
            f" Patches : {self.patches_label}\n"
            f" Size    : {size_disp}\n"
            f"━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        )

    def compose(self) -> ComposeResult:
        with Vertical(classes="dialog-box changelog-dialog"):
            yield Label("| Changelog |", classes="dialog-title")
            yield Label(self._meta_text(), classes="dialog-message changelog-meta")
            with VerticalScroll(id="changelog-scroll", classes="desc-scroll"):
                yield Label(
                    self.changelog if self.changelog else "No changelog provided for this release.",
                    classes="dialog-message desc-text",
                )
            with ButtonBar(classes="dialog-buttons"):
                yield Button(self.confirm_label, id="btn-download", classes="btn-primary")
                yield Button(self.back_label, id="btn-back", classes="btn-secondary")

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "btn-download":
            self.dismiss(True)
        elif event.button.id == "btn-back":
            self.dismiss(False)

    def action_back(self) -> None:
        self.dismiss(False)


# ---------------------------------------------------------------------------
# Toggle dialog — animated custom switches + Save (centred)
# ---------------------------------------------------------------------------

class ToggleSwitchDialog(ModalScreen[Optional[Dict[str, bool]]]):
    """
    Centred dialog listing options as animated CyberSwitch rows.

    Result: dict {switch_key: new_value} on Save, None on Cancel.
    """

    BINDINGS = [
        Binding("escape", "cancel", "Cancel", show=False),
    ]

    def __init__(
        self,
        title: str,
        options: List[Tuple[str, str, str]],
        initial: Dict[str, bool],
        save_label: str = "💾 Save",
        cancel_label: str = "Cancel",
        **kwargs,
    ):
        super().__init__(**kwargs)
        self.dialog_title = title
        self.options = options  # (key, label, description)
        self.initial = initial
        self.save_label = save_label
        self.cancel_label = cancel_label

    def compose(self) -> ComposeResult:
        from src.tui.widgets.switch import CyberSwitch

        with Vertical(classes="dialog-box small-dialog toggle-dialog"):
            yield Label(self.dialog_title, classes="dialog-title")
            with Vertical(id="toggle-scroll", classes="toggle-scroll"):
                for key, label, desc in self.options:
                    yield CyberSwitch(
                        label,
                        desc,
                        switch_key=key,
                        initial=bool(self.initial.get(key, False)),
                    )
            with ButtonBar(classes="dialog-buttons"):
                yield Button(self.save_label, id="btn-save", classes="btn-primary")
                yield Button(self.cancel_label, id="btn-cancel", classes="btn-secondary")

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "btn-save":
            from src.tui.widgets.switch import CyberSwitch

            result = {
                sw.switch_key: bool(sw.value)
                for sw in self.query(CyberSwitch)
                if sw.switch_key
            }
            self.dismiss(result)
        elif event.button.id == "btn-cancel":
            self.action_cancel()

    def action_cancel(self) -> None:
        self.dismiss(None)


# ---------------------------------------------------------------------------
# Appearance & Themes dialog (centred)
# ---------------------------------------------------------------------------

class AppearanceDialog(ModalScreen[Optional[str]]):
    """
    Centred 'Appearance & Themes' dialog.

    Result: "switch_theme" when Switch Theme pressed, None when closed.
    """

    BINDINGS = [
        Binding("escape", "close", "Close", show=False),
    ]

    def __init__(
        self,
        theme_name: str,
        theme_description: str = "",
        theme_color: str = "#00ff7f",
        **kwargs,
    ):
        super().__init__(**kwargs)
        self.theme_name = theme_name
        self.theme_description = theme_description
        self.theme_color = theme_color

    def compose(self) -> ComposeResult:
        from src.tui.widgets.gradient import GradientProgressBar

        with Vertical(classes="dialog-box small-dialog appearance-dialog"):
            yield Label("🎨 Appearance & Themes", classes="dialog-title")
            yield Label(
                f"Active Theme: [bold {self.theme_color}]{self.theme_name}[/]",
                classes="dialog-message",
            )
            if self.theme_description:
                yield Label(self.theme_description, classes="dialog-message desc-text")
            yield GradientProgressBar(id="theme-palette", show_percentage=False)
            with ButtonBar(classes="dialog-buttons"):
                yield Button("🎨 Switch Theme", id="btn-switch", classes="btn-primary")
                yield Button("Close", id="btn-close", classes="btn-secondary")

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "btn-switch":
            self.dismiss("switch_theme")
        elif event.button.id == "btn-close":
            self.action_close()

    def action_close(self) -> None:
        self.dismiss(None)


# ---------------------------------------------------------------------------
# Configuration Modules dialog (centred)
# ---------------------------------------------------------------------------

class ConfigModulesDialog(ModalScreen[Optional[str]]):
    """
    Centred 'Configuration Modules' dialog.

    Result: the selected module key (e.g. "custom_sources") or None.
    """

    BINDINGS = [
        Binding("escape", "close", "Close", show=False),
    ]

    MODULES: List[Tuple[str, str]] = [
        ("custom_sources", "➕ Custom Sources"),
        ("keystore", "🔑 Keystore Manager"),
        ("token", "🎫 GitHub Token"),
        ("apkmirror", "🌐 APKMirror Scraper Config"),
        ("backup", "📦 Backup Stock Apps"),
        ("auto_upgrade", "🔄 Auto Upgrade"),
    ]

    def __init__(self, **kwargs):
        super().__init__(**kwargs)

    def compose(self) -> ComposeResult:
        with Vertical(classes="dialog-box small-dialog modules-dialog"):
            yield Label("🔧 Configuration Modules", classes="dialog-title")
            yield Label("Access advanced managers and tools:", classes="dialog-message")
            with ButtonBar(classes="modules-list"):
                for key, label in self.MODULES:
                    yield Button(label, id=f"mod-{key}")
            with ButtonBar(classes="dialog-buttons"):
                yield Button("Close", id="btn-close", classes="btn-secondary")

    def on_button_pressed(self, event: Button.Pressed) -> None:
        btn_id = event.button.id
        if btn_id == "btn-close":
            self.action_close()
            return
        if btn_id.startswith("mod-"):
            self.dismiss(btn_id[len("mod-"):])

    def action_close(self) -> None:
        self.dismiss(None)
