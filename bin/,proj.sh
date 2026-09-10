#!/usr/bin/env bash
# ,proj.sh — one entry point for "put me in project X, on tab Y".
#
# The project list is not a second source of truth: it is scraped from the tms
# config (~/.config/tms/config.toml), so tms's own picker and this one always
# agree on what a project is.
#
# One tmux SERVER per project, on socket `proj-<name>`. That is the whole point
# of the split: a server is the unit you can throw away, so "close this project"
# never reaches another one. Inside a project's server there is one session with
# a fixed window template (nvim / zsh / run); a second terminal on the same
# project gets a GROUPED session (`new-session -t <proj>`) — same windows, its
# own current-window — so the two windows stop fighting over the focus.
#
# The servers are meant to be invisible. Nothing below takes a socket by hand:
# commands that act on "the current project" resolve it from $TMUX when run in a
# pane, and otherwise from the focused Hyprland window, by walking its process
# tree to the tmux client and reading the -L it was started with.
#
#   ,proj.sh pick [window]        rofi over all projects
#   ,proj.sh open <path> [window] open a known path
#   ,proj.sh list                 name<TAB>path, one per line
#   ,proj.sh running              project servers that are up, with client count
#   ,proj.sh window <name>        jump to a window in the current session
#   ,proj.sh close                detach this window's client — closes the
#                                 portal, leaves the project running
#   ,proj.sh kill                 kill the focused project's server
#   ,proj.sh kill-all             kill every project server
#
# `window` defaults to nvim. `kill`/`kill-all` confirm first — on a tty by
# prompt, otherwise through rofi, since they are also reachable from a keybind.
# `-y` skips the confirmation.
set -euo pipefail

TMS_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/tms/config.toml"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/proj-list"
CACHE_TTL=300
TEMPLATE_WINDOWS=(nvim zsh run)
DEFAULT_WINDOW=nvim
TERM_CLASS=Tmux-Main
SOCKET_PREFIX=proj-

die() {
  printf '%s: %s\n' "${0##*/}" "$1" >&2
  exit 1
}

# Every tmux call goes through here, so no command below has to remember which
# server it is talking to.
socket=""
tmux() { command tmux ${socket:+-L "$socket"} "$@"; }

socket_for() { printf '%s%s\n' "$SOCKET_PREFIX" "${1//\//_}"; }

# --- project list -----------------------------------------------------------

# tms's toml is flat and hand-written, so a line scraper beats a toml parser
# here — no extra runtime dependency for four keys.
toml_array() { # $1 = key
  sed -n "/^$1[[:space:]]*=[[:space:]]*\[/,/^]/p" "$TMS_CONFIG" |
    grep -o '"[^"]*"' | tr -d '"'
}

scan() {
  local -a excludes=()
  local dir
  while read -r dir; do
    # ".git" is in tms's exclude list, but it is exactly what the scan matches
    # on — excluding it would find nothing.
    [[ -n $dir && $dir != .git ]] && excludes+=(--exclude "$dir")
  done < <(toml_array excluded_dirs)

  # A project is a git repo (tms's definition) …
  local path depth
  while read -r path depth; do
    [[ -d $path ]] || continue
    # No --type filter: a linked worktree's .git is a file, not a directory.
    fd --hidden --no-ignore --max-depth "$depth" \
      "${excludes[@]}" '^\.git$' "$path" 2>/dev/null |
      sed 's:/\.git/\?$::'
  done < <(awk '
    function flush() { if (path != "") print path, depth; path = ""; depth = 10 }
    function quoted(   s) {
      return (match($0, /"[^"]*"/)) ? substr($0, RSTART + 1, RLENGTH - 2) : ""
    }
    BEGIN                             { depth = 10 }
    /^\[/                             { flush() }
    /^[[:space:]]*path[[:space:]]*=/  { path = quoted() }
    /^[[:space:]]*depth[[:space:]]*=/ { depth = $0; gsub(/[^0-9]/, "", depth) }
    END                               { flush() }
  ' "$TMS_CONFIG")

  # … plus the bookmarks, which are plain directories.
  toml_array bookmarks
}

list() {
  if [[ ${1-} != --refresh && -f $CACHE ]] &&
    (($(date +%s) - $(stat -c %Y "$CACHE") < CACHE_TTL)); then
    cat "$CACHE"
    return
  fi
  mkdir -p "${CACHE%/*}"
  # Two projects can share a basename, so the display name falls back to
  # parent/name — and the session and socket names follow it.
  scan | sed 's:/*$::' | sort -u | awk -F/ '
    { name[NR] = $NF; path[NR] = $0; parent[NR] = $(NF-1); n = NR }
    END {
      for (i = 1; i <= n; i++) count[name[i]]++
      for (i = 1; i <= n; i++)
        printf "%s\t%s\n", (count[name[i]] > 1 ? parent[i] "/" name[i] : name[i]), path[i]
    }' | sort > "$CACHE"
  cat "$CACHE"
}

# tmux forbids "." and ":" in session names; everything else survives.
project_name() { list | awk -F'\t' -v p="${1%/}" '$2 == p { print $1; found = 1 }
  END { if (!found) { n = split(p, a, "/"); print a[n] } }' | head -1 | tr '.:' '__'; }

# --- which server am I in ---------------------------------------------------

# The tmux client for a window is a descendant of it, not the window process
# itself (kitty -> $SHELL -c -> tmux attach), so this walks the tree.
socket_under_pid() { # $1 = root pid
  local -a queue=("$1")
  local pid cmd rest
  while ((${#queue[@]})); do
    pid=${queue[0]}
    queue=("${queue[@]:1}")
    [[ -r /proc/$pid/cmdline ]] || continue
    cmd=$(tr '\0' ' ' <"/proc/$pid/cmdline")
    if [[ $cmd == tmux\ * && $cmd == *" -L "* ]]; then
      rest=${cmd#* -L }
      printf '%s\n' "${rest%% *}"
      return 0
    fi
    mapfile -t -O "${#queue[@]}" queue < <(pgrep -P "$pid" 2>/dev/null)
  done
  return 1
}

# Resolution order: an explicit override, the pane we were run from, then the
# focused window. The last one is what makes a Hyprland bind act on the project
# you are looking at.
resolve_socket() {
  if [[ -n ${PROJ_SOCKET-} ]]; then
    socket=$PROJ_SOCKET
    return 0
  fi
  if [[ -n ${TMUX-} ]]; then
    # $TMUX is "<socket path>,<pid>,<session>"; the socket's basename is its -L.
    socket=$(basename "${TMUX%%,*}")
    return 0
  fi
  command -v hyprctl >/dev/null 2>&1 || return 1
  local pid
  pid=$(hyprctl activewindow -j 2>/dev/null | sed -n 's/.*"pid": *\([0-9]*\).*/\1/p' | head -1)
  [[ -n $pid ]] || return 1
  socket=$(socket_under_pid "$pid") || return 1
}

require_socket() { # $1 = what for
  resolve_socket || die "$1: no project window focused"
  [[ $socket == "$SOCKET_PREFIX"* ]] ||
    die "$1: focused window is on '$socket', not a project server"
}

# --- sessions ---------------------------------------------------------------

# tmux's "=" exact-match target is only honoured on session targets here
# (has-session, list-clients, attach, switch-client); set-option and window
# targets take the bare name, so those are kept apart deliberately.
has_session() { tmux has-session -t "=$1" 2>/dev/null; }

# Create the session with the full window template. Windows are addressed by
# name everywhere below, so the template can be reordered without touching binds.
create_session() { # $1 = name, $2 = path
  local name=$1 path=$2 w
  tmux new-session -d -s "$name" -c "$path" -n "${TEMPLATE_WINDOWS[0]}"
  for w in "${TEMPLATE_WINDOWS[@]:1}"; do
    tmux new-window -d -t "$name:" -c "$path" -n "$w"
  done
  tmux send-keys -t "$name:${TEMPLATE_WINDOWS[0]}" 'nvim .' C-m
}

# The session a new client should attach to: the project session itself while
# nobody is on it, otherwise a fresh member of its group.
attach_target() { # $1 = base session name
  local base=$1 clients i
  clients=$(tmux list-clients -t "=$base" 2>/dev/null | wc -l)
  ((clients == 0)) && {
    printf '%s\n' "$base"
    return
  }
  for ((i = 2; ; i++)); do
    # "-N", not "~N": tmux's target parser chokes on "~" in a session name.
    has_session "$base-$i" && continue
    tmux new-session -d -t "$base" -s "$base-$i"
    printf '%s\n' "$base-$i"
    return
  done
}

select_window() { # $1 = session, $2 = window name, $3 = cwd for a missing window
  tmux select-window -t "$1:$2" 2>/dev/null && return
  tmux new-window -t "$1:" -n "$2" -c "${3:-$HOME}"
}

open() { # $1 = path, $2 = window
  local path=${1%/} window=${2:-$DEFAULT_WINDOW} name target
  [[ -d $path ]] || die "no such directory: $path"
  name=$(project_name "$path")
  socket=$(socket_for "$name")

  has_session "$name" || create_session "$name" "$path"

  # Run from a pane on this project's own server: move this client, no new
  # window. From anywhere else a window is what we came for.
  if [[ -n ${TMUX-} ]] && [[ $(basename "${TMUX%%,*}") == "$socket" ]]; then
    select_window "$name" "$window" "$path"
    tmux switch-client -t "=$name"
    return
  fi

  target=$(attach_target "$name")
  select_window "$target" "$window" "$path"
  # A grouped session is a throwaway view, so it dies with its client. Doing
  # that here rather than with destroy-unattached is deliberate: that option
  # would reap the session in the gap before kitty ever attaches to it.
  local attach="tmux -L $socket attach-session -t '=$target'"
  [[ $target != "$name" ]] &&
    attach="$attach; tmux -L $socket kill-session -t '$target' 2>/dev/null"

  local -a launch=(kitty --class "$TERM_CLASS" -e "$SHELL" -c "$attach")
  if command -v uwsm >/dev/null 2>&1; then
    exec uwsm app -- "${launch[@]}"
  fi
  exec "${launch[@]}"
}

pick() { # $1 = window
  local choice
  choice=$(list | cut -f1 | rofi -dmenu -i -p " Project " -no-custom \
    -theme-str 'window {width: 40%;} listview {lines: 12;}') || exit 0
  [[ -n $choice ]] || exit 0
  open "$(list | awk -F'\t' -v c="$choice" '$1 == c { print $2 }')" "${1-}"
}

# A killed server leaves its socket file behind, so liveness is decided by
# actually talking to it — and the dead ones are swept while we are here.
live_sockets() {
  local sock saved=$socket
  for sock in "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$SOCKET_PREFIX"*; do
    [[ -S $sock ]] || continue
    socket=${sock##*/}
    if tmux list-sessions >/dev/null 2>&1; then
      printf '%s\n' "$socket"
    else
      rm -f "$sock"
    fi
  done
  socket=$saved
}

running() {
  local name
  while read -r name; do
    socket=$name
    printf '%s\t%s client(s)\t%s window(s)\n' "${name#"$SOCKET_PREFIX"}" \
      "$(tmux list-clients 2>/dev/null | wc -l)" \
      "$(tmux list-windows -a 2>/dev/null | wc -l)"
  done < <(live_sockets)
}

# --- teardown ---------------------------------------------------------------

# Reachable from a keybind, where there is no tty to prompt on, so rofi stands
# in. Defaults to "no" in both forms.
confirm() { # $1 = question
  [[ ${ASSUME_YES-} == 1 ]] && return 0
  if [[ -t 0 ]]; then
    local answer
    read -r -p "$1 [y/N] " answer
    [[ $answer == [yY]* ]]
    return
  fi
  [[ $(printf 'no\nyes\n' | rofi -dmenu -i -p "$1" -no-custom \
    -theme-str 'window {width: 30%;} listview {lines: 2;}') == yes ]]
}

# Close the portal, not the project: detach the one client living in the
# focused window. Its kitty exits with it; the server keeps running.
close() {
  local pid client want
  if [[ -n ${TMUX-} ]]; then
    resolve_socket
    tmux detach-client
    return
  fi
  command -v hyprctl >/dev/null 2>&1 || die "close: no tty and no hyprctl"
  pid=$(hyprctl activewindow -j 2>/dev/null | sed -n 's/.*"pid": *\([0-9]*\).*/\1/p' | head -1)
  [[ -n $pid ]] || die "close: no window focused"
  socket=$(socket_under_pid "$pid") || die "close: focused window holds no tmux client"
  # Match on the client's own pid, so a project with several windows open loses
  # exactly the one you are looking at.
  want=$(client_pid_under "$pid")
  client=$(tmux list-clients -F '#{client_pid} #{client_name}' |
    awk -v want="$want" '$1 == want { print $2 }')
  [[ -n $client ]] || die "close: no tmux client in the focused window"
  tmux detach-client -t "$client"
}

client_pid_under() { # $1 = root pid — the tmux client process itself
  local -a queue=("$1")
  local pid cmd
  while ((${#queue[@]})); do
    pid=${queue[0]}
    queue=("${queue[@]:1}")
    [[ -r /proc/$pid/cmdline ]] || continue
    cmd=$(tr '\0' ' ' <"/proc/$pid/cmdline")
    [[ $cmd == tmux\ * && $cmd == *" -L "* ]] && {
      printf '%s\n' "$pid"
      return 0
    }
    mapfile -t -O "${#queue[@]}" queue < <(pgrep -P "$pid" 2>/dev/null)
  done
  return 1
}

# Kill one project outright — server and all. Scoped by construction: this
# socket holds nothing but this project.
kill_project() {
  require_socket kill
  local name=${socket#"$SOCKET_PREFIX"}
  confirm "Kill project $name (server, all its windows)?" || exit 0
  tmux kill-server
}

kill_all() {
  local -a socks=()
  mapfile -t socks < <(live_sockets)
  ((${#socks[@]})) || die "no project servers running"
  confirm "Kill all ${#socks[@]} project server(s)?" || exit 0
  for socket in "${socks[@]}"; do
    tmux kill-server 2>/dev/null || true
  done
}

while [[ ${1-} == -y || ${1-} == --yes ]]; do
  ASSUME_YES=1
  shift
done

case "${1-pick}" in
  list) list "${2-}" ;;
  running) running ;;
  pick) pick "${2-}" ;;
  open)
    shift
    open "$@"
    ;;
  window)
    [[ -n ${TMUX-} ]] || die "window: not inside tmux"
    resolve_socket
    select_window "$(tmux display-message -p '#{session_name}')" "${2:?window name}" "$PWD"
    ;;
  close) close ;;
  kill) kill_project ;;
  kill-all) kill_all ;;
  *) die "unknown command: $1" ;;
esac
