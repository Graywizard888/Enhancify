"""
Enhancify System & Environment Detection Module
Handles Termux, Android props (getprop), privilege levels (Root, Rish, Non-privilege),
Java runtime checks, memory calculation, and network status.
"""

import os
import re
import shutil
import socket
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Optional, Tuple


@dataclass
class DeviceSpecs:
    device_name: str
    device_brand: str
    dpi: str
    arch: str
    android_version: str
    sdk_version: str
    total_ram: str
    available_ram_mb: int
    total_ram_mb: int
    storage_info: str
    kernel_version: str
    enhancify_version: str
    locale: str


class Environment:
    """Detects and provides Android / Termux environment information."""

    def __init__(self, workspace_dir: Optional[Path] = None):
        self.workspace_dir = workspace_dir or Path(__file__).resolve().parent.parent
        self.home_dir = Path.home()
        self.prefix_dir = Path(os.environ.get("PREFIX", "/data/data/com.termux/files/usr"))
        
        # Determine storage directory
        shared_storage = self.home_dir / "storage" / "shared" / "Enhancify"
        if not shared_storage.parent.exists():
            # Fallback for development / non-termux environments
            self.storage_dir = self.workspace_dir / "storage"
        else:
            self.storage_dir = shared_storage
            
        self._cached_specs: Optional[DeviceSpecs] = None
        self._cached_network: Optional[Tuple[bool, bool, str, float]] = None
        self._cached_privileges: Optional[Tuple[bool, bool, str]] = None

    @property
    def is_termux(self) -> bool:
        return bool(os.environ.get("TERMUX_VERSION")) or Path("/data/data/com.termux").exists()

    def getprop(self, prop_name: str, default: str = "") -> str:
        """Read an Android system property using getprop."""
        try:
            res = subprocess.run(
                ["getprop", prop_name],
                capture_output=True,
                text=True,
                timeout=1,
            )
            val = res.stdout.strip()
            return val if val else default
        except Exception:
            return default

    def get_arch(self) -> str:
        """Get CPU ABI architecture."""
        arch = self.getprop("ro.product.cpu.abi")
        if not arch:
            try:
                u = os.uname().machine
                if "aarch64" in u or "arm64" in u:
                    arch = "arm64-v8a"
                elif "arm" in u:
                    arch = "armeabi-v7a"
                elif "x86_64" in u or "amd64" in u:
                    arch = "x86_64"
                elif "i386" in u or "i686" in u or "x86" in u:
                    arch = "x86"
                else:
                    arch = u
            except Exception:
                arch = "arm64-v8a"
        return arch

    def get_dpi(self) -> str:
        """Get LCD density."""
        return self.getprop("ro.sf.lcd_density", "420")

    def get_locale(self) -> str:
        """Get system locale language code (e.g., 'en')."""
        loc = self.getprop("persist.sys.locale", "en-US")
        return loc.split("-")[0].split("_")[0] if loc else "en"

    def get_version(self) -> str:
        """Read Enhancify version from .info file."""
        info_file = self.workspace_dir / ".info"
        if info_file.exists():
            content = info_file.read_text(encoding="utf-8")
            match = re.search(r"(?:VERSION|version|Version)\s*=\s*['\"]?([^'\"\n]+)['\"]?", content)
            if match:
                return match.group(1).strip()
            first_line = content.splitlines()[0].strip() if content.splitlines() else "Unknown"
            return first_line.strip("'\"")
        return "v6.2.4"

    def check_privileges(self, force_root: Optional[bool] = None, force_rish: Optional[bool] = None) -> Tuple[bool, bool, str]:
        """
        Check privilege level.
        Returns: (has_root, has_rish, mode_label)
        """
        if force_root is True:
            return True, False, "Root Mode"
        if force_rish is True:
            return False, True, "Rish Mode"

        if self._cached_privileges is not None:
            return self._cached_privileges

        # Check Root access
        has_root = False
        try:
            res = subprocess.run(["su", "-c", "exit"], capture_output=True, timeout=1)
            if res.returncode == 0:
                has_root = True
        except Exception:
            has_root = False

        if has_root:
            self._cached_privileges = (True, False, "Root Mode")
            return self._cached_privileges

        # Check Rish access
        has_rish = False
        try:
            res = subprocess.run(["rish", "-c", "exit"], capture_output=True, timeout=1)
            if res.returncode == 0:
                has_rish = True
        except Exception:
            has_rish = False

        if has_rish:
            self._cached_privileges = (False, True, "Rish Mode")
            return self._cached_privileges

        self._cached_privileges = (False, False, "Non-privilege Mode")
        return self._cached_privileges

    def check_network(self, force_refresh: bool = False) -> Tuple[bool, bool, str]:
        """
        Fast socket connectivity check to GitHub and APKMirror with caching.
        Returns: (github_ok, apkmirror_ok, status_text)
        """
        now = time.time()
        if not force_refresh and self._cached_network is not None:
            gh, apk, stat, ts = self._cached_network
            if now - ts < 30.0:  # 30 second cache
                return gh, apk, stat

        github_ok = False
        apkmirror_ok = False

        def _test_host(host: str, port: int = 443, timeout: float = 0.8) -> bool:
            try:
                s = socket.create_connection((host, port), timeout=timeout)
                s.close()
                return True
            except Exception:
                return False

        github_ok = _test_host("api.github.com")
        apkmirror_ok = _test_host("www.apkmirror.com")

        if github_ok and apkmirror_ok:
            status = "Online"
        elif github_ok and not apkmirror_ok:
            status = "Partial (Apkmirror Down)"
        elif not github_ok and apkmirror_ok:
            status = "Partial (Github Down)"
        else:
            status = "Offline"

        self._cached_network = (github_ok, apkmirror_ok, status, now)
        return github_ok, apkmirror_ok, status

    def get_memory_info(self) -> Tuple[int, int, str]:
        """
        Returns (total_ram_mb, avail_ram_mb, formatted_string).
        """
        total_mb = 4096
        avail_mb = 2048
        total_str = "4.0 GB"

        try:
            if Path("/proc/meminfo").exists():
                meminfo = Path("/proc/meminfo").read_text()
                mem_total_k = re.search(r"MemTotal:\s+(\d+)\s+kB", meminfo)
                mem_avail_k = re.search(r"MemAvailable:\s+(\d+)\s+kB", meminfo)

                if mem_total_k:
                    total_mb = int(mem_total_k.group(1)) // 1024
                    total_str = f"{total_mb / 1024:.1f} GB"
                if mem_avail_k:
                    avail_mb = int(mem_avail_k.group(1)) // 1024
        except Exception:
            pass

        return total_mb, avail_mb, total_str

    def get_storage_info(self) -> str:
        """Get internal storage size and used space."""
        try:
            res = subprocess.run(
                ["df", "-h", "/sdcard"],
                capture_output=True,
                text=True,
                timeout=1,
            )
            if res.returncode == 0 and res.stdout.strip():
                lines = res.stdout.strip().splitlines()
                if len(lines) >= 2:
                    parts = lines[-1].split()
                    if len(parts) >= 4:
                        return f"{parts[1]} (Used: {parts[2]})"
        except Exception:
            pass

        try:
            stat = os.statvfs(str(self.workspace_dir))
            total_gb = (stat.f_blocks * stat.f_frsize) / (1024**3)
            free_gb = (stat.f_bfree * stat.f_frsize) / (1024**3)
            used_gb = total_gb - free_gb
            return f"{total_gb:.1f} GB (Used: {used_gb:.1f} GB)"
        except Exception:
            return "Unknown"

    def detect_java_version(self) -> Tuple[str, str]:
        """
        Detect Java runtime version.
        Returns (version_str, package_name) e.g. ("21", "openjdk-21").
        """
        if not shutil.which("java"):
            return "none", "none"

        try:
            res = subprocess.run(
                ["java", "-version"],
                capture_output=True,
                text=True,
                timeout=1,
            )
            output = res.stderr or res.stdout
            first_line = output.splitlines()[0] if output else ""

            if re.search(r'["\s]25[\.\s"]|openjdk 25', first_line):
                return "25", "openjdk-25"
            elif re.search(r'["\s]21[\.\s"]|openjdk 21', first_line):
                return "21", "openjdk-21"
            elif re.search(r'["\s]17[\.\s"]|openjdk 17', first_line):
                return "17", "openjdk-17"
            else:
                digits = re.findall(r"\d+", first_line)
                if digits and digits[0] in ("25", "21", "17"):
                    return digits[0], f"openjdk-{digits[0]}"
                return "other", "openjdk-17"
        except Exception:
            return "none", "none"

    def get_device_specs(self) -> DeviceSpecs:
        """Fetch all specs for display in the Specs screen."""
        if self._cached_specs:
            return self._cached_specs

        total_mb, avail_mb, total_ram_str = self.get_memory_info()

        kernel = "Unknown"
        try:
            kernel = os.uname().release
        except Exception:
            pass

        self._cached_specs = DeviceSpecs(
            device_name=self.getprop("ro.product.model", "Android Device"),
            device_brand=self.getprop("ro.product.brand", "Android"),
            dpi=self.get_dpi(),
            arch=self.get_arch(),
            android_version=self.getprop("ro.build.version.release", "Android 14"),
            sdk_version=self.getprop("ro.build.version.sdk", "34"),
            total_ram=total_ram_str,
            available_ram_mb=avail_mb,
            total_ram_mb=total_mb,
            storage_info=self.get_storage_info(),
            kernel_version=kernel,
            enhancify_version=self.get_version(),
            locale=self.get_locale(),
        )
        return self._cached_specs


# Global helper instance
env = Environment()
