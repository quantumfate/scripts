# Scripts

Standalone CLI helpers on `$PATH`, used across my desktop. Part of the
quantumfate desktop, alongside the
[**hypr**](https://codeberg.org/quantumfate/hypr) compositor config and the
[**quickshell**](https://codeberg.org/quantumfate/quickshell) UI.

Most are small `,name.sh` wrappers invoked from Hyprland keybinds. A few
integrate with the shared state / UI:

- `bin/qfs` — "quantumfate shell": wraps the Quickshell IPC surface
  (`qfs theme cycle`, `qfs window rename "..."`, `qfs show`, …). Zsh completion
  `_qfs` lives in the quickshell repo's `completions/`.

- `bin/dofus_swap.py` — Dofus auto turn-swap detector. Reads its roster from the
  shared team source of truth (`$XDG_STATE_HOME/dofus/team.json`), the same file
  the Quickshell UI edits, so team changes take effect live.
  (Querying that team store from the shell is done with `dofus-team`, which lives
  in the quickshell repo's `scripts/`.)

- `bin/obsidian_vault.py` + `bin/,obsidian-cli-wrapper.sh` — Obsidian Zettelkasten
  bootstrap: scans `~/Documents/Obsidian/Main`, infers the missing
  `idx`/`meta_idx` index-note chain for a topic, creates notes via Templater, and
  keeps a tag-structure store (`$XDG_STATE_HOME/obsidian/tags.json`, plus a
  GPG-encrypted `.gpg` copy). The vault is the source of truth; the store is a
  projection. Full reference: quickshell
  `docs/obsidian-vault-manifest.md`.

  ```
  ,obsidian-cli-wrapper.sh status                                  # vault/store state
  ,obsidian-cli-wrapper.sh create atomic "Some Title" --tag Topic/Sub
  ,obsidian-cli-wrapper.sh ensure-topic Topic/Sub --dry-run        # plan index notes
  ```

How the shared state + IPC bridges work:
[quickshell/ARCHITECTURE.md](https://codeberg.org/quantumfate/quickshell/blob/main/ARCHITECTURE.md).
