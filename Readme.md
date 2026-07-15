# Scripts

Standalone CLI helpers on `$PATH`, used across my desktop. Part of the
quantumfate desktop, alongside the
[**hypr**](https://github.com/quantumfate/hypr) compositor config and the
[**quickshell**](https://github.com/quantumfate/quickshell) UI.

Most are small `,name.sh` wrappers invoked from Hyprland keybinds. A few
integrate with the shared state / UI:

- `bin/dofus_swap.py` — Dofus auto turn-swap detector. Reads its roster from the
  shared team source of truth (`$XDG_STATE_HOME/dofus/team.json`), the same file
  the Quickshell UI edits, so team changes take effect live.
  (Querying that team store from the shell is done with `dofus-team`, which lives
  in the quickshell repo's `scripts/`.)

How the shared state + IPC bridges work:
[quickshell/ARCHITECTURE.md](https://github.com/quantumfate/quickshell/blob/main/ARCHITECTURE.md).
