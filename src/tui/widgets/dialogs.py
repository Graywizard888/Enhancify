"""
Enhancify Reusable Modal Dialog Widgets
Provides Confirm, Message, Input, and Progress modals with cybernetic styling.
"""

from typing import Any, Callable, Optional

from rich.text import Text
from textual.app import ComposeResult
from textual.containers import Container, Horizontal, Vertical
from textual.screen import ModalScreen
from textual.widgets import Button, Input, Label, LoadingIndicator, ProgressBar, Static


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

    def __init__(self, title: str, message: str, yes_label: str = "Yes", no_label: str = "No", **kwargs):
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
        """Update progress message."""
        try:
            lbl = self.query_one("#progress-msg", Label)
            lbl.update(new_msg)
        except Exception:
            pass
