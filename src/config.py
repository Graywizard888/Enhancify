"""
Enhancify Configuration Manager
Handles on-disk config (.config), user settings, tokens, and tag caching.
Ensures 100% data compatibility with original bash scripts.
"""

import json
import os
import re
import time
from pathlib import Path
from typing import Any, Dict, Optional


DEFAULT_CONFIG: Dict[str, str] = {
    "SOURCE": "Anddea",
    "THEME_ID": "cyber_green",
    "THEME": "Cybernetic Green",
    "DARK_THEME": "off",
    "GREEN_THEME": "on",
    "OPTIMIZE_LIBS": "on",
    "LAUNCH_APP_AFTER_MOUNT": "on",
    "ALLOW_APP_VERSION_DOWNGRADE": "off",
    "SKIP_VERIFICATION": "off",
    "BYPASS_LOW_TARGET_SDK_BLOCK": "off",
    "CLI_RIPLIB_ANTISPLIT": "off",
    "USE_PARALLEL_GC": "off",
    "FORCE_BACKGROUND_WHITELIST": "off",
    "CACHE_CLI": "off",
    "ENABLE_MULTIPATCHER": "off",
    "PREFER_SPLIT_APK": "off",
    "USE_PRE_RELEASE": "off",
    "DISABLE_NETWORK_ACCELERATION": "off",
    "Use_CUSTOM_KEYSTORE": "off",
}


class ConfigManager:
    """Manages reading and writing configuration files."""

    def __init__(self, workspace_dir: Optional[Path] = None):
        self.workspace_dir = workspace_dir or Path(__file__).resolve().parent.parent
        self.config_file = self.workspace_dir / ".config"
        self.token_file = self.workspace_dir / "github_token.json"
        self.token_log_file = self.workspace_dir / "github_api_log.json"
        self.apkmirror_config_file = self.workspace_dir / "apkmirror_config.json"
        self.tag_file = self.workspace_dir / "tag.json"
        self.cli_detection_file = self.workspace_dir / "cli_detection.json"
        self.user_sources_file = self.workspace_dir / "user_sources.json"
        self.bundle_sources_file = self.workspace_dir / "bundle_patcher_sources.json"
        self.sources_file = self.workspace_dir / "sources.json"
        
        # In-memory config dictionary
        self.settings: Dict[str, str] = {}
        self.load_config()

    def load_config(self) -> Dict[str, str]:
        """Load configuration from .config file into memory."""
        self.settings = dict(DEFAULT_CONFIG)
        if self.config_file.exists():
            content = self.config_file.read_text(encoding="utf-8")
            for line in content.splitlines():
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                match = re.match(r"^([A-Za-z0-9_]+)=['\"]?(.*?)['\"]?$", line)
                if match:
                    k, v = match.group(1), match.group(2)
                    self.settings[k] = v
        else:
            self.save_config()
        return self.settings

    def get(self, key: str, default: str = "") -> str:
        """Get a configuration option value."""
        return self.settings.get(key, default)

    def is_on(self, key: str) -> bool:
        """Return True if the toggle setting is 'on'."""
        return self.settings.get(key, "off").lower() == "on"

    def set(self, key: str, value: str) -> None:
        """Set a configuration option and persist to disk."""
        self.settings[key] = value
        self.save_config()

    def toggle(self, key: str) -> bool:
        """Toggle an on/off option and return new state (True=on)."""
        new_state = "off" if self.is_on(key) else "on"
        self.set(key, new_state)
        return new_state == "on"

    def save_config(self) -> None:
        """Write current settings to .config file preserving format."""
        lines = []
        for k, v in self.settings.items():
            lines.append(f"{k}='{v}'")
        self.config_file.write_text("\n".join(lines) + "\n", encoding="utf-8")

    # --- GitHub Token Management ---

    def get_github_token(self) -> Optional[str]:
        """Read GitHub token from github_token.json if present."""
        if self.token_file.exists():
            try:
                data = json.loads(self.token_file.read_text(encoding="utf-8"))
                tok = data.get("token")
                if tok and isinstance(tok, str) and tok.strip():
                    return tok.strip()
            except Exception:
                pass
        return None

    def set_github_token(self, token: str) -> bool:
        """Save GitHub token to github_token.json."""
        try:
            self.token_file.write_text(
                json.dumps({"token": token.strip()}, indent=2),
                encoding="utf-8",
            )
            return True
        except Exception:
            return False

    def delete_github_token(self) -> bool:
        """Remove github_token.json."""
        try:
            if self.token_file.exists():
                self.token_file.unlink()
            return True
        except Exception:
            return False

    def log_github_api_call(self, endpoint: str, limit: int, remaining: int, reset_ts: int) -> None:
        """Log rate limit usage to github_api_log.json."""
        import datetime

        entry = {
            "timestamp": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "endpoint": endpoint,
            "limit": limit,
            "remaining": remaining,
            "reset": reset_ts,
        }
        try:
            logs = []
            if self.token_log_file.exists():
                try:
                    logs = json.loads(self.token_log_file.read_text(encoding="utf-8"))
                    if not isinstance(logs, list):
                        logs = []
                except Exception:
                    logs = []
            logs.append(entry)
            # Keep latest 100 entries to prevent file bloat
            if len(logs) > 100:
                logs = logs[-100:]
            self.token_log_file.write_text(json.dumps(logs, indent=2), encoding="utf-8")
        except Exception:
            pass

    # --- APKMirror Config ---

    def get_apkmirror_page_limit(self) -> int:
        """Get APKMirror max page limit."""
        if self.apkmirror_config_file.exists():
            try:
                data = json.loads(self.apkmirror_config_file.read_text(encoding="utf-8"))
                val = data.get("max_page_limit", 5)
                return int(val) if int(val) > 0 else 5
            except Exception:
                pass
        return 5

    def set_apkmirror_page_limit(self, limit: int) -> bool:
        """Set APKMirror max page limit."""
        try:
            self.apkmirror_config_file.write_text(
                json.dumps({"max_page_limit": max(1, limit)}, indent=2),
                encoding="utf-8",
            )
            return True
        except Exception:
            return False

    # --- CLI Capabilities ---

    def get_cli_capabilities(self) -> Dict[str, bool]:
        """Read cached CLI detection."""
        if self.cli_detection_file.exists():
            try:
                return json.loads(self.cli_detection_file.read_text(encoding="utf-8"))
            except Exception:
                pass
        return {"unsigned": False, "riplib": False, "striplibs": False}

    def save_cli_capabilities(self, unsigned: bool, riplib: bool, striplibs: bool) -> None:
        """Save CLI capability detection."""
        try:
            data = {"unsigned": unsigned, "riplib": riplib, "striplibs": striplibs}
            self.cli_detection_file.write_text(json.dumps(data, indent=2), encoding="utf-8")
        except Exception:
            pass


# Global config instance
config = ConfigManager()
