#!/usr/bin/env python3
"""Extract the dated CHANGELOG section for $VERSION into a file for gh-release.

Requires Python 3.11+ (compatible with stdlib only).
"""
import os
import re
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def main() -> int:
    version = os.environ["VERSION"]
    changelog_path = Path(os.environ.get("CHANGELOG_PATH", ROOT / "CHANGELOG.md"))
    content = changelog_path.read_text(encoding="utf-8")
    # Capture from this dated header up to: the next "## [" header, OR the first
    # keepachangelog link-reference line ("[label]: url"), OR EOF. The link-ref
    # alternative prevents the top/last section from absorbing the footer block.
    pattern = (
        rf"## \[{re.escape(version)}\] - \d{{4}}-\d{{2}}-\d{{2}}\n"
        rf"(.*?)(?=\n## \[|\n\[[^\]]+\]: |$)"
    )
    match = re.search(pattern, content, re.DOTALL)
    if not match:
        print(f"::error::No CHANGELOG section for version {version}")
        return 1
    fd, path = tempfile.mkstemp(suffix=".md", prefix="release-notes-")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(match.group(1).strip() + "\n")
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as out:
        out.write(f"notes_file={path}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
