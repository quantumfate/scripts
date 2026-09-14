#!/usr/bin/env bash
# ,hyprfocus — the read-only verbs, pinned against the shipped declaration.
#
# The resolver now exists twice: in Lua for the compositor and here in Python
# for the CLI. That duplication is deliberate (the CLI must work with no
# compositor) and it is a real drift risk, so this pins what the Python side
# resolves to. If the two implementations disagree about what a mode means,
# one of them is wrong and this is where it shows.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cli="$here/../bin/,hyprfocus"
[[ -x $cli ]] || cli="$here/../,hyprfocus"
declaration="$here/../../quickshell/assets/hyprfocus.default.json"

if [[ ! -f $declaration ]]; then
    echo "skip: sibling quickshell checkout not found at $declaration" >&2
    exit 0
fi

fail=0
check() {
    local name=$1 expected=$2 actual=$3
    if [[ $actual == "$expected" ]]; then
        echo "  ok   $name"
    else
        echo "  FAIL $name"
        echo "    expected: $expected"
        echo "    actual:   $actual"
        fail=1
    fi
}

run() { "$cli" --declaration "$declaration" "$@"; }

# Game mode is the sharpest case: it is the only one using `only`, and the one
# whose whole point is giving things up.
check "game admits only its four workspaces" \
    "gaming, comms, ankama, logs" \
    "$(run resolve game | awk '/^workspaces/ {sub(/^workspaces */, ""); print}')"

check "game stops the Obsidian suite" \
    "theme-auto, state-backup, chezmoi, audio-notify" \
    "$(run resolve game | awk '/^services/ {sub(/^services */, ""); print}')"

# The soft-edge case: media keeps the window and drops the background work.
check "media keeps Obsidian but not its indexer or sync" \
    "theme-auto, obsidian, state-backup, chezmoi, audio-notify" \
    "$(run resolve media | awk '/^services/ {sub(/^services */, ""); print}')"

# A scene is geometry for a workspace; one whose workspace is gone must go too.
check "game carries only the gaming scene" \
    "gaming" \
    "$(run resolve game | awk '/^scenes/ {sub(/^scenes */, ""); print}')"

check "neutral carries both scenes" \
    "code, gaming" \
    "$(run resolve neutral | awk '/^scenes/ {sub(/^scenes */, ""); print}')"

# Dependency closure: nothing names the indexer, it arrives via `wants`.
check "neutral pulls in Obsidian's companions without naming them" \
    "theme-auto, obsidian, obsidian-index, linear-sync, state-backup, chezmoi, audio-notify" \
    "$(run resolve neutral | awk '/^services/ {sub(/^services */, ""); print}')"

check "every declared mode is listed" \
    "chores deep game llm media neutral reflect" \
    "$(run modes | sed 's/^[* ] *//' | awk '{print $1}' | tr '\n' ' ' | sed 's/ $//')"

# A typo must fail loudly rather than resolving to a desk missing a workspace.
if run resolve gamming >/dev/null 2>&1; then
    echo "  FAIL an unknown mode should exit non-zero"
    fail=1
else
    echo "  ok   an unknown mode exits non-zero"
fi

# Seeding, against a scratch state tree — never the machine this runs on.
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

check "seeding installs the declaration" \
    "seeded $scratch/hyprfocus.json (7 modes)" \
    "$(XDG_STATE_HOME=$scratch "$cli" seed "$declaration")"

# The store is edited at runtime, so a seed that clobbered it would throw away
# whatever was tuned by hand.
if XDG_STATE_HOME=$scratch "$cli" seed "$declaration" >/dev/null 2>&1; then
    echo "  FAIL seeding over an existing store should refuse"
    fail=1
else
    echo "  ok   seeding over an existing store refuses"
fi

if XDG_STATE_HOME=$scratch "$cli" seed "$declaration" --force >/dev/null 2>&1; then
    echo "  ok   --force replaces it"
else
    echo "  FAIL --force should replace it"
    fail=1
fi

# A declaration that cannot resolve is one the desk would fail on at the next
# mode change; failing at seed time is the cheaper place to find out.
broken=$scratch/broken.json
sed 's/"gaming", "comms"/"gamming", "comms"/' "$declaration" >"$broken"
if XDG_STATE_HOME=$scratch "$cli" seed "$broken" --force >/dev/null 2>&1; then
    echo "  FAIL seeding an unresolvable declaration should refuse"
    fail=1
else
    echo "  ok   seeding an unresolvable declaration refuses"
fi

echo
[[ $fail -eq 0 ]] && echo "hyprfocus: all checks passed" || echo "hyprfocus: failures above"
exit $fail
