#!/usr/bin/env python3
"""Mirror Linear issues into the Zettelkasten as index notes.

Linear is the source of truth; the sync is strictly one-way and never deletes.
Each Linear project becomes a meta-index note, each of its issues an index note
beneath it, so the index-notes plugin renders the project's issues and each
issue's own notes without either script knowing about the other:

    Projects/<Project>/meta_idx      project note   (this script creates it)
    Projects/<Project>/<IDENT>/idx   issue note     (this script creates it)
    Projects/<Project>/<IDENT>       your notes     (you tag them)

Issues with no Linear project are skipped: assigning a project is the gesture
that pulls an issue into the vault.

Ownership inside an issue note is narrow. The `linear_*` frontmatter keys and
the `%% linear:begin %%` block under the H1 belong to the sync; everything else
belongs to you and is never rewritten. Filenames are frozen at creation so a
title change in Linear cannot break an inbound wikilink.

Dry-run by default; pass --apply to write.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from obsidian_vault import (
    TEMPLATES,
    Config,
    NoteAction,
    ObsidianCli,
    _ensure_index,
    read_frontmatter,
    save_store,
    scan_vault,
)

API_URL = "https://api.linear.app/graphql"
PAGE_SIZE = 100
PROJECTS_TAG = "Projects"

PASS_VAULT = os.environ.get("LINEAR_PASS_VAULT", "Productivity")
PASS_ITEM = os.environ.get("LINEAR_PASS_ITEM", "linear.app")
PASS_FIELD = os.environ.get("LINEAR_PASS_FIELD", "api_key")

BLOCK_START = "%% linear:begin %%"
BLOCK_END = "%% linear:end %%"

STATUS_ICONS = {
    "backlog": "🗒️",
    "unstarted": "📋",
    "started": "🔄",
    "completed": "✅",
    "canceled": "❌",
}

ISSUES_QUERY = """
query Issues($after: String) {
  issues(first: {page}, after: $after, includeArchived: true) {
    pageInfo { hasNextPage endCursor }
    nodes {
      id
      identifier
      title
      url
      priority
      estimate
      createdAt
      updatedAt
      archivedAt
      state { name type }
      assignee { displayName }
      team { key name }
      labels { nodes { name } }
      project { id name url }
    }
  }
}
""".replace("{page}", str(PAGE_SIZE))


# --------------------------------------------------------------------------
# Credential

class AuthError(RuntimeError):
    """Proton Pass could not hand over the API key."""


def notify(title: str, body: str, urgency: str = "critical") -> None:
    """Best-effort desktop notification; a headless run must not fail on this."""
    try:
        subprocess.run(
            ["notify-send", "-u", urgency, "-i", "dialog-password", "-t", "0", title, body],
            check=False,
            capture_output=True,
        )
    except FileNotFoundError:
        pass


def read_api_key() -> str:
    """Pull the key out of Proton Pass. Never written to disk, never logged."""
    env_key = os.environ.get("LINEAR_API_KEY")
    if env_key:
        return env_key.strip()

    try:
        proc = subprocess.run(
            ["pass-cli", "item", "view", "--vault-name", PASS_VAULT,
             "--item-title", PASS_ITEM, "--output=json"],
            check=False,
            capture_output=True,
            text=True,
            timeout=20,
        )
    except FileNotFoundError as exc:
        raise AuthError("pass-cli is not installed") from exc
    except subprocess.TimeoutExpired as exc:
        raise AuthError("pass-cli timed out") from exc

    if proc.returncode != 0 or not proc.stdout.strip():
        # A forced logout prints to stdout and still exits non-zero; either way
        # the recovery is the same interactive login.
        raise AuthError((proc.stderr or proc.stdout).strip().splitlines()[-1:] or ["no session"])

    try:
        item = json.loads(proc.stdout)["item"]["content"]
    except (json.JSONDecodeError, KeyError) as exc:
        raise AuthError("unexpected pass-cli output shape") from exc

    for field in item.get("extra_fields", []):
        if field.get("name") == PASS_FIELD:
            value = field.get("content", {}).get("Hidden", "")
            if value:
                return value.strip()
    raise AuthError(f"item {PASS_ITEM!r} has no {PASS_FIELD!r} field")


# --------------------------------------------------------------------------
# Linear API

def graphql(key: str, query: str, variables: dict) -> dict:
    request = urllib.request.Request(
        API_URL,
        data=json.dumps({"query": query, "variables": variables}).encode(),
        headers={"Authorization": key, "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = json.load(response)
    except urllib.error.HTTPError as exc:
        if exc.code in (401, 403):
            raise AuthError(f"Linear rejected the API key (HTTP {exc.code})") from exc
        raise RuntimeError(f"Linear API error: HTTP {exc.code}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"Linear unreachable: {exc.reason}") from exc

    if payload.get("errors"):
        raise RuntimeError(f"Linear API error: {payload['errors'][0].get('message')}")
    return payload["data"]


def fetch_issues(key: str) -> list[dict]:
    """Every issue, archived included, walked to the end of the cursor."""
    issues: list[dict] = []
    after = None
    while True:
        page = graphql(key, ISSUES_QUERY, {"after": after})["issues"]
        issues.extend(page["nodes"])
        if not page["pageInfo"]["hasNextPage"]:
            return issues
        after = page["pageInfo"]["endCursor"]


# --------------------------------------------------------------------------
# Naming

INVALID_FILENAME = re.compile(r'[<>:"/\\|?*\x00-\x1f]')
SLUG_STRIP = re.compile(r"[^\w\- ]+")


def slug(name: str) -> str:
    """Project name to tag segment, preserving case so humanize() round-trips."""
    cleaned = SLUG_STRIP.sub("", name).strip()
    cleaned = re.sub(r"[\s_]+", "-", cleaned)
    return re.sub(r"-{2,}", "-", cleaned).strip("-")


def note_title(issue: dict) -> str:
    """Filename stem, frozen at creation: identifier first so it sorts and greps."""
    title = INVALID_FILENAME.sub("", issue["title"]).strip()
    title = re.sub(r"\s{2,}", " ", title)
    return f"{issue['identifier']} {title}".strip()


def status_icon(state: dict | None) -> str:
    return STATUS_ICONS.get((state or {}).get("type", ""), "•")


# --------------------------------------------------------------------------
# Note content

FRONTMATTER_RE = re.compile(r"^(---\n)(.*?)(\n---\n)", re.DOTALL)


def linear_fields(issue: dict, orphaned: bool = False) -> dict:
    """The frontmatter keys this script owns. Everything else is left alone."""
    project = issue.get("project") or {}
    labels = [n["name"] for n in (issue.get("labels") or {}).get("nodes", [])]
    fields = {
        "linear_id": issue["id"],
        "linear_identifier": issue["identifier"],
        "linear_url": issue["url"],
        "linear_status": (issue.get("state") or {}).get("name", ""),
        "linear_state_type": (issue.get("state") or {}).get("type", ""),
        "linear_assignee": (issue.get("assignee") or {}).get("displayName", ""),
        "linear_team": (issue.get("team") or {}).get("name", ""),
        "linear_project": project.get("name", ""),
        "linear_project_id": project.get("id", ""),
        "linear_project_url": project.get("url", ""),
        "linear_priority": str(issue.get("priority", 0) or 0),
        "linear_labels": ", ".join(labels),
        "linear_created": issue.get("createdAt", ""),
        "linear_updated": issue.get("updatedAt", ""),
        "linear_last_synced": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    }
    if issue.get("archivedAt"):
        fields["linear_archived"] = "true"
    if orphaned:
        fields["linear_state"] = "orphaned"
        fields["linear_orphaned_at"] = datetime.now(timezone.utc).date().isoformat()
    return fields


def merge_frontmatter(text: str, fields: dict) -> str:
    """Replace the linear_* keys in place, appending any that are new.

    Untouched keys keep their position, so a Templater-written header and any
    property the user added by hand survive verbatim.
    """
    match = FRONTMATTER_RE.match(text)
    if not match:
        block = "".join(f"{k}: {v}\n" for k, v in fields.items())
        return f"---\n{block}---\n\n{text}"

    lines = match.group(2).split("\n")
    remaining = dict(fields)
    out = []
    for line in lines:
        key = re.match(r"^(\w+):", line)
        name = key.group(1) if key else None
        if name in remaining:
            out.append(f"{name}: {remaining.pop(name)}")
        else:
            out.append(line)
    out.extend(f"{k}: {v}" for k, v in remaining.items())
    return f"{match.group(1)}{chr(10).join(out)}{match.group(3)}{text[match.end():]}"


def render_block(issue: dict) -> str:
    """The sync-owned callout. Kept small: Linear is where you act on an issue."""
    state = (issue.get("state") or {}).get("name", "Unknown")
    assignee = (issue.get("assignee") or {}).get("displayName") or "unassigned"
    lines = [
        BLOCK_START,
        f"> [!info] {status_icon(issue.get('state'))} {state} · {assignee}",
        f"> [Open {issue['identifier']} in Linear]({issue['url']})",
        BLOCK_END,
    ]
    return "\n".join(lines)


H1_RE = re.compile(r"^#\s+\S", re.MULTILINE)


def merge_block(text: str, block: str) -> str:
    """Replace the delimited block, or plant it directly under the H1.

    The normalizer parks `^indexof-*` callouts just above the first H2, so a
    block written here always ends up above the index block. That is the
    agreed layout and needs no coordination between the two scripts.
    """
    start = text.find(BLOCK_START)
    end = text.find(BLOCK_END)
    if start != -1 and end > start:
        return text[:start] + block + text[end + len(BLOCK_END):]

    h1 = H1_RE.search(text)
    if not h1:
        return f"{text.rstrip()}\n\n{block}\n"
    line_end = text.find("\n", h1.start())
    line_end = len(text) if line_end == -1 else line_end
    return f"{text[:line_end]}\n\n{block}\n{text[line_end:]}"


def render_title(text: str, title: str) -> str:
    """Track the Linear title in the H1 without ever touching the filename."""
    h1 = H1_RE.search(text)
    if not h1:
        return text
    line_end = text.find("\n", h1.start())
    line_end = len(text) if line_end == -1 else line_end
    return f"# {title}{text[line_end:]}" if h1.start() == 0 else (
        text[:h1.start()] + f"# {title}" + text[line_end:]
    )


# --------------------------------------------------------------------------
# Sync

def ensure_project_index(cfg: Config, topics: dict, topic: str, title: str) -> NoteAction | None:
    """Like obsidian_vault._ensure_index, but titled from Linear rather than the slug.

    The slug is lossy on purpose (`lance.nvim` -> `lancenvim`) so tags stay
    plain; the note itself should still carry the project's real name.
    """
    if topics.get(topic, {}).get("meta_idx_note"):
        return None
    tag = f"{topic}/meta_idx"

    existing = topics.get(topic, {}).get("idx_note")
    if existing:
        return NoteAction("add_tags", existing, [tag])

    unique = title
    while (cfg.vault_root / f"{unique}.md").exists():
        unique = f"{unique} Index"
    return NoteAction("create", unique, [tag])


class Plan:
    """What one run intends to do, so --dry-run and --apply share a code path."""

    def __init__(self) -> None:
        self.index_actions: list[NoteAction] = []
        self.creates: list[tuple[str, str, list[str], dict]] = []
        self.updates: list[tuple[Path, dict, dict]] = []
        self.orphans: list[tuple[Path, str]] = []
        self.skipped_no_project = 0
        self.unchanged = 0

    def empty(self) -> bool:
        return not (self.index_actions or self.creates or self.updates or self.orphans)


def index_notes_by_linear_id(cfg: Config) -> dict[str, Path]:
    """Existing issue notes, keyed by the identity Linear renames cannot touch."""
    found: dict[str, Path] = {}
    for path in cfg.vault_root.rglob("*.md"):
        linear_id = read_frontmatter(path).get("linear_id")
        if linear_id:
            found[linear_id] = path
    return found


def build_plan(cfg: Config, issues: list[dict], topics: dict, only: str | None = None) -> Plan:
    plan = Plan()
    known = index_notes_by_linear_id(cfg)
    seen: set[str] = set()
    planned_topics = set()

    for issue in issues:
        project = issue.get("project")
        if not project or not project.get("name"):
            plan.skipped_no_project += 1
            continue
        if only and only.lower() not in (project["name"].lower(), slug(project["name"]).lower()):
            continue

        seen.add(issue["id"])
        project_tag = f"{PROJECTS_TAG}/{slug(project['name'])}"
        issue_tag = f"{project_tag}/{issue['identifier']}"
        fields = linear_fields(issue)

        # Ancestor index notes, planned once each even across many issues.
        if PROJECTS_TAG not in planned_topics:
            planned_topics.add(PROJECTS_TAG)
            root = _ensure_index(cfg, topics, PROJECTS_TAG, "meta_idx")
            if root:
                plan.index_actions.append(root)
        if project_tag not in planned_topics:
            planned_topics.add(project_tag)
            title = INVALID_FILENAME.sub("", project["name"]).strip()
            action = ensure_project_index(cfg, topics, project_tag, title)
            if action:
                plan.index_actions.append(action)

        existing = known.get(issue["id"])
        if existing is None:
            plan.creates.append((note_title(issue), issue_tag, [f"{issue_tag}/idx"], issue))
            continue

        # Rewriting an unchanged note would wake the index watcher and bump
        # date_modified on every tick, so only touch what Linear actually moved.
        current = read_frontmatter(existing)
        if current.get("linear_updated") == issue.get("updatedAt"):
            plan.unchanged += 1
            continue
        plan.updates.append((existing, fields, issue))

    # A filtered run has only seen part of Linear, so it cannot judge orphans.
    for linear_id, path in known.items() if not only else []:
        if linear_id in seen:
            continue
        if read_frontmatter(path).get("linear_state") == "orphaned":
            continue
        plan.orphans.append((path, linear_id))

    return plan


def describe(plan: Plan) -> None:
    for action in plan.index_actions:
        print(f"  index   {action.describe()}")
    for title, tag, _, _ in plan.creates:
        print(f"  create  {title}  [{tag}/idx]")
    for path, _, issue in plan.updates:
        print(f"  update  {path.name}  ({issue['identifier']})")
    for path, _ in plan.orphans:
        print(f"  orphan  {path.name}")
    if plan.unchanged:
        print(f"  {plan.unchanged} issue(s) unchanged since last sync")
    if plan.skipped_no_project:
        print(f"  skipped {plan.skipped_no_project} issue(s) with no Linear project")


def write_note(path: Path, issue: dict, fields: dict) -> None:
    text = path.read_text(encoding="utf-8")
    text = merge_frontmatter(text, fields)
    text = render_title(text, issue["title"])
    text = merge_block(text, render_block(issue))
    path.write_text(text, encoding="utf-8")


def apply_plan(cfg: Config, plan: Plan) -> None:
    cli = ObsidianCli(cfg)
    if (plan.index_actions or plan.creates) and not cli.app_running():
        raise RuntimeError("Obsidian is not running; note creation needs Templater via its CLI")

    for action in plan.index_actions:
        if action.kind == "create":
            rel = f"{cfg.root}/{action.title}"
            cli.create_from_template(TEMPLATES["moc"], rel, open_file=False)
            cli.set_tags(rel, action.tags)
        else:
            path = cfg.vault_root / f"{action.title}.md"
            current = read_frontmatter(path).get("tags", [])
            cli.set_tags(f"{cfg.root}/{action.title}",
                         current + [t for t in action.tags if t not in current])
        print(f"  index   {action.describe()}")

    for title, _, tags, issue in plan.creates:
        rel = f"{cfg.root}/{title}"
        target = cfg.vault_root / f"{title}.md"
        if target.exists():
            # No merge logic by design: move the stranger aside and start clean.
            aside = cfg.vault_root / f"{title} (pre-linear).md"
            target.rename(aside)
            print(f"  moved   {target.name} -> {aside.name}")
        cli.create_from_template(TEMPLATES["moc"], rel, open_file=False)
        cli.set_tags(rel, tags)
        write_note(target, issue, linear_fields(issue))
        print(f"  create  {title}")

    for path, fields, issue in plan.updates:
        write_note(path, issue, fields)
        print(f"  update  {path.name}")

    for path, _ in plan.orphans:
        text = path.read_text(encoding="utf-8")
        path.write_text(merge_frontmatter(text, {
            "linear_state": "orphaned",
            "linear_orphaned_at": datetime.now(timezone.utc).date().isoformat(),
        }), encoding="utf-8")
        print(f"  orphan  {path.name}")


def cmd_sync(cfg: Config, apply: bool, encrypt: bool, only: str | None = None) -> int:
    key = read_api_key()
    issues = fetch_issues(key)
    plan = build_plan(cfg, issues, scan_vault(cfg)["topics"], only)

    print(f"{len(issues)} issue(s) from Linear")
    if plan.empty():
        describe(plan)
        print("nothing to do")
        return 0

    if not apply:
        describe(plan)
        pending = len(plan.index_actions) + len(plan.creates) + len(plan.updates) + len(plan.orphans)
        print(f"\n{pending} change(s) planned. Re-run with --apply.", file=sys.stderr)
        return 0

    apply_plan(cfg, plan)
    save_store(cfg, scan_vault(cfg), encrypt)
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="obsidian_linear_sync",
        description=__doc__.splitlines()[0],
    )
    parser.add_argument("--apply", action="store_true", help="write changes (default: dry run)")
    parser.add_argument("--no-encrypt", action="store_true", help="skip the tags.json.gpg copy")
    parser.add_argument("--project", metavar="NAME",
                        help="only sync this Linear project (name or slug); skips orphan checks")
    args = parser.parse_args(argv)

    cfg = Config()
    try:
        return cmd_sync(cfg, args.apply, encrypt=not args.no_encrypt, only=args.project)
    except AuthError as exc:
        notify(
            "Linear sync: Proton Pass locked",
            "Obsidian cannot reach Linear.\nRecover with:  pass-cli login --interactive",
        )
        print(f"auth: {exc}", file=sys.stderr)
        print("recover with: pass-cli login --interactive", file=sys.stderr)
        return 2
    except RuntimeError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
