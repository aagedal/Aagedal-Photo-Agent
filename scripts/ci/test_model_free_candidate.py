#!/usr/bin/env python3
"""Check candidate provenance guards using real temporary Git repositories."""
import subprocess
from contextlib import nullcontext
import os
import stat
import tempfile
import unittest
import zipfile
from pathlib import Path

import build_model_free_candidate as candidate


class CandidateTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.repo = Path(temporary.name)
        self.run_git('init', '-q')
        self.run_git('config', 'user.name', 'Test')
        self.run_git('config', 'user.email', 'test@example.invalid')
        (self.repo / '.gitignore').write_text('build/\n')
        (self.repo / 'source').write_text('original')
        self.run_git('add', '.')
        self.run_git('commit', '-qm', 'Initial source')
        self.revision = candidate.source_revision(self.repo)

    def run_git(self, *args):
        subprocess.run(['git', *args], cwd=self.repo, check=True, capture_output=True)

    def test_dirty_staged_and_untracked_sources_are_rejected(self):
        (self.repo / 'source').write_text('edited')
        with self.assertRaisesRegex(ValueError, 'clean worktree'):
            candidate.source_revision(self.repo)
        self.run_git('add', 'source')
        with self.assertRaisesRegex(ValueError, 'clean worktree'):
            candidate.source_revision(self.repo)
        self.run_git('reset', '--hard', 'HEAD')
        (self.repo / 'new-source').write_text('untracked')
        with self.assertRaisesRegex(ValueError, 'clean worktree'):
            candidate.source_revision(self.repo)

    def test_revision_change_during_build_is_rejected(self):
        self.run_git('commit', '--allow-empty', '-qm', 'New revision')
        with self.assertRaisesRegex(ValueError, 'revision changed'):
            candidate.verify_source(self.repo, self.revision)

    def test_existing_output_is_preserved(self):
        output = self.repo / 'build/candidate'
        output.mkdir(parents=True)
        marker = output / 'measurement.json'
        marker.write_text('existing evidence')
        with self.assertRaises(FileExistsError):
            candidate.build_candidate(self.repo, output)
        self.assertEqual(marker.read_text(), 'existing evidence')

    def test_output_outside_build_is_rejected_without_creation(self):
        output = self.repo / 'candidate'
        with self.assertRaisesRegex(ValueError, 'inside'):
            candidate.build_candidate(self.repo, output)
        self.assertFalse(output.exists())

    def test_ignored_build_output_does_not_invalidate_source(self):
        (self.repo / 'build').mkdir()
        (self.repo / 'build/log').write_text('output')
        candidate.verify_source(self.repo, self.revision)


class ArchiveTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.app = self.root / 'Photo.app'
        (self.app / 'Contents/MacOS').mkdir(parents=True)
        self.executable = self.app / 'Contents/MacOS/Photo'
        self.executable.write_bytes(b'original executable')
        self.executable.chmod(0o755)
        (self.app / 'Contents/current').symlink_to('MacOS/Photo')
        self.archive = self.root / 'candidate.zip'

    def package(self, *, omit=None, replace=None, extra=None):
        with zipfile.ZipFile(self.archive, 'w') as archive:
            for path in self.app.rglob('*'):
                name = path.relative_to(self.root).as_posix()
                if name == omit or path.is_dir():
                    continue
                data = os.fsencode(os.readlink(path)) if path.is_symlink() else path.read_bytes()
                mode = path.lstat().st_mode
                if replace and name == replace[0]:
                    data, mode = replace[1:]
                entry = zipfile.ZipInfo(name)
                entry.create_system = 3
                entry.external_attr = mode << 16
                archive.writestr(entry, data)
            if extra:
                archive.writestr(*extra)

    def test_complete_bundle_and_internal_link_are_verified(self):
        self.package()
        self.assertEqual(candidate.verify_archive(self.app, self.archive), {
            'archivePayloadVerified': True, 'archivePayloadEntryCount': 2,
        })

    def test_missing_changed_link_and_executable_payloads_fail(self):
        name = 'Photo.app/Contents/MacOS/Photo'
        link = 'Photo.app/Contents/current'
        cases = [
            {'omit': name},
            {'replace': (name, b'changed executable', stat.S_IFREG | 0o755)},
            {'replace': (name, b'original executable', stat.S_IFREG | 0o644)},
            {'replace': (link, b'../elsewhere', stat.S_IFLNK | 0o777)},
            {'replace': (link, b'MacOS/Photo', stat.S_IFREG | 0o644)},
        ]
        for case in cases:
            with self.subTest(case=case):
                self.package(**case)
                with self.assertRaises(ValueError):
                    candidate.verify_archive(self.app, self.archive)

    def test_unexpected_unsafe_and_duplicate_entries_fail(self):
        for name in ('Photo.app/extra', '../outside', '/absolute',
                     'Photo.app/./extra', 'Photo.app//extra',
                     'Photo.app/Contents/MacOS/Photo', '__MACOSX/extra'):
            with self.subTest(name=name):
                with self.assertWarns(UserWarning) if name.endswith('/MacOS/Photo') else nullcontext():
                    self.package(extra=(name, b'extra'))
                with self.assertRaises(ValueError):
                    candidate.verify_archive(self.app, self.archive)

    def test_appledouble_requires_corresponding_payload_and_magic(self):
        for prefix in ('', '__MACOSX/'):
            name = prefix + 'Photo.app/Contents/MacOS/._Photo'
            self.package(extra=(name, b'\x00\x05\x16\x07metadata'))
            self.assertTrue(candidate.verify_archive(self.app, self.archive)['archivePayloadVerified'])
            self.package(extra=(name, b'invalid'))
            with self.assertRaisesRegex(ValueError, 'metadata'):
                candidate.verify_archive(self.app, self.archive)

    @unittest.skipUnless(Path('/usr/bin/ditto').exists(), 'macOS ditto required')
    def test_real_ditto_archive_matches_bundle(self):
        subprocess.run(['/usr/bin/ditto', '-c', '-k', '--keepParent', str(self.app),
                        str(self.archive)], check=True)
        self.assertTrue(candidate.verify_archive(self.app, self.archive)['archivePayloadVerified'])


if __name__ == '__main__':
    unittest.main()
