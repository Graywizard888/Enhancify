"""
Enhancify Patch Options Configuration Screen
Allows users to customize patch settings (e.g., custom branding name, API URLs, toggles)
with type-safe input dialogs before launching the patcher.
"""

from typing import Any, Dict, List, Optional, Set

from rich.text import Text
from textual.app import ComposeResult
from textual.containers import Container, Horizontal, ScrollableContainer, Vertical
from textual.screen import Screen
from textual.widgets import Button, Footer, Label, ListItem, ListView

from src.config import config
from src.environment import env
from src.patches import patches_mgr
from src.tui.widgets.dialogs import ConfirmDialog, InputDialog, MessageDialog
from src.tui.widgets.header import CyberHeader


class OptionsEditScreen(Screen):
    """Screen for configuring patch options."""

    BINDINGS = [
        ("s", "action_start_patching", "Start Patching"),
        ("r", "action_reset_defaults", "Reset Defaults"),
        ("b", "action_back", "Back"),
        ("escape", "action_back", "Back"),
    ]

    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.options_list: List[Dict[str, Any]] = []

    def compose(self) -> ComposeResult:
        has_root, has_rish, mode_label = env.check_privileges()
        _, _, net_status = env.check_network()

        app_info = getattr(self.app, "selected_app", {})
        app_name = app_info.get("appName", "App")

        yield CyberHeader(mode_label=mode_label, online_status=net_status)

        with ScrollableContainer(classes="container-box"):
            with Vertical(classes="card"):
                yield Label(f"⚙️ Configure Patch Options for [bold #00ff7f]{app_name}[/]", classes="card-title")
                yield Label("Select an option below to modify its value, or proceed to start patching:", classes="card-desc")

                with Horizontal():
                    yield Button("🚀 Start Patching [S]", id="btn-start", classes="btn-primary")
                    yield Button("🔄 Reset Defaults [R]", id="btn-reset")
                    yield Button("🔙 Back [B]", id="btn-back", classes="btn-secondary")

                yield ListView(id="options-list")

        yield Footer()

    def on_mount(self) -> None:
        self.load_options()

    def load_options(self) -> None:
        """Load and filter options for enabled patches."""
        app_info = getattr(self.app, "selected_app", {})
        enabled_patches: Set[str] = app_info.get("enabled_patches", set())
        available_options: List[Dict[str, Any]] = app_info.get("available_options", [])
        source_name = config.get("SOURCE", "Anddea")
        pkg_name = app_info.get("pkgName", "")

        # Filter options for enabled patches
        filtered = []
        for opt in available_options:
            if opt.get("patchName") in enabled_patches:
                filtered.append({
                    "patchName": opt.get("patchName"),
                    "key": opt.get("key"),
                    "title": opt.get("title", opt.get("key")),
                    "description": opt.get("description", ""),
                    "type": opt.get("type", "String"),
                    "default": opt.get("default"),
                    "value": opt.get("value", opt.get("default")),
                })

        self.options_list = filtered
        self.populate_options()

    def populate_options(self) -> None:
        """Populate ListView with configured options."""
        o_list = self.query_one("#options-list", ListView)
        o_list.clear()

        if not self.options_list:
            o_list.append(ListItem(Label(Text("No configurable options for enabled patches. You can proceed directly!", style="#00ff7f"))))
            return

        for idx, opt in enumerate(self.options_list):
            title = opt["title"]
            pn = opt["patchName"]
            val = opt["value"]
            opt_type = opt["type"]

            txt = Text()
            txt.append("⚙️ ", style="bold #00e5ff")
            txt.append(f"{title:<30}", style="bold #ffffff")
            txt.append(f" ({pn})", style="#8b949e")
            txt.append(f" = [ {val} ]", style="bold #00ff7f")

            item = ListItem(Label(txt), id=f"opt-{idx}")
            o_list.append(item)

    def on_list_view_selected(self, event: ListView.Selected) -> None:
        item_id = event.item.id or ""
        if item_id.startswith("opt-"):
            idx = int(item_id[4:])
            opt = self.options_list[idx]
            self.edit_option(opt, idx)

    def edit_option(self, opt: Dict[str, Any], idx: int) -> None:
        """Open editor dialog for option."""
        opt_type = opt["type"]
        title = opt["title"]
        desc = opt["description"]
        cur_val = str(opt["value"] if opt["value"] is not None else "")

        if opt_type == "Boolean":
            # Toggle boolean directly or confirm
            new_val = not bool(opt["value"])
            self.options_list[idx]["value"] = new_val
            self.populate_options()
        else:
            def handle_input(res: Optional[str]) -> None:
                if res is not None:
                    if opt_type == "Number":
                        try:
                            self.options_list[idx]["value"] = int(res) if res else None
                        except ValueError:
                            self.app.push_screen(MessageDialog("Invalid Input", "Field must be a valid number!"))
                            return
                    else:
                        self.options_list[idx]["value"] = res if res != "" else None
                    self.populate_options()

            self.app.push_screen(
                InputDialog(
                    title=f"Edit {title}",
                    prompt=f"{desc}\n\nType: {opt_type}",
                    initial_value=cur_val,
                ),
                handle_input,
            )

    def on_button_pressed(self, event: Button.Pressed) -> None:
        btn_id = event.button.id
        if btn_id == "btn-start":
            self.action_start_patching()
        elif btn_id == "btn-reset":
            self.action_reset_defaults()
        elif btn_id == "btn-back":
            self.action_back()

    def action_reset_defaults(self) -> None:
        for opt in self.options_list:
            opt["value"] = opt["default"]
        self.populate_options()

    def action_start_patching(self) -> None:
        """Save selections and launch patch progress screen."""
        app_info = getattr(self.app, "selected_app", {})
        source_name = config.get("SOURCE", "Anddea")
        pkg_name = app_info.get("pkgName", "")
        enabled_patches = app_info.get("enabled_patches", set())

        # Persist to disk
        patches_mgr.save_pkg_selection(source_name, pkg_name, enabled_patches, self.options_list)

        self.app.selected_app["configured_options"] = self.options_list
        self.app.push_screen("patch_progress_screen")

    def action_back(self) -> None:
        self.app.pop_screen()
