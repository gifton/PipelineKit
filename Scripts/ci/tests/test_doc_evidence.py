"""Documentation evidence stays attached to code: cited tests exist and the
`@unchecked Sendable` inventory in docs/CONCURRENCY.md matches the library sources."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[3]
DOCUMENTS = ("README.md", "docs/CONCURRENCY.md")
CITATION = re.compile(r"`(\w+Tests)\.(test\w+)`")
DECLARATION = re.compile(
    r"^\s*(?:(?:public|internal|private|fileprivate|package|final)\s+)*(?:class|struct|enum|actor|extension)\s+(\w+)"
    r"[^{\n]*@unchecked\s+Sendable", re.MULTILINE)
INVENTORY = re.compile(r"<!-- unchecked-sendable:start -->(.*?)<!-- unchecked-sendable:end -->", re.DOTALL)
ROW = re.compile(r"^\| `(\w+)` \| `(Sources/[^`]+)` \|", re.MULTILINE)
EXCLUDED_MODULES = {"PipelineKitTestSupport"}


class DocumentationEvidenceTests(unittest.TestCase):
    def test_cited_swift_tests_exist(self):
        suites = {}
        for path in (ROOT / "Tests").rglob("*.swift"):
            if ".build" in path.parts:
                continue
            text = path.read_text()
            for suite in re.findall(r"\bclass\s+(\w+Tests)\b", text):
                suites.setdefault(suite, set()).update(re.findall(r"\bfunc\s+(test\w+)\s*\(", text))
        cited = 0
        for document in DOCUMENTS:
            for suite, test in CITATION.findall((ROOT / document).read_text()):
                cited += 1
                self.assertIn(test, suites.get(suite, set()), f"{document} cites missing test {suite}.{test}")
        self.assertGreater(cited, 0, "no test citations found; the citation format changed")

    def test_unchecked_sendable_inventory_matches_library_sources(self):
        declared = set()
        for path in (ROOT / "Sources").rglob("*.swift"):
            relative = path.relative_to(ROOT)
            if relative.parts[1] in EXCLUDED_MODULES:
                continue
            text = path.read_text()
            names = DECLARATION.findall(text)
            # Every non-comment occurrence must be parsed, so a form the pattern does not
            # recognise (for example a multi-line declaration) fails here instead of being skipped.
            uses = [line for line in text.splitlines()
                    if "@unchecked Sendable" in line and not line.lstrip().startswith("//")]
            self.assertEqual(len(names), len(uses), f"unparsed @unchecked Sendable in {relative}")
            for name in names:
                declared.add((name, relative.as_posix()))
        section = INVENTORY.search((ROOT / "docs/CONCURRENCY.md").read_text())
        self.assertIsNotNone(section, "inventory markers missing from docs/CONCURRENCY.md")
        documented = set(ROW.findall(section.group(1)))
        self.assertTrue(declared, "no declarations found; the declaration pattern changed")
        self.assertEqual(documented, declared)


if __name__ == "__main__":
    unittest.main()
