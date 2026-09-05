"""
Enhancify Live Patch Execution & Log Viewer Screen
Executes the CLI patcher, streams live console output, renders progress,
and handles one-click installation or log sharing upon completion.
"""

import shutil
import subprocess
from pathlib import Path
from typing import Optional

from rich.text import Text
from textual import work
from textual.app import ComposeResult
from textual.containers import Container, Horizontal, ScrollableContainer, Vertical
from textual.screen import Screen
from textual.widgets import Button, Footer, Label, ProgressBar, RichLog, Static

from src.assets import assets_mgr
from src.config import config
from src.environment import env
from src.installer import app_installer
from src.patcher import PatchExecutionConfig, patcher_engine
from src.tui.widgets.dialogs import MessageDialog, ProgressModal
from src.tui.widgets.header import CyberHeader


class PatchProgressScreen(Screen):
    """Live patch execution console and installer."""

    BINDINGS = [
        ("i", "action_install", "Install APK"),
        ("s", "action_share_logs", "Share Logs"),
        ("m", "action_main_menu", "Main Menu"),
    ]

    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.patch_in_progress = False
        self.patch_success = False
        self.output_apk: Optional[Path] = None

    def compose(self) -> ComposeResult:
        has_root, has_rish, mode_label = env.check_privileges()
        _, _, net_status = env.check_network()

        app_info = getattr(self.app, "selected_app", {})
        app_name = app_info.get("appName", "App")
        app_ver = app_info.get("version", "")
        source_name = config.get("SOURCE", "Anddea")

        yield CyberHeader(mode_label=mode_label, online_status=net_status)

        with ScrollableContainer(classes="container-box"):
            with Vertical(classes="card"):
                yield Label(f"🚀 Patching [bold #00ff7f]{app_name} {app_ver}[/] with [bold #00e5ff]{source_name}[/]", classes="card-title")
                yield Label("Status: [bold #ffd700]Initializing JVM & CLI Patcher...[/]", id="status-label", classes="card-desc")
                yield ProgressBar(total=100, show_eta=False, id="progress-bar")

                with Horizontal(id="action-buttons"):
                    yield Button("⚡ Install & Finalize [I]", id="btn-install", classes="btn-primary", disabled=True)
                    yield Button("📤 Share Logs [S]", id="btn-share")
                    yield Button("🏠 Main Menu [M]", id="btn-menu", classes="btn-secondary")

            with Vertical(classes="card"):
                yield Label("📜 Live Console Output", classes="card-title")
                yield RichLog(id="log-viewer", highlight=True, markup=True)

        yield Footer()

    def on_mount(self) -> None:
        self.start_patching_process()

    def start_patching_process(self) -> None:
        """Initialize parameters and start worker."""
        app_info = getattr(self.app, "selected_app", {})
        app_name = app_info.get("appName", "")
        app_ver = app_info.get("version", "1.0")
        pkg_name = app_info.get("pkgName", "")
        source_name = config.get("SOURCE", "Anddea")
        enabled_patches = app_info.get("enabled_patches", set())
        options_list = app_info.get("configured_options", [])

        # Paths
        input_apk = app_info.get("apk_path") or app_info.get("imported_file")
        if not input_apk or not Path(input_apk).exists():
            input_apk = assets_mgr.workspace_dir / "apps" / app_name / f"{app_ver}.apk"

        output_apk = assets_mgr.workspace_dir / "apps" / app_name / f"{app_ver}-{source_name}.apk"
        self.output_apk = output_apk

        # Find CLI and Patches
        cli_jars = list(assets_mgr.assets_dir.glob("CLI-*.jar"))
        src_dir = assets_mgr.assets_dir / source_name
        patch_files = list(src_dir.glob("Patches-*.*"))
        patch_bins = [p for p in patch_files if p.suffix.lower() in [".jar", ".rvp", ".mpp"]]

        if not cli_jars or not patch_bins or not Path(input_apk).exists():
            self.app.push_screen(
                MessageDialog("Error", "Missing input APK, CLI jar, or patches bundle!")
            )
            return

        cfg = PatchExecutionConfig(
            source_name=source_name,
            app_name=app_name,
            app_version=app_ver,
            pkg_name=pkg_name,
            input_apk_path=Path(input_apk),
            output_apk_path=output_apk,
            cli_jar=cli_jars[0],
            patches_file=patch_bins[0],
            enabled_patches=enabled_patches,
            patch_options=options_list,
        )

        self.patch_in_progress = True
        self.run_patcher_worker(cfg)

    @work(thread=True)
    def run_patcher_worker(self, cfg: PatchExecutionConfig) -> None:
        log_view = self.query_one("#log-viewer", RichLog)

        def log_cb(line: str) -> None:
            self.app.call_from_thread(log_view.write, line)

        def prog_cb(pct: float, msg: str) -> None:
            def update_ui():
                try:
                    self.query_one("#status-label", Label).update(f"Status: [bold #00e5ff]{msg}[/]")
                    self.query_one("#progress-bar", ProgressBar).update(progress=int(pct * 100))
                except Exception:
                    pass
            self.app.call_from_thread(update_ui)

        success, msg = patcher_engine.run_patch(cfg, log_cb, prog_cb)
        self.patch_success = success
        self.patch_in_progress = False

        def finalize_ui():
            try:
                pbar = self.query_one("#progress-bar", ProgressBar)
                status_lbl = self.query_one("#status-label", Label)
                btn_install = self.query_one("#btn-install", Button)

                if success:
                    pbar.update(progress=100)
                    status_lbl.update("Status: [bold #00ff7f]✓ Patching Succeeded![/]")
                    btn_install.disabled = False
                    self.app.push_screen(MessageDialog("Success", "Patching completed successfully! Click 'Install & Finalize' to install or export."))
                else:
                    status_lbl.update(f"Status: [bold #ff4444]✗ Patching Failed![/]")
                    self.app.push_screen(MessageDialog("Patching Failed", msg))
            except Exception:
                pass

        self.app.call_from_thread(finalize_ui)

    def on_button_pressed(self, event: Button.Pressed) -> None:
        btn_id = event.button.id
        if btn_id == "btn-install":
            self.action_install()
        elif btn_id == "btn-share":
            self.action_share_logs()
        elif btn_id == "btn-menu":
            self.action_main_menu()

    def action_install(self) -> None:
        """Trigger installer."""
        if not self.output_apk or not self.output_apk.exists():
            self.app.push_screen(MessageDialog("Error", "Patched APK file not found!"))
            return

        app_info = getattr(self.app, "selected_app", {})
        app_name = app_info.get("appName", "")
        app_ver = app_info.get("version", "1.0")
        pkg_name = app_info.get("pkgName", "")
        source_name = config.get("SOURCE", "Anddea")

        has_root, has_rish, _ = env.check_privileges()

        modal = ProgressModal("Installing APK", "Finalizing, signing, and installing APK...")
        self.app.push_screen(modal)
        self.run_install_worker(modal, app_name, pkg_name, app_ver, source_name, has_root, has_rish)

    @work(thread=True)
    def run_install_worker(
        self,
        modal: ProgressModal,
        app_name: str,
        pkg_name: str,
        app_ver: str,
        source_name: str,
        has_root: bool,
        has_rish: bool,
    ) -> None:
        try:
            ok, msg = app_installer.install_or_export(
                self.output_apk,
                app_name,
                pkg_name,
                app_ver,
                source_name,
                has_root,
                has_rish,
                progress_callback=lambda m: modal.update_message(m),
            )
            self.app.call_from_thread(modal.dismiss, None)
            if ok:
                self.app.call_from_thread(
                    self.app.push_screen,
                    MessageDialog("Installation Result", msg)
                )
            else:
                self.app.call_from_thread(
                    self.app.push_screen,
                    MessageDialog("Installation Error", msg)
                )
        except Exception as e:
            self.app.call_from_thread(modal.dismiss, None)
            self.app.call_from_thread(
                self.app.push_screen,
                MessageDialog("Error", f"Installation error: {e}")
            )

    def action_share_logs(self) -> None:
        """Share patch_log.txt using termux-open if available."""
        log_file = env.storage_dir / "patch_log.txt"
        if log_file.exists() and shutil.which("termux-open"):
            subprocess.run(["termux-open", "--send", str(log_file)], capture_output=True)
            self.app.push_screen(MessageDialog("Share Logs", "Opened share menu with patch logs."))
        elif log_file.exists():
            self.app.push_screen(MessageDialog("Log Path", f"Logs saved at:\n{log_file}"))
        else:
            self.app.push_screen(MessageDialog("Error", "No log file found!"))

    def action_main_menu(self) -> None:
        while len(self.app.screen_stack) > 1:
            self.app.pop_screen()
