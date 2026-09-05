"""
Enhancify Settings & Configuration Screen
Provides toggle switches for runtime options (Theme Selection, Lib Optimization,
Parallel GC, Pre-release Patches, Rish Flags, Keystore, CLI Cache) and links to sub-managers.
"""

from rich.text import Text
from textual import work
from textual.app import ComposeResult
from textual.containers import Container, Horizontal, ScrollableContainer, Vertical
from textual.screen import Screen
from textual.widgets import Button, Checkbox, Footer, Label, ListItem, ListView, Switch

from src.config import config
from src.environment import env
from src.theme import get_current_theme
from src.tui.widgets.dialogs import InputDialog, MessageDialog, ProgressModal
from src.tui.widgets.header import CyberHeader


TOGGLE_KEYS = [
    ("OPTIMIZE_LIBS", "Optimize Libs (RipLibs)", "Strip unused native CPU architecture binaries from APK"),
    ("LAUNCH_APP_AFTER_MOUNT", "Auto Launch After Mount", "Automatically launch patched application after install/mount"),
    ("ALLOW_APP_VERSION_DOWNGRADE", "Allow Version Downgrades", "Permit installing APK with lower version code"),
    ("USE_PRE_RELEASE", "Use Pre-release Patches", "Fetch and use bleeding-edge pre-release patches & CLI"),
    ("DISABLE_NETWORK_ACCELERATION", "Disable Network Acceleration", "Use standard downloader instead of aria2c multi-thread"),
    ("Use_CUSTOM_KEYSTORE", "Use Custom Keystore", "Sign patched APK with your custom cryptographic keystore"),
    ("CLI_RIPLIB_ANTISPLIT", "CLI RipLib / Antisplit Override", "Prefer CLI internal --striplibs / --rip-lib arguments"),
    ("USE_PARALLEL_GC", "Parallel Garbage Collection", "Enable multi-threaded Java ParallelGC engine"),
    ("CACHE_CLI", "Cache CLI Jar", "Cache downloaded CLI binaries locally across runs"),
    ("ENABLE_MULTIPATCHER", "Multi-Patcher (Experimental)", "Combine and merge patches from up to 3 sources"),
]

RISH_FLAGS = [
    ("SKIP_VERIFICATION", "Skip Signature Verification", "Pass --skip-verification to Rish installer"),
    ("BYPASS_LOW_TARGET_SDK_BLOCK", "Bypass Low Target SDK Block", "Pass --bypass-low-target-sdk-block to Rish installer"),
    ("FORCE_BACKGROUND_WHITELIST", "Force Background Whitelist", "Automatically grant background runtime whitelist"),
]


class SettingsScreen(Screen):
    """Settings & configuration screen."""

    BINDINGS = [
        ("t", "action_theme_select", "Change Theme"),
        ("b", "action_back", "Back"),
        ("escape", "action_back", "Back"),
    ]

    def compose(self) -> ComposeResult:
        has_root, has_rish, mode_label = env.check_privileges()
        _, _, net_status = env.check_network()

        cur_theme = get_current_theme()

        yield CyberHeader(mode_label=mode_label, online_status=net_status)

        with ScrollableContainer(classes="container-box"):
            # Theme Card
            with Vertical(classes="card"):
                yield Label("🎨 Appearance & Themes", classes="card-title")
                yield Label(f"Active Theme: [bold {cur_theme.primary_color}]{cur_theme.name}[/] — {cur_theme.description}", classes="card-desc")

                with Horizontal():
                    yield Button("🎨 Switch Theme [T]", id="btn-theme-select", classes="btn-primary")

            # Sub-manager shortcuts
            with Vertical(classes="card"):
                yield Label("🔧 Configuration Modules", classes="card-title")
                yield Label("Access advanced managers and tools below:", classes="card-desc")

                with Horizontal():
                    yield Button("➕ Custom Sources", id="btn-custom-src")
                    yield Button("🔑 Keystore Manager", id="btn-keystore")
                    yield Button("🎫 GitHub Token", id="btn-token")

                with Horizontal():
                    yield Button("🌐 APKMirror Scraper Config", id="btn-apkmirror-cfg")
                    yield Button("📦 Backup Stock Apps", id="btn-backup-apps")
                    yield Button("🔄 Auto Upgrade", id="btn-auto-upgrade")
                    yield Button("🔙 Back to Main Menu [B]", id="btn-back", classes="btn-secondary")

            # General Toggles
            with Vertical(classes="card"):
                yield Label("⚡ Feature & Optimization Toggles", classes="card-title")
                yield Label("Click any item to toggle feature ON or OFF:", classes="card-desc")

                yield ListView(id="toggles-list")

            # Rish Flags
            if has_rish or True:
                with Vertical(classes="card"):
                    yield Label("🛡️ Rish Installer Flags", classes="card-title")
                    yield Label("Flags passed to package manager during Rish installation:", classes="card-desc")

                    yield ListView(id="rish-flags-list")

        yield Footer()

    def on_mount(self) -> None:
        self.populate_toggles()

    def populate_toggles(self) -> None:
        """Populate list of switches."""
        t_list = self.query_one("#toggles-list", ListView)
        t_list.clear()

        for key, title, desc in TOGGLE_KEYS:
            is_active = config.is_on(key)
            txt = Text()
            if is_active:
                txt.append("● [ON]  ", style="bold #00ff7f")
            else:
                txt.append("○ [OFF] ", style="dim")

            txt.append(f"{title:<35}", style="bold #ffffff" if is_active else "#c9d1d9")
            txt.append(f" — {desc}", style="#8b949e")

            item = ListItem(Label(txt), id=f"toggle-{key}")
            t_list.append(item)

        # Rish flags
        r_list = self.query_one("#rish-flags-list", ListView)
        r_list.clear()

        for key, title, desc in RISH_FLAGS:
            is_active = config.is_on(key)
            txt = Text()
            if is_active:
                txt.append("● [ON]  ", style="bold #00ff7f")
            else:
                txt.append("○ [OFF] ", style="dim")

            txt.append(f"{title:<35}", style="bold #ffffff" if is_active else "#c9d1d9")
            txt.append(f" — {desc}", style="#8b949e")

            item = ListItem(Label(txt), id=f"rflag-{key}")
            r_list.append(item)

    def on_list_view_selected(self, event: ListView.Selected) -> None:
        item_id = event.item.id or ""
        if item_id.startswith("toggle-"):
            key = item_id[7:]
            new_state = config.toggle(key)
            self.populate_toggles()
            if key == "USE_PRE_RELEASE" and new_state:
                self.app.push_screen(
                    MessageDialog("Warning", "Pre-release patches enabled!\nThese patches are under active development and may be unstable.")
                )
            elif key == "ENABLE_MULTIPATCHER" and new_state:
                self.app.push_screen(
                    MessageDialog("Warning", "Multi-Patcher is experimental!\nCombining patches from multiple sources may cause runtime conflicts.")
                )
        elif item_id.startswith("rflag-"):
            key = item_id[6:]
            config.toggle(key)
            self.populate_toggles()

    def on_button_pressed(self, event: Button.Pressed) -> None:
        btn_id = event.button.id
        if btn_id == "btn-theme-select":
            self.action_theme_select()
        elif btn_id == "btn-custom-src":
            self.app.push_screen("custom_sources_screen")
        elif btn_id == "btn-keystore":
            self.app.push_screen("keystore_mgr_screen")
        elif btn_id == "btn-token":
            self.app.push_screen("token_mgr_screen")
        elif btn_id == "btn-apkmirror-cfg":
            self.configure_apkmirror()
        elif btn_id == "btn-backup-apps":
            from src.features import storage_ops
            count, msg = storage_ops.backup_stock_apps()
            self.app.push_screen(MessageDialog("Backup Result", msg))
        elif btn_id == "btn-auto-upgrade":
            from src.features import storage_ops
            modal = ProgressModal("Auto Upgrade", "Checking for package updates via pkg...")
            self.app.push_screen(modal)
            self.run_auto_upgrade_worker(modal)
        elif btn_id == "btn-back":
            self.action_back()

    @work(thread=True)
    def run_auto_upgrade_worker(self, modal: ProgressModal) -> None:
        from src.features import storage_ops
        ok, msg = storage_ops.auto_upgrade_dependencies()
        self.app.call_from_thread(modal.dismiss, None)
        self.app.call_from_thread(
            self.app.push_screen,
            MessageDialog("Auto Upgrade Result", msg)
        )

    def action_theme_select(self) -> None:
        self.app.push_screen("theme_select_screen")

    def configure_apkmirror(self) -> None:
        cur_limit = config.get_apkmirror_page_limit()

        def handle_limit(res: Optional[str]) -> None:
            if res is not None:
                try:
                    val = int(res)
                    if val > 0:
                        config.set_apkmirror_page_limit(val)
                        self.app.push_screen(MessageDialog("Saved", f"APKMirror max page limit set to {val}"))
                        return
                except ValueError:
                    pass
                self.app.push_screen(MessageDialog("Invalid Input", "Must be a positive integer!"))

        self.app.push_screen(
            InputDialog(
                title="APKMirror Scraper Config",
                prompt="Enter max pages to scrape for version lists (default: 5):",
                initial_value=str(cur_limit),
            ),
            handle_limit,
        )

    def action_back(self) -> None:
        self.app.pop_screen()
