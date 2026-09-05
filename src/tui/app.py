"""
Enhancify Textual Application
Main TUI application class tying all screens, themes, and global events together.
"""

from pathlib import Path
from typing import Any, Dict, Optional

from textual.app import App, ComposeResult

from src.config import config
from src.environment import env
from src.tui.screens.app_select import AppSelectScreen
from src.tui.screens.bundle_patcher import BundlePatcherScreen
from src.tui.screens.custom_sources import CustomSourcesScreen
from src.tui.screens.gmscore import GmsCoreScreen
from src.tui.screens.keystore_mgr import KeystoreManagerScreen
from src.tui.screens.main_menu import MainMenuScreen
from src.tui.screens.options_edit import OptionsEditScreen
from src.tui.screens.patch_progress import PatchProgressScreen
from src.tui.screens.patch_select import PatchSelectScreen
from src.tui.screens.settings import SettingsScreen
from src.tui.screens.source_select import SourceSelectScreen
from src.tui.screens.specs import SpecsScreen
from src.tui.screens.storage_mgr import StorageManagerScreen
from src.tui.screens.token_mgr import TokenManagerScreen
from src.tui.screens.unmount import UnmountScreen
from src.tui.screens.version_select import VersionSelectScreen


TCSS_PATH = Path(__file__).resolve().parent / "styles.tcss"


class EnhancifyApp(App):
    """Main Textual Application for Enhancify."""

    TITLE = "Enhancify"
    SUB_TITLE = "The Ultimate Custom Revancify Experience"
    CSS_PATH = TCSS_PATH

    SCREENS = {
        "main_menu_screen": MainMenuScreen,
        "source_select_screen": SourceSelectScreen,
        "app_select_screen": AppSelectScreen,
        "version_select_screen": VersionSelectScreen,
        "patch_select_screen": PatchSelectScreen,
        "options_edit_screen": OptionsEditScreen,
        "patch_progress_screen": PatchProgressScreen,
        "settings_screen": SettingsScreen,
        "custom_sources_screen": CustomSourcesScreen,
        "keystore_mgr_screen": KeystoreManagerScreen,
        "token_mgr_screen": TokenManagerScreen,
        "storage_mgr_screen": StorageManagerScreen,
        "specs_screen": SpecsScreen,
        "gmscore_screen": GmsCoreScreen,
        "bundle_patcher_screen": BundlePatcherScreen,
        "unmount_screen": UnmountScreen,
    }

    def __init__(self, force_root: Optional[bool] = None, force_rish: Optional[bool] = None, **kwargs):
        super().__init__(**kwargs)
        self.force_root = force_root
        self.force_rish = force_rish
        self.selected_app: Dict[str, Any] = {}

    def on_mount(self) -> None:
        """Start on main menu."""
        self.push_screen("main_menu_screen")
