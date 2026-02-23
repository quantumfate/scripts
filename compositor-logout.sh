#!/bin/bash
VT=${VT:-1}

case "${XDG_SESSION_DESKTOP,,}" in
Hyprland)
  hyprshutdown --vt "$VT"
  ;;
Niri)
  sudo systemd-run --no-block sh -c "sleep 1 && chvt $VT"
  niri msg action quit
  ;;
Sway)
  sudo systemd-run --no-block sh -c "sleep 1 && chvt $VT"
  swaymsg exit
  ;;
*)
  sudo systemd-run --no-block sh -c "sleep 1 && chvt $VT"
  uwsm stop
  ;;
esac
