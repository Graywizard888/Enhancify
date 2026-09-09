"""
Enhancify Special Features Module
Handles Dependency downloading (GmsCore / PotHelper), Bundle Patcher,
Keystore Generation/Management, Storage Cleanups, Stock App Backups,
and Specifications/Changelog.
"""

import json
import os
import re
import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple

import requests

from src.config import config
from src.environment import env
import threading

from src.utils import DownloadResult, download_file, download_file_ex, format_size, run_command


USER_AGENT_GITHUB = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Mobile Safari/537.36 EdgA/142.0.0.0"

# Matches bash: $STORAGE/Dependencies
DEPENDENCIES_SUBDIR = "Dependencies"
POTHELPER_REPO = "MorpheApp/PotHelper"


def _github_headers() -> Dict[str, str]:
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": USER_AGENT_GITHUB,
        "X-GitHub-Api-Version": "2022-11-28",
    }
    tok = config.get_github_token()
    if tok:
        headers["Authorization"] = f"Bearer {tok}"
    return headers


def _normalize_release_payload(data: Any) -> Optional[Dict[str, Any]]:
    """Pick the newest release object whether API returned a list or a single object."""
    if isinstance(data, list):
        if not data:
            return None
        return data[0] if isinstance(data[0], dict) else None
    if isinstance(data, dict):
        return data
    return None


def _first_apk_asset(release: Dict[str, Any]) -> Optional[Tuple[str, int, str]]:
    """Return (download_url, size, asset_name) for the first .apk asset."""
    for asset in release.get("assets") or []:
        if not isinstance(asset, dict):
            continue
        name = asset.get("name") or ""
        if name.endswith(".apk"):
            url = asset.get("browser_download_url") or ""
            size = int(asset.get("size") or 0)
            if url and size > 0:
                return url, size, name
    return None


def _dependencies_dir(workspace_dir: Optional[Path] = None) -> Path:
    """Resolve $STORAGE/Dependencies (bash parity)."""
    if workspace_dir is not None:
        path = workspace_dir / "storage" / DEPENDENCIES_SUBDIR
    else:
        path = env.storage_dir / DEPENDENCIES_SUBDIR
    path.mkdir(parents=True, exist_ok=True)
    return path


def _fetch_repo_release(repo: str) -> Optional[Dict[str, Any]]:
    """Fetch releases list for a GitHub repo and return normalized first release + apk asset info."""
    url = f"https://api.github.com/repos/{repo}/releases"
    try:
        r = requests.get(url, headers=_github_headers(), timeout=12)
        if r.status_code != 200:
            return None
        release = _normalize_release_payload(r.json())
        if not release:
            return None

        tag_name = release.get("tag_name") or ""
        if not tag_name:
            return None

        asset = _first_apk_asset(release)
        if not asset:
            return None

        apk_url, apk_size, apk_name = asset
        body = release.get("body") or "No changelog provided."
        clean_tag = re.sub(r"[^a-zA-Z0-9._-]", "", tag_name)

        return {
            "tag": clean_tag,
            "raw_tag": tag_name,
            "url": apk_url,
            "size": apk_size,
            "changelog": body,
            "asset_name": apk_name,
        }
    except Exception:
        return None


# ==========================================
# 1. GmsCore (MicroG) Downloader
# ==========================================

@dataclass
class GmsCoreProvider:
    id: str
    name: str
    repo: str
    recommended: bool = False


GMSCORE_PROVIDERS = [
    GmsCoreProvider("1", "Wst_Xda (Recommended)", "MorpheApp/MicroG-RE", True),
    GmsCoreProvider("2", "ReVanced", "ReVanced/GmsCore", False),
    GmsCoreProvider("3", "Rex", "YT-Advanced/GmsCore", False),
]


class GmsCoreManager:
    """Manages fetching and downloading GmsCore (MicroG) APKs into $STORAGE/Dependencies."""

    def __init__(self, workspace_dir: Optional[Path] = None):
        self.workspace_dir = workspace_dir or Path(__file__).resolve().parent.parent
        self.storage_dir = _dependencies_dir(workspace_dir if workspace_dir else None)

    def fetch_provider_release(self, provider: GmsCoreProvider) -> Optional[Dict[str, Any]]:
        """Fetch newest release info, APK download URL, and changelog for a GmsCore provider."""
        raw = _fetch_repo_release(provider.repo)
        if not raw:
            return None

        provider_label = provider.name.split()[0]
        # Match bash: ${provider}-${clean_tag}.apk
        target_filename = f"{provider_label}-{raw['tag']}.apk"
        target_path = self.storage_dir / target_filename

        return {
            "kind": "gmscore",
            "provider": provider_label,
            "provider_full": provider.name,
            "tag": raw["tag"],
            "url": raw["url"],
            "size": raw["size"],
            "changelog": raw["changelog"],
            "filename": target_filename,
            "target_path": target_path,
            "is_downloaded": target_path.exists() and target_path.stat().st_size == raw["size"],
        }

    def download_gmscore(
        self,
        info: Dict[str, Any],
        progress_callback: Optional[Callable[[int, int, str], None]] = None,
        cancel_event: Optional[threading.Event] = None,
    ) -> DownloadResult:
        """Download GmsCore APK to $STORAGE/Dependencies/."""
        target_path: Path = info["target_path"]
        target_path.parent.mkdir(parents=True, exist_ok=True)
        # Remove previous builds for the same provider (bash: rm provider-*.apk)
        provider = info.get("provider")
        if provider:
            for old in target_path.parent.glob(f"{provider}-*.apk"):
                if old != target_path:
                    old.unlink(missing_ok=True)
        return download_file_ex(
            info["url"], target_path, info["size"], progress_callback, cancel_event=cancel_event
        )


# ==========================================
# 1b. PotHelper Downloader
# ==========================================

class PotHelperManager:
    """Manages fetching and downloading PotHelper APK into $STORAGE/Dependencies."""

    REPO = POTHELPER_REPO

    def __init__(self, workspace_dir: Optional[Path] = None):
        self.workspace_dir = workspace_dir or Path(__file__).resolve().parent.parent
        self.storage_dir = _dependencies_dir(workspace_dir if workspace_dir else None)

    def fetch_release(self) -> Optional[Dict[str, Any]]:
        """Fetch newest PotHelper release info and APK asset."""
        raw = _fetch_repo_release(self.REPO)
        if not raw:
            return None

        # Match bash: keep upstream asset filename
        target_filename = raw["asset_name"]
        target_path = self.storage_dir / target_filename

        return {
            "kind": "pothelper",
            "provider": "PotHelper",
            "provider_full": "PotHelper",
            "tag": raw["tag"],
            "url": raw["url"],
            "size": raw["size"],
            "changelog": raw["changelog"],
            "filename": target_filename,
            "target_path": target_path,
            "is_downloaded": target_path.exists() and target_path.stat().st_size == raw["size"],
        }

    def download(
        self,
        info: Dict[str, Any],
        progress_callback: Optional[Callable[[int, int, str], None]] = None,
        cancel_event: Optional[threading.Event] = None,
    ) -> DownloadResult:
        """Download PotHelper APK to $STORAGE/Dependencies/."""
        target_path: Path = info["target_path"]
        target_path.parent.mkdir(parents=True, exist_ok=True)
        # Match bash: rm pot-helper-*.apk before download
        for old in target_path.parent.glob("pot-helper-*.apk"):
            if old != target_path:
                old.unlink(missing_ok=True)
        return download_file_ex(
            info["url"], target_path, info["size"], progress_callback, cancel_event=cancel_event
        )


# ==========================================
# 2. Bundle Patcher Manager
# ==========================================

class BundlePatcherManager:
    """Manages custom bundle JSON URLs and sources."""

    def __init__(self, workspace_dir: Optional[Path] = None):
        self.workspace_dir = workspace_dir or Path(__file__).resolve().parent.parent
        self.sources_file = self.workspace_dir / "bundle_patcher_sources.json"
        self._ensure_file()

    def _ensure_file(self) -> None:
        if not self.sources_file.exists():
            self.sources_file.write_text("{}\n", encoding="utf-8")

    def get_bundle_sources(self) -> Dict[str, str]:
        """Read saved bundle sources."""
        try:
            return json.loads(self.sources_file.read_text(encoding="utf-8"))
        except Exception:
            return {}

    def save_bundle_source(self, name: str, url: str) -> bool:
        """Save a new bundle source."""
        try:
            sources = self.get_bundle_sources()
            sources[name] = url
            self.sources_file.write_text(json.dumps(sources, indent=2), encoding="utf-8")
            return True
        except Exception:
            return False

    def validate_and_fetch_bundle_url(self, url: str) -> Tuple[bool, str, Optional[Dict[str, Any]]]:
        """Validate and fetch a bundle JSON from URL."""
        headers = {"User-Agent": USER_AGENT_GITHUB}
        try:
            r = requests.get(url, headers=headers, timeout=10)
            if r.status_code != 200:
                return False, f"HTTP Error {r.status_code}", None
            data = r.json()
            ver = data.get("version")
            dl_url = data.get("download_url")
            if not ver or not dl_url:
                return False, "JSON missing required 'version' or 'download_url' fields", None
            return True, "Bundle JSON is valid", data
        except Exception as e:
            return False, f"Failed to connect or parse JSON: {e}", None


# ==========================================
# 3. Custom Keystore Management
# ==========================================

class KeystoreManager:
    """Handles keytool generation and custom keystore storage."""

    def __init__(self, workspace_dir: Optional[Path] = None):
        self.workspace_dir = workspace_dir or Path(__file__).resolve().parent.parent
        self.keystore_dir = self.workspace_dir / "keystore"
        self.keystore_json = self.keystore_dir / "keystore.json"
        self.utils_dir = self.workspace_dir / "utils"
        self.keystore_dir.mkdir(parents=True, exist_ok=True)

    def has_keystore(self) -> bool:
        """Check if any custom keystore is present."""
        if not self.keystore_dir.exists():
            return False
        return any(self.keystore_dir.glob("*.p12")) or any(self.keystore_dir.glob("*.jks")) or \
               any(self.keystore_dir.glob("*.pfx")) or any(self.keystore_dir.glob("*.keystore")) or \
               any(self.keystore_dir.glob("*.uber")) or any(self.keystore_dir.glob("*.bks"))

    def get_keystores_list(self) -> List[Dict[str, Any]]:
        """List configured keystores."""
        if not self.keystore_json.exists():
            return []
        try:
            data = json.loads(self.keystore_json.read_text(encoding="utf-8"))
            return [{"filename": k, **v} for k, v in data.items()]
        except Exception:
            return []

    def generate_keystore(
        self,
        name: str,
        store_type: str,
        alias: str,
        keystore_pass: str,
        key_pass: str,
        validity_days: int = 10000,
        cn: str = "Unknown",
        ou: str = "Unknown",
        org: str = "Unknown",
        city: str = "Unknown",
        state: str = "Unknown",
        country: str = "US",
    ) -> Tuple[bool, str]:
        """Generate a new cryptographic keystore using Java keytool."""
        if not shutil.which("keytool"):
            return False, "Java 'keytool' utility not found!"

        ext_map = {"PKCS12": "p12", "JKS": "jks", "JCEKS": "jceks", "UBER": "uber", "BKS": "bks"}
        ext = ext_map.get(store_type.upper(), "p12")
        filename = f"{name}.{ext}"
        target_path = self.keystore_dir / filename

        # Clean existing
        if self.keystore_dir.exists():
            shutil.rmtree(self.keystore_dir, ignore_errors=True)
        self.keystore_dir.mkdir(parents=True, exist_ok=True)

        dname = f"CN={cn}, OU={ou}, O={org}, L={city}, ST={state}, C={country}"

        cmd = [
            "keytool",
            "-genkeypair",
            "-v",
            "-keystore",
            str(target_path),
            "-storetype",
            store_type.upper(),
            "-alias",
            alias,
            "-keyalg",
            "RSA",
            "-keysize",
            "2048",
            "-sigalg",
            "SHA512withRSA",
            "-validity",
            str(validity_days),
            "-storepass",
            keystore_pass,
            "-keypass",
            key_pass,
            "-dname",
            dname,
        ]

        if store_type.upper() in ("UBER", "BKS"):
            bc_jar = next(self.utils_dir.glob("bcprov*.jar"), None)
            if not bc_jar:
                return False, "Bouncy Castle provider JAR not found in utils directory!"
            cmd.extend([
                "-providerclass",
                "org.bouncycastle.jce.provider.BouncyCastleProvider",
                "-providerpath",
                str(bc_jar),
            ])

        code, out, err = run_command(cmd, timeout=30)
        if code != 0 or not target_path.exists():
            return False, f"Keystore generation failed: {err or out}"

        # Write keystore.json
        meta = {
            filename: {
                "alias": alias,
                "keystore_password": keystore_pass,
                "private_key_password": key_pass,
                "keystore_type": store_type.upper(),
            }
        }
        self.keystore_json.write_text(json.dumps(meta, indent=2), encoding="utf-8")
        return True, f"Keystore '{filename}' generated successfully!"

    def import_keystore_file(
        self,
        src_path: Path,
        alias: str,
        keystore_pass: str,
        key_pass: str,
        store_type: str = "PKCS12",
    ) -> Tuple[bool, str]:
        """Import an existing keystore file."""
        if not src_path.exists():
            return False, "Source keystore file does not exist."

        # Clean existing
        if self.keystore_dir.exists():
            shutil.rmtree(self.keystore_dir, ignore_errors=True)
        self.keystore_dir.mkdir(parents=True, exist_ok=True)

        target_path = self.keystore_dir / src_path.name
        shutil.copy2(src_path, target_path)

        meta = {
            src_path.name: {
                "alias": alias,
                "keystore_password": keystore_pass,
                "private_key_password": key_pass,
                "keystore_type": store_type.upper(),
            }
        }
        self.keystore_json.write_text(json.dumps(meta, indent=2), encoding="utf-8")
        return True, f"Keystore '{src_path.name}' imported successfully!"

    def delete_keystores(self) -> bool:
        """Delete all keystores."""
        if self.keystore_dir.exists():
            shutil.rmtree(self.keystore_dir, ignore_errors=True)
        self.keystore_dir.mkdir(parents=True, exist_ok=True)
        return True


# ==========================================
# 4. Storage & Backup Operations
# ==========================================

class StorageOperations:
    """Handles deletion of apps, assets, and backing up stock apps."""

    def __init__(self, workspace_dir: Optional[Path] = None):
        self.workspace_dir = workspace_dir or Path(__file__).resolve().parent.parent
        self.apps_dir = self.workspace_dir / "apps"
        self.assets_dir = self.workspace_dir / "assets"
        self.storage_dir = (self.workspace_dir / "storage") if workspace_dir else env.storage_dir
        self.patched_dir = self.storage_dir / "Patched"
        self.stock_backup_dir = self.storage_dir / "Stock"

    def delete_patched_apks(self) -> int:
        """Delete all patched APKs in internal storage."""
        count = 0
        if self.patched_dir.exists():
            for f in self.patched_dir.glob("*.apk"):
                f.unlink(missing_ok=True)
                count += 1
        return count

    def delete_workspace_apps(self) -> int:
        """Delete all downloaded/imported apps in workspace apps/ directory."""
        count = 0
        if self.apps_dir.exists():
            for item in self.apps_dir.iterdir():
                if item.is_dir():
                    shutil.rmtree(item, ignore_errors=True)
                    count += 1
                elif item.is_file():
                    item.unlink(missing_ok=True)
                    count += 1
        return count

    def backup_stock_apps(self) -> Tuple[int, str]:
        """Backup all stock APKs from apps/ to $STORAGE/Stock/."""
        if not self.apps_dir.exists():
            return 0, "No downloaded apps found in workspace."

        apks = list(self.apps_dir.glob("*/*.apk"))
        if not apks:
            return 0, "No stock APK files found to backup."

        self.stock_backup_dir.mkdir(parents=True, exist_ok=True)
        copied = 0
        for apk in apks:
            try:
                shutil.copy2(apk, self.stock_backup_dir / apk.name)
                copied += 1
            except Exception:
                pass

        return copied, f"Successfully backed up {copied} apps to:\n{self.stock_backup_dir}"

    def auto_upgrade_dependencies(self) -> Tuple[bool, str]:
        """Check and upgrade Termux dependency packages."""
        if not shutil.which("pkg"):
            return False, "Not running in Termux (pkg package manager not available)."

        target_pkgs = ["wget", "ncurses-utils", "dialog", "pup", "jq", "aria2", "unzip", "zip", "python"]
        code, _, _ = run_command(["pkg", "update", "-y"], timeout=60)
        code2, out, _ = run_command(["apt", "list", "--upgradable"], timeout=30)

        upgradable = [p.split("/")[0] for p in out.splitlines() if "/" in p]
        to_upgrade = [p for p in target_pkgs if p in upgradable]

        if not to_upgrade:
            return True, "All Enhancify dependency packages are already up to date!"

        code3, _, _ = run_command(["pkg", "install", "-y"] + to_upgrade, timeout=120)
        if code3 == 0:
            return True, f"Successfully upgraded packages: {', '.join(to_upgrade)}"
        return False, "Failed to upgrade packages. Check internet connection."


# Global feature manager instances
gmscore_mgr = GmsCoreManager()
pothelper_mgr = PotHelperManager()
bundle_mgr = BundlePatcherManager()
keystore_mgr = KeystoreManager()
storage_ops = StorageOperations()
