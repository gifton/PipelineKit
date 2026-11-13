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
TEST_SUITE = re.compile(r"\bclass\s+(\w+Tests)\b")
TEST_FUNCTION = re.compile(r"\bfunc\s+(test\w*)\s*\(")
SWIFT_TOKEN = re.compile(r'"""|"|//|/\*|\*/')


def strip_swift_comments(text):
    """`text` without its `//` and `/* */` comments; block comments nest, as in Swift.

    Comment markers inside string literals are kept. Raw strings (`#"..."#`) and string
    literals nested inside an interpolation are not parsed; test_swift_comment_stripping
    pins the forms that are."""
    kept, position, depth = [], 0, 0
    while True:
        match = SWIFT_TOKEN.search(text, position)
        if not match:
            if depth == 0:
                kept.append(text[position:])
            return "".join(kept)
        token, start, end = match.group(), match.start(), match.end()
        if depth:
            depth += {"/*": 1, "*/": -1}.get(token, 0)
            position = end
            continue
        kept.append(text[position:start])
        if token == "/*":
            depth, position = 1, end
        elif token == "//":
            newline = text.find("\n", end)
            position = len(text) if newline < 0 else newline
        elif token == "*/":
            kept.append(token)
            position = end
        else:  # a string literal: copy it whole, honouring backslash escapes
            close = end
            while close < len(text) and not text.startswith(token, close):
                if token == '"' and text[close] == "\n":
                    break  # unterminated single-line literal; resume scanning on the next line
                close += 2 if text[close] == "\\" else 1
            position = min(len(text), close + len(token)) if text.startswith(token, close) else close
            kept.append(text[start:position])


def swift_test_sources():
    """(path, text without comments) for every Swift file under Tests/."""
    return [(path, strip_swift_comments(path.read_text()))
            for path in sorted((ROOT / "Tests").rglob("*.swift")) if ".build" not in path.parts]


def declared_swift_tests():
    """Test suite name -> names of the test functions declared, outside comments, in its files."""
    suites = {}
    for _, text in swift_test_sources():
        for suite in TEST_SUITE.findall(text):
            suites.setdefault(suite, set()).update(TEST_FUNCTION.findall(text))
    return suites


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
        suites = declared_swift_tests()
        cited = 0
        for document in DOCUMENTS:
            for suite, test in CITATION.findall((ROOT / document).read_text()):
                cited += 1
                self.assertIn(test, suites.get(suite, set()), f"{document} cites missing test {suite}.{test}")
        self.assertGreater(cited, 0, "no test citations found; the citation format changed")

    def test_swift_comment_stripping(self):
        source = (
            'let url = "https://example.com/*" // func testInLineComment() {}\n'
            '/* class GoneTests: XCTestCase {\n'
            '   /* nested */ func testInBlockComment() {}\n'
            '*/\n'
            'let text = """\n'
            '// kept: inside a multi-line string\n'
            '"""\n'
            'let escaped = "quote \\" // still a string"\n'
            'final class LiveTests: XCTestCase { func testLive() {} }\n')
        stripped = strip_swift_comments(source)
        self.assertEqual(TEST_SUITE.findall(stripped), ["LiveTests"])
        self.assertEqual(TEST_FUNCTION.findall(stripped), ["testLive"])
        self.assertIn('"https://example.com/*"', stripped)
        self.assertIn("// kept: inside a multi-line string", stripped)
        self.assertIn('"quote \\" // still a string"', stripped)
        self.assertEqual(strip_swift_comments("a /* never closed\nfunc testX() {}"), "a ")

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
