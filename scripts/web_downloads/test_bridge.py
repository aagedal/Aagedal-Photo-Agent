"""Run with Vendor/web-download-runtime/bin/python3 -I scripts/web_downloads/test_bridge.py."""
import contextlib
import importlib.util
from pathlib import Path
import re
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Vendor/web-download-runtime/packages"))
spec = importlib.util.spec_from_file_location("bridge", ROOT / "Aagedal Photo Agent/Resources/WebDownloads/web_download_bridge.py")
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)
from gallery_dl import extractor, job
from gallery_dl.extractor.common import Extractor
from gallery_dl.extractor.message import Message


class SyntheticPost(Extractor):
    category = "instagram"
    subcategory = "post"
    filename_fmt = "{num:03}.{extension}"
    directory_fmt = ()
    pattern = r"https://www.instagram.com/p/fixture/"

    def items(self):
        shared = {"post_id": "post", "username": "reporter", "description": "Original caption"}
        yield Message.Directory, "", shared.copy()
        for number, extension in ((1, "jpg"), (2, "mp4"), (3, "jpg")):
            yield Message.Url, f"https://cdn.example/{number}.{extension}", {
                **shared, "num": number, "extension": extension, "media_id": f"media{number}",
                "width": 2048, "height": 1536}


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.request = {"url": "https://www.instagram.com/p/fixture/"}
        bridge.configure(self.request)

    def post(self, url):
        return SyntheticPost(re.match(SyntheticPost.pattern, url))

    def test_post_urls_are_canonical_and_bounded(self):
        self.assertEqual(bridge.post_url("https://instagram.com/p/ABC/?igsh=secret"), "https://www.instagram.com/p/ABC/")
        self.assertEqual(bridge.post_url("https://twitter.com/name/status/123/photo/2"), "https://x.com/name/status/123")
        for value in ("file:///tmp/a", "https://instagram.com.evil/p/a/", "https://x.com/name", "https://user@x.com/name/status/1", "https://127.0.0.1/p/a"):
            with self.assertRaises(ValueError):
                bridge.post_url(value)

    def test_mixed_carousel_preserves_order_and_attribution(self):
        with patch.object(extractor, "find", self.post):
            result = bridge.inspect(self.request)
        self.assertEqual([item["kind"] for item in result["items"]], ["image", "video", "image"])
        self.assertEqual([item["position"] for item in result["items"]], [1, 2, 3])
        self.assertEqual(result["items"][1]["id"], "post:media2:2")
        self.assertEqual(result["items"][0]["description"], "Original caption")
        self.assertEqual(result["items"][0]["username"], "reporter")

    def test_selected_download_matches_inspected_identity_and_bytes(self):
        with patch.object(extractor, "find", self.post):
            inspection = bridge.inspect(self.request)
        with tempfile.TemporaryDirectory() as temporary:
            self.request.update(destination=temporary, items=[inspection["items"][1]])
            payload = b"original video bytes\x00\xff"
            def fake_download(instance, url, metadata):
                path = Path(temporary) / f"{metadata['num']:03}.{metadata['extension']}"
                path.write_bytes(payload)
                instance.pathfmt.realpath = str(path)
            with patch.object(extractor, "find", self.post), patch.object(job.DownloadJob, "handle_url", fake_download):
                result = bridge.download(self.request)
            self.assertEqual(result["files"][0]["filename"], "002.mp4")
            self.assertEqual((Path(temporary) / "002.mp4").read_bytes(), payload)
            self.assertEqual(len(list(Path(temporary).iterdir())), 1)

    def test_changed_post_selection_fails(self):
        with tempfile.TemporaryDirectory() as temporary:
            self.request.update(destination=temporary, items=[{"id": "removed-item"}])
            with patch.object(extractor, "find", self.post), self.assertRaises(ValueError):
                bridge.download(self.request)

    def test_real_gallery_download_finalizes_selected_file(self):
        class BytesPost(SyntheticPost):
            def items(self):
                for kind, url, metadata in super().items():
                    yield kind, "text:original fixture bytes" if kind == Message.Url else url, metadata
        def post(url):
            return BytesPost(re.match(BytesPost.pattern, url))
        with patch.object(extractor, "find", post):
            inspection = bridge.inspect(self.request)
        with tempfile.TemporaryDirectory() as temporary:
            self.request.update(destination=temporary, items=[inspection["items"][1]])
            with patch.object(extractor, "find", post):
                result = bridge.download(self.request)
            self.assertEqual(result["files"][0]["filename"], "002.mp4")
            self.assertEqual((Path(temporary) / "002.mp4").read_bytes(), b"original fixture bytes")
            self.assertEqual(len(list(Path(temporary).iterdir())), 1)

    def test_wheel_traversal_native_code_and_links_are_rejected(self):
        for filename, mode in (("../escape.py", 0), ("native.so", 0), ("link", 0o120777 << 16)):
            with tempfile.TemporaryDirectory() as temporary:
                wheel = Path(temporary) / "test.whl"
                with zipfile.ZipFile(wheel, "w") as archive:
                    entry = zipfile.ZipInfo(filename)
                    entry.external_attr = mode
                    archive.writestr(entry, "data")
                with self.assertRaises(ValueError):
                    bridge.extract_wheel(wheel, Path(temporary) / "packages")

    def test_wheel_licenses_are_retained(self):
        with tempfile.TemporaryDirectory() as temporary:
            wheel = Path(temporary) / "test.whl"
            with zipfile.ZipFile(wheel, "w") as archive:
                archive.writestr("package/__init__.py", "")
                archive.writestr("package-1.dist-info/licenses/LICENSE", "License text")
            bridge.extract_wheel(wheel, Path(temporary) / "packages")
            self.assertEqual((Path(temporary) / "packages/package-1.dist-info/licenses/LICENSE").read_text(), "License text")


if __name__ == "__main__":
    unittest.main()
