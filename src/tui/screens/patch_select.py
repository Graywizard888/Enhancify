"""
Enhancify Patch Selection Screen
Interactive checklist for enabling/disabling patches with real-time search,
category filtering (Recommended / All / None), and patch description inspector.
"""

from pathlib import Path
from typing import Any, Dict, List, Optional, Set

from rich.text import Text
from textual.app import ComposeResult
from textual.containers import Container, Horizontal, ScrollableContainer, Vertical
from textual.screen import Screen
from textual.widgets import Button, Checkbox, Footer, Input, Label, ListItem, ListView, Static

from src.assets import assets_mgr
from src.config import config
from src.environment import env
from src.patches import patches_mgr
from src.tui.widgets.dialogs import MessageDialog
from src.tui.widgets.header import CyberHeader


class PatchSelectScreen(Screen):
    """Patch selection checklist screen."""

    BINDINGS = [
        ("r", "action_select_recommended", "Recommended"),
        ("a", "action_select_all", "Select All"),
        ("d", "action_deselect_all", "Deselect All"),
        ("n", "action_next", "Configure Options"),
        ("b", "action_back", "Back"),
        ("escape", "action_back", "Back"),
    ]

    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.all_patches: List[Dict[str, Any]] = []
        self.filtered_patches: List[Dict[str, Any]] = []
        self.enabled_patches: Set[str] = set()
        self.patch_descriptions: Dict[str, str] = {}
        self.patch_options: List[Dict[str, Any]] = []

    def compose(self) -> ComposeResult:
        has_root, has_rish, mode_label = env.check_privileges()
        _, _, net_status = env.check_network()

        app_info = getattr(self.app, "selected_app", {})
        app_name = app_info.get("appName", "App")

        yield CyberHeader(mode_label=mode_label, online_status=net_status)

        with ScrollableContainer(classes="container-box"):
            with Vertical(classes="card"):
                yield Label(f"🛠️ Select Patches for [bold #00ff7f]{app_name}[/]", classes="card-title")
                yield Label("Enabled: 0 / 0", id="patch-count-label", classes="card-desc")

                yield Input(placeholder="🔍 Search patches by name or keyword...", id="search-patches")

                with Horizontal():
                    yield Button("⚡ Recommended [R]", id="btn-rec", classes="btn-primary")
                    yield Button("✅ Select All [A]", id="btn-all")
                    yield Button("❌ Deselect All [D]", id="btn-none")
                    yield Button("🚀 Next: Options [N]", id="btn-next", classes="btn-primary")
                    yield Button("🔙 Back [B]", id="btn-back", classes="btn-secondary")

                yield ListView(id="patches-list")

            with Vertical(classes="card"):
                yield Label("ℹ️ Patch Description", classes="card-title")
                yield Label("Select a patch above to view its details.", id="patch-desc-label", classes="card-desc")

        yield Footer()

    def on_mount(self) -> None:
        self.load_patches()

    def load_patches(self) -> None:
        """Load available patches and populate checklist."""
        app_info = getattr(self.app, "selected_app", {})
        pkg_name = app_info.get("pkgName", "")
        source_name = config.get("SOURCE", "Anddea")

        src_dir = assets_mgr.assets_dir / source_name
        # Find json
        json_files = list(src_dir.glob("Patches-*.json"))
        if not json_files:
            self.app.push_screen(
                MessageDialog("Error", f"No patches metadata found for {source_name}!")
            )
            return

        patches_meta = json_files[0]
        import json
        try:
            meta_list = json.loads(patches_meta.read_text(encoding="utf-8"))
        except Exception:
            meta_list = []

        # Find app entry in meta_list
        app_entry = None
        for item in meta_list:
            if item.get("pkgName") == pkg_name or item.get("pkgName") is None:
                app_entry = item
                break

        if not app_entry:
            self.app.push_screen(
                MessageDialog("Error", f"No patch entries found for package: {pkg_name}")
            )
            return

        rec = app_entry.get("patches", {}).get("recommended", [])
        opt = app_entry.get("patches", {}).get("optional", [])
        self.patch_descriptions = app_entry.get("descriptions", {})
        self.patch_options = app_entry.get("options", [])

        # Load saved enabled patches or default to recommended
        saved_enabled = patches_mgr.get_enabled_patches_for_pkg(source_name, pkg_name, meta_list)
        self.enabled_patches = saved_enabled if saved_enabled else set(rec)

        # Assemble list
        all_p = []
        for p in rec:
            all_p.append({"name": p, "recommended": True})
        for p in opt:
            if p not in rec:
                all_p.append({"name": p, "recommended": False})

        self.all_patches = sorted(all_p, key=lambda x: (not x["recommended"], x["name"]))
        self.filter_and_display()

    def filter_and_display(self, query: str = "") -> None:
        """Filter patch list by search string and populate ListView."""
        p_list = self.query_one("#patches-list", ListView)
        p_list.clear()

        q = query.strip().lower()
        self.filtered_patches = [
            p for p in self.all_patches
            if not q or q in p["name"].lower() or q in self.patch_descriptions.get(p["name"], "").lower()
        ]

        # Update counter
        tot_enabled = len(self.enabled_patches)
        tot_all = len(self.all_patches)
        try:
            self.query_one("#patch-count-label", Label).update(
                f"Enabled: [bold #00ff7f]{tot_enabled}[/] / {tot_all} patches"
            )
        except Exception:
            pass

        for idx, p in enumerate(self.filtered_patches):
            name = p["name"]
            is_enabled = name in self.enabled_patches
            is_rec = p["recommended"]

            txt = Text()
            if is_enabled:
                txt.append("☑ ", style="bold #00ff7f")
            else:
                txt.append("☐ ", style="dim")

            txt.append(f"{name:<35}", style="bold #ffffff" if is_enabled else "#c9d1d9")
            if is_rec:
                txt.append(" [RECOMMENDED]", style="bold #00ff7f")

            item = ListItem(Label(txt), id=f"patch-{idx}")
            p_list.append(item)

    def on_input_changed(self, event: Input.Changed) -> None:
        if event.input.id == "search-patches":
            self.filter_and_display(event.value)

    def on_list_view_highlighted(self, event: ListView.Highlighted) -> None:
        """Update description panel when an item is focused."""
        if not event.item:
            return
        item_id = event.item.id or ""
        if item_id.startswith("patch-"):
            idx = int(item_id[6:])
            if 0 <= idx < len(self.filtered_patches):
                pname = self.filtered_patches[idx]["name"]
                desc = self.patch_descriptions.get(pname, "No description available.")
                try:
                    self.query_one("#patch-desc-label", Label).update(f"[bold #00ff7f]{pname}[/]:\n{desc}")
                except Exception:
                    pass

    def on_list_view_selected(self, event: ListView.Selected) -> None:
        """Toggle patch on click or Enter."""
        item_id = event.item.id or ""
        if item_id.startswith("patch-"):
            idx = int(item_id[6:])
            pname = self.filtered_patches[idx]["name"]
            if pname in self.enabled_patches:
                self.enabled_patches.remove(pname)
            else:
                self.enabled_patches.add(pname)
            self.filter_and_display(self.query_one("#search-patches", Input).value)

    def on_button_pressed(self, event: Button.Pressed) -> None:
        btn_id = event.button.id
        if btn_id == "btn-rec":
            self.action_select_recommended()
        elif btn_id == "btn-all":
            self.action_select_all()
        elif btn_id == "btn-none":
            self.action_deselect_all()
        elif btn_id == "btn-next":
            self.action_next()
        elif btn_id == "btn-back":
            self.action_back()

    def action_select_recommended(self) -> None:
        self.enabled_patches = {p["name"] for p in self.all_patches if p["recommended"]}
        self.filter_and_display(self.query_one("#search-patches", Input).value)

    def action_select_all(self) -> None:
        self.enabled_patches = {p["name"] for p in self.all_patches}
        self.filter_and_display(self.query_one("#search-patches", Input).value)

    def action_deselect_all(self) -> None:
        self.enabled_patches.clear()
        self.filter_and_display(self.query_one("#search-patches", Input).value)

    def action_next(self) -> None:
        if not self.enabled_patches:
            self.app.push_screen(
                MessageDialog("Warning", "No patches enabled! Please select at least one patch.")
            )
            return

        # Save enabled patches to app state
        self.app.selected_app["enabled_patches"] = self.enabled_patches
        self.app.selected_app["available_options"] = self.patch_options
        self.app.push_screen("options_edit_screen")

    def action_back(self) -> None:
        self.app.pop_screen()
