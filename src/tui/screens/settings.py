"""
Enhancify Configure Screen
Opening Configure shows category buttons — Appearance & Themes,
Configuration Modules, Features Toggles, Rish Installer Flags.
Pressing a category opens a small centred dialog with its options.
Feature / Optimization and Rish Installer flag options are animated custom
switches with a Save button (changes apply only on Save).
"""

from typing import Dict, List, Optional

from textual import work
from textual.app import ComposeResult
from textual.containers import ScrollableContainer, Vertical
from textual.screen import Screen
from textual.widgets import Button, Footer, Label

from src.config import config
from src.environment import env
from src.theme import get_current_theme
from src.tui.widgets.dialogs import (
    AppearanceDialog,
    ConfigModulesDialog,
    InputDialog,
    MessageDialog,
    ProgressModal,
    ToggleSwitchDialog,
)
from src.tui.widgets.header import CyberHeader
from src.tui.widgets.button_bar import ButtonBar


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
    """Configure screen — category buttons, options in small centred dialogs."""

    BINDINGS = [
        ("t", "theme_select", "Change Theme"),
        ("b", "back", "Back"),
        ("escape", "back", "Back"),
    ]

    def compose(self) -> ComposeResult:
        has_root, has_rish, mode_label = env.check_privileges()
        _, _, net_status = env.check_network()

        yield CyberHeader(mode_label=mode_label, online_status=net_status)

        # Single card: with two auto-height cards Textual 8.x splits the
        # container between them, which squashes the button rows.
        with ScrollableContainer(classes="container-box"):
            with Vertical(classes="card"):
                yield Label("⚙️ Configure", classes="card-title")
                yield Label("Open a module below to manage its options:", classes="card-desc")

                with ButtonBar():
                    yield Button("🎨 Appearance & Themes", id="cat-appearance", classes="btn-primary")
                    yield Button("🔧 Configuration Modules", id="cat-modules")

                with ButtonBar():
                    yield Button("⚡ Features Toggles", id="cat-features")
                    yield Button("🛡️ Rish Installer Flags", id="cat-rish")

                # Live summary of current toggle states (updates after Save)
                yield Label("📊 Current State", classes="card-title")
                yield Label("", id="state-summary", classes="card-desc")

                with ButtonBar():
                    yield Button("🔙 Back to Main Menu [B]", id="btn-back", classes="btn-secondary")

        yield Footer()

    def on_mount(self) -> None:
        self.refresh_summary()

    def refresh_summary(self) -> None:
        """Show a compact on/off summary of features + rish flags."""
        try:
            feat_on = sum(1 for key, _t, _d in TOGGLE_KEYS if config.is_on(key))
            flag_on = sum(1 for key, _t, _d in RISH_FLAGS if config.is_on(key))
            self.query_one("#state-summary", Label).update(
                f"Feature & Optimization: [bold #00ff7f]{feat_on}[/] ON / {len(TOGGLE_KEYS)}    ·    "
                f"Rish Flags: [bold #00ff7f]{flag_on}[/] ON / {len(RISH_FLAGS)}"
            )
        except Exception:
            pass

    # ------------------------------------------------------------- category

    def open_appearance_dialog(self) -> None:
        cur_theme = get_current_theme()
        dlg = AppearanceDialog(
            theme_name=cur_theme.name,
            theme_description=cur_theme.description,
            theme_color=cur_theme.primary_color,
        )
        self.app.push_screen(dlg, self._on_appearance_result)

    def _on_appearance_result(self, result: Optional[str]) -> None:
        if result == "switch_theme":
            self.action_theme_select()

    def open_modules_dialog(self) -> None:
        self.app.push_screen(ConfigModulesDialog(), self._on_modules_result)

    def _on_modules_result(self, result: Optional[str]) -> None:
        if result == "custom_sources":
            self.app.push_screen("custom_sources_screen")
        elif result == "keystore":
            self.app.push_screen("keystore_mgr_screen")
        elif result == "token":
            self.app.push_screen("token_mgr_screen")
        elif result == "apkmirror":
            self.configure_apkmirror()
        elif result == "backup":
            from src.features import storage_ops

            count, msg = storage_ops.backup_stock_apps()
            self.app.push_screen(MessageDialog("Backup Result", msg))
        elif result == "auto_upgrade":
            from src.features import storage_ops

            modal = ProgressModal("Auto Upgrade", "Checking for package updates via pkg...")
            self.app.push_screen(modal)
            self.run_auto_upgrade_worker(modal)

    def open_features_dialog(self) -> None:
        initial = {key: config.is_on(key) for key, _t, _d in TOGGLE_KEYS}
        dlg = ToggleSwitchDialog(
            title="⚡ Feature & Optimization Toggles",
            options=TOGGLE_KEYS,
            initial=initial,
        )
        self.app.push_screen(dlg, self._on_features_result)

    def open_rish_dialog(self) -> None:
        initial = {key: config.is_on(key) for key, _t, _d in RISH_FLAGS}
        dlg = ToggleSwitchDialog(
            title="🛡️ Rish Installer Flags",
            options=RISH_FLAGS,
            initial=initial,
        )
        self.app.push_screen(dlg, self._on_rish_result)

    # ------------------------------------------------------------ save apply

    def _apply_toggles(self, values: Dict[str, bool]) -> List[tuple]:
        """Write values to config; returns [(key, new_state)] that changed."""
        changed: List[tuple] = []
        for key, new_state in values.items():
            if config.is_on(key) != bool(new_state):
                config.set(key, "on" if new_state else "off")
                changed.append((key, bool(new_state)))
        return changed

    def _on_features_result(self, result: Optional[Dict[str, bool]]) -> None:
        if not result:
            return
        changed = self._apply_toggles(result)
        self.refresh_summary()
        for key, new_state in changed:
            if key == "USE_PRE_RELEASE":
                if new_state:
                    self.app.push_screen(
                        MessageDialog(
                            "Pre-release Enabled",
                            "Pre-release patches enabled!\n"
                            "These patches are under active development and may be unstable.\n\n"
                            "Next: open Source Selection and press Refresh Tags [R]\n"
                            "to fetch prerelease tags, then re-download assets.",
                        )
                    )
                else:
                    self.app.push_screen(
                        MessageDialog(
                            "Stable Channel",
                            "Switched back to stable releases.\n\n"
                            "Next: open Source Selection and press Refresh Tags [R]\n"
                            "to show stable tags again.",
                        )
                    )
            elif key == "ENABLE_MULTIPATCHER" and new_state:
                self.app.push_screen(
                    MessageDialog("Warning", "Multi-Patcher is experimental!\nCombining patches from multiple sources may cause runtime conflicts.")
                )
        if not changed:
            self.app.push_screen(MessageDialog("Saved", "No changes to save."))

    def _on_rish_result(self, result: Optional[Dict[str, bool]]) -> None:
        if not result:
            return
        changed = self._apply_toggles(result)
        self.refresh_summary()
        if not changed:
            self.app.push_screen(MessageDialog("Saved", "No changes to save."))

    # --------------------------------------------------------------- buttons

    def on_button_pressed(self, event: Button.Pressed) -> None:
        btn_id = event.button.id
        if btn_id == "cat-appearance":
            self.open_appearance_dialog()
        elif btn_id == "cat-modules":
            self.open_modules_dialog()
        elif btn_id == "cat-features":
            self.open_features_dialog()
        elif btn_id == "cat-rish":
            self.open_rish_dialog()
        elif btn_id == "btn-back":
            self.action_back()

    @work(thread=True)
    def run_auto_upgrade_worker(self, modal: ProgressModal) -> None:
        from src.features import storage_ops

        ok, msg = storage_ops.auto_upgrade_dependencies()
        self.app.call_from_thread(modal.safe_dismiss)
        self.app.call_from_thread(
            self.app.push_screen,
            MessageDialog("Auto Upgrade Result", msg),
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
