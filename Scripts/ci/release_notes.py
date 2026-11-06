#!/usr/bin/env python3
"""Validate a versioned tag and extract its exact, nonempty changelog section."""
import argparse
from pathlib import Path
import re

SEMVER = re.compile(
    r'v(?P<version>(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)'
    r'(?:-(?P<prerelease>[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?'
    r'(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?)'
)
SECTION = re.compile(r'^## \[([^]\r\n]+)\](?:[^\r\n]*)$', re.MULTILINE)


def extract(tag, changelog):
    match = SEMVER.fullmatch(tag)
    if match is None:
        raise ValueError('tag must be v followed by a valid semantic version')
    prerelease = match.group('prerelease')
    if prerelease and any(part.isdecimal() and len(part) > 1 and part.startswith('0')
                          for part in prerelease.split('.')):
        raise ValueError('numeric prerelease identifiers cannot have leading zeros')
    version = match.group('version')
    sections = list(SECTION.finditer(changelog))
    selected = [index for index, section in enumerate(sections) if section.group(1) == version]
    if len(selected) != 1:
        raise ValueError(f'expected exactly one changelog section [{version}]; found {len(selected)}')
    index = selected[0]
    end = sections[index + 1].start() if index + 1 < len(sections) else len(changelog)
    body = changelog[sections[index].end():end].strip()
    content = re.sub(r'<!--.*?-->', '', body, flags=re.DOTALL)
    content = re.sub(r'^\s*#{1,6}\s+.*$', '', content, flags=re.MULTILINE).strip()
    if not content:
        raise ValueError(f'changelog section [{version}] has no release notes')
    return version, bool(prerelease), body + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--changelog', type=Path, default=Path('CHANGELOG.md'))
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--github-output', type=Path)
    args = parser.parse_args()
    try:
        version, prerelease, notes = extract(args.tag, args.changelog.read_text())
    except (OSError, ValueError) as error:
        parser.error(str(error))
    args.output.write_text(notes)
    if args.github_output:
        with args.github_output.open('a') as stream:
            stream.write(f'version={version}\nprerelease={str(prerelease).lower()}\n')


if __name__ == '__main__':
    main()
