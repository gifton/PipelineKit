#!/usr/bin/env python3
"""Release-note input and publication dependency contracts."""
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]


class ReleaseNotesTests(unittest.TestCase):
    def run_notes(self, tag, changelog):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'CHANGELOG.md').write_text(changelog)
            result = subprocess.run([
                sys.executable, str(ROOT / 'Scripts/ci/release_notes.py'),
                '--tag', tag, '--changelog', str(root / 'CHANGELOG.md'),
                '--output', str(root / 'notes.md'), '--github-output', str(root / 'outputs'),
            ], text=True, capture_output=True, timeout=10)
            notes = (root / 'notes.md').read_text() if (root / 'notes.md').exists() else None
            outputs = (root / 'outputs').read_text() if (root / 'outputs').exists() else None
            return result, notes, outputs

    def test_exact_section_including_final_line_and_semver_metadata(self):
        for version, prerelease in [('0.6.0', 'false'), ('0.6.0-rc.1', 'true'),
                                    ('0.6.0+build-with-hyphen', 'false')]:
            for suffix in ['', '\n\n## [0.5.4]\nOld notes.\n']:
                with self.subTest(version=version, suffix=bool(suffix)):
                    result, notes, outputs = self.run_notes('v' + version,
                        '# Changelog\n\n## [Unreleased]\nFuture work.\n\n'
                        f'## [{version}] - 2026-11-05\n### Fixed\n- Correct admission.' + suffix)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(notes, '### Fixed\n- Correct admission.\n')
                    self.assertEqual(outputs, f'version={version}\nprerelease={prerelease}\n')

    def test_missing_empty_duplicate_and_regex_lookalike_sections_fail(self):
        cases = [
            '## [Unreleased]\nChanges.\n',
            '## [0x6x0]\nWrong version.\n',
            '## [0.6.0]\n\n## [0.5.4]\nOlder.\n',
            '## [0.6.0]\n### Fixed\n<!-- notes pending -->\n',
            '## [0.6.0]\nFirst.\n## [0.6.0]\nDuplicate.\n',
        ]
        for changelog in cases:
            with self.subTest(changelog=changelog):
                result, notes, outputs = self.run_notes('v0.6.0', changelog)
                self.assertNotEqual(result.returncode, 0)
                self.assertIsNone(notes)
                self.assertIsNone(outputs)

    def test_invalid_semver_is_rejected_before_writing_outputs(self):
        for tag in ['0.6.0', 'v01.6.0', 'v0.6', 'v0.6.0-01', 'v0.6.0-rc..1',
                    'v0.6.0+', 'v0.6.0\n', 'v0.6.0;echo injected', 'v0.6.0-']:
            with self.subTest(tag=tag):
                result, notes, outputs = self.run_notes(tag, '## [0.6.0]\nChanges.\n')
                self.assertNotEqual(result.returncode, 0)
                self.assertIsNone(notes)
                self.assertIsNone(outputs)


def jobs(workflow):
    """Read this workflow's two-space job blocks; fail loudly on unsupported needs."""
    blocks = re.split(r'^  ([a-z][a-z0-9-]*):\s*$', workflow.split('\njobs:\n', 1)[1], flags=re.M)
    return dict(zip(blocks[1::2], blocks[2::2]))


def dependencies(blocks, name):
    match = re.search(r'^    needs: (.+)$', blocks[name], flags=re.M)
    if not match:
        return set()
    value = match.group(1)
    direct = json.loads(value.replace("'", '"')) if value.startswith('["') else (
        [item.strip() for item in value[1:-1].split(',')] if value.startswith('[') else [value])
    if not all(re.fullmatch('[a-z][a-z0-9-]*', item) for item in direct):
        raise AssertionError('Unsupported needs syntax: ' + value)
    return set(direct).union(*(dependencies(blocks, item) for item in direct))


class PublicationGraphTests(unittest.TestCase):
    def test_publication_requires_same_commit_qualification_and_built_docs(self):
        workflow = (ROOT / '.github/workflows/release.yml').read_text()
        blocks = jobs(workflow)
        required = {'validate-tag', 'qualification', 'build-docs'}
        self.assertTrue(required <= dependencies(blocks, 'create-release'))
        self.assertTrue(required | {'create-release'} <= dependencies(blocks, 'publish-docs'))
        for name in required | {'create-release', 'publish-docs'}:
            self.assertNotRegex(blocks[name], r'(?m)^    (if:|continue-on-error:)')
        self.assertRegex(blocks['qualification'],
                         r'(?m)^    uses: \./\.github/workflows/ci-multiplatform\.yml$')
        shared = (ROOT / '.github/workflows/ci-multiplatform.yml').read_text()
        self.assertIn('\n  workflow_call:', shared)
        self.assertIn('Scripts/ci/release_notes.py', blocks['validate-tag'])
        self.assertIn('Scripts/ci/release_notes.py', blocks['create-release'])
        self.assertIn('body_path: release-notes.md', blocks['create-release'])
        self.assertIn('Scripts/build-docs-site.sh', blocks['build-docs'])
        self.assertIn('actions/upload-pages-artifact@', blocks['build-docs'])
        self.assertNotIn('Scripts/build-docs-site.sh', blocks['publish-docs'])


if __name__ == '__main__':
    unittest.main()
