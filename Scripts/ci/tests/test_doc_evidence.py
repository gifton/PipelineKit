"""Documentation evidence stays attached to code: cited tests exist, the
`@unchecked Sendable` inventory in docs/CONCURRENCY.md matches the library sources,
relative links and anchors resolve, and printed protocol requirements match the source."""
from pathlib import Path
import re
import unicodedata
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
USER_DOC_GLOBS = ("*.md", "docs/*.md", "docs/getting-started/*.md", "docs/guides/**/*.md",
                  "docs/tutorials/*.md", "docs/migrations/*.md", "Examples/README.md",
                  "Tests/README.md", "Scripts/validation/README.md", "Sources/*/*.docc/*.md")
FENCE_BLOCK = re.compile(r"^```.*?^```", re.DOTALL | re.MULTILINE)
SWIFT_FENCE = re.compile(r"^```swift\n(.*?)^```", re.DOTALL | re.MULTILINE)
MARKDOWN_LINK = re.compile(r"(?<!!)\[[^\]]*\]\(([^)\s]+)\)")
HEADING = re.compile(r"^#{1,6}\s+(.*?)\s*#*\s*$", re.MULTILINE)
PRINTED_PROTOCOL = re.compile(r"^public protocol (\w+)[^{]*\{(.*?)^\}", re.DOTALL | re.MULTILINE)
REQUIREMENT = re.compile(r"\bfunc\b.*?(?=\n\s*\n|\n\s*func\b|\Z)", re.DOTALL)


def user_documents():
    return sorted({path for pattern in USER_DOC_GLOBS for path in ROOT.glob(pattern)})


def github_anchors(text):
    """Anchors GitHub generates for a Markdown file's headings (fenced code excluded)."""
    anchors, seen = set(), {}
    for title in HEADING.findall(FENCE_BLOCK.sub("", text)):
        title = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", title).lower()
        slug = "".join(character for character in title
                       if character in "- " or unicodedata.category(character)[0] in "LMN"
                       or unicodedata.category(character) == "Pc").replace(" ", "-")
        count = seen.get(slug, 0)
        seen[slug] = count + 1
        anchors.add(slug if count == 0 else f"{slug}-{count}")
    return anchors


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

    def test_relative_links_and_anchors_resolve(self):
        checked, broken = 0, []
        for document in user_documents():
            text = FENCE_BLOCK.sub("", document.read_text())
            for target in MARKDOWN_LINK.findall(text):
                if re.match(r"[a-z][a-z0-9+.-]*:", target):
                    continue  # http:, https:, mailto:, doc:
                checked += 1
                path, _, fragment = target.partition("#")
                resolved = (document.parent / path).resolve() if path else document
                if not resolved.exists():
                    broken.append(f"{document.relative_to(ROOT)}: missing file {target}")
                elif fragment and resolved.suffix == ".md" \
                        and fragment.lower() not in github_anchors(resolved.read_text()):
                    broken.append(f"{document.relative_to(ROOT)}: missing anchor {target}")
        self.assertGreater(checked, 50, "few links found; the link pattern or document set changed")
        self.assertEqual(broken, [])

    def test_printed_protocol_requirements_match_source(self):
        sources = re.sub(r"\s+", "", "".join(
            path.read_text() for path in sorted((ROOT / "Sources/PipelineKitCore").rglob("*.swift"))))
        printed, differing = 0, []
        for document in user_documents():
            if "command-bus" in document.parts:
                continue  # the book declares its own teaching protocols with the same names
            for fence in SWIFT_FENCE.findall(document.read_text()):
                for protocol, body in PRINTED_PROTOCOL.findall(fence):
                    for requirement in REQUIREMENT.findall(body):
                        printed += 1
                        if re.sub(r"\s+", "", requirement) not in sources:
                            differing.append(f"{document.relative_to(ROOT)}: {protocol}: "
                                             + " ".join(requirement.split()))
        self.assertGreater(printed, 0, "no printed protocol requirements found; the pattern changed")
        self.assertEqual(differing, [], "printed protocol requirements differ from Sources/PipelineKitCore")


if __name__ == "__main__":
    unittest.main()
