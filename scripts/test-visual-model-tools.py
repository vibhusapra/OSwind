#!/usr/bin/env python3
"""Offline safety contracts; requires neither model dependencies nor weights."""
import hashlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(file))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


convert = load("visual_converter", "convert-visual-model.py")
evaluate = load("visual_evaluator", "evaluate-visual-model.py")


class VisualToolContracts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="oswind-visual-tools-")
        self.root = Path(self.temp.name)
        self.body = b"synthetic public weights"
        self.catalog = dict(repository="synthetic/public", revision="a" * 40,
                            files=[dict(path="model.bin", bytes=len(self.body), sha256=hashlib.sha256(self.body).hexdigest())])

    def tearDown(self):
        self.temp.cleanup()

    def test_offline_source_verification_never_downloads_or_creates(self):
        with patch.object(convert, "SOURCE", self.catalog), patch.object(convert.urllib.request, "urlopen", side_effect=AssertionError("network")):
            with self.assertRaises(ValueError):
                convert.source_files(self.root / "missing", False)
            self.assertFalse((self.root / "missing").exists())
            (self.root / "model.bin").write_bytes(self.body)
            convert.source_files(self.root, False)
            (self.root / "model.bin").write_bytes(b"X" * len(self.body))
            with self.assertRaises(ValueError):
                convert.source_files(self.root, False)

    def test_source_symlink_rejected(self):
        (self.root / "outside").write_bytes(self.body)
        (self.root / "model.bin").symlink_to(self.root / "outside")
        with patch.object(convert, "SOURCE", self.catalog), self.assertRaises(ValueError):
            convert.source_files(self.root, False)

    def test_bad_download_does_not_publish(self):
        with patch.object(convert, "SOURCE", self.catalog), patch.object(convert.urllib.request, "urlopen", return_value=io.BytesIO(b"X" * len(self.body))):
            with self.assertRaises(ValueError):
                convert.source_files(self.root, True)
        self.assertFalse((self.root / "model.bin").exists())

    def test_existing_partial_and_new_destination_never_overwritten(self):
        (self.root / "model.bin.partial").write_bytes(b"keep partial")
        with patch.object(convert, "SOURCE", self.catalog), patch.object(convert.urllib.request, "urlopen", side_effect=AssertionError("network")):
            with self.assertRaises(FileExistsError):
                convert.source_files(self.root, True)
        self.assertEqual((self.root / "model.bin.partial").read_bytes(), b"keep partial")
        (self.root / "model.bin.partial").unlink()

        def response(*args, **kwargs):
            (self.root / "model.bin").write_bytes(b"concurrent destination")
            return io.BytesIO(self.body)

        with patch.object(convert, "SOURCE", self.catalog), patch.object(convert.urllib.request, "urlopen", side_effect=response):
            with self.assertRaises(FileExistsError):
                convert.source_files(self.root, True)
        self.assertEqual((self.root / "model.bin").read_bytes(), b"concurrent destination")

    def test_downloader_uses_pinned_url_without_headers(self):
        with patch.object(convert, "SOURCE", self.catalog), patch.object(convert.urllib.request, "urlopen", return_value=io.BytesIO(self.body)) as request:
            convert.source_files(self.root, True)
        self.assertEqual(request.call_args.args, ("https://huggingface.co/synthetic/public/resolve/" + "a" * 40 + "/model.bin",))
        self.assertEqual(request.call_args.kwargs, dict(timeout=120))
        self.assertEqual((self.root / "model.bin").read_bytes(), self.body)
        self.assertFalse((self.root / "model.bin.partial").exists())

    def test_dataset_download_bounds_and_existing_symlinks(self):
        with patch.object(evaluate.urllib.request, "urlopen", return_value=io.BytesIO(b"oversized")):
            with self.assertRaises(ValueError):
                evaluate.fetch("https://example.invalid", self.root / "dataset", 2)
        self.assertFalse((self.root / "dataset").exists())
        (self.root / "outside").write_bytes(b"a")
        (self.root / "link").symlink_to(self.root / "outside")
        with self.assertRaises(ValueError):
            evaluate.fetch("https://example.invalid", self.root / "link", 2)

    def test_source_catalog_is_exact_and_public(self):
        self.assertEqual(convert.SOURCE["repository"], "google/siglip2-base-patch16-224")
        self.assertEqual(len(convert.SOURCE["revision"]), 40)
        self.assertEqual(len(convert.SOURCE["files"]), 8)
        self.assertTrue(all(len(x["sha256"]) == 64 and x["bytes"] > 0 for x in convert.SOURCE["files"]))


if __name__ == "__main__":
    unittest.main()
