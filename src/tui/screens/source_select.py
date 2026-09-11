"""
Enhancify Source Selection Screen
Allows users to switch active patch source, refresh release tags, manage custom sources,
and initiate the app patching flow.
"""

from typing import Any, Dict, List, Optional

from rich.text import Text
from textual import work
from textual.app import ComposeResult
from textual.containers import Container, Horizontal, ScrollableContainer, Vertical
from textual.screen import Screen
from textual.widgets import Button, Footer, Label, ListItem, ListView, Static

from src.config import config
from src.environment import env
from src.sources import SourceInfo, sources_mgr
from src.tui.widgets.dialogs import MessageDialog, ProgressModal
from src.tui.widgets.header import CyberHeader
from src.tui.widgets.button_bar import ButtonBar


class SourceSelectScreen(Screen):
    """Screen for selecting active patch source or picking sources to start patching."""

    BINDINGS = [
        ("p", "proceed", "Proceed"),
        ("r", "refresh_tags", "Refresh Tags"),
        ("c", "custom_sources", "Custom Sources"),
        ("b", "back", "Back"),
        ("escape", "back", "Back"),
    ]

    def __init__(self, is_patch_flow: bool = False, **kwargs):
        super().__init__(**kwargs)
        self.is_patch_flow = is_patch_flow
        self.selected_multi_sources: List[str] = []
        self.displayed_sources: List[SourceInfo] = []

    def compose(self) -> ComposeResult:
        has_root, has_rish, mode_label = env.check_privileges()
        _, _, net_status = env.check_network()

        is_multi = config.is_on("ENABLE_MULTIPATCHER")
        current_src = config.get("SOURCE", "Anddea")

        yield CyberHeader(mode_label=mode_label, online_status=net_status)

        with ScrollableContainer(classes="container-box"):
            with Vertical(classes="card"):
                if self.is_patch_flow:
                    if is_multi:
                        yield Label("🚀 Step 1: Select Patch Sources (Multi-Patcher)", classes="card-title")
                        yield Label("Select up to 3 sources to combine, then click Proceed [P / Enter]:", classes="card-desc")
                    else:
                        yield Label("🚀 Step 1: Select Patch Source", classes="card-title")
                        yield Label("Choose a patch source below to load supported applications and proceed:", classes="card-desc")
                else:
                    if is_multi:
                        yield Label("📦 Multi-Patcher Mode: Select up to 3 sources", classes="card-title")
                        yield Label("Click sources to toggle selection (1 to 3 sources):", classes="card-desc")
                    else:
                        yield Label(f"📦 Active Source: [bold #00ff7f]{current_src}[/]", classes="card-title")
                        yield Label("Select a patch source below or refresh tags from GitHub/GitLab:", classes="card-desc")

                with ButtonBar():
                    if self.is_patch_flow or is_multi:
                        yield Button("🚀 Proceed to Apps [P]", id="btn-proceed", classes="btn-primary")
                    yield Button("🔄 Refresh Tags [R]", id="btn-refresh-tags", classes="btn-primary" if not (self.is_patch_flow or is_multi) else "-style-default")
                    yield Button("➕ Custom Sources [C]", id="btn-custom-sources")
                    yield Button("🔙 Back [B]", id="btn-back", classes="btn-secondary")

                yield Label("", id="channel-hint", classes="card-desc")

                yield ListView(id="sources-list")

        yield Footer()

    def on_mount(self) -> None:
        if not self.selected_multi_sources:
            cur = config.get("SOURCE", "Anddea")
            self.selected_multi_sources = [cur]
        self.populate_sources()

    def populate_sources(self) -> None:
        """Populate list of sources honouring the USE_PRE_RELEASE toggle."""
        sources = sources_mgr.get_all_sources()
        self.displayed_sources = sources
        current_src = config.get("SOURCE", "Anddea")
        is_multi = config.is_on("ENABLE_MULTIPATCHER")
        use_pre = config.is_on("USE_PRE_RELEASE")

        sources_list = self.query_one("#sources-list", ListView)
        sources_list.clear()

        for s in sources:
            # Channel-aware tag: prerelease when enabled, stable otherwise.
            version_str, channel = sources_mgr.get_display_tag(s.source)
            if not version_str:
                version_str = "No tag cached"

            if is_multi:
                is_active = s.source in self.selected_multi_sources
            else:
                is_active = (s.source == current_src)

            txt = Text()
            if is_active:
                txt.append("● " if not is_multi else "☑ ", style="bold #00ff7f")
            else:
                txt.append("○ " if not is_multi else "☐ ", style="dim")

            txt.append(f"{s.source:<20}", style="bold #ffffff" if is_active else "#e6edf3")
            if version_str == "No tag cached":
                txt.append(f" ({version_str})", style="#8b949e")
            elif channel == "pre":
                txt.append(f" ({version_str})", style="#ffd700")
                txt.append(" [PRE]", style="bold #ffd700")
            else:
                txt.append(f" ({version_str})", style="#00e5ff")

            if s.is_custom:
                txt.append(" [CUSTOM]", style="bold #d2a8ff")

            item = ListItem(Label(txt))
            item.source_name = s.source
            sources_list.append(item)

        # Refresh the channel hint label so the mode is always visible.
        try:
            hint = self.query_one("#channel-hint", Label)
            if use_pre:
                hint.update("[Pre-release] Showing bleeding-edge prerelease tags — Refresh Tags [R] to update.")
            else:
                hint.update("[Stable] Showing stable release tags — Refresh Tags [R] to update.")
        except Exception:
            pass

    def on_list_view_selected(self, event: ListView.Selected) -> None:
        """Handle selection of a source."""
        source_name = getattr(event.item, "source_name", None)
        if not source_name and 0 <= event.index < len(self.displayed_sources):
            source_name = self.displayed_sources[event.index].source

        if not source_name:
            return

        is_multi = config.is_on("ENABLE_MULTIPATCHER")

        if is_multi:
            if source_name in self.selected_multi_sources:
                if len(self.selected_multi_sources) > 1:
                    self.selected_multi_sources.remove(source_name)
            else:
                if len(self.selected_multi_sources) >= 3:
                    self.selected_multi_sources.pop(0)
                self.selected_multi_sources.append(source_name)

            config.set("SOURCE", self.selected_multi_sources[0])
            self.app.multi_sources = self.selected_multi_sources
            self.populate_sources()
        else:
            config.set("SOURCE", source_name)
            self.app.multi_sources = [source_name]

            if self.is_patch_flow:
                # Proceed directly to AppSelectScreen in patching flow
                from src.tui.screens.app_select import AppSelectScreen
                self.app.push_screen(AppSelectScreen())
            else:
                self.populate_sources()
                self.app.push_screen(
                    MessageDialog("Source Updated", f"Active source set to: {source_name}")
                )

    def on_button_pressed(self, event: Button.Pressed) -> None:
        btn_id = event.button.id
        if btn_id == "btn-proceed":
            self.action_proceed()
        elif btn_id == "btn-refresh-tags":
            self.action_refresh_tags()
        elif btn_id == "btn-custom-sources":
            self.action_custom_sources()
        elif btn_id == "btn-back":
            self.action_back()

    def action_proceed(self) -> None:
        """Proceed to app selection with selected source(s)."""
        is_multi = config.is_on("ENABLE_MULTIPATCHER")
        if is_multi and self.selected_multi_sources:
            config.set("SOURCE", self.selected_multi_sources[0])
            self.app.multi_sources = self.selected_multi_sources

        from src.tui.screens.app_select import AppSelectScreen
        self.app.push_screen(AppSelectScreen())

    def action_refresh_tags(self) -> None:
        """Trigger background tag refresh."""
        modal = ProgressModal("Refreshing Tags", "Fetching latest tags from GitHub / GitLab...")
        self.app.push_screen(modal)
        self.run_tag_refresh_worker(modal)

    @work(thread=True)
    def run_tag_refresh_worker(self, modal: ProgressModal) -> None:
        try:
            sources_mgr.update_tags(progress_callback=lambda cur, tot, name: modal.update_message(f"Fetching {name} ({cur}/{tot})..."))
        finally:
            self.app.call_from_thread(modal.safe_dismiss)
            self.app.call_from_thread(self.populate_sources)

    def action_custom_sources(self) -> None:
        self.app.push_screen("custom_sources_screen")

    def action_back(self) -> None:
        self.app.pop_screen()
