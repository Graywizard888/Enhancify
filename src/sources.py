"""
Enhancify Sources Management Module
Handles sources.json, user_sources.json, tag fetching, caching, and custom source CRUD.
"""

import datetime
import json
import re
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import requests

from src.config import config
from src.environment import env


USER_AGENT_GITHUB = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Mobile Safari/537.36 EdgA/142.0.0.0"


@dataclass
class SourceInfo:
    source: str
    repository: str
    json_url: str = ""
    version: Optional[str] = None
    gitlab_id: Optional[str] = None
    is_custom: bool = False
    latest_tag: str = ""
    prerelease_tag: str = ""

    def to_dict(self) -> Dict[str, Any]:
        d: Dict[str, Any] = {
            "source": self.source,
            "repository": self.repository,
            "api": {
                "json": self.json_url or "",
                "version": self.version,
            },
        }
        if self.gitlab_id:
            d["gitlab"] = self.gitlab_id
        return d


class SourcesManager:
    """Manages built-in and custom patch sources."""

    def __init__(self, workspace_dir: Optional[Path] = None):
        self.workspace_dir = workspace_dir or Path(__file__).resolve().parent.parent
        self.sources_file = self.workspace_dir / "sources.json"
        self.user_sources_file = self.workspace_dir / "user_sources.json"
        self.tag_file = self.workspace_dir / "tag.json"
        self._ensure_files()

    def _ensure_files(self) -> None:
        if not self.user_sources_file.exists():
            self.user_sources_file.write_text("[]\n", encoding="utf-8")
        if not self.tag_file.exists():
            self._init_tag_file()

    def _init_tag_file(self) -> None:
        now_ts = int(time.time())
        now_dt = datetime.date.today().strftime("%Y-%m-%d")
        data = {
            "_meta": {
                "timestamp": now_ts,
                "date": now_dt,
                "has_token": "true" if config.get_github_token() else "false",
            },
            "sources": {},
        }
        self.tag_file.write_text(json.dumps(data, indent=2), encoding="utf-8")

    def get_all_sources(self) -> List[SourceInfo]:
        """Load and merge sources.json and user_sources.json."""
        sources: List[SourceInfo] = []
        
        # Load built-in sources
        if self.sources_file.exists():
            try:
                builtin = json.loads(self.sources_file.read_text(encoding="utf-8"))
                for item in builtin:
                    api = item.get("api", {})
                    sources.append(
                        SourceInfo(
                            source=item.get("source", ""),
                            repository=item.get("repository", ""),
                            json_url=api.get("json", "") or "",
                            version=api.get("version"),
                            gitlab_id=item.get("gitlab"),
                            is_custom=False,
                        )
                    )
            except Exception:
                pass

        # Load user custom sources
        if self.user_sources_file.exists():
            try:
                user_src = json.loads(self.user_sources_file.read_text(encoding="utf-8"))
                for item in user_src:
                    api = item.get("api", {})
                    sources.append(
                        SourceInfo(
                            source=item.get("source", ""),
                            repository=item.get("repository", ""),
                            json_url=api.get("json", "") or "",
                            version=api.get("version"),
                            gitlab_id=item.get("gitlab"),
                            is_custom=True,
                        )
                    )
            except Exception:
                pass

        return sources

    def get_source(self, name: str) -> Optional[SourceInfo]:
        """Find a source by name."""
        for s in self.get_all_sources():
            if s.source == name:
                return s
        return None

    def add_custom_source(self, name: str, repo: str, json_url: str = "", version: Optional[str] = None) -> Tuple[bool, str]:
        """Add a new custom source."""
        name = name.strip()
        repo = repo.strip()
        if not name:
            return False, "Source name cannot be empty."
        if not repo or "/" not in repo:
            return False, "Invalid repository format! Must be: username/repo"

        # Check existing
        for s in self.get_all_sources():
            if s.source.lower() == name.lower():
                return False, f"Source '{name}' already exists!"

        try:
            custom_sources = []
            if self.user_sources_file.exists():
                custom_sources = json.loads(self.user_sources_file.read_text(encoding="utf-8"))
            new_entry = {
                "source": name,
                "repository": repo,
                "api": {
                    "json": json_url.strip() if json_url else "",
                    "version": version.strip() if version else None,
                },
            }
            custom_sources.append(new_entry)
            self.user_sources_file.write_text(json.dumps(custom_sources, indent=2), encoding="utf-8")
            return True, f"Custom source '{name}' added successfully!"
        except Exception as e:
            return False, f"Failed to add source: {e}"

    def update_custom_source(self, old_name: str, new_name: str, new_repo: str, new_json: str = "", new_version: Optional[str] = None) -> Tuple[bool, str]:
        """Update an existing custom source."""
        new_name = new_name.strip()
        new_repo = new_repo.strip()
        if not new_name:
            return False, "Source name cannot be empty."
        if not new_repo or "/" not in new_repo:
            return False, "Invalid repository format! Must be: username/repo"

        try:
            custom_sources = []
            if self.user_sources_file.exists():
                custom_sources = json.loads(self.user_sources_file.read_text(encoding="utf-8"))
            
            found = False
            for entry in custom_sources:
                if entry.get("source") == old_name:
                    entry["source"] = new_name
                    entry["repository"] = new_repo
                    entry["api"] = {
                        "json": new_json.strip() if new_json else "",
                        "version": new_version.strip() if new_version else None,
                    }
                    found = True
                    break

            if not found:
                return False, f"Custom source '{old_name}' not found."

            self.user_sources_file.write_text(json.dumps(custom_sources, indent=2), encoding="utf-8")
            return True, f"Source '{new_name}' updated successfully!"
        except Exception as e:
            return False, f"Failed to update source: {e}"

    def delete_custom_source(self, name: str) -> Tuple[bool, str]:
        """Delete a custom source."""
        try:
            custom_sources = []
            if self.user_sources_file.exists():
                custom_sources = json.loads(self.user_sources_file.read_text(encoding="utf-8"))
            
            new_list = [entry for entry in custom_sources if entry.get("source") != name]
            self.user_sources_file.write_text(json.dumps(new_list, indent=2), encoding="utf-8")
            return True, f"Source '{name}' deleted successfully!"
        except Exception as e:
            return False, f"Failed to delete source: {e}"

    # --- Tag Fetching & Caching ---

    def _get_headers(self) -> Dict[str, str]:
        headers = {
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": USER_AGENT_GITHUB,
        }
        tok = config.get_github_token()
        if tok:
            headers["Authorization"] = f"Bearer {tok}"
        return headers

    def fetch_latest_github_tag(self, repo: str) -> Tuple[str, int]:
        """Fetch the latest release tag from GitHub."""
        url = f"https://api.github.com/repos/{repo}/releases/latest"
        try:
            r = requests.get(url, headers=self._get_headers(), timeout=5)
            # Log ratelimit
            limit = int(r.headers.get("x-ratelimit-limit", 0))
            rem = int(r.headers.get("x-ratelimit-remaining", 0))
            reset = int(r.headers.get("x-ratelimit-reset", 0))
            config.log_github_api_call(url, limit, rem, reset)

            if r.status_code == 200:
                data = r.json()
                return data.get("tag_name", ""), r.status_code
            return "", r.status_code
        except Exception:
            return "", 0

    def fetch_prerelease_github_tag(self, repo: str) -> Tuple[str, int]:
        """Fetch the latest prerelease tag from GitHub."""
        url = f"https://api.github.com/repos/{repo}/releases?per_page=1"
        try:
            r = requests.get(url, headers=self._get_headers(), timeout=5)
            limit = int(r.headers.get("x-ratelimit-limit", 0))
            rem = int(r.headers.get("x-ratelimit-remaining", 0))
            reset = int(r.headers.get("x-ratelimit-reset", 0))
            config.log_github_api_call(url, limit, rem, reset)

            if r.status_code == 200:
                data = r.json()
                if isinstance(data, list) and data:
                    return data[0].get("tag_name", ""), r.status_code
            return "", r.status_code
        except Exception:
            return "", 0

    def fetch_revanced_custom_api_version(self, use_prerelease: bool = False) -> str:
        """Fetch version from official ReVanced API."""
        url = "https://api.revanced.app/v5/patches/prerelease" if use_prerelease else "https://api.revanced.app/v5/patches"
        try:
            r = requests.get(url, headers={"Accept": "application/json", "User-Agent": USER_AGENT_GITHUB}, timeout=5)
            if r.status_code == 200:
                data = r.json()
                return data.get("version", "")
        except Exception:
            pass
        return ""

    def fetch_gitlab_tag(self, gitlab_id: str) -> str:
        """Fetch tag from GitLab releases API."""
        url = f"https://gitlab.com/api/v4/projects/{gitlab_id}/releases"
        try:
            r = requests.get(url, headers={"Accept": "application/json", "User-Agent": USER_AGENT_GITHUB}, timeout=5)
            if r.status_code == 200:
                data = r.json()
                if isinstance(data, list) and data:
                    return data[0].get("tag_name", "")
        except Exception:
            pass
        return ""

    def get_cached_tags(self) -> Dict[str, Dict[str, Any]]:
        """Read tags from tag.json."""
        if self.tag_file.exists():
            try:
                data = json.loads(self.tag_file.read_text(encoding="utf-8"))
                return data.get("sources", {})
            except Exception:
                pass
        return {}

    def fetch_source_tags(self, source_info: SourceInfo) -> Tuple[str, str]:
        """Fetch latest and prerelease tag for a single source."""
        latest = ""
        prerelease = ""

        if source_info.source == "ReVanced":
            latest = self.fetch_revanced_custom_api_version(False)
            prerelease = self.fetch_revanced_custom_api_version(True)
            if not latest and not prerelease:
                latest, _ = self.fetch_latest_github_tag(source_info.repository)
                prerelease, _ = self.fetch_prerelease_github_tag(source_info.repository)
        else:
            tag, status_code = self.fetch_latest_github_tag(source_info.repository)
            if status_code == 404:
                # Try GitLab
                gl_id = source_info.gitlab_id or source_info.repository.replace("/", "%2F")
                tag = self.fetch_gitlab_tag(gl_id)
                latest = tag
                prerelease = tag
            else:
                latest = tag
                prerelease, _ = self.fetch_prerelease_github_tag(source_info.repository)

        return latest, prerelease

    def update_tags(self, specific_source: Optional[str] = None, progress_callback=None) -> Dict[str, Dict[str, Any]]:
        """
        Refresh tag cache for sources.
        If specific_source is provided, only that source is updated;
        otherwise all sources (or current source if unauthenticated).
        """
        sources = self.get_all_sources()
        has_token = bool(config.get_github_token())
        current_src_name = config.get("SOURCE", "Anddea")

        if specific_source:
            targets = [s for s in sources if s.source == specific_source]
        elif has_token:
            targets = sources
        else:
            # If no token, only fetch current source to conserve rate limits
            targets = [s for s in sources if s.source == current_src_name]
            if not targets and sources:
                targets = [sources[0]]

        tags_cache = self.get_cached_tags()
        total = len(targets)

        for idx, s in enumerate(targets):
            if progress_callback:
                progress_callback(idx + 1, total, s.source)
            try:
                lat, pre = self.fetch_source_tags(s)
                tags_cache[s.source] = {
                    "latest": lat,
                    "prerelease": pre,
                    "custom": s.is_custom,
                }
            except Exception:
                pass

        # Save tag.json
        now_ts = int(time.time())
        now_dt = datetime.date.today().strftime("%Y-%m-%d")
        data = {
            "_meta": {
                "timestamp": now_ts,
                "date": now_dt,
                "has_token": "true" if has_token else "false",
            },
            "sources": tags_cache,
        }
        self.tag_file.write_text(json.dumps(data, indent=2), encoding="utf-8")
        return tags_cache


# Global sources manager instance
sources_mgr = SourcesManager()
