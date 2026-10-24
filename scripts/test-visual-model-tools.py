#!/usr/bin/env python3
"""Offline safety contracts; requires neither model dependencies nor weights."""
import hashlib
import fcntl
import os
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

    def test_explicit_retry_restarts_only_an_owned_regular_partial(self):
        partial = self.root / "model.bin.partial"
        partial.write_bytes(b"unfinished")
        with patch.object(convert, "SOURCE", self.catalog), patch.object(convert.urllib.request, "urlopen", return_value=io.BytesIO(self.body)):
            convert.source_files(self.root, True, retry_partials=True)
        self.assertEqual((self.root / "model.bin").read_bytes(), self.body)
        self.assertFalse(partial.exists())

    def test_retry_refuses_partial_links_and_preserves_their_targets(self):
        outside = self.root / "outside"
        outside.write_bytes(b"keep")
        partial = self.root / "model.bin.partial"
        for hard in [False, True]:
            if hard:
                os.link(outside, partial)
            else:
                partial.symlink_to(outside)
            with patch.object(convert, "SOURCE", self.catalog), patch.object(convert.urllib.request, "urlopen", side_effect=AssertionError("network")):
                with self.assertRaises(ValueError):
                    convert.source_files(self.root, True, retry_partials=True)
            self.assertEqual(outside.read_bytes(), b"keep")
            partial.unlink()

    def test_unverified_optional_loader_config_is_refused(self):
        (self.root / "model.bin").write_bytes(self.body)
        extra = self.root / "adapter_config.json"
        extra.write_text("{}")
        with patch.object(convert, "SOURCE", self.catalog), patch.object(convert.urllib.request, "urlopen", side_effect=AssertionError("network")):
            with self.assertRaisesRegex(ValueError, "Unexpected public source member"):
                convert.source_files(self.root, False)
        self.assertEqual(extra.read_text(), "{}")

    def test_retry_recovers_verified_publish_before_partial_unlink(self):
        target, partial = self.root / "model.bin", self.root / "model.bin.partial"
        target.write_bytes(self.body)
        os.link(target, partial)
        with patch.object(convert, "SOURCE", self.catalog), patch.object(convert.urllib.request, "urlopen", side_effect=AssertionError("network")):
            convert.source_files(self.root, True, retry_partials=True)
        self.assertEqual(target.read_bytes(), self.body)
        self.assertFalse(partial.exists())
        self.assertEqual(target.stat().st_nlink, 1)

    def test_completed_target_does_not_allow_deleting_an_unrelated_hardlink(self):
        target, partial, outside = self.root / "model.bin", self.root / "model.bin.partial", self.root / "outside"
        target.write_bytes(self.body)
        outside.write_bytes(b"keep")
        os.link(outside, partial)
        with patch.object(convert, "SOURCE", self.catalog), patch.object(convert.urllib.request, "urlopen", side_effect=AssertionError("network")):
            with self.assertRaises(ValueError):
                convert.source_files(self.root, True, retry_partials=True)
        self.assertEqual(outside.read_bytes(), b"keep")
        self.assertEqual(target.read_bytes(), self.body)

    def test_source_cache_writer_lock_refuses_concurrent_prepare(self):
        descriptor = os.open(self.root / ".oswind-source.lock", os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with patch.object(convert, "SOURCE", self.catalog), patch.object(convert.urllib.request, "urlopen", side_effect=AssertionError("network")):
                with self.assertRaisesRegex(ValueError, "already being prepared"):
                    convert.source_files(self.root, True, retry_partials=True)
        finally:
            os.close(descriptor)

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
