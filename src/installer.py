"""
Enhancify App Installer & Mounting Engine
Handles zipalign, custom keystore signing with apksigner / BouncyCastle,
Root mount/umount scripts, Rish privilege installs with Dex Optimizer,
and Non-privilege export to $STORAGE/Patched/.
"""

import json
import os
import re
import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Optional, Tuple

from src.config import config
from src.environment import env
from src.utils import run_command


class AppInstaller:
    """Handles APK realignment, signing, and installation across privilege modes."""

    def __init__(self, workspace_dir: Optional[Path] = None):
        self.workspace_dir = workspace_dir or Path(__file__).resolve().parent.parent
        self.utils_dir = self.workspace_dir / "utils"
        self.system_dir = self.workspace_dir / "system"
        self.storage_dir = (self.workspace_dir / "storage") if workspace_dir else env.storage_dir
        self.zipalign_bin = self.utils_dir / "zipalign"
        self.keystore_dir = self.workspace_dir / "keystore"

    # --- Zipalign ---

    def realign_apk(self, apk_path: Path, progress_callback: Optional[Callable[[str], None]] = None) -> bool:
        """Align APK on 4-byte boundaries with 16-page alignment using zipalign."""
        if not self.zipalign_bin.exists():
            return False

        if not os.access(self.zipalign_bin, os.X_OK):
            try:
                self.zipalign_bin.chmod(0o755)
            except Exception:
                pass

        if progress_callback:
            progress_callback("Realigning APK on 4-byte boundaries...")

        aligned_tmp = apk_path.parent / f"{apk_path.stem}_aligned.apk"
        cmd = [str(self.zipalign_bin), "-f", "-P", "16", "4", str(apk_path), str(aligned_tmp)]
        code, out, err = run_command(cmd, timeout=30)

        if code == 0 and aligned_tmp.exists():
            shutil.move(str(aligned_tmp), str(apk_path))
            return True
        aligned_tmp.unlink(missing_ok=True)
        return False

    # --- Custom Keystore Signing ---

    def sign_with_custom_keystore(
        self,
        apk_path: Path,
        progress_callback: Optional[Callable[[str], None]] = None,
    ) -> Tuple[bool, str]:
        """Sign APK using custom keystore, apksigner.jar, and Bouncy Castle."""
        keystore_json = self.keystore_dir / "keystore.json"
        if not self.keystore_dir.exists() or not keystore_json.exists():
            return False, "Custom keystore configuration not found!"

        # Find keystore file
        ks_files = list(self.keystore_dir.glob("*.p12")) + list(self.keystore_dir.glob("*.jks")) + \
                   list(self.keystore_dir.glob("*.pfx")) + list(self.keystore_dir.glob("*.keystore")) + \
                   list(self.keystore_dir.glob("*.jceks")) + list(self.keystore_dir.glob("*.uber")) + \
                   list(self.keystore_dir.glob("*.bks"))

        if not ks_files:
            return False, "No keystore file found in keystore directory!"

        ks_file = ks_files[0]
        try:
            ks_meta = json.loads(keystore_json.read_text(encoding="utf-8"))
            ks_info = ks_meta.get(ks_file.name, {})
        except Exception:
            return False, "Failed to read keystore.json metadata!"

        alias = ks_info.get("alias", "")
        ks_pass = ks_info.get("keystore_password", "")
        key_pass = ks_info.get("private_key_password", ks_pass)
        ks_type = ks_info.get("keystore_type", "PKCS12")

        if not alias or not ks_pass:
            return False, "Keystore alias or password missing in keystore.json!"

        apksigner_jar = next(self.utils_dir.glob("apksigner*.jar"), None)
        bc_jar = next(self.utils_dir.glob("bcprov*.jar"), None)

        if not apksigner_jar or not apksigner_jar.exists():
            return False, "apksigner.jar not found in utils directory!"

        if progress_callback:
            progress_callback(f"Signing APK with {ks_type} keystore ({ks_file.name})...")

        # Create temporary password files for apksigner
        with tempfile.NamedTemporaryFile(mode="w", delete=False) as f_kspass, \
             tempfile.NamedTemporaryFile(mode="w", delete=False) as f_keypass:
            f_kspass.write(ks_pass)
            f_keypass.write(key_pass)
            p_kspass = Path(f_kspass.name)
            p_keypass = Path(f_keypass.name)

        try:
            signed_out = apk_path.parent / f"{apk_path.stem}_signed.apk"

            if ks_type in ("UBER", "BKS"):
                if not bc_jar or not bc_jar.exists():
                    return False, f"Bouncy Castle provider JAR required for {ks_type} keystores!"

                cmd = [
                    "java",
                    "--enable-native-access=ALL-UNNAMED",
                    "-Xms100m",
                    "-Xmx512m",
                    "-cp",
                    f"{apksigner_jar}:{bc_jar}",
                    "com.android.apksigner.ApkSignerTool",
                    "sign",
                    "--provider-class",
                    "org.bouncycastle.jce.provider.BouncyCastleProvider",
                    "--provider-pos",
                    "1",
                    "--ks",
                    str(ks_file),
                    "--ks-pass",
                    f"file:{p_kspass}",
                    "--key-pass",
                    f"file:{p_keypass}",
                    "--ks-type",
                    ks_type,
                    "--ks-key-alias",
                    alias,
                    "--v1-signing-enabled",
                    "true",
                    "--v2-signing-enabled",
                    "true",
                    "--v3-signing-enabled",
                    "true",
                    "--v4-signing-enabled",
                    "false",
                    "--out",
                    str(signed_out),
                    str(apk_path),
                ]
            else:
                cmd = [
                    "java",
                    "--enable-native-access=ALL-UNNAMED",
                    "-Xms100m",
                    "-Xmx512m",
                    "-jar",
                    str(apksigner_jar),
                    "sign",
                    "--ks",
                    str(ks_file),
                    "--ks-pass",
                    f"file:{p_kspass}",
                    "--key-pass",
                    f"file:{p_keypass}",
                    "--ks-type",
                    ks_type,
                    "--ks-key-alias",
                    alias,
                    "--v1-signing-enabled",
                    "true",
                    "--v2-signing-enabled",
                    "true",
                    "--v3-signing-enabled",
                    "true",
                    "--v4-signing-enabled",
                    "false",
                    "--out",
                    str(signed_out),
                    str(apk_path),
                ]

            code, out, err = run_command(cmd, timeout=30)
            if code == 0 and signed_out.exists():
                shutil.move(str(signed_out), str(apk_path))
                return True, "APK signed successfully with custom keystore!"
            else:
                return False, f"Signing failed: {out}\n{err}"
        finally:
            p_kspass.unlink(missing_ok=True)
            p_keypass.unlink(missing_ok=True)

    # --- Mode-Specific Installation ---

    def run_dex_optimization(self, pkg_name: str, install_type: str = "new") -> bool:
        """Run dex optimization via Rish."""
        profile_mode = "speed" if install_type == "update" else "quicken"
        force_flag = "-f" if install_type == "update" else ""
        cmd = ["rish", "-c", f"cmd package compile -m {profile_mode} {force_flag} {pkg_name}"]
        code, out, _ = run_command(cmd, timeout=30)
        return code == 0

    def install_or_export(
        self,
        apk_path: Path,
        app_name: str,
        pkg_name: str,
        app_ver: str,
        source_name: str,
        has_root: bool,
        has_rish: bool,
        progress_callback: Optional[Callable[[str], None]] = None,
    ) -> Tuple[bool, str]:
        """Finalize APK, realign, sign, and install/export according to privilege level."""
        # 1. Realign APK if custom keystore is used
        if config.is_on("Use_CUSTOM_KEYSTORE"):
            self.realign_apk(apk_path, progress_callback)
            ok, msg = self.sign_with_custom_keystore(apk_path, progress_callback)
            if not ok:
                return False, f"Signing failed: {msg}"

        # 2. Root Mode Mount
        if has_root:
            if progress_callback:
                progress_callback("Mounting patched APK via Root...")

            mount_script = self.system_dir / "mount.sh"
            if mount_script.exists():
                cmd = ["su", "-mm", "-c", f"/system/bin/sh {mount_script} {pkg_name} {app_name} {app_ver} {source_name}"]
                code, out, err = run_command(cmd, timeout=30)
                if code == 0:
                    if config.is_on("LAUNCH_APP_AFTER_MOUNT"):
                        launch_cmd = f"settings list secure | sed -n -e 's/\\/.*//' -e 's/default_input_method=//p' | xargs pidof | xargs kill -9 && pm resolve-activity --brief {pkg_name} | tail -n 1 | xargs am start -n"
                        subprocess.run(["su", "-c", launch_cmd], capture_output=True)
                    return True, f"{app_name} mounted successfully via Root!"
                return False, f"Root mounting failed: {err or out}"
            return False, "mount.sh script not found!"

        # 3. Rish Mode Installation
        elif has_rish:
            if progress_callback:
                progress_callback("Installing patched APK via Rish...")

            canonical_ver = app_ver.replace(":", "")
            exported_name = f"{app_name}-{canonical_ver}-{source_name}"
            target_storage_apk = self.storage_dir / "Patched" / f"{exported_name}.apk"
            target_storage_apk.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(apk_path, target_storage_apk)

            rish_script = self.system_dir / "rish-install.sh"
            if rish_script.exists():
                cmd = ["bash", str(rish_script), pkg_name, app_name, exported_name, str(self.storage_dir), "new"]
                code, out, err = run_command(cmd, timeout=60)
                if code == 0:
                    # Run DEX Optimization
                    if progress_callback:
                        progress_callback("Running DEX Optimization via Rish...")
                    self.run_dex_optimization(pkg_name, "new")

                    if config.is_on("LAUNCH_APP_AFTER_MOUNT"):
                        launch_cmd = f"pm resolve-activity --brief {pkg_name} | tail -n 1 | xargs am start -n"
                        subprocess.run(["rish", "-c", launch_cmd], capture_output=True)
                    return True, f"{app_name} installed successfully via Rish with Dex Optimization!"
                return False, f"Rish installation failed: {err or out}"
            return False, "rish-install.sh script not found!"

        # 4. Non-Privilege Mode (Copy to Internal Storage)
        else:
            if progress_callback:
                progress_callback("Exporting patched APK to Internal Storage...")

            canonical_ver = app_ver.replace(":", "")
            exported_name = f"{app_name}-{canonical_ver}-{source_name}.apk"
            target_storage_apk = self.storage_dir / "Patched" / exported_name
            target_storage_apk.parent.mkdir(parents=True, exist_ok=True)

            try:
                shutil.copy2(apk_path, target_storage_apk)
                # Try opening with termux-open
                if shutil.which("termux-open"):
                    subprocess.run(["termux-open", "--view", str(target_storage_apk)], capture_output=True)
                return True, f"Patched APK exported to:\n{target_storage_apk}"
            except Exception as e:
                return False, f"Failed to export APK: {e}"


# Global installer instance
app_installer = AppInstaller()
