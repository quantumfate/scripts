#!/usr/bin/env bash
APP_NAME=Brightness
has_hyprsunset=false
if [[ "$XDG_CURRENT_DESKTOP" == "Hyprland" ]] && command -v hyprsunset &>/dev/null; then
  has_hyprsunset=true
fi

get_brightness() {
  if [ "$has_hyprsunset" = true ]; then
    # gamma is 0-100 in hyprsunset, parse from profile output
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

notify_user() {
  notify-send --app-name="$APP_NAME" -h string:x-canonical-private-synchronous:sys-notify -u low "$(get_icon)   $(get_brightness)%"
}

inc_brightness() {
  if [ "$has_hyprsunset" = true ]; then
    hyprctl hyprsunset gamma +10
  else
    brightnessctl s +10%
  fi
  notify_user
}

dec_brightness() {
  if [ "$has_hyprsunset" = true ]; then
    hyprctl hyprsunset gamma -10
  else
    brightnessctl s 10%-
  fi
  notify_user
}

if [[ "$1" == "--get" ]]; then
  get_brightness
elif [[ "$1" == "--inc" ]]; then
  inc_brightness
elif [[ "$1" == "--dec" ]]; then
  dec_brightness
elif [[ "$1" == "--get-with-icon" ]]; then
  echo "$(get_brightness)  $(get_icon) "
else
  get_brightness
fi
