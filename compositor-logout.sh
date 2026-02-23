#!/bin/bash
VT=${VT:-1}

case "${XDG_SESSION_DESKTOP,,}" in
hyprland)
  hyprshutdown --vt "$VT"
  ;;
niri)
  sudo systemd-run --no-block sh -c "sleep 1 && chvt $VT"
  niri msg action quit
  ;;
sway)
  sudo systemd-run --no-block sh -c "sleep 1 && chvt $VT"
  swaymsg exit
  ;;
*)
  sudo systemd-run --no-block sh -c "sleep 1 && chvt $VT"
  uwsm stop
  ;;
esac
