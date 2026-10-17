---
name: dyneo-checks
description: Use when about to report DyNeo work as done, commit it, or claim a change works, including when the user asks for a quick check or it is late
---

# Checking DyNeo before reporting

## Overview

In `mode: symlink` this tree is the user's real editor: a broken startup is a
broken Neovim. Both channels are in daily use, so **every check runs on
`latest` and on `stable`, and each channel is reported on its own.** "Quickly"
shortens the report, never the list of checks.

## What to run

Pick by what changed (`git diff --name-only main...`), then run the rows on
both channels.

| Changed                                   | Run                                              |
|-------------------------------------------|--------------------------------------------------|
| any `.lua`                                | specs for it, `check-startup.sh`, `validate-tools.lua`, `keymaps-doc.sh` + `git diff --exit-code doc/` |
| `lua/config/languages.lua`, `lsp/`, a tool | the above with `CHECK_STARTUP_ALL=1`            |
| a mapping or `keys`                       | `keymaps-doc.sh`, commit the regenerated `doc/dyneo-keymaps.txt` (from `latest`) |
| `doc/dyneo.txt`                           | `scripts/keymaps-doc.sh` (it runs `helptags`), commit `doc/tags` |
| a shell script                            | `dyshellint <script>`                            |
| before the last commit                    | `prek run --all-files`                           |

`latest`:

```bash
scripts/test.sh tests/spec/<mirror of the changed module>
scripts/check-startup.sh
nvim --clean --headless -l scripts/validate-tools.lua
scripts/keymaps-doc.sh && /usr/bin/git diff --exit-code doc/
```

`stable` (its own data dir, so `latest`'s plugins and lockfile stay untouched).
Each Bash call is a fresh shell: keep the `export` in the same call as the
commands.

```bash
export NVIM_APPNAME=nvim-stable
mise exec neovim@stable -- scripts/test.sh tests/spec/<...>
mise exec neovim@stable -- scripts/check-startup.sh
mise exec neovim@stable -- nvim --clean --headless -l scripts/validate-tools.lua
mise exec neovim@stable -- scripts/keymaps-doc.sh && /usr/bin/git diff --exit-code doc/
```

A `doc/` diff after the `stable` run is a mapping that differs between
channels: fix it, then run `scripts/keymaps-doc.sh` on `latest` again so the
committed file is `latest`'s.

## When a check cannot run

`check-startup.sh` clones and installs, so it fails inside a no-network
sandbox. Re-run it outside the sandbox; if that is refused, report it as
**not run** with the reason and the command the user should run. A failure
caused only by the machine (no tree-sitter CLI, Copilot signed out) is
stubbed with `before_config` in `scripts/lib/samples.lua`, never by changing
the config.

## Report

One block per channel: each command, pass / fail / not run, and the failing
output quoted. Nothing unrun is called working.

## Red flags

- "Only cron.lua changed, `validate-tools` is irrelevant": it takes seconds, run it.
- "Stable is the same code": the plugins and Neovim differ; run it.
- "check-startup failed because of the sandbox, so it passed": it is unverified.
