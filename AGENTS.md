# brewery — AGENTS.md

## Project

Design research for **brewery**: a macOS GUI app to inspect and manipulate installed
Homebrew formulae, bottles, casks, taps, and services. `https://docs.brew.sh/` is the
canonical reference. Current phase: compatibility research only — no app code yet.

## Agent rules (project-wide, strict)

- At most **one** sub-agent may be spawned at a time. Wait for it to finish before
  spawning another.
- A spawned sub-agent must **not** spawn further sub-agents. State this explicitly in
  every spawn prompt.
- After any change to app code or resources: rebuild the bundle
  (`./Tools/make-app-bundle.sh`) and relaunch `build/Brewery.app` without asking.
  If the app is running, quit it first and launch the new build.

## Ground rules for research

- Read-only Homebrew commands are fine (`brew list`, `brew info --json=v2`, `brew config`, ...).
- Never run install / uninstall / upgrade / reinstall / tap add / `brew services`
  start-stop against the user's machine without explicit approval.
- Record findings in `docs/compatibilities.md`: capability → exact command →
  machine-readable output → gotchas.

## Layout

- `docs/` — research notes and the compatibility list.
