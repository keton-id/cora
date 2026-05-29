#!/usr/bin/env python3
"""Rewrite the stable section of CHANGELOG.md with GitHub-generated notes.

Usage: enrich_changelog.py <tag> <notes_path> <changelog_path>
  tag             stable tag with or without leading 'v' (e.g. v0.5.1 or 0.5.1)
  notes_path      file containing markdown body from generate-release-notes API
  changelog_path  path to CHANGELOG.md to mutate in place
"""
import re
import sys
from pathlib import Path


def main(tag: str, notes_path: str, changelog_path: str) -> int:
    bare = tag[1:] if tag.startswith("v") else tag
    notes = Path(notes_path).read_text().rstrip() + "\n"
    changelog = Path(changelog_path).read_text()

    heading_pat = re.compile(
        r"^(## \[" + re.escape(bare) + r"\][^\n]*\n)",
        re.MULTILINE,
    )
    m = heading_pat.search(changelog)
    if not m:
        print(f"error: heading '## [{bare}]' not found in {changelog_path}", file=sys.stderr)
        return 1

    start = m.end()
    next_heading = re.search(r"^## \[", changelog[start:], re.MULTILINE)
    end = start + next_heading.start() if next_heading else len(changelog)

    handles = sorted(set(re.findall(r"@([A-Za-z0-9](?:[A-Za-z0-9-]{0,38})?)", notes)))
    contributors = ""
    if handles:
        mentions = ", ".join(f"@{h}" for h in handles)
        contributors = f"\n### Contributors\n\n{mentions}\n"

    new_body = "\n" + notes + contributors + "\n"
    Path(changelog_path).write_text(changelog[:start] + new_body + changelog[end:])
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 4:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1], sys.argv[2], sys.argv[3]))
