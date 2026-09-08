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

- `bin/obsidian_linear_sync.py` + `bin/obsidian-linear-sync` — one-way mirror of
  Linear into the same vault. Projects, milestones and issues become index notes
  under `Projects/`, so the index-notes plugin renders the hierarchy; sub-issues
  are filed under their parent. Linear is the source of truth and nothing is ever
  deleted. The API key is read from Proton Pass at runtime (`Productivity` /
  `linear.app` / `api_key`); a locked vault notifies and exits. Runs every five
  minutes from `obsidian-linear-sync.timer`, deployed by the `obsidian_linear`
  role in **system-config**.

  Because tags are derived from Linear's naming, a rename moves a whole subtree.
  The previous hierarchy is kept in `$XDG_STATE_HOME/obsidian/linear.json` so the
  next run can diff it and rename the old tag prefix wherever it appears —
  including on notes the sync never created.

  ```
  obsidian-linear-sync                       # dry run
  obsidian-linear-sync --apply               # sync now
  obsidian-linear-sync --project lance.nvim --apply
  obsidian-linear-sync --apply --force       # rewrite managed blocks regardless
  ```

How the shared state + IPC bridges work:
[quickshell/ARCHITECTURE.md](https://codeberg.org/quantumfate/quickshell/blob/main/ARCHITECTURE.md).
