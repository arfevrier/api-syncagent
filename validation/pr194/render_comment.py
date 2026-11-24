#!/usr/bin/env python3
"""Render the short comment with URLs pinned to the evidence commit."""

import argparse
from pathlib import Path
import re


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("commit", help="Full evidence commit SHA")
    parser.add_argument("--repository", default="arfevrier/api-syncagent")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", args.commit):
        parser.error("Expected a full commit SHA")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repository):
        parser.error("Expected owner/repository")
    # GitHub resolves this immutable commit prefix; keep Markdown lines within 100 columns.
    revision = args.commit[:12]
    base = "https://github.com/" + args.repository
    location = Path(__file__).resolve().parent
    body = (location / "COMMENT.template.md").read_text().split("\n<!-- Evidence links", 1)[0]
    targets = {
        "method": ("blob", "validation/pr194/README.md"),
        "results": ("blob", "validation/pr194/summary.json"),
        "e2e": ("blob", "validation/pr194/logs/e2e.log"),
        "logs": ("tree", "validation/pr194/logs"),
        "details": ("blob", "validation/pr194/REPORT.md"),
    }
    for label, (view, path) in targets.items():
        body += "\n[" + label + "]:\n  " + base + "/" + view + "/" + revision + "/" + path + "\n"
    if any(len(line) > 100 for line in body.splitlines()):
        parser.error("A rendered Markdown line exceeds 100 columns")
    if args.output:
        args.output.write_text(body)
    else:
        print(body, end="")


if __name__ == "__main__":
    main()
