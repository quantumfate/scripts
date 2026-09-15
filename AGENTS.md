# Agent instructions

## Operating model

This desktop is a scene-driven system.

The active **scene**, **time**, and **mood mode** may determine:

- Theme, wallpaper, translucency, information density, and motion
- Allowed applications and actions
- Window state, placement, grouping, and layout
- Class-aware and mode-scoped keybindings
- Notification routing and filtering
- Background work, services, and sync behavior

Unavailable actions may intentionally do nothing without warning. This is
deliberate: availability should become legible through the current interface and
mode.

Study mode may block AI coding tools such as OpenCode or Claude. Vibe Coding is
a separate, visually distinct mode.

## Model routing

Read the Linear issue's `Model tier` label before starting.

- **Frontier**
  - Use a frontier model.
  - Required for architecture, security, systemd/service lifecycle, state
    machines, cross-repository changes, migrations, dependency strategy, or
    ambiguous failures.
  - Research first. Return a detailed plan and risks before implementation.

- **Standard**
  - Use a capable implementation model.
  - Appropriate for bounded implementation with clear acceptance criteria.
  - Confirm scope, implement, test, and document.

- **Fast**
  - Use a lower-cost model only for mechanical, focused, low-risk work.
  - Suitable for small config edits, narrow tests, formatting, or documentation
    corrections.
  - Escalate immediately if dependencies, architecture, or failure modes become
    unclear.

If no model tier exists:

- Use Frontier for architecture or security.
- Use Standard for normal implementation.
- Use Fast only for demonstrably mechanical work.

## Required planning process

Before changing code:

1. Read the Linear issue, its project, milestone, linked issues, and relevant
   module documentation.
2. Identify affected repositories, modules, scenes, modes, machine profiles,
   services, and configuration.
3. Check current behavior before proposing a replacement.
4. Preserve existing contracts unless the issue explicitly changes them.
5. For Frontier work, present a plan before implementation.
6. Do not invent requirements, dependencies, acceptance criteria, or UI
   behavior.

## Context lives in module documentation

Context awareness is managed in the documentation, not in memory or session
notes. Every module owns a Markdown document next to it; documents are modular
and cross-linked, so what an agent needs is always one deliberate link away —
never a search through code to rediscover an invariant someone already wrote
down.

- **Before touching a module, read its document first.** The doc is the
  contract; the code is one implementation of it.
- Each module's doc lives NEXT to the module (`bin/Readme.md`, `docs/scenes.md`,
  `AGENTS.md`), so discovery is local by construction.
- Documents link to their neighbours rather than duplicating architecture
  explanations — follow links deliberately instead of re-reading code to
  reconstruct what a link would have said.
- Update the documentation in the SAME change as the behavior it describes; a
  doc left behind is a defect, not a note.
- Durable decisions land in the Linear issue (and the module doc when they
  define long-term behavior). Comments carry progress, not contracts.
- A module with no doc should get one with its first meaningful change — the
  absence of documentation is the cue to write the contract sentence.

## Documentation is context

Documentation is part of the architecture.

- Keep module documentation close to the module it describes.
- Link related Markdown documents rather than duplicating architecture
  explanations.
- Update documentation when behavior, configuration, state contracts, bindings,
  or integration boundaries change.
- Record decisions in the Linear issue description when they define durable
  behavior.
- Use comments for progress and discussion, not as the only location for
  important decisions.

## Machine profiles

Use explicit machine profiles for screen-dependent behavior:

- `quantum-desktop`
  - Ultrawide layouts may use dedicated regions, intentional gaps, and visible
    wallpaper.

- `quantum-laptop`
  - Smaller displays must fit or float windows without clipping, overlap, or
    desktop-sized geometry.

Any issue involving geometry, widgets, layouts, or display-dependent behavior
must verify both applicable profiles.

## Window scenes and groups

Hyprland owns window state, placement, grouping, and layouts.

- Scenes define deterministic behavior from the current workspace and matching
  windows.
- A scene may define position, size, opacity, blur, grouping, layout,
  bindings, and visual context.
- Groups are class-scoped.
- A group must reject windows whose class is not explicitly allowed.
- Admission guards must apply to keyboard actions, mouse-driven drops, and
  focus-driven paths.
- Tmux groups accept only tmux-role windows.
- Dofus groups accept only Dofus windows.
- Ad-hoc terminals remain floating or slide in from the bottom.
- Prefer reusable scene and group rules over application-specific exceptions.

## Keybindings and which-key

Maintain three keybinding classes:

1. **System-level**
   - Always available.
   - Never withheld by mode.
   - Includes escape hatches, exits, and essential compositor controls.

2. **Contextual**
   - Depend on workspace, focused class, group, layout, or scene.

3. **Mode-scoped**
   - Admitted or withheld by the active mode declaration.

Which-key must render the runtime-enabled set by construction.

- Never show bindings that cannot execute.
- Withholding a submap also withholds its entry path.
- Do not allow users to enter an empty or unavailable submap.
- Keep the current context path visible.
- Prefer human-readable key labels.
- Preserve generous spacing, readable grouping, and laptop-safe layout.

## Mood policies and services

Mood modes are policy-bearing operating states.

Policies may allow, modify, defer, or suppress:

- Notifications
- Application launches
- Background tasks
- Sync services
- Widget availability
- Window scenes and binding trees

Protect general-operating system units.

Scene-managed applications and services may stop or start cooperatively:

- Never forcefully terminate unfinished work.
- Request a transition first.
- Let services finish necessary work or defer shutdown.
- Use systemd restart behavior where appropriate.
- A delayed restart after a mode switch is acceptable.
- Send lifecycle outcomes to the logging workspace.

Critical vault-access or security alerts must bypass mood filtering.

## Theme and application adapters

Quickshell owns presentation. Hyprland owns compositor behavior. Scripts and
adapters own external application integration.

For every themed application, document:

- Configuration source
- Live reload behavior
- Relaunch-required behavior
- Next-login-required behavior
- Error and pending-state behavior

Theme switching must report honestly what changed immediately, what requires
relaunch, and what requires login.

Do not rely on shell environment for graphical applications under UWSM. Respect
systemd user-manager environment boundaries.

## Dependencies and bootstrap

When a change introduces a dependency, service, environment variable, generated
file, or machine configuration:

- Update the associated System Config Ansible playbook in the same deliverable.
- Ensure bootstrap can reproduce the required environment.
- Document any manual setup that cannot be automated.
- Do not mark the issue complete until the dependency path is verified.

## Verification and completion

Before marking work complete:

- Verify every explicit acceptance criterion.
- Add or update tests, fixtures, benchmarks, or health checks when relevant.
- Verify desktop and laptop behavior for geometry-dependent work.
- Verify scene transitions, mode changes, service restarts, and failure behavior
  where applicable.
- Update module and architecture documentation.
- Update the Linear issue with decisions, verification evidence, changed
  dependencies, and remaining risks.
- Do not silently widen scope. Create or propose follow-up issues for
  additional work.


## This repo

The scripts tree mirrors parts of hypr's `bin/` and `tests/` — where a copy
drifts, hypr's file is the source of truth and this repo follows (the lockstep
guard is LEO-287's). A writer here re-checks hypr's counterpart instead of
editing only one side.

## Commands

```sh
just check                         # fmt + lint + test + ,privacy-check
```
