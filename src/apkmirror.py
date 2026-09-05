"""
Enhancify APKMirror Scraper & Downloader Module
Handles scraping app version lists, tag detection ([RECOMMENDED], [INSTALLED], [STABLE], [BETA]),
caching in apps_meta/, download URL scraping, and downloading APK/APKM files.
"""

import concurrent.futures
import datetime
import json
import re
import shutil
import urllib.parse
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple

import requests
from bs4 import BeautifulSoup

from src.config import config
from src.environment import env
from src.utils import download_file


USER_AGENT = "APKUpdater-3.0.3"
APKMIRROR_BASE = "https://www.apkmirror.com"


@dataclass
class ScrapedVersion:
    version: str
    tag: str  # e.g. "[STABLE]", "[BETA]", "[ALPHA]", "[RECOMMENDED]", "[INSTALLED]"
    url: str


class APKMirrorScraper:
    """Scrapes APKMirror for app versions and download links."""

    def __init__(self, workspace_dir: Optional[Path] = None):
        self.workspace_dir = workspace_dir or Path(__file__).resolve().parent.parent
        self.cache_dir = self.workspace_dir / "apps_meta"
        self.apps_dir = self.workspace_dir / "apps"
        self._ensure_dirs()

    def _ensure_dirs(self) -> None:
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        self.apps_dir.mkdir(parents=True, exist_ok=True)

    def _get_cache_file(self, app_name: str) -> Path:
        safe_name = re.sub(r"[^a-zA-Z0-9_-]", "_", app_name)
        return self.cache_dir / f"{safe_name}_metadata.json"

    # --- Cache Manager ---

    def read_cached_versions(self, app_name: str, min_page_limit: int = 5) -> Optional[List[Dict[str, str]]]:
        """Read cached version list if valid."""
        cache_file = self._get_cache_file(app_name)
        if not cache_file.exists():
            return None

        try:
            data = json.loads(cache_file.read_text(encoding="utf-8"))
            cached_pages = data.get("page_limit", 0)
            if cached_pages < min_page_limit:
                return None
            versions = data.get("versions", [])
            if isinstance(versions, list) and versions:
                return versions
        except Exception:
            pass
        return None

    def write_cached_versions(self, app_name: str, versions: List[Dict[str, str]], page_limit: int = 5) -> None:
        """Write scraped versions to cache."""
        cache_file = self._get_cache_file(app_name)
        now_dt = datetime.date.today().strftime("%Y-%m-%d")
        data = {
            "app_name": app_name,
            "cached_at": now_dt,
            "page_limit": page_limit,
            "version_count": len(versions),
            "versions": versions,
        }
        try:
            cache_file.write_text(json.dumps(data, indent=2), encoding="utf-8")
        except Exception:
            pass

    def clear_cache(self, app_name: str) -> None:
        """Clear cache for a given app."""
        cache_file = self._get_cache_file(app_name)
        cache_file.unlink(missing_ok=True)

    # --- Scraping ---

    def scrape_versions_page(self, apkmirror_app_name: str, page_num: int) -> List[Dict[str, str]]:
        """Scrape a single uploads page on APKMirror."""
        url = f"{APKMIRROR_BASE}/uploads/page/{page_num}/?appcategory={apkmirror_app_name}"
        headers = {"User-Agent": USER_AGENT}
        results = []

        try:
            r = requests.get(url, headers=headers, timeout=10)
            if r.status_code != 200:
                return []

            soup = BeautifulSoup(r.text, "html.parser")
            rows = soup.select("div.widget_appmanager_recentpostswidget div.listWidget div:not([class])")
            if not rows:
                rows = soup.select("div.listWidget div.appRow")

            for row in rows:
                title_elem = row.select_one("a.fontBlack") or row.select_one("h5 a") or row.select_one("a")
                if not title_elem:
                    continue

                full_title = title_elem.get_text(strip=True)
                href = title_elem.get("href", "")
                if not href:
                    continue

                # Extract version
                ver_match = re.search(r"(\d+(?:\.\d+)+(?:-[a-zA-Z0-9\._]+)?)", full_title)
                version_str = ver_match.group(1) if ver_match else full_title

                tag = "[STABLE]"
                title_lower = full_title.lower()
                if "beta" in title_lower:
                    tag = "[BETA]"
                elif "alpha" in title_lower:
                    tag = "[ALPHA]"

                results.append({
                    "version": version_str,
                    "tag": tag,
                    "url": href,
                })
        except Exception:
            pass

        return results

    def fetch_versions_list(
        self,
        apkmirror_app_name: str,
        supported_versions: Optional[List[str]] = None,
        installed_version: str = "",
        force_refresh: bool = False,
        progress_callback: Optional[Callable[[str], None]] = None,
    ) -> List[ScrapedVersion]:
        """
        Fetch version list for an app, either from cache or by scraping APKMirror.
        Tags versions with [RECOMMENDED] and [INSTALLED].
        """
        page_limit = config.get_apkmirror_page_limit()
        supported_versions = supported_versions or []

        raw_versions = None
        if not force_refresh:
            raw_versions = self.read_cached_versions(apkmirror_app_name, page_limit)

        if not raw_versions:
            if progress_callback:
                progress_callback(f"Scraping {page_limit} pages from APKMirror...")

            all_scraped = []
            with concurrent.futures.ThreadPoolExecutor(max_workers=5) as executor:
                futures = {
                    executor.submit(self.scrape_versions_page, apkmirror_app_name, p): p
                    for p in range(1, page_limit + 1)
                }
                for fut in concurrent.futures.as_completed(futures):
                    try:
                        res = fut.result()
                        all_scraped.extend(res)
                    except Exception:
                        pass

            # Deduplicate by version
            seen = set()
            raw_versions = []
            for item in all_scraped:
                v = item["version"]
                if v not in seen:
                    seen.add(v)
                    raw_versions.append(item)

            if raw_versions:
                self.write_cached_versions(apkmirror_app_name, raw_versions, page_limit)

        if not raw_versions:
            return []

        # Process tags
        processed: List[ScrapedVersion] = []
        for item in raw_versions:
            v = item.get("version", "")
            base_tag = item.get("tag", "[STABLE]")
            url = item.get("url", "")

            final_tag = base_tag
            if v in supported_versions:
                final_tag = "[RECOMMENDED]"
            elif installed_version and v == installed_version:
                final_tag = "[INSTALLED]"

            processed.append(ScrapedVersion(version=v, tag=final_tag, url=url))

        return processed

    # --- Scrape Download Link ---

    def scrape_download_link(self, version_url: str) -> Optional[Tuple[str, str, int, str]]:
        """
        Scrape download URL, file extension (apk/apkm), expected size, and download link.
        Returns (download_url, format_type, size_bytes, extension)
        """
        headers = {"User-Agent": USER_AGENT}
        full_url = version_url if version_url.startswith("http") else f"{APKMIRROR_BASE}{version_url}"

        try:
            # 1. Fetch release / version page
            r = requests.get(full_url, headers=headers, timeout=10)
            if r.status_code != 200:
                return None

            soup = BeautifulSoup(r.text, "html.parser")

            # Check if direct download or variants table
            canonical = soup.select_one("link[rel='canonical']")
            canonical_href = canonical.get("href", "") if canonical else ""

            target_variant_url = ""
            app_format = "APK"
            app_ext = "apk"
            arch = env.get_arch()

            if "apk-download" in canonical_href:
                target_variant_url = canonical_href
            else:
                # Variant selection table
                table = soup.select_one("div.table-variants") or soup.select_one("div.variants-table")
                if not table:
                    # Look for download buttons directly
                    dl_btn = soup.select_one("a.accent_bg[href*='download']")
                    if dl_btn:
                        target_variant_url = urllib.parse.urljoin(APKMIRROR_BASE, dl_btn.get("href"))
                else:
                    prefer_split = config.is_on("PREFER_SPLIT_APK")
                    rows = table.select("div.table-row")
                    chosen_row = None

                    # Find matching architecture & type
                    for row in rows:
                        row_text = row.get_text().lower()
                        is_bundle = "bundle" in row_text or "apkm" in row_text or "split" in row_text
                        if prefer_split and not is_bundle:
                            continue

                        # Check architecture match
                        if arch in row_text or "universal" in row_text or "noarch" in row_text:
                            chosen_row = row
                            if is_bundle:
                                app_format = "BUNDLE"
                                app_ext = "apkm"
                            break

                    if not chosen_row and rows:
                        # Fallback to first row
                        chosen_row = rows[0]
                        if "bundle" in chosen_row.get_text().lower():
                            app_format = "BUNDLE"
                            app_ext = "apkm"

                    if chosen_row:
                        btn = chosen_row.select_one("a[href*='apk-download']") or chosen_row.select_one("a")
                        if btn:
                            target_variant_url = urllib.parse.urljoin(APKMIRROR_BASE, btn.get("href"))

            if not target_variant_url:
                target_variant_url = full_url

            # 2. Fetch variant download page
            r2 = requests.get(target_variant_url, headers=headers, timeout=10)
            if r2.status_code != 200:
                return None

            soup2 = BeautifulSoup(r2.text, "html.parser")
            download_btn = soup2.select_one("a.accent_bg[href*='download/']") or soup2.select_one("a[href*='download.php']")
            if not download_btn:
                # Direct download page link
                download_btn = soup2.select_one("a[href*='download/?key=']")

            if not download_btn:
                return None

            step2_url = urllib.parse.urljoin(APKMIRROR_BASE, download_btn.get("href"))

            # 3. Final download page with direct link
            r3 = requests.get(step2_url, headers=headers, timeout=10)
            if r3.status_code != 200:
                return None

            soup3 = BeautifulSoup(r3.text, "html.parser")
            final_link_elem = (
                soup3.select_one("a[rel='nofollow'][href*='download.php']")
                or soup3.select_one("a.accent_bg[href*='download.php']")
                or soup3.select_one("p.notes a[href*='download.php']")
            )

            if not final_link_elem:
                return None

            final_url = urllib.parse.urljoin(APKMIRROR_BASE, final_link_elem.get("href"))

            # Head request to find size
            size = 0
            try:
                head_r = requests.head(final_url, headers=headers, allow_redirects=True, timeout=5)
                size = int(head_r.headers.get("content-length", 0))
            except Exception:
                pass

            return final_url, app_format, size, app_ext
        except Exception:
            return None

    def download_app(
        self,
        app_name: str,
        version: str,
        download_url: str,
        ext: str,
        expected_size: int = 0,
        progress_callback: Optional[Callable[[int, int, str], None]] = None,
    ) -> Optional[Path]:
        """Download APK / APKM to apps/<APP_NAME>/<version>.<ext>."""
        target_dir = self.apps_dir / app_name
        target_dir.mkdir(parents=True, exist_ok=True)
        target_file = target_dir / f"{version}.{ext}"

        # Write .data metadata
        data_lines = [
            f"APP_FORMAT='{'BUNDLE' if ext != 'apk' else 'APK'}'",
            f"APP_EXT='{ext}'",
            f"APP_SIZE='{expected_size}'",
        ]
        (target_dir / ".data").write_text("\n".join(data_lines) + "\n", encoding="utf-8")

        if target_file.exists() and (expected_size <= 0 or target_file.stat().st_size == expected_size):
            return target_file

        success = download_file(download_url, target_file, expected_size, progress_callback)
        if success and target_file.exists():
            new_size = target_file.stat().st_size
            # Update .data size
            data_lines[2] = f"APP_SIZE='{new_size}'"
            (target_dir / ".data").write_text("\n".join(data_lines) + "\n", encoding="utf-8")
            return target_file
        return None


# Global APKMirror scraper instance
apkmirror_scraper = APKMirrorScraper()
