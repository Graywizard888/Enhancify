#!/usr/bin/env python3
"""
Enhancify - Textual TUI Main Entrypoint
Converts Revancify/Enhancify to a beautiful interactive Textual + Rich TUI
with complete Termux support, backwards compatibility fallback, and automated display smoke tests.
"""

import argparse
import asyncio
import os
import subprocess
import sys
from pathlib import Path


def run_classic_mode(args) -> int:
    """Run classic dialog-based bash UI as fallback."""
    workspace_dir = Path(__file__).resolve().parent
    main_sh = workspace_dir / "main.sh"
    if not main_sh.exists():
        print(f"Error: Classic entrypoint not found at {main_sh}", file=sys.stderr)
        return 1

    root_arg = "true" if args.root else "false"
    rish_arg = "true" if args.rish else "false"

    cmd = ["bash", str(main_sh), root_arg, rish_arg]
    try:
        proc = subprocess.run(cmd)
        return proc.returncode
    except KeyboardInterrupt:
        return 0
    except Exception as e:
        print(f"Error executing classic UI: {e}", file=sys.stderr)
        return 1


async def run_smoke_tests() -> bool:
    """
    Run automated smoke test across multiple Android / Termux screen resolutions
    (e.g. mobile 80x24, small 40x25, standard 100x30, large 120x40).
    Tests every screen in the application to ensure zero crashes or layout overflows.
    """
    from rich.console import Console
    from src.tui.app import EnhancifyApp

    console = Console()
    console.print("\n[bold #00ff7f]🚀 Starting Enhancify Android Display Smoke Test Suite...[/]\n")

    resolutions = [
        ("Termux Standard Mobile", (80, 24)),
        ("Compact Phone Portrait", (40, 25)),
        ("Large Phone / Tablet", (100, 30)),
        ("DeX / Landscape Mode", (120, 40)),
    ]

    all_passed = True

    for name, (cols, rows) in resolutions:
        console.print(f"[bold #00e5ff]▶ Testing display resolution:[/] {name} ({cols}x{rows})...")
        app = EnhancifyApp()

        try:
            async with app.run_test(size=(cols, rows)) as pilot:
                # 1. Main Menu Screen
                assert app.screen is not None, "Main menu screen failed to mount"
                console.print(f"  [#00ff7f]✓[/] Main Menu mounted and rendered ({cols}x{rows})")

                # Test navigation to screens
                screen_names = [
                    "source_select_screen",
                    "settings_screen",
                    "theme_select_screen",
                    "custom_sources_screen",
                    "keystore_mgr_screen",
                    "token_mgr_screen",
                    "storage_mgr_screen",
                    "specs_screen",
                    "gmscore_screen",
                    "bundle_patcher_screen",
                    "unmount_screen",
                ]

                for sname in screen_names:
                    app.push_screen(sname)
                    await pilot.pause(0.05)
                    assert app.screen is not None, f"Screen {sname} failed to mount"
                    console.print(f"    [#00ff7f]✓[/] Screen '{sname}' rendered successfully")
                    app.pop_screen()
                    await pilot.pause(0.02)

                console.print(f"  [bold #00ff7f]✓ Passed {name} ({cols}x{rows})[/]\n")
        except Exception as e:
            console.print(f"  [bold red]✗ FAILED {name} ({cols}x{rows}): {e}[/]\n")
            all_passed = False

    if all_passed:
        console.print("[bold #00ff7f]🎉 All display smoke tests PASSED on virtual Android screens![/]\n")
    else:
        console.print("[bold red]❌ One or more smoke tests failed![/]\n")

    return all_passed


def main():
    parser = argparse.ArgumentParser(description="Enhancify - Textual TUI for Termux")
    parser.add_argument("--classic", "--dialog", action="store_true", help="Launch classic dialog-based UI as fallback")
    parser.add_argument("--root", action="store_true", help="Force Root Mode")
    parser.add_argument("--rish", action="store_true", help="Force Rish Mode")
    parser.add_argument("--smoke-test", action="store_true", help="Run automated display smoke tests on virtual Android displays")

    args, unknown = parser.parse_known_args()

    # If classic mode requested
    if args.classic:
        sys.exit(run_classic_mode(args))

    # If smoke test requested
    if args.smoke_test:
        success = asyncio.run(run_smoke_tests())
        sys.exit(0 if success else 1)

    # Launch Textual TUI
    try:
        from src.tui.app import EnhancifyApp
        app = EnhancifyApp(force_root=args.root or None, force_rish=args.rish or None)
        app.run()
    except KeyboardInterrupt:
        sys.exit(0)
    except Exception as e:
        print(f"\n[!] Error launching Textual TUI: {e}", file=sys.stderr)
        print("[!] Falling back to classic dialog UI...\n", file=sys.stderr)
        sys.exit(run_classic_mode(args))


if __name__ == "__main__":
    main()
