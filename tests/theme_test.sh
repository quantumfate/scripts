#!/usr/bin/env bash
# Functional tests for ,theme.sh.
#
# The script's whole job is editing files that belong to a running desktop, so
# the tests give it a fake one: XDG_CONFIG_HOME and XDG_STATE_HOME point into a
# scratch tree seeded with the same file shapes the real config has.
#
# That is not enough on its own. gsettings writes over D-Bus to the dconf
# service, which uses ITS environment rather than the caller's, so a redirected
# XDG_CONFIG_HOME does not contain it — an early version of this file repainted
# the live desktop it was meant to be isolated from. hyprctl and pkill address
# the session by name and escape the same way.
#
# So THEME_GSETTINGS points at a recorder below. It stubs the one call that can
# escape, tells the script it is sandboxed so the signals and hyprctl pokes are
# held back, and gives the tests something to assert on that they could not
# check before.

set -euo pipefail

THEME=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/,theme.sh
pass=0
fail=0

check() {
    local what=$1 expected=$2 actual=$3
    if [ "$expected" = "$actual" ]; then
        pass=$((pass + 1))
        printf '  ok   %s\n' "$what"
    else
        fail=$((fail + 1))
        printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$what" "$expected" "$actual"
    fi
}

contains() {
    local what=$1 needle=$2 haystack=$3
    case "$haystack" in
    *"$needle"*)
        pass=$((pass + 1))
        printf '  ok   %s\n' "$what"
        ;;
    *)
        fail=$((fail + 1))
        printf '  FAIL %s\n       %q not found in: %s\n' "$what" "$needle" "$haystack"
        ;;
    esac
}

# A scratch desktop: the files the script edits, with the shapes it expects.
setup() {
    ROOT=$(mktemp -d)
    export XDG_CONFIG_HOME="$ROOT/config" XDG_STATE_HOME="$ROOT/state"

    # The gsettings recorder. Appends its arguments and succeeds, so the script
    # takes the same path it would on a real desktop.
    GSETTINGS_LOG="$ROOT/gsettings.log"
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$GSETTINGS_LOG" >"$ROOT/gsettings"
    chmod +x "$ROOT/gsettings"
    export THEME_GSETTINGS="$ROOT/gsettings"
    : >"$GSETTINGS_LOG"
    mkdir -p "$XDG_CONFIG_HOME"/{kitty/themes,qt5ct/colors,qt6ct/colors,Kvantum} "$XDG_STATE_HOME"

    for flavour in latte frappe macchiato mocha; do
        touch "$XDG_CONFIG_HOME/kitty/themes/$flavour.conf"
        for v in qt5ct qt6ct; do
            touch "$XDG_CONFIG_HOME/$v/colors/catppuccin-$flavour-mauve.conf"
        done
        mkdir -p "$XDG_CONFIG_HOME/Kvantum/catppuccin-$flavour-mauve"
    done

    printf 'style=kvantum\ncolor_scheme_path=%s/qt6ct/colors/catppuccin-macchiato-mauve.conf\n' \
        "$XDG_CONFIG_HOME" >"$XDG_CONFIG_HOME/qt6ct/qt6ct.conf"
    printf 'style=kvantum\ncolor_scheme_path=%s/qt5ct/colors/catppuccin-macchiato-mauve.conf\n' \
        "$XDG_CONFIG_HOME" >"$XDG_CONFIG_HOME/qt5ct/qt5ct.conf"
    printf '[General]\ntheme=catppuccin-macchiato-mauve\n' >"$XDG_CONFIG_HOME/Kvantum/kvantum.kvconfig"

    STORE="$XDG_STATE_HOME/theme.json"
}

teardown() {
    unset THEME_GSETTINGS
    rm -rf "$ROOT"
}

gsettings_log() { cat "$GSETTINGS_LOG"; }

field() { jq -r ".$1" "$STORE"; }

echo "seeding an empty store"
setup
"$THEME" set mocha >/dev/null
check "palette written" "mocha" "$(field palette)"
check "an explicit set pins the mode" "manual" "$(field mode)"
check "get agrees" "mocha" "$("$THEME" get)"
check "kitty link repointed" "themes/mocha.conf" "$(readlink "$XDG_CONFIG_HOME/kitty/current-theme.conf")"
contains "qt6ct rewritten" "catppuccin-mocha-mauve.conf" "$(cat "$XDG_CONFIG_HOME/qt6ct/qt6ct.conf")"
contains "qt5ct rewritten" "catppuccin-mocha-mauve.conf" "$(cat "$XDG_CONFIG_HOME/qt5ct/qt5ct.conf")"
contains "kvantum rewritten" "theme=catppuccin-mocha-mauve" "$(cat "$XDG_CONFIG_HOME/Kvantum/kvantum.kvconfig")"
contains "qt5ct style untouched" "style=kvantum" "$(cat "$XDG_CONFIG_HOME/qt5ct/qt5ct.conf")"
teardown

echo "GTK is told the theme and the light/dark scheme"
setup
"$THEME" set latte >/dev/null
contains "a light palette asks for the light theme" "gtk-theme catppuccin-latte-mauve-standard+default" "$(gsettings_log)"
contains "and for prefer-light" "color-scheme prefer-light" "$(gsettings_log)"
teardown

setup
"$THEME" set macchiato >/dev/null
contains "a dark palette asks for prefer-dark" "color-scheme prefer-dark" "$(gsettings_log)"
teardown

echo "nothing reaches the live session"
setup
"$THEME" set mocha >/dev/null
# The desk this runs on must be untouched: every write landed under $ROOT, and
# the session-wide pokes were held back.
check "gsettings was stubbed, not the real one" "$ROOT/gsettings" "$THEME_GSETTINGS"
contains "hyprland was skipped" "skipped (sandboxed)" "$("$THEME" apply)"
teardown

echo "auto mode resolves from day/night, not from palette"
setup
printf '{"mode":"auto","day":"latte","night":"mocha","palette":"frappe"}\n' >"$STORE"
resolved=$("$THEME" get)
case "$resolved" in
latte | mocha)
    printf '  ok   resolved to a day/night palette (%s)\n' "$resolved"
    pass=$((pass + 1))
    ;;
*)
    printf '  FAIL auto resolved to %s, expected latte or mocha\n' "$resolved"
    fail=$((fail + 1))
    ;;
esac
"$THEME" apply >/dev/null
check "apply records what it resolved" "$resolved" "$(field palette)"
check "apply leaves the mode alone" "auto" "$(field mode)"
teardown

echo "auto hands the choice back"
setup
"$THEME" set latte >/dev/null
check "pinned" "manual" "$(field mode)"
"$THEME" auto >/dev/null
check "handed back" "auto" "$(field mode)"
teardown

echo "toggle swaps day and night"
setup
printf '{"mode":"manual","day":"latte","night":"mocha","palette":"latte"}\n' >"$STORE"
"$THEME" toggle >/dev/null
check "latte toggles to night" "mocha" "$(field palette)"
"$THEME" toggle >/dev/null
check "and back to day" "latte" "$(field palette)"
teardown

echo "refusing what it cannot do"
setup
if "$THEME" set dracula >/dev/null 2>&1; then
    printf '  FAIL an unknown palette was accepted\n'
    fail=$((fail + 1))
else
    printf '  ok   an unknown palette is refused\n'
    pass=$((pass + 1))
fi
# A refused set must not create the store either: writing a file to record a
# rejection is how a typo ends up as persisted state.
if [ ! -e "$STORE" ]; then
    printf '  ok   a refused set leaves no store behind\n'
    pass=$((pass + 1))
else
    check "a refused set wrote no palette" "null" "$(jq -r '.palette // "null"' "$STORE")"
fi
if "$THEME" nonsense >/dev/null 2>&1; then
    printf '  FAIL an unknown command was accepted\n'
    fail=$((fail + 1))
else
    printf '  ok   an unknown command is refused\n'
    pass=$((pass + 1))
fi
teardown

echo "surviving a half-provisioned machine"
setup
rm -rf "$XDG_CONFIG_HOME/Kvantum" "$XDG_CONFIG_HOME/qt5ct"
if out=$("$THEME" set frappe 2>&1); then
    printf '  ok   a missing surface does not abort the rest\n'
    pass=$((pass + 1))
else
    printf '  FAIL aborted on a missing surface:\n%s\n' "$out"
    fail=$((fail + 1))
fi
check "the surfaces that exist still changed" "frappe" "$(field palette)"
contains "qt6ct still rewritten" "catppuccin-frappe-mauve.conf" "$(cat "$XDG_CONFIG_HOME/qt6ct/qt6ct.conf")"
teardown

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
