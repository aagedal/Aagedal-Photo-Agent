#!/usr/bin/env python3
"""Check candidate provenance guards using real temporary Git repositories."""
import subprocess
import tempfile
import unittest
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


if __name__ == '__main__':
    unittest.main()
