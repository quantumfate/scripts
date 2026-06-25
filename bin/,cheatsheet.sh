#!/usr/bin/env bash
# Keybind cheatsheet: parse `hyprctl binds -j` and show in rofi.
# Descriptions come from the `description` field set in the Lua bind layer.
set -euo pipefail

rows() {
  hyprctl binds -j | jq -r '
    # modmask -> "SUPER+CTRL+..." (bit flags)
    def mods($m):
      [ {"1":"SHIFT","4":"CTRL","8":"ALT","64":"SUPER"}
        | to_entries[]
        | select((($m / (.key|tonumber)) | floor) % 2 == 1)
        | .value ]
      | join("+");
    .[]
    | select(.description != "")
    | ( mods(.modmask // 0) | if . == "" then "" else . + "+" end ) as $m
    | ( if .submap != "" then "  [" + .submap + "]" else "" end ) as $sm
    | "\($m)\(.key)\t\(.description)\($sm)"
  ' | sort -u
}

formatted="$(rows | column -t -s$'\t')"

if command -v rofi >/dev/null 2>&1; then
  printf '%s\n' "$formatted" | rofi -dmenu -i -p "binds" -no-custom -theme-str 'window {width: 50%;}'
elif command -v wofi >/dev/null 2>&1; then
  printf '%s\n' "$formatted" | wofi --dmenu -p binds
else
  printf '%s\n' "$formatted"
fi
