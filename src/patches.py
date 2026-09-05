"""
Enhancify Patches & Options Management Module
Handles reading and writing saved patches and patch options in $STORAGE/<source>-patches.json.
Ensures 100% data compatibility with original bash scripts.
"""

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional, Set

from src.config import config
from src.environment import env


@dataclass
class PatchOptionValue:
    title: str
    patch_name: str
    key: str
    value: Any


@dataclass
class SavedAppPatches:
    pkg_name: str
    patches: List[str] = field(default_factory=list)
    options: List[Dict[str, Any]] = field(default_factory=list)


class PatchesManager:
    """Manages patch selections and option configuration for apps."""

    def __init__(self, workspace_dir: Optional[Path] = None):
        self.workspace_dir = workspace_dir or Path(__file__).resolve().parent.parent
        self.storage_dir = env.storage_dir

    def _get_storage_key(self, source_name: str, multi_sources: Optional[List[str]] = None) -> str:
        if config.is_on("ENABLE_MULTIPATCHER") and multi_sources and len(multi_sources) > 1:
            return "&".join(multi_sources)
        return source_name

    def get_patches_file(self, source_name: str, multi_sources: Optional[List[str]] = None) -> Path:
        """Get the storage path for saved patches JSON."""
        key = self._get_storage_key(source_name, multi_sources)
        return self.storage_dir / f"{key}-patches.json"

    def load_saved_patches(self, source_name: str, multi_sources: Optional[List[str]] = None) -> List[Dict[str, Any]]:
        """Load saved patches JSON from storage."""
        fpath = self.get_patches_file(source_name, multi_sources)
        if fpath.exists():
            try:
                data = json.loads(fpath.read_text(encoding="utf-8"))
                if isinstance(data, list):
                    return data
            except Exception:
                pass
        return []

    def save_patches(self, source_name: str, patches_data: List[Dict[str, Any]], multi_sources: Optional[List[str]] = None) -> bool:
        """Save enabled patches and options to storage."""
        fpath = self.get_patches_file(source_name, multi_sources)
        fpath.parent.mkdir(parents=True, exist_ok=True)
        try:
            fpath.write_text(json.dumps(patches_data, indent=2), encoding="utf-8")
            return True
        except Exception:
            return False

    def get_enabled_patches_for_pkg(
        self,
        source_name: str,
        pkg_name: str,
        available_patches_meta: List[Dict[str, Any]],
        multi_sources: Optional[List[str]] = None,
    ) -> Set[str]:
        """Get the set of enabled patch names for a package."""
        saved = self.load_saved_patches(source_name, multi_sources)
        for entry in saved:
            if entry.get("pkgName") == pkg_name:
                return set(entry.get("patches", []))

        # Default to recommended patches from available metadata
        for item in available_patches_meta:
            if item.get("pkgName") == pkg_name or item.get("pkgName") is None:
                rec = item.get("patches", {}).get("recommended", [])
                if rec:
                    return set(rec)

        return set()

    def get_options_for_pkg(
        self,
        source_name: str,
        pkg_name: str,
        available_patches_meta: List[Dict[str, Any]],
        multi_sources: Optional[List[str]] = None,
    ) -> List[Dict[str, Any]]:
        """Get all available options for enabled patches with saved values populated."""
        saved = self.load_saved_patches(source_name, multi_sources)
        saved_options_map: Dict[Tuple[str, str], Any] = {}
        saved_entry = None
        for entry in saved:
            if entry.get("pkgName") == pkg_name:
                saved_entry = entry
                for opt in entry.get("options", []):
                    k = opt.get("key")
                    pn = opt.get("patchName")
                    if k and pn:
                        saved_options_map[(pn, k)] = opt.get("value")

        # Collect options from available metadata
        options_list = []
        for item in available_patches_meta:
            if item.get("pkgName") == pkg_name or item.get("pkgName") is None:
                for opt in item.get("options", []):
                    pn = opt.get("patchName")
                    k = opt.get("key")
                    default_val = opt.get("default")
                    val = saved_options_map.get((pn, k), default_val)
                    options_list.append({
                        "patchName": pn,
                        "key": k,
                        "title": opt.get("title", k),
                        "description": opt.get("description", ""),
                        "required": opt.get("required", False),
                        "default": default_val,
                        "type": opt.get("type", "String"),
                        "values": opt.get("values", []),
                        "value": val,
                    })

        return options_list

    def save_pkg_selection(
        self,
        source_name: str,
        pkg_name: str,
        enabled_patches: Set[str],
        options_list: List[Dict[str, Any]],
        multi_sources: Optional[List[str]] = None,
    ) -> bool:
        """Update saved selection for a package and persist to storage."""
        saved = self.load_saved_patches(source_name, multi_sources)
        
        # Build options to persist for enabled patches
        persisted_options = []
        for opt in options_list:
            if opt.get("patchName") in enabled_patches:
                persisted_options.append({
                    "title": opt.get("title", opt.get("key")),
                    "patchName": opt.get("patchName"),
                    "key": opt.get("key"),
                    "value": opt.get("value"),
                })

        found = False
        for entry in saved:
            if entry.get("pkgName") == pkg_name:
                entry["patches"] = sorted(list(enabled_patches))
                entry["options"] = persisted_options
                found = True
                break

        if not found:
            saved.append({
                "pkgName": pkg_name,
                "patches": sorted(list(enabled_patches)),
                "options": persisted_options,
            })

        return self.save_patches(source_name, saved, multi_sources)


# Global patches manager instance
patches_mgr = PatchesManager()
