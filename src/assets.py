"""
Enhancify Assets Management Module
Handles CLI and Patches download, version resolution, CLI argument detection,
Patches JSON parsing (via API or CLI list-patches/list-versions), and CLI caching.
"""

import json
import os
import re
import shutil
import subprocess
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple

import requests

from src.config import config
from src.environment import env
from src.sources import SourceInfo, sources_mgr
from src.utils import download_file, format_size, run_command


USER_AGENT = "APKUpdater-3.0.3"
USER_AGENT_GITHUB = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Mobile Safari/537.36 EdgA/142.0.0.0"


@dataclass
class AssetReleaseInfo:
    source_name: str
    patches_version: str
    patches_ext: str
    patches_url: str
    patches_size: int
    cli_version: str
    cli_url: str
    cli_size: int
    json_url: str = ""
    changelog: str = ""
    extra_assets: Dict[str, Tuple[str, int]] = field(default_factory=dict)


class AssetsManager:
    """Manages CLI jars, Patches bundles, and patches metadata."""

    def __init__(self, workspace_dir: Optional[Path] = None):
        self.workspace_dir = workspace_dir or Path(__file__).resolve().parent.parent
        self.assets_dir = self.workspace_dir / "assets"
        self.cli_cache_dir = self.workspace_dir / "cli_cache"
        self.storage_dir = env.storage_dir
        self._ensure_dirs()

    def _ensure_dirs(self) -> None:
        self.assets_dir.mkdir(parents=True, exist_ok=True)
        self.cli_cache_dir.mkdir(parents=True, exist_ok=True)
        self.storage_dir.mkdir(parents=True, exist_ok=True)

    def _get_github_headers(self) -> Dict[str, str]:
        headers = {
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": USER_AGENT_GITHUB,
        }
        tok = config.get_github_token()
        if tok:
            headers["Authorization"] = f"Bearer {tok}"
        return headers

    def get_patches_extension(self, source_name: str) -> str:
        """Determine file extension (.jar, .rvp, or .mpp)."""
        if source_name == "ReVanced":
            return "rvp"
        if source_name in ("hoo-dles", "MorpheApp", "brossh", "Doom-Patches"):
            return "mpp"
        return "jar"

    def resolve_cli_repo(self, patches_ext: str, source_name: str) -> str:
        """Determine which CLI repo to use based on patch extension and source."""
        if source_name == "ReVanced":
            return "ReVanced/revanced-cli"
        if patches_ext == "rvp":
            return "inotia00/revanced-cli"
        return "MorpheApp/morphe-cli"

    # --- CLI Caching ---

    def get_cached_cli(self, source_name: str, expected_version: str, target_file: Path) -> bool:
        """Check if CLI is in cache when CACHE_CLI is enabled."""
        if not config.is_on("CACHE_CLI"):
            return False

        cache_dir = self.cli_cache_dir / source_name
        cache_json = cache_dir / "cache.json"
        if not cache_json.exists():
            return False

        try:
            data = json.loads(cache_json.read_text(encoding="utf-8"))
            cached_ver = data.get("version")
            cached_file = cache_dir / data.get("filename", "")
            if cached_ver == expected_version and cached_file.exists() and cached_file.stat().st_size > 0:
                target_file.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(cached_file, target_file)
                return True
        except Exception:
            pass
        return False

    def save_cli_to_cache(self, source_name: str, version: str, downloaded_file: Path) -> None:
        """Save CLI to cache."""
        if not config.is_on("CACHE_CLI"):
            return

        cache_dir = self.cli_cache_dir / source_name
        cache_dir.mkdir(parents=True, exist_ok=True)
        filename = downloaded_file.name

        # Clean old CLI jars
        for old_jar in cache_dir.glob("CLI-*.jar"):
            if old_jar.name != filename:
                old_jar.unlink(missing_ok=True)

        cached_target = cache_dir / filename
        shutil.copy2(downloaded_file, cached_target)

        cache_json = cache_dir / "cache.json"
        cache_json.write_text(
            json.dumps({"version": version, "filename": filename}, indent=2),
            encoding="utf-8",
        )

    # --- Fetch Release Info ---

    def fetch_source_release_info(self, source_name: str) -> Optional[AssetReleaseInfo]:
        """Fetch patch and CLI release metadata from GitHub or custom API."""
        src_info = sources_mgr.get_source(source_name)
        if not src_info:
            return None

        headers = self._get_github_headers()
        use_prerelease = config.is_on("USE_PRE_RELEASE")

        # 1. Fetch Patches info
        repo = src_info.repository
        patches_api_url = (
            f"https://api.github.com/repos/{repo}/releases"
            if use_prerelease
            else f"https://api.github.com/repos/{repo}/releases/latest"
        )

        changelog = ""
        patches_ver = ""
        patches_url = ""
        patches_size = 0
        patches_ext = self.get_patches_extension(source_name)
        extra_assets = {}

        try:
            r = requests.get(patches_api_url, headers=headers, timeout=8)
            if r.status_code == 200:
                data = r.json()
                release_obj = data[0] if isinstance(data, list) else data
                patches_ver = release_obj.get("tag_name", "")
                changelog = release_obj.get("body", "")

                for asset in release_obj.get("assets", []):
                    name = asset.get("name", "")
                    dl_url = asset.get("browser_download_url", "")
                    sz = int(asset.get("size", 0))

                    if name.endswith(".asc") or name.endswith(".json") or any(x in name.lower() for x in ["sha256", "sha1", "md5", "checksum"]):
                        continue

                    # Detect actual extension if different
                    for ext_candidate in ["mpp", "rvp", "jar"]:
                        if name.endswith(f".{ext_candidate}"):
                            patches_ext = ext_candidate
                            patches_url = dl_url
                            patches_size = sz
                            break
                    else:
                        extra_assets[name] = (dl_url, sz)
            elif r.status_code == 404 and src_info.gitlab_id:
                # GitLab release
                gl_url = f"https://gitlab.com/api/v4/projects/{src_info.gitlab_id}/releases"
                gl_r = requests.get(gl_url, headers={"Accept": "application/json"}, timeout=8)
                if gl_r.status_code == 200:
                    gl_data = gl_r.json()
                    if gl_data and isinstance(gl_data, list):
                        patches_ver = gl_data[0].get("tag_name", "")
                        changelog = gl_data[0].get("description", "")
        except Exception:
            pass

        # 2. Fetch CLI info
        cli_repo = self.resolve_cli_repo(patches_ext, source_name)
        cli_api_url = (
            f"https://api.github.com/repos/{cli_repo}/releases"
            if use_prerelease
            else f"https://api.github.com/repos/{cli_repo}/releases/latest"
        )

        cli_ver = ""
        cli_url = ""
        cli_size = 0

        try:
            r_cli = requests.get(cli_api_url, headers=headers, timeout=8)
            if r_cli.status_code == 200:
                data_cli = r_cli.json()
                cli_obj = data_cli[0] if isinstance(data_cli, list) else data_cli
                cli_ver = cli_obj.get("tag_name", "")
                for asset in cli_obj.get("assets", []):
                    name = asset.get("name", "")
                    if name.endswith(".jar") and not name.endswith(".asc") and not name.endswith("-sources.jar"):
                        cli_url = asset.get("browser_download_url", "")
                        cli_size = int(asset.get("size", 0))
                        break
        except Exception:
            pass

        if not patches_ver or not cli_ver:
            return None

        # Write bash compatible .data files
        src_dir = self.assets_dir / source_name
        src_dir.mkdir(parents=True, exist_ok=True)
        data_lines = [
            f"PATCHES_VERSION='{patches_ver}'",
            f"PATCHES_EXT='{patches_ext}'",
            f"PATCHES_URL='{patches_url}'",
            f"PATCHES_SIZE='{patches_size}'",
        ]
        if src_info.json_url:
            data_lines.append(f"JSON_URL='{src_info.json_url}'")
        (src_dir / ".data").write_text("\n".join(data_lines) + "\n", encoding="utf-8")

        cli_data_lines = [
            f"CLI_VERSION='{cli_ver}'",
            f"CLI_URL='{cli_url}'",
            f"CLI_SIZE='{cli_size}'",
        ]
        (self.assets_dir / ".data").write_text("\n".join(cli_data_lines) + "\n", encoding="utf-8")

        return AssetReleaseInfo(
            source_name=source_name,
            patches_version=patches_ver,
            patches_ext=patches_ext,
            patches_url=patches_url,
            patches_size=patches_size,
            cli_version=cli_ver,
            cli_url=cli_url,
            cli_size=cli_size,
            json_url=src_info.json_url,
            changelog=changelog,
            extra_assets=extra_assets,
        )

    def download_assets(
        self,
        info: AssetReleaseInfo,
        progress_callback: Optional[Callable[[str, int, int, str], None]] = None,
    ) -> bool:
        """Download CLI and Patches binaries with progress tracking."""
        # Clean older versions
        src_dir = self.assets_dir / info.source_name
        src_dir.mkdir(parents=True, exist_ok=True)

        target_patches = src_dir / f"Patches-{info.patches_version}.{info.patches_ext}"
        target_cli = self.assets_dir / f"CLI-{info.cli_version}.jar"

        # 1. Check or download CLI
        cli_ok = False
        if target_cli.exists() and (info.cli_size <= 0 or target_cli.stat().st_size == info.cli_size):
            cli_ok = True
        elif self.get_cached_cli(info.source_name, info.cli_version, target_cli):
            cli_ok = True
        else:
            def cli_prog(cur, tot, pct):
                if progress_callback:
                    progress_callback(f"CLI-{info.cli_version}.jar", cur, tot, pct)

            if download_file(info.cli_url, target_cli, info.cli_size, cli_prog):
                self.save_cli_to_cache(info.source_name, info.cli_version, target_cli)
                cli_ok = True

        if not cli_ok:
            return False

        # 2. Check or download Patches
        patches_ok = False
        if target_patches.exists() and (info.patches_size <= 0 or target_patches.stat().st_size == info.patches_size):
            patches_ok = True
        else:
            def patch_prog(cur, tot, pct):
                if progress_callback:
                    progress_callback(f"Patches-{info.patches_version}.{info.patches_ext}", cur, tot, pct)

            if download_file(info.patches_url, target_patches, info.patches_size, patch_prog):
                patches_ok = True

        return patches_ok

    # --- CLI Capability Detection ---

    def detect_cli_capabilities(self, cli_jar: Path) -> Dict[str, bool]:
        """Detect supported arguments by invoking `java -jar <cli> patch --help`."""
        unsigned = False
        riplib = False
        striplibs = False

        if cli_jar.exists() and shutil.which("java"):
            code, out, err = run_command(["java", "-jar", str(cli_jar), "patch", "--help"], timeout=5)
            full_out = (out + "\n" + err).lower()
            if "--unsigned" in full_out:
                unsigned = True
            if "--rip-lib" in full_out:
                riplib = True
            if "--striplibs" in full_out:
                striplibs = True

        config.save_cli_capabilities(unsigned, riplib, striplibs)
        return {"unsigned": unsigned, "riplib": riplib, "striplibs": striplibs}

    # --- Patches JSON Parsing ---

    def parse_patches_json_from_api(self, json_url: str, target_file: Path) -> Optional[List[Dict[str, Any]]]:
        """Fetch and parse patches metadata from direct JSON URL."""
        try:
            r = requests.get(json_url, headers={"User-Agent": USER_AGENT_GITHUB}, timeout=10)
            if r.status_code != 200:
                return None
            data = r.json()
            patches_list = data if isinstance(data, list) else data.get("patches", [])
            if not patches_list:
                return None

            packages_map: Dict[Optional[str], Dict[str, Any]] = {}

            for p in patches_list:
                name = p.get("name", "")
                desc = p.get("description", "No description available").replace("\n", " ").strip()
                use = bool(p.get("use", p.get("default", True)))
                comp_pkgs = p.get("compatiblePackages", [])

                # Options parsing
                raw_options = p.get("options", [])
                parsed_options = []
                if raw_options:
                    for opt in raw_options:
                        opt_type = opt.get("type", "String")
                        if "List" in str(opt_type):
                            clean_type = "StringArray"
                        elif "Boolean" in str(opt_type):
                            clean_type = "Boolean"
                        elif any(x in str(opt_type) for x in ["Long", "Int", "Float", "Number"]):
                            clean_type = "Number"
                        else:
                            clean_type = "String"

                        parsed_options.append({
                            "patchName": name,
                            "key": opt.get("key", ""),
                            "title": opt.get("title", opt.get("name", opt.get("key", ""))),
                            "description": opt.get("description", ""),
                            "required": bool(opt.get("required", False)),
                            "default": opt.get("default"),
                            "type": clean_type,
                            "values": opt.get("values", []) or [],
                        })

                # Packages mapping
                targets: List[Tuple[Optional[str], List[str]]] = []
                if isinstance(comp_pkgs, dict):
                    for pkg_k, ver_v in comp_pkgs.items():
                        targets.append((pkg_k, ver_v if isinstance(ver_v, list) else []))
                elif isinstance(comp_pkgs, list):
                    for entry in comp_pkgs:
                        if isinstance(entry, dict):
                            pname = entry.get("packageName") or entry.get("name")
                            t_vers = entry.get("targets") or entry.get("versions") or []
                            v_clean = [v.get("version", v) if isinstance(v, dict) else v for v in t_vers if v]
                            targets.append((pname, v_clean))
                        elif isinstance(entry, str):
                            targets.append((entry, []))

                if not targets:
                    targets = [(None, [])]

                for pkg_name, versions in targets:
                    if pkg_name not in packages_map:
                        packages_map[pkg_name] = {
                            "pkgName": pkg_name,
                            "versions": [],
                            "patches": {"recommended": [], "optional": []},
                            "options": [],
                            "descriptions": {},
                        }

                    entry = packages_map[pkg_name]
                    # Merge versions
                    for v in versions:
                        if v and v not in entry["versions"] and v.lower() != "any":
                            entry["versions"].append(v)

                    # Add patch
                    if use:
                        if name not in entry["patches"]["recommended"]:
                            entry["patches"]["recommended"].append(name)
                    else:
                        if name not in entry["patches"]["optional"]:
                            entry["patches"]["optional"].append(name)

                    entry["descriptions"][name] = desc
                    entry["options"].extend(parsed_options)

            result_list = list(packages_map.values())
            target_file.parent.mkdir(parents=True, exist_ok=True)
            target_file.write_text(json.dumps(result_list, indent=2), encoding="utf-8")
            return result_list
        except Exception:
            return None

    def parse_patches_json_from_cli(
        self,
        cli_jar: Path,
        patches_file: Path,
        source_name: str,
        target_file: Path,
        progress_callback: Optional[Callable[[int, int], None]] = None,
    ) -> Optional[List[Dict[str, Any]]]:
        """Parse patches metadata by running CLI list-patches & list-versions."""
        if not cli_jar.exists() or not patches_file.exists() or not shutil.which("java"):
            return None

        # Build list-versions command
        ver_cmd = ["java", "-jar", str(cli_jar), "list-versions", f"--patches={patches_file}", "-u"]
        if source_name == "ReVanced":
            ver_cmd.append("--bypass-verification")

        patch_cmd = [
            "java",
            "-jar",
            str(cli_jar),
            "list-patches",
            f"--patches={patches_file}",
            "--with-descriptions",
            "--with-options",
            "--with-packages",
            "--with-versions",
            "--with-universal-patches",
        ]
        if source_name == "ReVanced":
            patch_cmd = [
                "java",
                "-jar",
                str(cli_jar),
                "list-patches",
                f"--patches={patches_file}",
                "--descriptions",
                "--options",
                "--packages",
                "--versions",
                "--universal-patches",
                "--bypass-verification",
            ]

        code_v, out_v, _ = run_command(ver_cmd, timeout=30)
        code_p, out_p, _ = run_command(patch_cmd, timeout=30)

        if code_p != 0:
            return None

        packages_map: Dict[Optional[str], Dict[str, Any]] = {}

        # Parse packages from list-versions output
        current_pkg = None
        for line in out_v.splitlines():
            line = line.strip()
            if line.startswith("Package name:") or line.startswith("Package:"):
                current_pkg = line.split(":", 1)[1].strip()
                if current_pkg not in packages_map:
                    packages_map[current_pkg] = {
                        "pkgName": current_pkg,
                        "versions": [],
                        "patches": {"recommended": [], "optional": []},
                        "options": [],
                        "descriptions": {},
                    }
            elif current_pkg and line and not line.startswith("INFO:") and "Any" not in line:
                v = line.split()[0].strip()
                if v and v not in packages_map[current_pkg]["versions"]:
                    packages_map[current_pkg]["versions"].append(v)

        # Parse patches from list-patches output
        blocks = re.split(r"\n(?=Name:|\nName:)", out_p)
        total_blocks = len(blocks)

        for idx, block in enumerate(blocks):
            if progress_callback:
                progress_callback(idx + 1, total_blocks)

            lines = [l.strip() for l in block.splitlines() if l.strip()]
            if not lines:
                continue

            patch_name = ""
            desc = "No description available"
            enabled = True
            comp_pkgs = []
            options = []

            for line in lines:
                if line.startswith("Name:"):
                    patch_name = line.split(":", 1)[1].strip()
                elif line.startswith("Description:"):
                    desc = line.split(":", 1)[1].strip()
                elif line.startswith("Enabled:"):
                    enabled = (line.split(":", 1)[1].strip().lower() == "true")
                elif line.startswith("Package name:"):
                    p = line.split(":", 1)[1].strip()
                    if p:
                        comp_pkgs.append(p)

            if not patch_name:
                continue

            if not comp_pkgs:
                comp_pkgs = [None]

            for pkg_name in comp_pkgs:
                if pkg_name not in packages_map:
                    packages_map[pkg_name] = {
                        "pkgName": pkg_name,
                        "versions": [],
                        "patches": {"recommended": [], "optional": []},
                        "options": [],
                        "descriptions": {},
                    }
                entry = packages_map[pkg_name]
                if enabled:
                    if patch_name not in entry["patches"]["recommended"]:
                        entry["patches"]["recommended"].append(patch_name)
                else:
                    if patch_name not in entry["patches"]["optional"]:
                        entry["patches"]["optional"].append(patch_name)
                entry["descriptions"][patch_name] = desc

        result_list = list(packages_map.values())
        target_file.parent.mkdir(parents=True, exist_ok=True)
        target_file.write_text(json.dumps(result_list, indent=2), encoding="utf-8")
        return result_list

    def load_or_fetch_patches_json(
        self,
        source_name: str,
        release_info: AssetReleaseInfo,
        progress_callback: Optional[Callable[[str], None]] = None,
    ) -> Optional[List[Dict[str, Any]]]:
        """Ensure Patches-<version>.json is generated and loaded."""
        src_dir = self.assets_dir / source_name
        json_target = src_dir / f"Patches-{release_info.patches_version}.json"

        if json_target.exists():
            try:
                data = json.loads(json_target.read_text(encoding="utf-8"))
                if isinstance(data, list) and data:
                    return data
            except Exception:
                pass

        # Try parsing from API
        if release_info.json_url:
            if progress_callback:
                progress_callback("Parsing Patches JSON from API...")
            res = self.parse_patches_json_from_api(release_info.json_url, json_target)
            if res:
                return res

        # Fallback to CLI parsing
        if progress_callback:
            progress_callback("Parsing Patches from CLI (this may take a moment)...")
        cli_jar = self.assets_dir / f"CLI-{release_info.cli_version}.jar"
        patches_file = src_dir / f"Patches-{release_info.patches_version}.{release_info.patches_ext}"

        return self.parse_patches_json_from_cli(cli_jar, patches_file, source_name, json_target)

    # --- Delete Assets ---

    def delete_assets(self) -> None:
        """Clear the assets directory."""
        if self.assets_dir.exists():
            shutil.rmtree(self.assets_dir, ignore_errors=True)
        self.assets_dir.mkdir(parents=True, exist_ok=True)


# Global assets manager instance
assets_mgr = AssetsManager()
