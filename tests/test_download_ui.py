"""Tests for gradient progress/spinner widgets, download cancel, and modal text parity."""

from __future__ import annotations

import threading
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from src.tui.widgets.dialogs import DownloadProgressModal, ParseProgressModal
from src.tui.widgets.gradient import GradientProgressBar, GradientSpinner, multi_lerp
from src.utils import DownloadResult, download_file_ex, format_size


class TestGradientWidgets(unittest.TestCase):
    def test_multi_lerp_endpoints(self):
        stops = ["#00ff7f", "#00e5ff", "#7c4dff"]
        self.assertEqual(multi_lerp(stops, 0.0).lower(), "#00ff7f")
        self.assertEqual(multi_lerp(stops, 1.0).lower(), "#7c4dff")
        mid = multi_lerp(stops, 0.5)
        self.assertTrue(mid.startswith("#") and len(mid) == 7)

    def test_progress_bar_fraction(self):
        bar = GradientProgressBar()
        bar.set_progress(50, 100)
        self.assertAlmostEqual(bar.progress, 0.5)
        bar.set_fraction(1.2)
        self.assertEqual(bar.progress, 1.0)
        bar.set_progress(0, 0)
        self.assertEqual(bar.progress, 0.0)

    def test_spinner_frames(self):
        spin = GradientSpinner(label="Working")
        self.assertEqual(spin.label, "Working")
        spin.set_label("50%")
        self.assertEqual(spin.label, "50%")
        self.assertGreater(len(GradientSpinner.FRAME_CHARS), 4)


class TestDownloadCancel(unittest.TestCase):
    def test_cancel_before_start(self):
        ev = threading.Event()
        ev.set()
        out = Path(tempfile.mkdtemp()) / "x.bin"
        result = download_file_ex(
            "https://example.com/x",
            out,
            expected_size=10,
            cancel_event=ev,
        )
        self.assertEqual(result, DownloadResult.CANCELLED)
        self.assertFalse(out.exists())

    def test_cancel_mid_stream(self):
        """Simulate streaming download that gets cancelled after first chunk."""
        ev = threading.Event()
        out = Path(tempfile.mkdtemp()) / "partial.bin"
        chunks = [b"A" * 1000, b"B" * 1000, b"C" * 1000]

        class FakeResp:
            status_code = 200
            headers = {"content-length": str(sum(len(c) for c in chunks))}

            def raise_for_status(self):
                return None

            def iter_content(self, chunk_size=65536):
                for i, c in enumerate(chunks):
                    if i == 1:
                        ev.set()  # cancel after first chunk delivered next loop
                    yield c

            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

        with mock.patch("src.utils.shutil.which", return_value=None):  # force requests path
            with mock.patch("src.utils.requests.get", return_value=FakeResp()):
                # Also disable aria2 path via config
                with mock.patch("src.utils.config.is_on", return_value=True):  # DISABLE_NETWORK_ACCELERATION on
                    result = download_file_ex(
                        "https://example.com/x",
                        out,
                        expected_size=3000,
                        cancel_event=ev,
                    )
        self.assertEqual(result, DownloadResult.CANCELLED)
        self.assertFalse(out.exists())


class TestModalTexts(unittest.TestCase):
    def test_asset_file_text(self):
        m = DownloadProgressModal.for_asset_file("CLI-4.0.0.jar", 12_000_000)
        self.assertIn("| Downloading Assets |", m.dialog_title)
        self.assertIn("File    : CLI-4.0.0.jar", m._body)
        self.assertIn("Size    :", m._body)
        self.assertIn("Downloading...", m._body)

    def test_assets_batch_text(self):
        m = DownloadProgressModal.for_assets_batch(2, 20_000_000, accelerated=True)
        self.assertIn("Downloading 2 file(s) simultaneously", m._body)
        self.assertIn("Accelerated: 8 parts each", m._body)

    def test_app_scrape_and_file_text(self):
        m = DownloadProgressModal.for_app_scrape("YouTube", "19.16.39")
        self.assertIn("App    : YouTube", m._body)
        self.assertIn("Version: 19.16.39", m._body)
        self.assertIn("Scraping Download Link...", m._body)

        m2 = DownloadProgressModal.for_app_file("YouTube", "19.16.39", "apk", 50_000_000)
        self.assertIn("File: YouTube-19.16.39.apk", m2._body)
        self.assertIn("Size:", m2._body)
        self.assertIn("Downloading...", m2._body)

    def test_dependency_text(self):
        m = DownloadProgressModal.for_dependency("Wst_Xda GmsCore 7.1.1", 40_000_000)
        self.assertIn("File    : Wst_Xda GmsCore 7.1.1", m._body)
        self.assertIn("Downloading...", m._body)

    def test_parse_cli_text_bash_parity(self):
        m = ParseProgressModal("Anddea", from_cli=True)
        self.assertTrue(m.from_cli)
        self.assertIn("Please Wait!!", m._body)
        self.assertIn(
            "Parsing JSON file for Anddea patches from CLI Output.", m._body
        )
        self.assertIn("This might take some time.", m._body)

    def test_parse_api_text(self):
        m = ParseProgressModal("ReVanced", from_cli=False)
        self.assertFalse(m.from_cli)
        self.assertIn("from API.", m._body)

    def test_cancel_sets_event(self):
        m = DownloadProgressModal.for_asset_file("x.jar", 1)
        self.assertFalse(m.was_cancelled)
        m.action_cancel()
        self.assertTrue(m.was_cancelled)
        self.assertTrue(m.cancel_event.is_set())


class TestFormatSize(unittest.TestCase):
    def test_sizes(self):
        self.assertEqual(format_size(0), "0 B")
        self.assertIn("KB", format_size(2048))
        self.assertIn("MB", format_size(5_000_000))


if __name__ == "__main__":
    unittest.main()
