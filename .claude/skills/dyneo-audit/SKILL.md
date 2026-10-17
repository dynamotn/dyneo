---
name: dyneo-audit
description: Use when asked to fix, optimize, clean up, speed up or review the DyNeo config as a whole, or when it "feels slow" or "is buggy" without a specific bug named
---

# Auditing DyNeo

## Overview

A green suite proves nothing about logic bugs, dead code or slow code.
An audit **reads every area** and measures before and after. It ends when
every area has a verdict, not when the first fixes look good.

## 1. Measure (both channels, before touching code)

```bash
nvim --clean --headless -l scripts/bench.lua            # startup, by scenario
nvim --clean --headless -l scripts/bench-filetypes.lua  # open/ready/reopen/plugins per filetype
```

Repeat both under `NVIM_APPNAME=nvim-stable mise exec neovim@stable --`; the
link they start Neovim on is named after `NVIM_APPNAME`, so `stable` measures
its own plugins.

Save the numbers in the scratchpad and compare runs made the same way, not
with README. Timings are noisy (read each script's header): the `plugins`
count per filetype is the steady signal, and `BENCH_FT_ONLY=<ft>` digs into
one lead but is not comparable with a full sweep. The benchmarks miss runtime
cost (servers, completion, statusline, redraw); when the numbers show nothing,
profile those (`:Lazy profile`, `--startuptime`) before asking the user.

README is rewritten when `bench.lua` moves past `BENCH_THRESHOLD` (20%) or
`bench-filetypes.lua` past `BENCH_FT_THRESHOLD` (25%), and the pre-commit
`bench` hook runs on every Lua commit. Keep that diff out of the fix commits
(leave README unstaged) and commit it last, on its own.

## 2. Read every area

Split the areas across parallel subagents (one per row, read-only), each
returning findings as `file:line — rule — concrete failure`.

| Area | Hunt for |
|------|----------|
| `lua/config` | eager `require`, `pairs` over `config.languages` where order matters, global `FileType` autocmds that belong in `ftplugin/` |
| `lua/plugins` | specs with no `event`/`cmd`/`ft`/`keys`, `VeryLazy` doing heavy work, keys a plugin silently overrides, catppuccin integration missing |
| `lua/tools` | `:wait()` on the UI path, missing deadline or output cap, a failure reading as success, destructive action without a prompt |
| `lua/util` | statusline/redraw work not cached, `enabled()` not cached per buffer, a CLI per keystroke |
| `lsp/`, `after/lsp/` | servers on too many filetypes, `enabled` decided at startup instead of per buffer |
| `plugin/` | heavy work at startup, breaking under `nvim --clean`, slow APIs in fast events |
| `ftplugin/`, `ftdetect/` | stacked autocmds (no `clear = true`), bare file-name patterns |
| `scripts/` | dyshellint findings, checks that pass when they could not run |

Dead code: a module or function nothing `require`s or calls (`rg`), a plugin
whose features are unused. Gone patterns (`LazyVim`, loose `_G.*`, `:e!`)
are bugs.

## 3. Fix

One branch in `.worktrees/`, one commit per concern
(`perf(<module>): ...`, `fix(<module>): ...`), each fix with a spec that fails
without it. Do not bump plugins or touch `lazy-lock*.json`.

## 4. Stop and report

Stop when every row of the table has a verdict (fixed / fine / left, with why)
and the benchmarks are re-run. Report the before/after numbers per channel,
the findings left unfixed, then **REQUIRED SUB-SKILL:** `dyneo-checks`.

## Red flags

- "Checks pass, so the config is fine" → read the code.
- Stopping after the first few fixes → every area needs a verdict.
- Asking the user where it is slow before measuring → measure and profile first.
