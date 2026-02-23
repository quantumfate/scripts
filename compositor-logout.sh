#!/bin/bash
VT=${VT:-1}

case "$XDG_SESSION_DESKTOP" in
Hyprland)
  hyprshutdown --vt "$VT"
  ;;
Niri)
  systemd-run --no-block sh -c "sleep 3 && uwsm stop; sleep 1 && chvt $VT"
  niri msg action quit
  ;;
Sway)
  systemd-run --no-block sh -c "sleep 3 && uwsm stop; sleep 1 && chvt $VT"
  swaymsg exit
  ;;
*)
  systemd-run --no-block sh -c "sleep 3 && uwsm stop; sleep 1 && chvt $VT"
  ;;
esac
