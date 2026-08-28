#!/usr/bin/env python3
"""Move `^indexof-*` callout blocks written by the Obsidian index-notes plugin
to a canonical position: immediately after the note's H1.

The plugin rewrites an index block in place when it can find the block anchor,
and only appends to the end of the file when it cannot. Relocating the block
once is therefore enough to pin it forever.

Dry-run by default; pass --apply to write.
"""

import argparse
import re
import sys
from pathlib import Path

DEFAULT_VAULT = Path.home() / "Documents/Obsidian/Main"

# Mirrors index-notes' own exclude_folders setting.
EXCLUDED = {"Journal", "QuickAdd Packages", "Templates", "__files", "__scripts", ".obsidian"}

ANCHOR = re.compile(r"^>\s*\^indexof-[\w-]+\s*$")
CALLOUT_START = re.compile(r"^>\s*\[!")
H1 = re.compile(r"^#\s+\S")


def split_frontmatter(lines):
    """Return (body_start_index). Frontmatter is never touched."""
    if not lines or lines[0].rstrip() != "---":
        return 0
    for i in range(1, len(lines)):
        if lines[i].rstrip() == "---":
            return i + 1
    return 0


def find_callout_blocks(lines, start):
    """Yield (block_start, block_end_exclusive) for each callout ending in an anchor.

    A run of `>` lines can hold several callouts with no blank line between them,
    so the run is split at each `> [!...]` header. Without that split an adjacent
    hand-written callout would be dragged along with the index block.
    """
    i = start
    while i < len(lines):
        if not lines[i].startswith(">"):
            i += 1
            continue
        run_start = i
        while i < len(lines) and lines[i].startswith(">"):
            i += 1
        run_end = i

        # Offsets of each callout header within the run; the run may also open
        # with continuation lines belonging to no header.
        heads = [j for j in range(run_start, run_end) if CALLOUT_START.match(lines[j])]
        bounds = [run_start] + heads if heads and heads[0] != run_start else heads or [run_start]
        bounds = sorted(set(bounds))

        for k, bs in enumerate(bounds):
            be = bounds[k + 1] if k + 1 < len(bounds) else run_end
            if any(ANCHOR.match(line) for line in lines[bs:be]):
                yield bs, be


def normalize(lines):
    """Return rewritten lines, or None if nothing to do."""
    body_start = split_frontmatter(lines)

    h1 = next((i for i in range(body_start, len(lines)) if H1.match(lines[i])), None)
    if h1 is None:
        return None

    blocks = list(find_callout_blocks(lines, body_start))
    if not blocks:
        return None

    # Already canonical: blocks sit directly under the H1, separated by one blank line.
    if blocks[0][0] == h1 + 2 and lines[h1 + 1].strip() == "":
        contiguous = all(b[0] == blocks[i][1] + 1 for i, b in enumerate(blocks[1:]))
        if contiguous:
            return None

    moved = []
    for bs, be in blocks:
        moved.extend(lines[bs:be])
        moved.append("")

    # Drop the originals back-to-front so earlier indices stay valid.
    rest = list(lines)
    for bs, be in reversed(blocks):
        # Absorb one trailing blank line so removal does not leave a gap.
        end = be + 1 if be < len(rest) and rest[be].strip() == "" else be
        del rest[bs:end]

    h1 = next(i for i in range(split_frontmatter(rest), len(rest)) if H1.match(rest[i]))
    out = rest[: h1 + 1] + [""] + moved + rest[h1 + 1 :]

    # Collapse runs of blank lines introduced by the splice.
    collapsed = []
    for line in out:
        if line.strip() == "" and collapsed and collapsed[-1].strip() == "":
            continue
        collapsed.append(line)
    return collapsed


def iter_notes(vault):
    for path in vault.rglob("*.md"):
        rel = path.relative_to(vault)
        if EXCLUDED & set(rel.parts[:-1]):
            continue
        yield path


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--vault", type=Path, default=DEFAULT_VAULT)
    ap.add_argument("--apply", action="store_true", help="write changes (default: dry run)")
    ap.add_argument("paths", nargs="*", type=Path, help="specific notes; default: whole vault")
    args = ap.parse_args()

    targets = args.paths or iter_notes(args.vault)

    changed = 0
    for path in targets:
        text = path.read_text(encoding="utf-8")
        lines = text.split("\n")
        result = normalize(lines)
        if result is None:
            continue
        changed += 1
        if args.apply:
            path.write_text("\n".join(result), encoding="utf-8")
            print(f"moved  {path}")
        else:
            print(f"would move  {path}")

    if not args.apply and changed:
        print(f"\n{changed} note(s) would change. Re-run with --apply.", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
