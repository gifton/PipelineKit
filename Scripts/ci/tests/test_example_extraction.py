"""Exercise the documentation extractor against independent source fixtures."""

import hashlib
import json
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
]
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

    def extract(self, snippets):
        (self.root / TUTORIAL).write_text(
            "# Tutorial\n\n" + "\n".join("```swift\n" + snippet + "```\n" for snippet in snippets)
        )
        result = subprocess.run(
            [sys.executable, str(self.extractor)], cwd=self.root,
            capture_output=True, text=True, timeout=15,
        )
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


if __name__ == "__main__":
    unittest.main()
