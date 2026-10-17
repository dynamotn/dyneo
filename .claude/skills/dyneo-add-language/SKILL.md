---
name: dyneo-add-language
description: Use when adding or changing a language, filetype, language server, linter, formatter, debug adapter or test adapter in DyNeo, or editing an entry of lua/config/languages.lua
---

# Adding a language to DyNeo

## Overview

A language is one `DyLangSpec` entry in `lua/config/languages.lua`. Most
mistakes are invented names: a server, formatter, parser or Mason package
written from memory instead of looked up. **Look every name up before writing
it.** The class definitions at the top of `languages.lua` are the schema; read
them, do not guess field names.

## Look up each name first

`D=~/.local/share/nvim` (the `latest` channel's data dir).

| What                         | Where to look                                                        |
|------------------------------|----------------------------------------------------------------------|
| Filetype already detected?   | `vim.filetype.match({ filename = 'x.<ext>' })` in `nvim --clean -l` |
| Parser known upstream?       | `rg -n '^  <lang> = ' $D/lazy/nvim-treesitter/lua/nvim-treesitter/parsers.lua` |
| Server's `vim.lsp.config` name | `ls $D/lazy/nvim-lspconfig/lsp/ \| rg <lang>`                      |
| conform formatter            | `ls $D/lazy/conform.nvim/lua/conform/formatters/`                    |
| nvim-lint linter             | `ls $D/lazy/nvim-lint/lua/lint/linters/`                             |
| Mason package                | `jq -r '.[].name' $D/mason/registries/github/mason-org/mason-registry/registry.json \| rg <tool>` |

Decide from the answers:

- Filetype detected → no `ftdetect/` file. Otherwise anchor the pattern to
  its project, not a bare file name.
- Parser upstream → `parser = '<name>'`. Only an unknown parser gets a
  `DyParserSpec` with a pinned commit `revision`.
- Server in nvim-lspconfig → use that name exactly; settings go in
  `lsp/<server>.lua`, an override of its `cmd` in `after/lsp/<server>.lua`.
- Formatter not in conform → define it on its entry:
  `{ 'topiary', opts = { command = 'topiary', args = { ... }, stdin = true } }`;
  `lua/plugins/executor/formatting.lua` hands an entry's `opts` to conform,
  and `validate-tools.lua` counts it as defined.
- Linter not in nvim-lint → `lua/lint/linters/<name>.lua`.
- Neither possible → drop the tool and tell the user. Never name a module
  that does not exist.
- A server needs no `mason` field: mason-lspconfig maps the lspconfig name to
  its package. Check the mapping exists:
  `jq -r '.[] | select(.neovim.lspconfig == "<server>") | .name' <registry.json>`
  (`nickel_ls` → `nickel-lang-lsp`); `validate-tools.lua` checks only lspconfig.
- Formatter / linter whose Mason package or binary differs from `[1]` → write
  `command` and `mason.package`; no package → a `lua/tools/mason-registry/` entry (release
  purl, else `dytoy:<tool>`), or `mason = { enabled = false }` for a system
  tool.

## Then

1. Add the entry in sorted position; a non-obvious tool choice gets a comment.
2. A conditional server: `enabled = function(bufnr)` using
   `vim.fs.root(bufnr, ...)`.
3. A new filetype: `check-startup` opens `sample.<filetype>`; when that name
   is not detected as the filetype (`sample.nickel` is not), add it to
   `M.names_of` in `scripts/lib/samples.lua` (`nickel = 'sample.ncl'`).
4. Extras (dap configs, neotest adapters) in `lua/plugins/lang/<lang>.lua`.
5. Spec in `tests/spec/config/languages_spec.lua` when the entry has logic.
6. `doc/dyneo.txt` and `README.md` only where they already list languages
   (`rg -n '\bnix\b' doc/dyneo.txt README.md`).
7. Verify with the `dyneo-checks` skill; `validate-tools.lua` is mandatory here.

## Common mistakes

| Mistake | Fix |
|---|---|
| `nls`, `topiary` written from memory | lspconfig says `nickel_ls`; conform has no `topiary` |
| Custom `install_info` for a parser upstream ships | `parser = '<name>'` |
| `ftdetect` for an extension Neovim knows | delete it |
| Server given `['*']` / `['_']` | pseudo-languages, never filetypes |
| Two entries for one tool with different `opts` | one shared definition that reads the buffer |
