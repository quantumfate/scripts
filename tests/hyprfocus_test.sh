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

# Applying, against a recorder rather than the machine's own systemd. Nothing
# in this file may touch a real unit.
recorder=$scratch/systemctl
cat >"$recorder" <<'REC'
#!/usr/bin/env bash
# Records what it was asked to do. `is-active` answers yes for the units named
# in ACTIVE, so a test can describe a desk and see what moves.
args=("$@")
verb=${2:-}
unit=${args[${#args[@]} - 1]}
if [[ $verb == is-active ]]; then
    [[ " ${ACTIVE:-} " == *" $unit "* ]] && exit 0 || exit 3
fi
echo "$verb $unit" >>"$RECORD"
exit 0
REC
chmod +x "$recorder"

apply_with() {
    local active=$1 mode=$2 decl=${3:-$declaration}
    : >"$scratch/record"
    RECORD=$scratch/record ACTIVE=$active SYSTEMCTL=$recorder \
        XDG_STATE_HOME=$scratch "$cli" --declaration "$decl" apply "$mode" >/dev/null 2>&1
    sort "$scratch/record" | tr '\n' ' ' | sed 's/ $//'
}

full_suite="obsidian.service obsidian-index-normalize.service obsidian-linear-sync.service obsidian-linear-sync.timer"
baseline="theme-auto.service theme-auto.timer state-backup.service state-backup.timer audio-notify.service"

check "entering game stops the Obsidian suite" \
    "stop obsidian-index-normalize.service stop obsidian-linear-sync.service stop obsidian-linear-sync.timer stop obsidian.service" \
    "$(apply_with "$full_suite $baseline" game)"

check "leaving game starts them again" \
    "start obsidian-index-normalize.service start obsidian-linear-sync.service start obsidian-linear-sync.timer start obsidian.service" \
    "$(apply_with "$baseline" neutral)"

# A unit already in the state the mode wants is left alone: switching between
# two modes that share a service must not stop and restart it.
check "a service both modes want is not touched" \
    "" \
    "$(apply_with "$baseline $full_suite" neutral)"

# The protected rail wins over any declaration: a hand-edited store must not be
# able to stop the audio stack or the idle daemon. Other units still move, so
# what is asserted is that no protected one was asked to stop.
protected_run=$(apply_with "pipewire.service hypridle.service theme-auto.service" game)
if [[ $protected_run == *"stop pipewire"* || $protected_run == *"stop hypridle"* ]]; then
    echo "  FAIL a protected unit was stopped"
    fail=1
else
    echo "  ok   protected units are never stopped"
fi

# Drift is reported rather than silently doing nothing: a task the contract
# does not implement means the declaration and the unit files have diverged.
drifted=$scratch/drifted.json
python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
d['base']['services'].append('ghost')
d['modes']['neutral']['services'] = {'add': ['ghost']}
json.dump(d, open(sys.argv[2], 'w'))
" "$declaration" "$drifted"

# Captured rather than piped into grep: `grep -q` exits on the first match, the
# writer takes SIGPIPE, and `pipefail` would turn a passing check into a
# failing one.
drift_output=$(RECORD=$scratch/record ACTIVE='' SYSTEMCTL=$recorder XDG_STATE_HOME=$scratch \
    "$cli" --declaration "$drifted" apply neutral 2>&1)
if [[ $drift_output == *"have drifted"* ]]; then
    echo "  ok   an unimplemented task is reported, not ignored"
else
    echo "  FAIL an unimplemented task should be reported"
    fail=1
fi

# Every decision is appended: with a schedule able to change the mode on its
# own, "why did my desk do that" needs an answer.
if [[ -s $scratch/hyprfocus/log.jsonl ]]; then
    echo "  ok   decisions are logged"
else
    echo "  FAIL decisions should be logged"
    fail=1
fi

echo
[[ $fail -eq 0 ]] && echo "hyprfocus: all checks passed" || echo "hyprfocus: failures above"
exit $fail
