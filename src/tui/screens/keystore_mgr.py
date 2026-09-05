"""
Enhancify Keystore Management Screen
Allows generating cryptographic signing keystores (PKCS12, JKS, JCEKS, UBER) using keytool,
importing existing keystores from storage, and deleting keys.
"""

from pathlib import Path
from typing import Optional

from rich.text import Text
from textual.app import ComposeResult
from textual.containers import Container, Horizontal, ScrollableContainer, Vertical
from textual.screen import Screen
from textual.widgets import Button, Footer, Label, ListItem, ListView

from src.environment import env
from src.features import keystore_mgr
from src.tui.screens.file_picker import FilePickerScreen
from src.tui.widgets.dialogs import ConfirmDialog, InputDialog, MessageDialog
from src.tui.widgets.header import CyberHeader


class KeystoreManagerScreen(Screen):
    """Keystore generation and management screen."""

    BINDINGS = [
        ("g", "action_generate", "Generate Keystore"),
        ("i", "action_import", "Import Keystore"),
        ("d", "action_delete", "Delete Keystore"),
        ("b", "action_back", "Back"),
        ("escape", "action_back", "Back"),
    ]

    def compose(self) -> ComposeResult:
        has_root, has_rish, mode_label = env.check_privileges()
        _, _, net_status = env.check_network()

        yield CyberHeader(mode_label=mode_label, online_status=net_status)

        with ScrollableContainer(classes="container-box"):
            with Vertical(classes="card"):
                yield Label("🔑 Custom Keystore Management", classes="card-title")
                yield Label("Generate or import custom cryptographic keystores for signing patched APKs:", classes="card-desc")

                with Horizontal():
                    yield Button("⚡ Generate Keystore [G]", id="btn-gen", classes="btn-primary")
                    yield Button("📥 Import File [I]", id="btn-import")
                    yield Button("🗑️ Delete All [D]", id="btn-delete", classes="btn-danger")
                    yield Button("🔙 Back [B]", id="btn-back", classes="btn-secondary")

                yield ListView(id="keystores-list")

        yield Footer()

    def on_mount(self) -> None:
        self.populate_keystores()

    def populate_keystores(self) -> None:
        """Populate ListView with configured keystores."""
        k_list = self.query_one("#keystores-list", ListView)
        k_list.clear()

        ks_list = keystore_mgr.get_keystores_list()
        if not ks_list:
            k_list.append(ListItem(Label(Text("No custom keystore configured. Click 'Generate' or 'Import' above.", style="dim"))))
            return

        for idx, ks in enumerate(ks_list):
            fname = ks.get("filename", "keystore")
            alias = ks.get("alias", "")
            ks_type = ks.get("keystore_type", "PKCS12")

            txt = Text()
            txt.append("🔑 ", style="bold #ffd700")
            txt.append(f"{fname:<25}", style="bold #ffffff")
            txt.append(f" [Type: {ks_type}]", style="#00e5ff")
            txt.append(f" (Alias: {alias})", style="#00ff7f")

            item = ListItem(Label(txt), id=f"ks-{idx}")
            k_list.append(item)

    def on_button_pressed(self, event: Button.Pressed) -> None:
        btn_id = event.button.id
        if btn_id == "btn-gen":
            self.action_generate()
        elif btn_id == "btn-import":
            self.action_import()
        elif btn_id == "btn-delete":
            self.action_delete()
        elif btn_id == "btn-back":
            self.action_back()

    def action_generate(self) -> None:
        """Sequential dialogs to generate new keystore."""
        def step1_name(name_res: Optional[str]) -> None:
            if not name_res or not name_res.strip():
                return
            ks_name = name_res.strip()

            def step2_alias(alias_res: Optional[str]) -> None:
                if not alias_res or not alias_res.strip():
                    return
                alias_name = alias_res.strip()

                def step3_pass(pass_res: Optional[str]) -> None:
                    if not pass_res or len(pass_res.strip()) < 4:
                        self.app.push_screen(MessageDialog("Error", "Password must be at least 4 characters!"))
                        return
                    ks_pass = pass_res.strip()

                    ok, msg = keystore_mgr.generate_keystore(
                        name=ks_name,
                        store_type="PKCS12",
                        alias=alias_name,
                        keystore_pass=ks_pass,
                        key_pass=ks_pass,
                    )
                    self.populate_keystores()
                    self.app.push_screen(MessageDialog("Generation Result", msg))

                self.app.push_screen(
                    InputDialog("Keystore Password", "Enter password for keystore & private key (min 4 chars):", password=True),
                    step3_pass,
                )

            self.app.push_screen(
                InputDialog("Key Alias", "Enter alias name for keypair:", initial_value="enhancify"),
                step2_alias,
            )

        self.app.push_screen(
            InputDialog("Keystore Name", "Enter file name for keystore (e.g. my_keystore):", initial_value="custom_keystore"),
            step1_name,
        )

    def action_import(self) -> None:
        """Import keystore via file picker."""
        allowed = {".p12", ".jks", ".pfx", ".keystore", ".jceks", ".uber", ".bks"}

        def handle_file(file_path: Optional[Path]) -> None:
            if not file_path:
                return

            def step_alias(alias_res: Optional[str]) -> None:
                if not alias_res:
                    return
                alias_name = alias_res.strip()

                def step_pass(pass_res: Optional[str]) -> None:
                    if not pass_res:
                        return
                    ks_pass = pass_res.strip()

                    ok, msg = keystore_mgr.import_keystore_file(
                        src_path=file_path,
                        alias=alias_name,
                        keystore_pass=ks_pass,
                        key_pass=ks_pass,
                    )
                    self.populate_keystores()
                    self.app.push_screen(MessageDialog("Import Result", msg))

                self.app.push_screen(
                    InputDialog("Keystore Password", "Enter password for imported keystore:", password=True),
                    step_pass,
                )

            self.app.push_screen(
                InputDialog("Keystore Alias", "Enter alias for imported keystore:"),
                step_alias,
            )

        self.app.push_screen(FilePickerScreen(allowed_exts=allowed), handle_file)

    def action_delete(self) -> None:
        def handle_confirm(yes: bool) -> None:
            if yes:
                keystore_mgr.delete_keystores()
                self.populate_keystores()
                self.app.push_screen(MessageDialog("Deleted", "All custom keystores removed."))

        self.app.push_screen(
            ConfirmDialog(
                "Confirm Deletion",
                "Are you sure you want to delete all imported and generated keystores?",
                yes_label="Delete",
                no_label="Cancel",
            ),
            handle_confirm,
        )

    def action_back(self) -> None:
        self.app.pop_screen()
