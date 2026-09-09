"""
Enhancify Utility Functions
Provides file downloading with aria2c / requests fallback, progress reporting,
size formatting, cancellable downloads, and process execution helpers.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import tempfile
import threading
import time
from enum import Enum
from pathlib import Path
from typing import Callable, List, Optional, Tuple, Union

import requests

from src.config import config


class DownloadResult(str, Enum):
    OK = "ok"
    CANCELLED = "cancelled"
    ERROR = "error"


def format_size(size_bytes: int) -> str:
    """Format bytes into human-readable IEC size string (e.g. '15.4 MB')."""
    if size_bytes <= 0:
        return "0 B"
    n = float(size_bytes)
    for unit in ["B", "KB", "MB", "GB", "TB"]:
        if n < 1024:
            return f"{n:.1f} {unit}" if unit != "B" else f"{int(n)} B"
        n /= 1024
    return f"{n:.1f} PB"


def _is_cancelled(cancel_event: Optional[threading.Event]) -> bool:
    return bool(cancel_event is not None and cancel_event.is_set())


def download_file(
    url: str,
    output_path: Path,
    expected_size: int = 0,
    progress_callback: Optional[Callable[[int, int, str], None]] = None,
    headers: Optional[dict] = None,
    cancel_event: Optional[threading.Event] = None,
) -> bool:
    """
    Download a file with progress tracking and size verification.
    Uses aria2c if available and network acceleration is enabled,
    otherwise uses streaming requests.

    Returns True on success, False on failure or cancel.
    Prefer download_file_ex() when cancel vs error must be distinguished.
    """
    return download_file_ex(
        url, output_path, expected_size, progress_callback, headers, cancel_event
    ) == DownloadResult.OK


def download_file_ex(
    url: str,
    output_path: Path,
    expected_size: int = 0,
    progress_callback: Optional[Callable[[int, int, str], None]] = None,
    headers: Optional[dict] = None,
    cancel_event: Optional[threading.Event] = None,
) -> DownloadResult:
    """
    Download a file; returns DownloadResult.OK / CANCELLED / ERROR.
    """
    output_path = Path(output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    if _is_cancelled(cancel_event):
        return DownloadResult.CANCELLED

    use_aria2 = (
        not config.is_on("DISABLE_NETWORK_ACCELERATION")
        and shutil.which("aria2c") is not None
    )

    if use_aria2:
        result = _download_aria2(
            url, output_path, expected_size, progress_callback, headers, cancel_event
        )
        if result != DownloadResult.ERROR:
            return result
        # fall through to requests on hard error

    return _download_requests(
        url, output_path, expected_size, progress_callback, headers, cancel_event
    )


def _download_aria2(
    url: str,
    output_path: Path,
    expected_size: int,
    progress_callback: Optional[Callable[[int, int, str], None]],
    headers: Optional[dict],
    cancel_event: Optional[threading.Event],
) -> DownloadResult:
    try:
        cmd = [
            "aria2c",
            "--console-log-level=warn",
            "--summary-interval=1",
            "--download-result=hide",
            "--no-conf",
            f"--dir={output_path.parent}",
            f"--out={output_path.name}",
            "--split=8",
            "--min-split-size=5M",
            "--max-connection-per-server=8",
            "--file-allocation=none",
            "--disk-cache=50M",
            "--enable-http-pipelining=true",
            "--retry-wait=1",
            "--max-tries=3",
            "--auto-file-renaming=false",
            "--allow-overwrite=true",
            url,
        ]
        if headers:
            for k, v in headers.items():
                cmd.append(f"--header={k}: {v}")

        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )

        cancelled = False
        if proc.stdout:
            for line in proc.stdout:
                if _is_cancelled(cancel_event):
                    cancelled = True
                    try:
                        proc.terminate()
                        try:
                            proc.wait(timeout=2)
                        except subprocess.TimeoutExpired:
                            proc.kill()
                    except Exception:
                        pass
                    break
                if "%" in line:
                    m = re.search(r"\((\d{1,3})%\)", line) or re.search(r"(\d{1,3})%", line)
                    if m and progress_callback:
                        pct = int(m.group(1))
                        cur_size = int(expected_size * (pct / 100)) if expected_size > 0 else 0
                        progress_callback(cur_size, expected_size, f"{pct}%")

        if cancelled:
            output_path.unlink(missing_ok=True)
            # aria2 partials
            for p in output_path.parent.glob(output_path.name + ".*"):
                p.unlink(missing_ok=True)
            return DownloadResult.CANCELLED

        proc.wait()
        if proc.returncode == 0 and output_path.exists():
            if expected_size <= 0 or output_path.stat().st_size == expected_size:
                if progress_callback:
                    progress_callback(expected_size or output_path.stat().st_size,
                                      expected_size or output_path.stat().st_size, "100%")
                return DownloadResult.OK
        return DownloadResult.ERROR
    except Exception:
        return DownloadResult.ERROR


def _download_requests(
    url: str,
    output_path: Path,
    expected_size: int,
    progress_callback: Optional[Callable[[int, int, str], None]],
    headers: Optional[dict],
    cancel_event: Optional[threading.Event],
) -> DownloadResult:
    req_headers = {
        "User-Agent": (
            "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 "
            "(KHTML, like Gecko) Chrome/142.0.0.0 Mobile Safari/537.36"
        ),
    }
    if headers:
        req_headers.update(headers)

    try:
        with requests.get(url, headers=req_headers, stream=True, timeout=15) as r:
            r.raise_for_status()
            total_len = int(r.headers.get("content-length", expected_size) or 0)
            if expected_size <= 0:
                expected_size = total_len

            downloaded = 0
            with open(output_path, "wb") as f:
                for chunk in r.iter_content(chunk_size=65536):
                    if _is_cancelled(cancel_event):
                        f.close()
                        output_path.unlink(missing_ok=True)
                        return DownloadResult.CANCELLED
                    if chunk:
                        f.write(chunk)
                        downloaded += len(chunk)
                        if progress_callback:
                            if expected_size > 0:
                                pct_str = f"{(downloaded / expected_size * 100):.0f}%"
                            else:
                                pct_str = format_size(downloaded)
                            progress_callback(downloaded, expected_size, pct_str)

        if expected_size > 0 and output_path.stat().st_size != expected_size:
            output_path.unlink(missing_ok=True)
            return DownloadResult.ERROR

        if progress_callback and expected_size > 0:
            progress_callback(expected_size, expected_size, "100%")
        return DownloadResult.OK
    except Exception:
        output_path.unlink(missing_ok=True)
        return DownloadResult.ERROR


def run_command(
    cmd: List[str],
    cwd: Optional[Path] = None,
    timeout: Optional[int] = None,
    log_file: Optional[Path] = None,
) -> Tuple[int, str, str]:
    """Execute a system command and return (returncode, stdout, stderr)."""
    try:
        proc = subprocess.run(
            cmd,
            cwd=str(cwd) if cwd else None,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        if log_file and proc.stdout:
            with open(log_file, "a", encoding="utf-8") as f:
                f.write(proc.stdout + "\n")
        return proc.returncode, proc.stdout, proc.stderr
    except subprocess.TimeoutExpired:
        return 124, "", "Command timed out"
    except Exception as e:
        return 1, "", str(e)
