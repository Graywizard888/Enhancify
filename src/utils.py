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
from typing import Callable, Dict, List, Optional, Tuple, Union

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


def _aria2_command(
    url: str,
    output_path: Path,
    headers: Optional[dict] = None,
) -> List[str]:
    """Build an accelerated aria2c command (8-way split — classic parity)."""
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
    return cmd


def _cleanup_partial(output_path: Path) -> None:
    """Remove a partial download + aria2c temp files."""
    try:
        output_path.unlink(missing_ok=True)
        for p in output_path.parent.glob(output_path.name + ".*"):
            p.unlink(missing_ok=True)
    except Exception:
        pass


def download_files_parallel(
    jobs: List[Tuple[str, Path, int]],
    labels: List[str],
    progress_callback: Optional[Callable[[str, int, int, str], None]] = None,
    cancel_event: Optional[threading.Event] = None,
) -> Dict[str, DownloadResult]:
    """
    Download several files at the SAME time with separate accelerated aria2c
    processes (classic `downloadBatchAria2c` parity — each file gets its own
    8-part split, all running concurrently).

    jobs:   [(url, output_path, expected_size), ...]
    labels: one label per job (shown in the UI mixed-gauge rows)
    progress_callback(label, current, total, pct)

    Returns {label: DownloadResult}. All CANCELLED if the user cancelled.
    """
    if len(jobs) != len(labels):
        raise ValueError("jobs and labels must have the same length")
    if not jobs:
        return {}
    if _is_cancelled(cancel_event):
        return {label: DownloadResult.CANCELLED for label in labels}

    results: Dict[str, DownloadResult] = {label: DownloadResult.ERROR for label in labels}
    procs: List[Tuple[subprocess.Popen, str, str, Path, int]] = []
    done: Dict[str, bool] = {label: False for label in labels}

    for (url, path, size), label in zip(jobs, labels):
        if _is_cancelled(cancel_event):
            break
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        try:
            proc = subprocess.Popen(
                _aria2_command(url, path),
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
            )
        except Exception:
            continue
        procs.append((proc, label, url, path, size))

    def _reader(label: str, proc: subprocess.Popen, url: str, path: Path, size: int) -> None:
        try:
            if proc.stdout:
                for line in proc.stdout:
                    if _is_cancelled(cancel_event):
                        break
                    if "%" in line:
                        m = re.search(r"\((\d{1,3})%\)", line) or re.search(r"(\d{1,3})%", line)
                        if m and progress_callback:
                            pct = int(m.group(1))
                            cur = int(size * (pct / 100)) if size > 0 else 0
                            progress_callback(label, cur, size, f"{pct}%")
        except Exception:
            pass
        finally:
            try:
                if proc.stdout:
                    proc.stdout.close()
            except Exception:
                pass
            done[label] = True

    threads = [
        threading.Thread(
            target=_reader,
            args=(label, proc, url, path, size),
            daemon=True,
        )
        for (proc, label, url, path, size) in procs
    ]
    for t in threads:
        t.start()

    # Wait until every aria2c output is fully drained or cancel is requested.
    while not all(done.values()):
        if _is_cancelled(cancel_event):
            for proc, _label, _url, _path, _size in procs:
                try:
                    proc.terminate()
                    try:
                        proc.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                except Exception:
                    pass
            break
        time.sleep(0.15)

    for t in threads:
        t.join(timeout=5)

    for proc, label, _url, path, size in procs:
        if _is_cancelled(cancel_event):
            _cleanup_partial(path)
            results[label] = DownloadResult.CANCELLED
            continue
        try:
            proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            try:
                proc.kill()
            except Exception:
                pass
            results[label] = DownloadResult.ERROR
            continue
        if (
            proc.returncode == 0
            and path.exists()
            and (size <= 0 or path.stat().st_size == size)
        ):
            results[label] = DownloadResult.OK
        else:
            _cleanup_partial(path)
            results[label] = DownloadResult.ERROR

    return results


def _download_aria2(
    url: str,
    output_path: Path,
    expected_size: int,
    progress_callback: Optional[Callable[[int, int, str], None]],
    headers: Optional[dict],
    cancel_event: Optional[threading.Event],
) -> DownloadResult:
    try:
        cmd = _aria2_command(url, output_path, headers)

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
