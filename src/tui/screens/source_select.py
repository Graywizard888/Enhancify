"""
Enhancify Source Selection Screen
Allows users to switch active patch source, refresh release tags, and manage custom sources.
"""

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


class SourceSelectScreen(Screen):
    """Screen for selecting active patch source."""

    BINDINGS = [
        ("r", "action_refresh_tags", "Refresh Tags"),
        ("c", "action_custom_sources", "Custom Sources"),
        ("b", "action_back", "Back"),
        ("escape", "action_back", "Back"),
    ]

    def compose(self) -> ComposeResult:
        has_root, has_rish, mode_label = env.check_privileges()
        _, _, net_status = env.check_network()

        yield CyberHeader(mode_label=mode_label, online_status=net_status)

        with ScrollableContainer(classes="container-box"):
            with Vertical(classes="card"):
                current_src = config.get("SOURCE", "Anddea")
                yield Label(f"📦 Active Source: [bold #00ff7f]{current_src}[/]", classes="card-title")
                yield Label("Select a patch source below or refresh tags from GitHub/GitLab:", classes="card-desc")

                with Horizontal():
                    yield Button("🔄 Refresh Tags [R]", id="btn-refresh-tags", classes="btn-primary")
                    yield Button("➕ Custom Sources [C]", id="btn-custom-sources")
                    yield Button("🔙 Back [B]", id="btn-back", classes="btn-secondary")

                yield ListView(id="sources-list")

        yield Footer()

    def on_mount(self) -> None:
        self.populate_sources()

    def populate_sources(self) -> None:
        """Populate list of sources."""
        sources = sources_mgr.get_all_sources()
        tags_cache = sources_mgr.get_cached_tags()
        current_src = config.get("SOURCE", "Anddea")

        sources_list = self.query_one("#sources-list", ListView)
        sources_list.clear()

        for s in sources:
            cached_info = tags_cache.get(s.source, {})
            lat = cached_info.get("latest", "")
            pre = cached_info.get("prerelease", "")

            version_str = lat if lat else (pre if pre else "No tag cached")
            is_active = (s.source == current_src)

            txt = Text()
            if is_active:
                txt.append("● ", style="bold #00ff7f")
            else:
                txt.append("○ ", style="dim")

            txt.append(f"{s.source:<20}", style="bold #ffffff" if is_active else "#e6edf3")
            txt.append(f" ({version_str})", style="#00e5ff" if lat else "#8b949e")

            if s.is_custom:
                txt.append(" [CUSTOM]", style="bold #d2a8ff")

            item = ListItem(Label(txt), id=f"src-{s.source}")
            sources_list.append(item)

    def on_list_view_selected(self, event: ListView.Selected) -> None:
        """Handle selection of a source."""
        item_id = event.item.id or ""
        if item_id.startswith("src-"):
            source_name = item_id[4:]
            config.set("SOURCE", source_name)
            self.populate_sources()
            self.app.push_screen(
                MessageDialog("Source Updated", f"Active source set to: {source_name}")
            )

    def on_button_pressed(self, event: Button.Pressed) -> None:
        btn_id = event.button.id
        if btn_id == "btn-refresh-tags":
            self.action_refresh_tags()
        elif btn_id == "btn-custom-sources":
            self.action_custom_sources()
        elif btn_id == "btn-back":
            self.action_back()

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
            self.app.call_from_thread(modal.dismiss, None)
            self.app.call_from_thread(self.populate_sources)

    def action_custom_sources(self) -> None:
        self.app.push_screen("custom_sources_screen")

    def action_back(self) -> None:
        self.app.pop_screen()
