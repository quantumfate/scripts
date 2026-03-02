#!/usr/bin/env bash
APP_NAME=Brightness
has_hyprsunset=false
CACHE_DIR="/tmp/hyprsunset"
CACHE_FILE="$CACHE_DIR/brightness"

mkdir -p "$CACHE_DIR"

if [[ "$XDG_CURRENT_DESKTOP" == "Hyprland" ]] && command -v hyprsunset &>/dev/null; then
  has_hyprsunset=true
fi

get_brightness() {
  if [ "$has_hyprsunset" = true ]; then
    hyprctl hyprsunset gamma | cut -d. -f1
  else
    echo $(($(brightnessctl g) * 100 / $(brightnessctl m)))
  fi
}

get_icon() {
  current=$(get_brightness)
  if [[ "$current" -eq "0" ]]; then
    echo "󰃞 "
  elif [[ ("$current" -ge "0") && ("$current" -le "30") ]]; then
    echo "󰃝 "
  elif [[ ("$current" -ge "30") && ("$current" -le "60") ]]; then
    echo "󰃟 "
  elif [[ ("$current" -ge "60") && ("$current" -le "100") ]]; then
    echo "󰃠 "
  fi
}

save_brightness() {
  get_brightness >"$CACHE_FILE"
}

notify_user() {
  notify-send --app-name="$APP_NAME" -h string:x-canonical-private-synchronous:sys-notify -u low "$(get_icon)   $(get_brightness)%"
}

inc_brightness() {
  if [ "$has_hyprsunset" = true ]; then
    hyprctl hyprsunset gamma +10
  else
    brightnessctl s +10%
  fi
  save_brightness
  notify_user
}

dec_brightness() {
  if [ "$has_hyprsunset" = true ]; then
    hyprctl hyprsunset gamma -10
  else
    brightnessctl s 10%-
  fi
  save_brightness
  notify_user
}

restore_brightness() {
  if [ "$has_hyprsunset" = true ]; then
    if [[ -f "$CACHE_FILE" ]]; then
      hyprctl hyprsunset gamma "$(cat "$CACHE_FILE")"
    else
      hyprctl hyprsunset gamma 100
    fi
  else
    brightnessctl -r
  fi
}

if [[ "$1" == "--get" ]]; then
  get_brightness
elif [[ "$1" == "--inc" ]]; then
  inc_brightness
elif [[ "$1" == "--dec" ]]; then
  dec_brightness
elif [[ "$1" == "--get-with-icon" ]]; then
  echo "$(get_brightness)  $(get_icon) "
elif [[ "$1" == "-r" ]]; then
  restore_brightness
elif [[ "$1" == "-s" ]]; then
  save_brightness
else
  get_brightness
fi
