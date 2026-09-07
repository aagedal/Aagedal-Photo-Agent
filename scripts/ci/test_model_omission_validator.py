#!/usr/bin/env python3
"""Regression coverage for the release app's on-demand model boundary."""
import plistlib
import tempfile
import unittest
from pathlib import Path

import validate_model_omission as validator


class ModelOmissionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / 'Photo.app'
        (self.app / 'Contents/MacOS').mkdir(parents=True)
        (self.app / 'Contents/MacOS/Photo').write_bytes(b'executable')
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleExecutable': 'Photo', 'CFBundleShortVersionString': '3.0.0',
            'CFBundleVersion': '738',
        }))

    def test_clean_app_reports_actual_regular_file_bytes(self):
        result = validator.inspect_app(self.app)
        self.assertEqual(result['regularFileBytes'], sum(
            path.stat().st_size for path in self.app.rglob('*') if path.is_file()))
        self.assertEqual(result['version'], '3.0.0')
        self.assertTrue(result['modelOmitted'])

    def test_nested_model_and_source_formats_are_rejected(self):
        for name in ('AuraFaceR100.mlmodelc', 'auraface-v2.MLPACKAGE',
                     'AuraFace.onnx', 'AuraFace.zip', 'AuraFace.mlmodel'):
            with self.subTest(name=name):
                model = self.app / 'Contents/Resources/nested' / name
                model.mkdir(parents=True)
                with self.assertRaisesRegex(ValueError, 'on-demand model'):
                    validator.inspect_app(self.app)
                model.rmdir()

    def test_broken_links_fail_closed(self):
        (self.app / 'Contents/broken').symlink_to('missing')
        with self.assertRaises(OSError):
            validator.inspect_app(self.app)

    def test_external_link_fails_even_with_unrecognizable_name(self):
        outside = self.root / 'weights'
        outside.write_bytes(b'model')
        (self.app / 'Contents/payload').symlink_to(outside)
        with self.assertRaisesRegex(ValueError, 'outside'):
            validator.inspect_app(self.app)

    def test_internal_framework_links_are_not_counted_twice(self):
        real = self.app / 'Contents/Frameworks/Example.framework/Versions/A'
        real.mkdir(parents=True)
        (real / 'Example').write_bytes(b'framework')
        (real.parent / 'Current').symlink_to('A')
        (real.parent.parent / 'Example').symlink_to('Versions/Current/Example')
        result = validator.inspect_app(self.app)
        self.assertEqual(result['regularFileCount'], 3)

    def test_missing_executable_fails_closed(self):
        (self.app / 'Contents/MacOS/Photo').unlink()
        with self.assertRaisesRegex(ValueError, 'executable'):
            validator.inspect_app(self.app)


if __name__ == '__main__':
    unittest.main()
