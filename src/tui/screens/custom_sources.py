"""
Enhancify Custom Sources Management Screen
Allows adding, editing, and deleting user custom patch sources.
"""

from typing import List, Optional

from rich.text import Text
from textual.app import ComposeResult
from textual.containers import Container, Horizontal, ScrollableContainer, Vertical
from textual.screen import Screen
from textual.widgets import Button, Footer, Label, ListItem, ListView

from src.environment import env
from src.sources import SourceInfo, sources_mgr
from src.tui.widgets.dialogs import ConfirmDialog, InputDialog, MessageDialog
from src.tui.widgets.header import CyberHeader


class CustomSourcesScreen(Screen):
    """Custom sources CRUD manager screen."""

    BINDINGS = [
        ("a", "action_add_source", "Add Source"),
        ("h", "action_help", "Help"),
        ("b", "action_back", "Back"),
        ("escape", "action_back", "Back"),
    ]

    def compose(self) -> ComposeResult:
        has_root, has_rish, mode_label = env.check_privileges()
        _, _, net_status = env.check_network()

        yield CyberHeader(mode_label=mode_label, online_status=net_status)

        with ScrollableContainer(classes="container-box"):
            with Vertical(classes="card"):
                yield Label("➕ Custom Sources Management", classes="card-title")
                yield Label("Add or manage custom ReVanced / Morphe patch repositories:", classes="card-desc")

                with Horizontal():
                    yield Button("➕ Add New Source [A]", id="btn-add", classes="btn-primary")
                    yield Button("📖 Description & Help [H]", id="btn-help")
                    yield Button("🔙 Back [B]", id="btn-back", classes="btn-secondary")

                yield ListView(id="custom-sources-list")

        yield Footer()

    def on_mount(self) -> None:
        self.populate_custom_sources()

    def populate_custom_sources(self) -> None:
        """Populate list of custom sources."""
        c_list = self.query_one("#custom-sources-list", ListView)
        c_list.clear()

        all_sources = sources_mgr.get_all_sources()
        custom_sources = [s for s in all_sources if s.is_custom]

        if not custom_sources:
            c_list.append(ListItem(Label(Text("No custom sources added yet. Click 'Add New Source' above.", style="dim"))))
            return

        for idx, s in enumerate(custom_sources):
            txt = Text()
            txt.append("📦 ", style="bold #d2a8ff")
            txt.append(f"{s.source:<20}", style="bold #ffffff")
            txt.append(f" ({s.repository})", style="#00e5ff")
            if s.json_url:
                txt.append(" [JSON API]", style="#00ff7f")

            item = ListItem(Label(txt), id=f"csrc-{idx}")
            c_list.append(item)

    def on_list_view_selected(self, event: ListView.Selected) -> None:
        item_id = event.item.id or ""
        if item_id.startswith("csrc-"):
            idx = int(item_id[5:])
            custom_sources = [s for s in sources_mgr.get_all_sources() if s.is_custom]
            if 0 <= idx < len(custom_sources):
                self.prompt_source_actions(custom_sources[idx])

    def prompt_source_actions(self, source: SourceInfo) -> None:
        """Show Edit / Delete confirmation."""
        def handle_confirm(delete_it: bool) -> None:
            if delete_it:
                ok, msg = sources_mgr.delete_custom_source(source.source)
                self.populate_custom_sources()
                self.app.push_screen(MessageDialog("Deleted", msg))

        self.app.push_screen(
            ConfirmDialog(
                title=f"Manage {source.source}",
                message=f"Repository: {source.repository}\nJSON URL: {source.json_url or 'None'}\n\nDo you want to DELETE this custom source?",
                yes_label="Delete",
                no_label="Cancel",
            ),
            handle_confirm,
        )

    def on_button_pressed(self, event: Button.Pressed) -> None:
        btn_id = event.button.id
        if btn_id == "btn-add":
            self.action_add_source()
        elif btn_id == "btn-help":
            self.action_help()
        elif btn_id == "btn-back":
            self.action_back()

    def action_add_source(self) -> None:
        """Sequential dialogs to add custom source."""
        def step1_name(name_res: Optional[str]) -> None:
            if not name_res or not name_res.strip():
                return
            src_name = name_res.strip()

            def step2_repo(repo_res: Optional[str]) -> None:
                if not repo_res or not repo_res.strip():
                    return
                repo_name = repo_res.strip()

                def step3_json(json_res: Optional[str]) -> None:
                    json_url = json_res.strip() if json_res else ""
                    ok, msg = sources_mgr.add_custom_source(src_name, repo_name, json_url)
                    self.populate_custom_sources()
                    self.app.push_screen(MessageDialog("Result", msg))

                self.app.push_screen(
                    InputDialog("Custom Source JSON (Optional)", "Enter patches.json raw URL (leave blank for CLI parsing):"),
                    step3_json,
                )

            self.app.push_screen(
                InputDialog("Custom Source Repository", "Enter GitHub repository (username/repo):", placeholder="e.g. Aunali321/ReVancedExperiments"),
                step2_repo,
            )

        self.app.push_screen(
            InputDialog("Custom Source Name", "Enter name for this custom source:", placeholder="e.g. MyExperiments"),
            step1_name,
        )

    def action_help(self) -> None:
        help_text = (
            "HOW TO ADD CUSTOM SOURCES:\n\n"
            "1. Source Name: Unique identifier for this patcher profile.\n"
            "2. Repository: Format 'owner/repo' containing patch releases.\n"
            "3. JSON URL (Optional): Raw link to patches-list.json file.\n"
            "   Adding this speeds up patch metadata loading."
        )
        self.app.push_screen(MessageDialog("Custom Sources Guide", help_text))

    def action_back(self) -> None:
        self.app.pop_screen()
