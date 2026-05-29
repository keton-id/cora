#!/usr/bin/env python3
"""Rewrite or insert the stable section of CHANGELOG.md with GitHub-generated notes.

Usage: enrich_changelog.py <tag> <notes_path> <changelog_path> [<previous_tag>] [<repo>]
  tag             stable tag with or without leading 'v' (e.g. v0.6.0 or 0.6.0)
  notes_path      file containing markdown body from generate-release-notes API
  changelog_path  path to CHANGELOG.md to mutate in place
  previous_tag    (optional) previous stable tag, used to build the compare link
                  when inserting a new heading (e.g. v0.5.1)
  repo            (optional) owner/name, defaults to keton-id/cora — used in the
                  compare URL when inserting a new heading

Behaviour:
  - If '## [<bare>]' already exists, its body (up to the next '## [' heading) is
    replaced with the generated notes plus a '### Contributors' subsection.
  - If it does not exist, a new '## [<bare>](<compare-url>) (<date>)' heading is
    inserted at the top of the changelog, above the first existing '## [' entry.
"""
import datetime as _dt
import re
import sys
from pathlib import Path


def build_heading(bare: str, prev: str, repo: str) -> str:
    today = _dt.date.today().isoformat()
    if prev:
        prev_bare = prev[1:] if prev.startswith("v") else prev
        url = f"https://github.com/{repo}/compare/v{prev_bare}...v{bare}"
        return f"## [{bare}]({url}) ({today})\n"
    return f"## [{bare}] ({today})\n"


def main(tag: str, notes_path: str, changelog_path: str, prev: str = "", repo: str = "keton-id/cora") -> int:
    bare = tag[1:] if tag.startswith("v") else tag
    notes = Path(notes_path).read_text().rstrip() + "\n"
    changelog = Path(changelog_path).read_text()

    handles = sorted(set(re.findall(r"@([A-Za-z0-9](?:[A-Za-z0-9-]{0,38})?)", notes)))
    contributors = ""
    if handles:
        mentions = ", ".join(f"@{h}" for h in handles)
        contributors = f"\n### Contributors\n\n{mentions}\n"

    heading_pat = re.compile(
        r"^(## \[" + re.escape(bare) + r"\][^\n]*\n)",
        re.MULTILINE,
    )
    m = heading_pat.search(changelog)

    if m:
        start = m.end()
        next_heading = re.search(r"^## \[", changelog[start:], re.MULTILINE)
        end = start + next_heading.start() if next_heading else len(changelog)
        new_body = "\n" + notes + contributors + "\n"
        Path(changelog_path).write_text(changelog[:start] + new_body + changelog[end:])
        return 0

    first = re.search(r"^## \[", changelog, re.MULTILINE)
    if not first:
        print(f"error: no existing '## [' section found in {changelog_path}", file=sys.stderr)
        return 1
    heading = build_heading(bare, prev, repo)
    section = heading + "\n" + notes + contributors + "\n"
    Path(changelog_path).write_text(changelog[: first.start()] + section + changelog[first.start():])
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 4 or len(sys.argv) > 6:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    args = sys.argv[1:]
    while len(args) < 5:
        args.append("")
    sys.exit(main(args[0], args[1], args[2], args[3], args[4] or "keton-id/cora"))
