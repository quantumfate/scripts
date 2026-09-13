#!/usr/bin/env bash
# ,theme.sh — one palette, every surface.
#
# Quickshell and Hyprland watch $XDG_STATE_HOME/theme.json directly and react on
# their own. Everything else — kitty, GTK, Qt, Kvantum, the wallpaper — needs a
# process to poke it, and that is all this script is: the fan-out for the
# surfaces that cannot read a JSON file for themselves.
#
# It is a script rather than a Quickshell service for three reasons: the theme
# has to apply while the shell is restarting, `kitty` and `gsettings` need to be
# executed either way, and a theme you cannot set from a tmux pane at 2am is not
# finished.
#
#   ,theme.sh apply            fan the current theme.json out to everything
#   ,theme.sh set <palette>    pick a palette (pins mode=manual) and apply
#   ,theme.sh auto             hand the choice back to the sun and apply
#   ,theme.sh toggle           swap between the day and night palettes
#   ,theme.sh get              print the resolved palette
#   ,theme.sh status           print what each surface is currently set to
#
# Writes go through the same store the shell uses, so setting a palette here and
# setting it from the bar are the same operation.

set -euo pipefail

STATE="${XDG_STATE_HOME:-$HOME/.local/state}/theme.json"
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/wallpapers"

# The accent is not yet a store field: every surface below takes flavour+accent
# as one theme name, and only one accent is installed per flavour that matters.
ACCENT="mauve"

PALETTES=(latte frappe macchiato mocha)
# Which flavours are light. Drives GTK's color-scheme, which is a separate
# setting from the theme name and is what applications actually branch on.
LIGHT=(latte)

die() {
    printf '%s: %s\n' "${0##*/}" "$1" >&2
    exit 1
}
have() { command -v "$1" >/dev/null 2>&1; }

# --- the store ---------------------------------------------------------------

# Reads one field. jq is a hard dependency of the shell already.
get() {
    local key=$1 fallback=${2-}
    [ -f "$STATE" ] || {
        printf '%s' "$fallback"
        return
    }
    jq -r --arg k "$key" --arg d "$fallback" '.[$k] // $d' "$STATE" 2>/dev/null || printf '%s' "$fallback"
}

# Merges a patch. Atomic: the shell is watching this file, and a half-written
# one is a palette nobody asked for.
put() {
    local patch=$1 tmp
    mkdir -p "$(dirname "$STATE")"
    [ -f "$STATE" ] || printf '{}' >"$STATE"
    tmp=$(mktemp "$STATE.XXXXXX")
    jq --argjson p "$patch" '. * $p' "$STATE" >"$tmp"
    mv -f "$tmp" "$STATE"
}

is_palette() {
    local p=$1
    for known in "${PALETTES[@]}"; do [ "$p" = "$known" ] && return 0; done
    return 1
}

is_light() {
    local p=$1
    for l in "${LIGHT[@]}"; do [ "$p" = "$l" ] && return 0; done
    return 1
}

# --- which palette --------------------------------------------------------

# `mode: auto` means the sun decides; `manual` means a deliberate pick stands
# until it is handed back. Resolving here rather than in the timer keeps every
# entry point agreeing on what "now" looks like.
resolve() {
    local mode palette
    mode=$(get mode auto)
    if [ "$mode" = "auto" ]; then
        if daytime; then get day latte; else get night macchiato; fi
    else
        palette=$(get palette macchiato)
        is_palette "$palette" && printf '%s' "$palette" || printf 'macchiato'
    fi
}

# Sunrise/sunset without a network call or a geolocation dependency: the hours
# are close enough for a colour scheme, and being wrong by twenty minutes at the
# equinox costs nothing.
daytime() {
    local hour
    hour=$(date +%-H)
    [ "$hour" -ge 7 ] && [ "$hour" -lt 19 ]
}

# --- the surfaces ------------------------------------------------------------
#
# Each applier is best-effort and independent: a missing tool must not stop the
# rest of the desk from changing colour. They report what they did so `apply`
# can summarise.

# gsettings is the one applier that does NOT respect $XDG_CONFIG_HOME: the write
# goes over D-Bus to the dconf service, which uses its own environment. Pointing
# XDG_CONFIG_HOME at a scratch tree therefore does not sandbox it — it changes
# the live session. Everything else here edits files under $CONFIG and is
# contained by that variable alone.
#
# So the call is injectable. Tests set THEME_GSETTINGS to a recorder and assert
# on what it was told; nothing else should ever override it.
GSETTINGS=${THEME_GSETTINGS:-gsettings}

# Same injection point, for the same reason: tests need to force the
# "ImageMagick missing" path deterministically rather than hoping the machine
# running them lacks it.
MAGICK=${THEME_MAGICK:-magick}

# The same hazard, three more times: hyprctl, pkill and hyprpaper all address the
# live session by name and ignore $XDG_CONFIG_HOME entirely. Setting
# THEME_GSETTINGS at all means "this is a test run" and holds every one of them
# back, so a test can never repaint the desk it is running on.
sandboxed() { [ -n "${THEME_GSETTINGS-}" ]; }

apply_kitty() {
    local palette=$1 conf="$CONFIG/kitty/current-theme.conf"
    [ -f "$CONFIG/kitty/themes/$palette.conf" ] || {
        echo "kitty: no theme for $palette"
        return
    }
    # Remote control is deliberately off in kitty.conf, so this is a file swap
    # plus SIGUSR1, which kitty answers by re-reading its config. Every running
    # window changes colour; no sockets, no open port.
    ln -sfn "themes/$palette.conf" "$conf"
    sandboxed || pkill -USR1 -x kitty 2>/dev/null || true
    echo "kitty: $palette"
}

apply_gtk() {
    local palette=$1 theme scheme
    theme="catppuccin-$palette-$ACCENT-standard+default"
    if [ ! -d "/usr/share/themes/$theme" ] && [ ! -d "$HOME/.themes/$theme" ]; then
        echo "gtk: $theme not installed (see the theming role)"
        return
    fi
    is_light "$palette" && scheme="prefer-light" || scheme="prefer-dark"
    if have "$GSETTINGS"; then
        "$GSETTINGS" set org.gnome.desktop.interface gtk-theme "$theme"
        "$GSETTINGS" set org.gnome.desktop.interface color-scheme "$scheme"
    fi
    # GTK4 ignores the theme name and reads this instead.
    mkdir -p "$CONFIG/gtk-4.0"
    ln -sfn "/usr/share/themes/$theme/gtk-4.0/gtk.css" "$CONFIG/gtk-4.0/gtk.css" 2>/dev/null || true
    echo "gtk: $theme ($scheme)"
}

apply_qt() {
    local palette=$1
    # Separate declarations: within one `local`, the earlier assignment has not
    # taken effect yet, so $palette would be empty here.
    local colors="catppuccin-$palette-$ACCENT"
    local applied=()
    for v in qt5ct qt6ct; do
        local conf="$CONFIG/$v/$v.conf" scheme="$CONFIG/$v/colors/$colors.conf"
        [ -f "$conf" ] || continue
        [ -f "$scheme" ] || {
            echo "$v: no colour scheme $colors"
            continue
        }
        # sed in place on one key: the rest of the file is qt5ct's own state and
        # is none of our business.
        sed -i "s|^color_scheme_path=.*|color_scheme_path=$scheme|" "$conf"
        applied+=("$v")
    done

    local kv="$CONFIG/Kvantum/kvantum.kvconfig"
    if [ -f "$kv" ] && [ -d "$CONFIG/Kvantum/$colors" ]; then
        sed -i "s|^theme=.*|theme=$colors|" "$kv"
        applied+=(kvantum)
    fi

    # xsettingsd is what tells already-running toolkits to re-read; without the
    # HUP the change waits for the next launch.
    sandboxed || pkill -HUP -x xsettingsd 2>/dev/null || true
    echo "qt: $colors [${applied[*]:-none}]"
}

apply_hyprland() {
    local palette=$1
    sandboxed && {
        echo "hyprland: skipped (sandboxed)"
        return
    }
    have hyprctl || {
        echo "hyprland: not running"
        return
    }
    # The accent, as Hyprland spells colours. Pulled from the same table the
    # shell uses so the border and the bar cannot disagree.
    local accent
    accent=$(accent_hex "$palette")
    hyprctl keyword general:col.active_border "rgb(${accent#\#})" >/dev/null
    hyprctl keyword general:col.inactive_border "rgb(${accent#\#})88" >/dev/null
    echo "hyprland: border $accent"

    apply_opacity
}

# The window-opacity dial lives in the theme store, but Hyprland builds its
# opacity window rules once, when the config loads: HL.WindowRule exposes only
# set_enabled, so a rule's value cannot be changed after the fact. Re-reading
# the store therefore means re-reading the config.
#
# `hyprctl reload` is the only lever, and it is too blunt to run on every apply
# — the sun timer fires hourly and a reload is visible. So it runs only when the
# dial actually moved, tracked by a stamp beside the wallpaper cache.
apply_opacity() {
    local dial stamp previous
    dial=$(get opacity 1.0)
    stamp="${XDG_CACHE_HOME:-$HOME/.cache}/quantumfate/opacity.applied"
    previous=$([ -f "$stamp" ] && cat "$stamp" || echo "")

    if [ "$dial" = "$previous" ]; then
        echo "opacity: $dial (unchanged)"
        return
    fi

    mkdir -p "$(dirname "$stamp")"
    printf '%s' "$dial" >"$stamp"
    hyprctl reload >/dev/null 2>&1 || true
    echo "opacity: $dial (reloaded)"
}

# A transparent bar over a high-contrast source image is unreadable, and the
# fix belongs here rather than in a wallpaper-picking rule: blur+desaturate+tint
# every wallpaper toward its palette's accent once, and hand hyprpaper the
# result instead of the original.
#
# Cached by source mtime rather than content hash — a stat is free and a
# wallpaper file does not change without its mtime moving. The stamp file next
# to the render is what makes an unchanged source a no-op on the next apply.
process_wallpaper() {
    local palette=$1 wall=$2
    have "$MAGICK" || {
        printf '%s' "$wall"
        return
    }
    local name="${wall##*/}"
    local out_dir="$CACHE/$palette"
    local cached="$out_dir/$name"
    local stamp="$cached.mtime"
    local src_mtime
    src_mtime=$(stat -c %Y "$wall" 2>/dev/null || echo 0)

    if [ -f "$cached" ] && [ "$(cat "$stamp" 2>/dev/null)" = "$src_mtime" ]; then
        printf '%s' "$cached"
        return
    fi

    mkdir -p "$out_dir"
    local accent
    accent=$(accent_hex "$palette")
    # Blur hides detail a bar would otherwise sit on top of; the modulate call
    # desaturates without flattening to grey; colorize is the tint toward the
    # palette's accent that makes the result read as "this palette" at a glance.
    if "$MAGICK" "$wall" -blur 0x12 -modulate 100,50,100 -fill "$accent" -colorize 25% "$cached" 2>/dev/null; then
        printf '%s' "$src_mtime" >"$stamp"
        printf '%s' "$cached"
    else
        rm -f "$cached" "$stamp"
        printf '%s' "$wall"
    fi
}

apply_wallpaper() {
    local palette=$1 wall
    wall=$(get wallpaper "")
    if [ -z "$wall" ]; then
        # "" means the palette decides. A per-palette file if one exists, the
        # shared default otherwise.
        local dir="$CONFIG/hypr/wallpapers"
        for candidate in "$dir/$palette.jpg" "$dir/$palette.png"; do
            [ -f "$candidate" ] && {
                wall=$candidate
                break
            }
        done
    fi
    [ -n "$wall" ] && [ -f "$wall" ] || {
        echo "wallpaper: unchanged"
        return
    }
    wall=$(process_wallpaper "$palette" "$wall")
    sandboxed && {
        echo "wallpaper: skipped (sandboxed)"
        return
    }
    have hyprctl || {
        echo "wallpaper: hyprctl not available"
        return
    }
    hyprctl hyprpaper reload ,"$wall" >/dev/null 2>&1 || true
    echo "wallpaper: ${wall##*/}"
}

# The accent colour per flavour, matching Theme.qml's tables. Duplicated here
# because a shell script cannot read QML, and asserted against the real table by
# the quickshell test suite rather than left to drift.
accent_hex() {
    case "$1" in
    latte) printf '#8839ef' ;;
    frappe) printf '#ca9ee6' ;;
    macchiato) printf '#c6a0f6' ;;
    mocha) printf '#cba6f7' ;;
    *) printf '#c6a0f6' ;;
    esac
}

# --- commands ----------------------------------------------------------------

cmd_apply() {
    local palette
    palette=$(resolve)
    # Keep the resolved palette in the store so the shell and the script never
    # disagree about what is showing, even in auto mode.
    put "$(jq -n --arg p "$palette" '{palette: $p}')"

    apply_kitty "$palette"
    apply_gtk "$palette"
    apply_qt "$palette"
    apply_hyprland "$palette"
    apply_wallpaper "$palette"
}

cmd_set() {
    local palette=${1-}
    [ -n "$palette" ] || die "set needs a palette: ${PALETTES[*]}"
    is_palette "$palette" || die "unknown palette '$palette' (have: ${PALETTES[*]})"
    # An explicit pick outlasts the next sunrise. `auto` is how you undo that.
    put "$(jq -n --arg p "$palette" '{palette: $p, mode: "manual"}')"
    cmd_apply
}

cmd_auto() {
    put '{"mode": "auto"}'
    cmd_apply
}

cmd_toggle() {
    local current day night
    current=$(resolve)
    day=$(get day latte)
    night=$(get night macchiato)
    if [ "$current" = "$day" ]; then cmd_set "$night"; else cmd_set "$day"; fi
}

cmd_status() {
    printf 'store     %s\n' "$STATE"
    printf 'mode      %s\n' "$(get mode auto)"
    printf 'resolved  %s\n' "$(resolve)"
    printf 'kitty     %s\n' "$(readlink "$CONFIG/kitty/current-theme.conf" 2>/dev/null || echo unset)"
    have gsettings && printf 'gtk       %s\n' "$(gsettings get org.gnome.desktop.interface gtk-theme)"
    printf 'qt6ct     %s\n' "$(sed -n 's/^color_scheme_path=.*\///p' "$CONFIG/qt6ct/qt6ct.conf" 2>/dev/null || echo unset)"
    printf 'kvantum   %s\n' "$(sed -n 's/^theme=//p' "$CONFIG/Kvantum/kvantum.kvconfig" 2>/dev/null || echo unset)"
}

case "${1-apply}" in
apply) cmd_apply ;;
set)
    shift
    cmd_set "${1-}"
    ;;
auto) cmd_auto ;;
toggle) cmd_toggle ;;
get)
    resolve
    echo
    ;;
status) cmd_status ;;
-h | --help | help) sed -n '3,22p' "$0" | sed 's/^# \{0,1\}//' ;;
*) die "unknown command '${1}' — try --help" ;;
esac
