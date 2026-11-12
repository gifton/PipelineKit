"""Repository hygiene: each test closes a class of defect that was found more than once.

- files that are tracked although `.gitignore` ignores them,
- documents, scripts and the Makefile naming workflow files that do not exist,
- `swift package <verb>` commands whose verb nothing provides,
- coverage and scan output committed to the tree,
- source comments citing tests that do not exist.
"""
from pathlib import Path
import re
import subprocess
import unittest

from test_doc_evidence import CITATION, USER_DOC_GLOBS

ROOT = Path(__file__).resolve().parents[3]
WORKFLOWS = ROOT / ".github/workflows"

# docs/superpowers/ was ignored after these files were committed; whether they stay tracked
# is an open maintainer decision. Remove this entry when that directory is untracked.
TRACKED_BUT_IGNORED_ALLOWED = ("docs/superpowers/",)

GENERATED_SUFFIXES = (".profdata", ".profraw", ".lcov", ".sarif")

# CHANGELOG.md is a historical record and may name workflows that have since been removed.
HISTORICAL_DOCUMENTS = {"CHANGELOG.md"}
# Workflow names a document mentions in order to say the workflow does not exist.
NAMED_AS_ABSENT = {"dependency-audit.yml"}
QUALIFIED_WORKFLOW = re.compile(r"\.github/workflows/([A-Za-z0-9_-][A-Za-z0-9_.-]*\.ya?ml)")
DISPATCHED_WORKFLOW = re.compile(r"gh workflow run\s+([A-Za-z0-9_.-]+\.ya?ml)")
BACKTICKED_YAML = re.compile(r"`([^`\s]*\.ya?ml)`")
SCRIPT_SUFFIXES = {".sh", ".py", ".swift", ".md", ".txt"}

# `swift package` subcommands that SwiftPM itself provides.
BUILTIN_PACKAGE_VERBS = {
    "add-dependency", "add-product", "add-target", "archive-source", "clean", "completion-tool",
    "compute-checksum", "config", "describe", "diagnose-api-breaking-changes", "dump-package",
    "edit", "init", "plugin", "purge-cache", "reset", "resolve", "show-dependencies",
    "tools-version", "unedit", "update",
}
# Command plugins contributed by package dependencies, keyed by the dependency that must be declared.
DEPENDENCY_PACKAGE_VERBS = {"swift-docc-plugin": {"generate-documentation", "preview-documentation"}}
PACKAGE_OPTIONS_WITH_VALUE = {"--allow-writing-to-directory", "--package-path", "--scratch-path",
                              "--configuration", "-c"}
PACKAGE_COMMAND = re.compile(r"\bswift package\b([^\n|;&]*)")
COMMAND_SOURCES = ("Makefile", "CONTRIBUTING.md")


def tracked(*arguments):
    output = subprocess.run(["git", "ls-files", "-z", *arguments], cwd=ROOT, check=True,
                            capture_output=True, text=True).stdout
    return [path for path in output.split("\0") if path]


def live_workflows():
    return {path.name for path in WORKFLOWS.iterdir() if path.suffix in (".yml", ".yaml")}


def missing_workflow_references(text, live, other_yaml, bare_names):
    """Workflow file names in `text` that are not live workflows.

    A name is a reference when it follows `.github/workflows/` or `gh workflow run`. With
    `bare_names`, a backticked YAML file name is one too, unless it is the name or path of
    another tracked YAML file (`.swiftlint.yml`, `.github/dependabot.yml`)."""
    names = set(QUALIFIED_WORKFLOW.findall(text)) | set(DISPATCHED_WORKFLOW.findall(text))
    if bare_names:
        for token in BACKTICKED_YAML.findall(text):
            if token in other_yaml or ("/" not in token and token in {Path(p).name for p in other_yaml}):
                continue
            names.add(Path(token).name)
    return sorted(names - live - NAMED_AS_ABSENT)


def package_verbs(text):
    """The verb of every `swift package ...` command in `text`."""
    verbs = []
    for arguments in PACKAGE_COMMAND.findall(text):
        tokens = arguments.replace("`", " ").split()
        while tokens and tokens[0].startswith("-"):
            option = tokens.pop(0)
            if option in PACKAGE_OPTIONS_WITH_VALUE and tokens:
                tokens.pop(0)
        if tokens and re.fullmatch(r"[a-z][a-z0-9-]*", tokens[0]):
            verbs.append(tokens[0])
    return verbs


def available_package_verbs(manifest):
    verbs = set(BUILTIN_PACKAGE_VERBS) | set(re.findall(r'verb:\s*"([^"]+)"', manifest))
    for dependency, provided in DEPENDENCY_PACKAGE_VERBS.items():
        if re.search(r'\.package\(\s*url:\s*"[^"]*/' + re.escape(dependency) + r'(?:\.git)?"', manifest):
            verbs |= provided
    return verbs


class RepositoryHygieneTests(unittest.TestCase):
    def test_no_tracked_file_is_ignored(self):
        ignored = [path for path in tracked("-ci", "--exclude-standard")
                   if not path.startswith(TRACKED_BUT_IGNORED_ALLOWED)]
        self.assertEqual(ignored, [], "tracked files that .gitignore ignores; untrack them or fix the rule")

    def test_no_generated_coverage_or_scan_output_is_tracked(self):
        generated = [path for path in tracked() if path.endswith(GENERATED_SUFFIXES)]
        self.assertEqual(generated, [])

    def test_referenced_workflows_exist(self):
        live = live_workflows()
        self.assertIn("ci.yml", live)
        other_yaml = {path for path in tracked("*.yml", "*.yaml")
                      if not path.startswith(".github/workflows/")}
        documents = {path for pattern in USER_DOC_GLOBS for path in ROOT.glob(pattern)}
        documents |= set((ROOT / ".github").rglob("*.md"))
        documents = {path for path in documents if path.name not in HISTORICAL_DOCUMENTS}
        scripts = {ROOT / path for path in tracked("Scripts", "Makefile")
                   if Path(path).suffix in SCRIPT_SUFFIXES or path == "Makefile"}
        # This file's own fixtures name a workflow that deliberately does not exist.
        scripts.discard(Path(__file__).resolve())
        self.assertGreater(len(documents), 20)
        self.assertGreater(len(scripts), 20)
        for path in sorted(documents | scripts):
            missing = missing_workflow_references(path.read_text(), live, other_yaml,
                                                  bare_names=path in documents)
            self.assertEqual(missing, [], f"{path.relative_to(ROOT)} names workflows that do not exist")

    def test_workflow_reference_scan_detects_each_form(self):
        live, other = {"ci.yml"}, {".swiftlint.yml", ".github/dependabot.yml"}
        for text in ("see `.github/workflows/gone.yml`", "gh workflow run gone.yml", "the `gone.yml` job"):
            with self.subTest(text=text):
                self.assertEqual(missing_workflow_references(text, live, other, bare_names=True), ["gone.yml"])
        accepted = "`ci.yml`, `.github/workflows/ci.yml`, `.swiftlint.yml`, `dependabot.yml`, `.github/dependabot.yml`"
        self.assertEqual(missing_workflow_references(accepted, live, other, bare_names=True), [])
        self.assertEqual(missing_workflow_references("the `gone.yml` job", live, other, bare_names=False), [])

    def test_package_commands_use_available_verbs(self):
        available = available_package_verbs((ROOT / "Package.swift").read_text())
        found = 0
        for name in COMMAND_SOURCES:
            path = ROOT / name
            if not path.exists():
                continue
            for verb in package_verbs(path.read_text()):
                found += 1
                self.assertIn(verb, available, f"{name} runs `swift package {verb}`, which nothing provides")
        self.assertGreater(found, 0)

    def test_package_verb_scan(self):
        text = "swift package test-stress\n\tswift package --allow-writing-to-directory out generate-documentation --target X\n"
        self.assertEqual(package_verbs(text), ["test-stress", "generate-documentation"])
        manifest = 'intent: .custom(verb: "test-unit", description: "")'
        self.assertIn("test-unit", available_package_verbs(manifest))
        self.assertNotIn("test-stress", available_package_verbs(manifest))
        self.assertNotIn("generate-documentation", available_package_verbs(manifest))
        self.assertIn("generate-documentation", available_package_verbs(
            manifest + '.package(url: "https://github.com/apple/swift-docc-plugin", from: "1.3.0")'))

    def test_tests_cited_in_sources_exist(self):
        suites = {}
        for path in (ROOT / "Tests").rglob("*.swift"):
            if ".build" in path.parts:
                continue
            text = path.read_text()
            for suite in re.findall(r"\bclass\s+(\w+Tests)\b", text):
                suites.setdefault(suite, set()).update(re.findall(r"\bfunc\s+(test\w+)\s*\(", text))
        cited = 0
        for path in sorted((ROOT / "Sources").rglob("*.swift")):
            for suite, test in CITATION.findall(path.read_text()):
                cited += 1
                self.assertIn(test, suites.get(suite, set()),
                              f"{path.relative_to(ROOT)} cites missing test {suite}.{test}")
        self.assertGreater(cited, 0)


if __name__ == "__main__":
    unittest.main()
