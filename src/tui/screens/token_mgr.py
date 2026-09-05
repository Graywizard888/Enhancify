"""
Enhancify Custom GitHub Token Management Screen
Allows adding and validating Personal Access Tokens (Classic) to raise GitHub API rate limits
from 60/hr to 5,000/hr.
"""

from typing import Optional

import requests
from rich.text import Text
from textual.app import ComposeResult
from textual.containers import Container, Horizontal, ScrollableContainer, Vertical
from textual.screen import Screen
from textual.widgets import Button, Footer, Label, Static

from src.config import config
from src.environment import env
from src.tui.widgets.dialogs import ConfirmDialog, InputDialog, MessageDialog
from src.tui.widgets.header import CyberHeader


class TokenManagerScreen(Screen):
    """GitHub Token configuration screen."""

    BINDINGS = [
        ("a", "action_add_token", "Add Token"),
        ("d", "action_delete_token", "Delete Token"),
        ("g", "action_guide", "Guide"),
        ("b", "action_back", "Back"),
        ("escape", "action_back", "Back"),
    ]

    def compose(self) -> ComposeResult:
        has_root, has_rish, mode_label = env.check_privileges()
        _, _, net_status = env.check_network()

        yield CyberHeader(mode_label=mode_label, online_status=net_status)

        with ScrollableContainer(classes="container-box"):
            with Vertical(classes="card"):
                yield Label("🎫 GitHub Personal Access Token (Classic)", classes="card-title")
                yield Label(self.get_token_status_text(), id="token-status-label", classes="card-desc")

                with Horizontal():
                    yield Button("➕ Add / Update Token [A]", id="btn-add", classes="btn-primary")
                    yield Button("🗑️ Delete Token [D]", id="btn-delete", classes="btn-danger")
                    yield Button("📖 Guide [G]", id="btn-guide")
                    yield Button("🔙 Back [B]", id="btn-back", classes="btn-secondary")

            with Vertical(classes="card"):
                yield Label("⚡ Benefits of GitHub Token", classes="card-title")
                benefits = (
                    "• Increases API rate limit from 60 requests/hour to 5,000 requests/hour\n"
                    "• Eliminates 'API Rate Limit Exceeded' warnings when downloading patches & CLI\n"
                    "• Speeds up parallel tag fetching across multiple sources\n"
                    "• Stored securely locally in github_token.json"
                )
                yield Label(benefits, classes="card-desc")

        yield Footer()

    def get_token_status_text(self) -> str:
        tok = config.get_github_token()
        if tok:
            masked = tok[:4] + "*" * (len(tok) - 8) + tok[-4:] if len(tok) > 8 else "***"
            return f"Status: [bold #00ff7f]✓ Active Token Configured ({masked})[/]"
        return "Status: [bold #ffd700]⚠ No Token Configured (Using unauthenticated 60 req/hr limit)[/]"

    def on_button_pressed(self, event: Button.Pressed) -> None:
        btn_id = event.button.id
        if btn_id == "btn-add":
            self.action_add_token()
        elif btn_id == "btn-delete":
            self.action_delete_token()
        elif btn_id == "btn-guide":
            self.action_guide()
        elif btn_id == "btn-back":
            self.action_back()

    def action_add_token(self) -> None:
        def handle_token(res: Optional[str]) -> None:
            if not res or not res.strip():
                return
            token = res.strip()
            # Verify with GitHub API
            try:
                r = requests.get(
                    "https://api.github.com/user",
                    headers={"Authorization": f"Bearer {token}", "User-Agent": "Enhancify"},
                    timeout=5,
                )
                if r.status_code == 200:
                    config.set_github_token(token)
                    try:
                        self.query_one("#token-status-label", Label).update(self.get_token_status_text())
                    except Exception:
                        pass
                    self.app.push_screen(MessageDialog("Success", "✓ GitHub Token verified and saved successfully!"))
                else:
                    self.app.push_screen(MessageDialog("Verification Failed", f"GitHub API rejected token (HTTP {r.status_code})."))
            except Exception as e:
                self.app.push_screen(MessageDialog("Connection Error", f"Failed to verify token: {e}"))

        self.app.push_screen(
            InputDialog("Import GitHub Token", "Paste your Personal Access Token (Classic):", password=True),
            handle_token,
        )

    def action_delete_token(self) -> None:
        def handle_confirm(yes: bool) -> None:
            if yes:
                config.delete_github_token()
                try:
                    self.query_one("#token-status-label", Label).update(self.get_token_status_text())
                except Exception:
                    pass
                self.app.push_screen(MessageDialog("Token Removed", "GitHub token has been deleted."))

        self.app.push_screen(
            ConfirmDialog("Delete Token", "Are you sure you want to remove the saved GitHub token?", yes_label="Delete", no_label="Cancel"),
            handle_confirm,
        )

    def action_guide(self) -> None:
        guide = (
            "HOW TO GENERATE GITHUB TOKEN:\n\n"
            "1. Visit https://github.com/settings/tokens\n"
            "2. Click 'Generate new token (classic)'\n"
            "3. Note: 'Enhancify Termux'\n"
            "4. Expiration: 90 days or No expiration\n"
            "5. Scopes: 'public_repo'\n"
            "6. Click 'Generate token' and copy the secret key\n"
            "7. Return here and paste the token."
        )
        self.app.push_screen(MessageDialog("GitHub Token Guide", guide))

    def action_back(self) -> None:
        self.app.pop_screen()
