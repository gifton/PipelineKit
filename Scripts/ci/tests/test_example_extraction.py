"""Exercise the documentation extractor against independent source fixtures."""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[3]
EXTRACTOR = ROOT / "Scripts/validation/extract_stabilization_examples.py"
TUTORIAL = "docs/tutorials/basic-usage.md"
DOCUMENTS = [
    "docs/migrations/first-stabilization-batch.md",
    "README.md",
    "docs/guides/security-best-practices.md",
    "docs/guides/resilience-patterns.md",
    "docs/migrations/security-serialization-and-numeric-safety.md",
    "docs/migrations/telemetry-hardening.md",
    "docs/migrations/error-cancellation-and-validation.md",
    "docs/migrations/monitoring-and-connection-lifecycle.md",
    "docs/migrations/resilience-policy-contracts.md",
    "docs/migrations/release-qualification.md",
    TUTORIAL,
    "docs/guides/testing.md",
    "Sources/PipelineKit/PipelineKit.docc/GettingStarted.md",
    "docs/guides/enterprise-evaluation.md",
]
WALKTHROUGH = "docs/guides/enterprise-evaluation.md"
DEFINITIONS = """import Foundation
import PipelineKitResilience

struct FetchDataCommand {}

func makeFetchDataRetryMiddleware() -> RetryMiddleware {
    RetryMiddleware(maxAttempts: 2, strategy: .fixed(delay: 0))
}
"""
USAGE = """let retry = makeFetchDataRetryMiddleware()
_ = retry
"""


class TutorialExtractionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.extractor = self.root / "Scripts/validation/extract_stabilization_examples.py"
        self.extractor.parent.mkdir(parents=True)
        shutil.copyfile(EXTRACTOR, self.extractor)
        for name in DOCUMENTS:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("# Fixture\n")
        self.output = self.root / "Tests/Integration/Consumer/Sources/Consumer/CompiledExamples.swift"
        self.output.parent.mkdir(parents=True)
        self.environment = os.environ.copy()
        binary = self.root / "bin/swift"
        binary.parent.mkdir()
        binary.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, pathlib, sys\n"
            "assert sys.argv[1:3] == ['package', '--package-path'], sys.argv\n"
            "assert sys.argv[4:] == ['dump-package'], sys.argv\n"
            "package = pathlib.Path(sys.argv[3]) / 'Package.swift'\n"
            "assert package.is_file()\n"
            "if os.environ.get('FAIL_DOCUMENTATION_MANIFEST'):\n"
            "    sys.stderr.write('invalid documentation manifest fixture\\n')\n"
            "    sys.exit(23)\n"
            "print(json.dumps({'name': 'DocumentationFixture'}))\n"
        )
        binary.chmod(0o755)
        self.environment["PATH"] = str(binary.parent) + os.pathsep + self.environment["PATH"]

    def run_extractor(self, snippets, document=TUTORIAL):
        (self.root / document).write_text(
            "# Tutorial\n\n" + "\n".join("```swift\n" + snippet + "```\n" for snippet in snippets)
        )
        return subprocess.run(
            [sys.executable, str(self.extractor)], cwd=self.root,
            capture_output=True, text=True, timeout=15, env=self.environment,
        )

    def extract(self, snippets, document=TUTORIAL):
        result = self.run_extractor(snippets, document)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        manifest = json.loads((self.root / ".build/validation/example-manifest.json").read_text())
        return self.output.read_text(), manifest

    def test_tutorial_definitions_are_available_to_the_executable_consumer(self):
        generated, manifest = self.extract([DEFINITIONS, USAGE])
        entries = [entry for entry in manifest["snippets"] if entry["file"] == TUTORIAL]
        self.assertEqual([entry["swift_fence"] for entry in entries], [1, 2])
        self.assertIn(
            "// docs/tutorials/basic-usage.md, Swift fence 1\n\n"
            "struct FetchDataCommand {}\n\n"
            "func makeFetchDataRetryMiddleware() -> RetryMiddleware {\n"
            "    RetryMiddleware(maxAttempts: 2, strategy: .fixed(delay: 0))\n}\n",
            generated,
        )
        self.assertNotIn("compiled_docs_tutorials_basic_usage_md_1()", generated)
        self.assertIn(
            "@MainActor func compiled_docs_tutorials_basic_usage_md_2() async throws {\n"
            "let retry = makeFetchDataRetryMiddleware()\n_ = retry\n",
            generated,
        )
        self.assertEqual(entries[0]["snippet_sha256"], hashlib.sha256(DEFINITIONS.encode()).hexdigest())
        self.assertEqual(entries[1]["snippet_sha256"], hashlib.sha256(USAGE.encode()).hexdigest())
        self.assertEqual(manifest["generated_sha256"], hashlib.sha256(self.output.read_bytes()).hexdigest())

    def test_factory_scope_does_not_depend_on_fence_number(self):
        for index in range(3):
            with self.subTest(factory_fence=index + 1):
                snippets = ["let unrelated = 1\n", "let another = 2\n"]
                snippets.insert(index, DEFINITIONS)
                generated, manifest = self.extract(snippets)
                entries = [entry for entry in manifest["snippets"] if entry["file"] == TUTORIAL]
                self.assertEqual(len(entries), 3)
                self.assertNotIn(f"compiled_docs_tutorials_basic_usage_md_{index + 1}()", generated)
                self.assertEqual(generated.count("func makeFetchDataRetryMiddleware()"), 1)

    def test_repeat_extraction_preserves_output_and_manifest(self):
        first = self.extract([DEFINITIONS, USAGE])
        second = self.extract([DEFINITIONS, USAGE])
        self.assertEqual(first, second)

    def test_manifest_fragments_preserve_context_and_validate_independent_of_fence_number(self):
        fragments = [
            'dependencies: [\n    .package(url: "https://example.com/Library.git", "1.0.0"..<"2.0.0")\n]\n',
            '// The target remains a manifest argument.\n targets: [\n    .target(name: "Example")\n]\n',
            '/* Package arguments */\ndependencies: [],\ntargets: []\n',
        ]
        for fragment in fragments:
            for index in range(3):
                with self.subTest(fragment=fragment, fence=index + 1):
                    snippets = ["let unrelated = 1\n", "let another = 2\n"]
                    snippets.insert(index, fragment)
                    generated, manifest = self.extract(snippets, "README.md")
                    entries = [entry for entry in manifest["snippets"] if entry["file"] == "README.md"]
                    self.assertNotIn(fragment, generated)
                    self.assertNotIn("import PackageDescription", generated)
                    entry = entries[index]
                    self.assertEqual(entry["snippet_sha256"], hashlib.sha256(fragment.encode()).hexdigest())
                    self.assertIn("dump-package", entry["harness"])
                    package = self.root / entry["manifest_file"]
                    self.assertEqual(package.read_text(),
                        '// swift-tools-version: 6.2\nimport PackageDescription\n\n'
                        'let package = Package(\n    name: "DocumentationFixture",\n' + fragment + '\n)\n')
                    dump = self.root / entry["dump_package_file"]
                    self.assertEqual(json.loads(dump.read_text())["name"], "DocumentationFixture")
                    ordinary = [item for item in entries if "manifest_file" not in item]
                    self.assertEqual(len(ordinary), 2)
                    self.assertIn("let unrelated = 1", generated)
                    self.assertIn("let another = 2", generated)

    def test_walkthrough_fences_share_one_function_in_document_order(self):
        declaration = "import Foundation\nstruct Step { let value = 1 }\n"
        fragment = 'dependencies: [\n    .package(url: "https://example.com/Library.git", "1.0.0"..<"2.0.0")\n]\n'
        use = "let step = Step()\n_ = step.value\n"
        generated, manifest = self.extract([declaration, fragment, use], WALKTHROUGH)
        entries = [entry for entry in manifest["snippets"] if entry["file"] == WALKTHROUGH]
        self.assertEqual([entry["swift_fence"] for entry in entries], [1, 2, 3])
        self.assertIn("dump-package", entries[1]["harness"])
        self.assertIn(
            "@MainActor func compiled_docs_guides_enterprise_evaluation_md() async throws {\n"
            "// docs/guides/enterprise-evaluation.md, Swift fence 1\n"
            "struct Step { let value = 1 }\n\n"
            "// docs/guides/enterprise-evaluation.md, Swift fence 3\n"
            "let step = Step()\n_ = step.value\n\n}\n",
            generated,
        )
        self.assertNotIn(fragment, generated)
        self.assertEqual(generated.count("func compiled_docs_guides_enterprise_evaluation_md"), 1)
        self.assertEqual([entry["snippet_sha256"] for entry in entries],
                         [hashlib.sha256(text.encode()).hexdigest() for text in (declaration, fragment, use)])

    def test_manifest_validation_failure_is_fatal_and_cannot_write_a_success_manifest(self):
        self.extract(["dependencies: []\n"], "README.md")
        self.environment["FAIL_DOCUMENTATION_MANIFEST"] = "1"
        result = self.run_extractor(["dependencies: [invalid]\n"], "README.md")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid documentation manifest fixture", result.stdout + result.stderr)
        self.assertFalse((self.root / ".build/validation/example-manifest.json").exists())


if __name__ == "__main__":
    unittest.main()
