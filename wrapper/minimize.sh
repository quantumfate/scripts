#!/usr/bin/env bash
class=$(hyprctl activewindow -j | jq -r ".class")

if [ "$class" = "steam" ]; then
  xdotool getactivewindow windowunmap
else
  hyprctl dispatch "hl.dsp.window.kill(activewindow)"
fi
