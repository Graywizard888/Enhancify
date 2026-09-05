"""
Enhancify CLI Patcher Execution Engine
Builds Java JVM flags, GC arguments, CLI arguments, streams live logs,
and writes comprehensive patch logs to $STORAGE/patch_log.txt.
"""

import os
import re
import shutil
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Set, Tuple

from src.config import config
from src.environment import env


MIN_HEAP_MB = 1024


@dataclass
class PatchExecutionConfig:
    source_name: str
    app_name: str
    app_version: str
    pkg_name: str
    input_apk_path: Path
    output_apk_path: Path
    cli_jar: Path
    patches_file: Path
    enabled_patches: Set[str]
    patch_options: List[Dict[str, Any]]
    multi_sources: Optional[List[str]] = None
    multi_patches_files: Optional[List[Path]] = None


class PatcherEngine:
    """Executes the ReVanced / Morphe / Inotia CLI patcher with JVM tuning."""

    def __init__(self, workspace_dir: Optional[Path] = None):
        self.workspace_dir = workspace_dir or Path(__file__).resolve().parent.parent
        self.storage_dir = env.storage_dir
        self.log_file = self.storage_dir / "patch_log.txt"

    def _calculate_heap_and_gc(self) -> Tuple[int, str, List[str]]:
        """Calculate heap size in MB and choose GC engine."""
        _, avail_mb, _ = env.get_memory_info()
        heap_mb = max(MIN_HEAP_MB, int(avail_mb * 0.75))

        # Low memory override
        if avail_mb < MIN_HEAP_MB:
            gc_mode = "SerialGC (Low Memory Fallback)"
            jvm_args = [
                f"-Xms128m",
                f"-Xmx{heap_mb}m",
                "-XX:+UseSerialGC",
                "-XX:+OptimizeStringConcat",
            ]
            return heap_mb, gc_mode, jvm_args

        # Parallel GC
        if config.is_on("USE_PARALLEL_GC"):
            gc_mode = "ParallelGC (Enabled)"
            jvm_args = [
                f"-Xms256m",
                f"-Xmx{heap_mb}m",
                "-XX:+UseParallelGC",
                "-XX:ParallelGCThreads=4",
                "-XX:+OptimizeStringConcat",
            ]
            return heap_mb, gc_mode, jvm_args

        # Default G1GC
        gc_mode = "G1GC (Default)"
        jvm_args = [
            f"-Xms256m",
            f"-Xmx{heap_mb}m",
            "-XX:+UseG1GC",
            "-XX:+OptimizeStringConcat",
        ]
        return heap_mb, gc_mode, jvm_args

    def write_log_header(
        self,
        cfg: PatchExecutionConfig,
        heap_mb: int,
        gc_mode: str,
        jvm_args: List[str],
        lib_args: List[str],
        bytecode_args: List[str],
        signing_args: List[str],
        patch_args: List[str],
    ) -> None:
        """Write formatted header to patch_log.txt."""
        specs = env.get_device_specs()
        java_ver, _ = env.detect_java_version()

        header = [
            "╔═══════════════════════════════════════════════════════════════╗",
            "║                  ENHANCIFY PATCHING LOGS                      ║",
            "╠═══════════════════════════════════════════════════════════════╣",
            "║ DEVICE INFO",
            "╠═══════════════════════════════════════════════════════════════╣",
            f"║ Device Model      : {specs.device_brand} {specs.device_name}",
            f"║ Architecture      : {specs.arch}",
            f"║ Total RAM         : {specs.total_ram}",
            f"║ Available RAM     : {specs.available_ram_mb} MB",
            f"║ Heap Allocated    : {heap_mb} MB",
            f"║ Android Version   : {specs.android_version} (SDK {specs.sdk_version})",
            f"║ Java Version      : OpenJDK {java_ver}",
            f"║ GC Mode           : {gc_mode}",
            "╠═══════════════════════════════════════════════════════════════╣",
            "║ APP INFO",
            "╠═══════════════════════════════════════════════════════════════╣",
            f"║ App Name          : {cfg.app_name}",
            f"║ App Version       : {cfg.app_version}",
            f"║ Package           : {cfg.pkg_name}",
            f"║ CLI               : {cfg.cli_jar.name}",
            f"║ Patches           : {cfg.patches_file.name}",
            f"║ Source            : {cfg.source_name}",
            "╠═══════════════════════════════════════════════════════════════╣",
            "║ JVM ARGUMENTS",
            "╠═══════════════════════════════════════════════════════════════╣",
        ]
        for arg in jvm_args:
            header.append(f"║ {arg}")

        header.extend([
            "╠═══════════════════════════════════════════════════════════════╣",
            "║ LIB OPTIMIZATION ARGUMENTS",
            "╠═══════════════════════════════════════════════════════════════╣",
            f"║ {' '.join(lib_args) if lib_args else 'None'}",
            "╠═══════════════════════════════════════════════════════════════╣",
            "║ BYTECODE MODE ARGUMENTS",
            "╠═══════════════════════════════════════════════════════════════╣",
            f"║ {' '.join(bytecode_args) if bytecode_args else 'None'}",
            "╠═══════════════════════════════════════════════════════════════╣",
            "║ SIGNING ARGUMENTS",
            "╠═══════════════════════════════════════════════════════════════╣",
            f"║ {' '.join(signing_args) if signing_args else 'None'}",
            "╠═══════════════════════════════════════════════════════════════╣",
            "║ PATCH ARGUMENTS",
            "╠═══════════════════════════════════════════════════════════════╣",
            f"║ Total Patches Enabled: {len(cfg.enabled_patches)}",
            "╚═══════════════════════════════════════════════════════════════╝",
            "",
            "========================= PATCHING LOGS =========================",
            "",
        ])

        self.storage_dir.mkdir(parents=True, exist_ok=True)
        self.log_file.write_text("\n".join(header) + "\n", encoding="utf-8")

    def run_patch(
        self,
        cfg: PatchExecutionConfig,
        log_callback: Optional[Callable[[str], None]] = None,
        progress_callback: Optional[Callable[[float, str], None]] = None,
    ) -> Tuple[bool, str]:
        """Execute patching process and stream logs."""
        if not shutil.which("java"):
            return False, "Java runtime (OpenJDK 17/21/25) not found in PATH!"

        heap_mb, gc_mode, jvm_args = self._calculate_heap_and_gc()

        # Build CLI command arguments
        cmd = ["java"] + jvm_args + ["-jar", str(cfg.cli_jar), "patch", "--force", "--exclusive"]

        # Patches bundle arg
        if config.is_on("ENABLE_MULTIPATCHER") and cfg.multi_patches_files:
            for pf in cfg.multi_patches_files:
                cmd.append(f"--patches={pf}")
        else:
            cmd.append(f"--patches={cfg.patches_file}")

        cfg.output_apk_path.parent.mkdir(parents=True, exist_ok=True)
        cmd.append(f"--out={cfg.output_apk_path}")

        # Signing args
        caps = config.get_cli_capabilities()
        signing_args = []
        if config.is_on("Use_CUSTOM_KEYSTORE") and caps.get("unsigned"):
            signing_args = ["--unsigned"]
        else:
            signing_args = [f"--keystore={self.storage_dir / 'revancify.keystore'}"]
        cmd.extend(signing_args)

        # Verification args
        verification_args = []
        if cfg.source_name == "ReVanced":
            verification_args = ["--bypass-verification"]
            cmd.extend(verification_args)

        # Lib optimization args
        lib_args = []
        arch = env.get_arch()
        if config.is_on("CLI_RIPLIB_ANTISPLIT"):
            if caps.get("striplibs"):
                lib_args = [f"--striplibs={arch}"]
            elif caps.get("riplib"):
                lib_args = [f"--rip-lib={arch}"]
        cmd.extend(lib_args)

        # Bytecode mode args
        bytecode_args = []
        if cfg.patches_file.suffix == ".mpp":
            bytecode_args = ["--bytecode-mode=STRIP_FAST"]
            cmd.extend(bytecode_args)

        # Patch options map
        options_map: Dict[str, Dict[str, Any]] = {}
        for opt in cfg.patch_options:
            pn = opt.get("patchName")
            if pn in cfg.enabled_patches and opt.get("value") is not None:
                if pn not in options_map:
                    options_map[pn] = {}
                options_map[pn][opt.get("key")] = opt.get("value")

        # Enable patches and options
        patch_args = []
        for patch in sorted(list(cfg.enabled_patches)):
            cmd.append("--enable")
            cmd.append(patch)
            patch_args.append(f"--enable {patch}")

            if patch in options_map:
                for k, v in options_map[patch].items():
                    val_str = str(v)
                    cmd.append(f"--options={k}={val_str}")
                    patch_args.append(f"--options={k}={val_str}")

        cmd.append(str(cfg.input_apk_path))

        # Write log header
        self.write_log_header(
            cfg, heap_mb, gc_mode, jvm_args, lib_args, bytecode_args, signing_args, patch_args
        )

        # Execute process and stream logs
        try:
            with open(self.log_file, "a", encoding="utf-8") as log_f:
                log_f.write(f"Executing: {' '.join(cmd)}\n\n")

                proc = subprocess.Popen(
                    cmd,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    bufsize=1,
                )

                if proc.stdout:
                    for line in proc.stdout:
                        log_f.write(line)
                        log_f.flush()
                        clean_line = line.strip()
                        if log_callback:
                            log_callback(clean_line)

                        # Update progress hints
                        if progress_callback:
                            if "Compiling resources" in clean_line:
                                progress_callback(0.2, "Compiling resources...")
                            elif "Executing patches" in clean_line:
                                progress_callback(0.5, "Executing patches...")
                            elif "Writing modified files" in clean_line:
                                progress_callback(0.8, "Writing modified files...")
                            elif "Signing" in clean_line:
                                progress_callback(0.9, "Signing APK...")

                proc.wait()

            # Check for memory errors in log
            log_content = self.log_file.read_text(encoding="utf-8")
            if any(err in log_content for err in ["OutOfMemoryError", "Cannot allocate memory", "GC overhead limit exceeded", "Java heap space"]):
                return False, f"Patching failed due to Java Out Of Memory Error! (Allocated: {heap_mb}MB)"

            if proc.returncode != 0 or not cfg.output_apk_path.exists():
                return False, f"Patching failed with exit code {proc.returncode}. Check logs for details."

            return True, f"Patching completed successfully! Output: {cfg.output_apk_path.name}"
        except Exception as e:
            return False, f"Execution failed: {e}"


# Global patcher engine instance
patcher_engine = PatcherEngine()
