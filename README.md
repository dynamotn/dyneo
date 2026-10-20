<div align="center">

<img src=".github/logo.svg" alt="DyNeo logo" width="128">

# DyNeo

**Neovim, turned into a workstation for infrastructure, architecture,
security and data.**

One table per language · nothing installed until a file asks ·
a supply chain on a leash

[![Neovim Minimum Version][badge-neovim]][neovim]
[![Lua][badge-lua]][lua]
[![Built on lazy.nvim][badge-lazy]][lazy]
[![Coverage][badge-coverage]][coverage]
[![License: GPLv3][badge-license]][license]

<sub><i>DyNeo</i> reads as <i>đi nào</i>, Vietnamese for "let's go" —
and as <b>Dy</b>namo + <b>Neo</b>vim.</sub>

</div>

[badge-neovim]: https://img.shields.io/badge/Neovim-0.13-blue?style=flat-square&logo=Neovim&logoColor=white
[neovim]: https://github.com/neovim/neovim
[badge-lua]: https://img.shields.io/badge/Made%20with%20Lua-blue.svg?style=flat-square&logo=lua
[lua]: https://lua.org
[badge-lazy]: https://img.shields.io/badge/built%20on-lazy.nvim-blueviolet.svg?style=flat-square
[lazy]: https://lazy.folke.io
[badge-coverage]: https://img.shields.io/coveralls/github/dynamotn/dyneo/main?style=flat-square
[coverage]: https://coveralls.io/github/dynamotn/dyneo?branch=main
[badge-license]: https://img.shields.io/badge/License-GPLv3-blue.svg?style=flat-square
[license]: https://www.gnu.org/licenses/gpl-3.0

## ✨ Highlights

- 🧩 **One entry per language** — parser, servers, linters, formatters,
  debugger and test runner in one table of
  [`languages.lua`](./lua/config/languages.lua).
- 🪶 **Nothing eager** — a language's tooling installs the first time one of
  its files opens; startup stays in the tens of milliseconds.
- 🔒 **Supply chain on a leash** — updates wait a week, can be reviewed
  before they land, and what is installed exports as an SBOM checked
  against OSV.
- 🤖 **AI with a guard rail** — secrets never reach Copilot, Avante, sidekick
  or Claude Code, and every handover is logged.
- 🎛 **One tree, many machines** — laptop, workstation or container: the same
  checkout, a few globals apart.
- 🛟 **Two channels** — `latest` rides plugin `main` on Neovim nightly;
  `stable` takes releases. Each keeps its own lockfile.

## 🚀 Quick start

```sh
git clone https://gitlab.com/dynamo-config/neovim.git ~/.config/nvim \
  --single-branch --depth 1
# or beside your own config:  … ~/.config/dynamo && NVIM_APPNAME=dynamo nvim
```

Needs **Neovim 0.13+** (0.12+ on `stable`), **git**, a
[Nerd Font](https://www.nerdfonts.com/), **curl**/**tar**/**unzip**/**gzip**,
a **C compiler** with the [tree-sitter CLI][tree-sitter-cli], **ripgrep** and
**fd**. Everything else installs itself; `:checkhealth dyneo` says what is
missing.

[tree-sitter-cli]: https://github.com/tree-sitter/tree-sitter/tree/master/crates/cli

> [!CAUTION]
> Neovim only, on Linux and macOS. `latest` can break with any `:Lazy update` —
> set `DyNeo.plugin_channel = 'stable'` where it must not.

## 🧰 What you get

Every command starts with `Dy`, so `:Dy<Tab>` lists them all. The groups
below follow the sections of `:help dyneo`.

### 🔒 Supply chain and secrets — `<leader>k`

- **Quarantine** — Mason and plugin releases wait a week; review what an
  update adds, flagged. `:DyQuarantine review`
- **SBOM** — the editor as CycloneDX, checked against OSV, and the project's
  lockfiles too. `:DySbom osv` · `:DySbom lock`
- **Scanner findings** — a SARIF report (semgrep, CodeQL, trivy…) in the
  quickfix list; semgrep on a project's own rules, offline. `:DySarif`
- **Detection rules and binaries** — YARA grammar and server, Sigma schema,
  hex editing. `:DyHex`
- **AI guard** — `.env`, keys and token-shaped text kept from every AI;
  masked on screen; every handover logged. `:DyAiGuardCheck` ·
  `:DyAiGuardLog`
- **Encrypted files** — SOPS, Ansible Vault and chezmoi `encrypted_` files
  edited in the clear, written back encrypted, and diffed in the clear; sops
  recipients listed and rotated. `:DyEncryptedDiff` · `:DyEncryptedRotate`

### 🏗 Infrastructure — `<leader>i`, `<localleader>`

- **YAML schemas** detected: Kubernetes, CRDs, cloud-init, Sigma. `<leader>cys`
- **Kubernetes** — the field under the cursor explained, diff, server dry
  run, apply, Helm and Kustomize render. `<localleader>k`
- **Helm values** to templates and back, unused values marked.
  `:DyHelmValue` · `:DyHelmUnused`
- **Container images** scanned for vulnerabilities and pinned to digests.
  `:DyImageScan` · `:DyImagePin`
- **Policy checks** with checkov, kube-linter, conftest, actionlint and
  zizmor.
- **Terraform plan** shown on the blocks it changes, with drift, the monthly
  cost of each block (infracost) and what depends on each replacement.
  `<localleader>p`
- **Terraform state** of the block under the cursor, what the state holds
  that the code no longer declares, and `import` blocks written for you.
  `<localleader>s`
- **Architecture diagrams** drawn from Terraform, manifests and compose
  files. `:DyArchitecture`

### 🛠 Operations

- **Runbooks** — Markdown code blocks run in place, destructive steps asking
  first, with inputs, resumed from any step and recorded as a timeline.
  `<localleader>r`
- **Logs** of files, the journal and pods read as records, filtered by level,
  request or jq. `:DyLog`
- **Certificates & tokens** — the certificate, key or JWT under the cursor
  decoded, held back from AI; expired or expiring certificates flagged.
  `:DyInspect`
- **CI** — the last pipeline on the jobs of the file that defines them,
  GitLab, GitHub, Azure DevOps, Jenkins and Argo Workflows, GitLab's and
  Jenkins' lint, GitHub Actions pinned to commits. `:DyCiStatus` ·
  `:DyActionsPin`
- **OpenAPI** — the operation under the cursor as a kulala or Hurl request,
  and the breaking changes of a spec since a revision. `:DyOpenApiRequest` ·
  `:DyOpenApiDiff`
- **Cron** — each schedule of a crontab, a CronJob or a workflow read out at
  the end of its line, with its next runs; a broken one flagged. `:DyCron`
- **jq / yq playground** — an expression tried against the JSON or YAML
  buffer as it is typed, the result beside it. `:DyQuery`
- **Tasks** — run, build and test the current file or project in ~50
  languages. `<leader>oo`

### 📊 Data and ML — `<leader>D`

- **Data files** — Parquet, CSV and JSON summed up and queried with SQL
  through DuckDB; a Parquet file opens as its summary. `:DyData`
- **Databases** — connections browsed and queried with dadbod, tables and
  columns completed, SQL linted and formatted by sqlfluff. `<leader>Db`
- **dbt** — the model of the buffer compiled, run, tested or previewed from
  its project root. `<leader>oo`
- **Model files** — a `.safetensors` or `.gguf` file opens as its header:
  metadata, tensors, shapes and the parameter count.
- **Cells & REPL** — `# %%` cells of a Python script moved through,
  selected and sent to IPython. `]j` `ij` `<localleader>c`
- **Quarto** — the chunks of a `.qmd` or `.Rmd` document with their language
  servers, run in the REPL, previewed. `<localleader>c` `<localleader>p`
- **Virtual environments** — picked once per project, from uv, poetry or
  conda, for the server, the debugger and the REPL. `<localleader>v`

### 🔍 Project and writing — `<leader>p`

- **Project overview** — the branch, diagnostics, tasks, reviews, pipeline
  and issues of the project on one page. `<leader>pp`
- **Whole-project diagnostics** — every file handed to the server, off the
  main loop. `<leader>xw`
- **Decision records**, written, listed and superseded. `<leader>pr`
- **Forges & trackers** — GitHub (Octo), GitLab merge requests, CI checks,
  Jira issues to branches and worklogs. `<leader>ph` `pl` `pc` `pj`
- **Previews** — D2 diagrams inline on kitty-graphics terminals, Markdown,
  Typst. `<leader>cp`
- **Spelling** — Vietnamese, Chinese and technical word lists; code comments
  too. `:DySpell vi`
- **Integrations** — Obsidian, chezmoi templates, firenvim, zellij, AI CLIs.
- **AI actions** — explain, review, test, document or fix the selection, or
  a diagnostic from its code action; prompts per project; a commit message,
  a review of the staged diff, a pull request, why a CI job failed; projects
  that keep AI local. `<leader>ai` · `:DyAi commit` · `:DyAi pr`

### 🏛 Architecture — `<leader>pA`

- **C4 models** — LikeC4 with its language server, a view drawn inline
  through D2; Structurizr DSL. `:DyC4`
- **AsyncAPI** — documents checked against their schema; the changes that
  break a consumer since a revision. `:DyAsyncApiDiff`
- **Protobuf and GraphQL** — the changes that break a client since a
  revision, through buf and graphql-inspector. `:DyBreaking`
- **Service levels and capacity** — the availability of a chain of
  components, its downtime and error budget; the bandwidth, storage and
  instances a load takes. `:DyNfr 99.9 2x99.95 rps=200 size=2KB capacity=250`
- **Network ranges** — the IPv4 range under the cursor read out; the subnets
  of a Terraform module that collide. `:DyCidr` · `:DyCidr overlaps`
- **Decision matrix** — options scored against weighted criteria, totals
  worked out, written into the decision record. `:DyMatrix`
- **Well-Architected review** — the questions of the six pillars as a
  checklist in a decision record; what is still open, per pillar. `:DyWar`
- **Dependency rules** — the module boundaries of a project checked by
  dependency-cruiser, go-arch-lint or import-linter. `:DyDeps`
- **Threat models** — STRIDE questions per category as a checklist in a
  decision record; what is still open. `:DyThreat new Checkout`

<details>
<summary><b>42 languages · 13 frameworks · 40 tools</b> —
133 filetypes in all</summary>

**Languages** — Arduino, AWK, Bash, C/C++, C#, Clojure, CSS/Less, Cucumber,
Dart, Elixir, Erlang, Fish, GDScript, GDShader, Gleam, Go, GraphQL, Haskell,
HTML, Java, JS/TS, Julia, Kotlin, LaTeX, Lua, Nushell, OCaml, Perl, PHP,
Python, R, Ruby, Rust, SASS/SCSS, Scala, Solidity, SQL, Swift, Typst,
Vimscript, Zig, Zsh

**Frameworks** — Angular, Astro, Django, Ember, Laravel, Phoenix, Qt (QML),
Rails, Rust, Svelte, Symfony, Templ, Vue

**Tools & markup** — Ansible, Beancount, Bicep, CMake, CSV/TSV, CUE, D2, DBML,
Dockerfile, Git, GoTemplate/Helm, Groovy, HTTP, Hurl, Hyprlang, Jinja, jq,
JSON/JSONL, Jsonnet, Just, KDL, LikeC4, Make, Markdown, Mermaid, Nextflow,
Nginx, Nix, Prisma, PromQL, Protobuf, Rego, Snakemake, Structurizr, SystemD,
Terraform, Terragrunt, TOML, Treesitter, XML, YAML, Yuck

</details>

## 📖 Help

Configuration, mappings and commands live inside Neovim:

```vim
:help dyneo                " everything
:help dyneo-configuration  " per-machine settings and every DyNeo.* global
:help dyneo-keymaps        " every mapping
:help dyneo-commands       " every command
```

…or press `<Space>` and let which-key show the way.

## 🧪 Development

<details>
<summary>Checks, layout</summary>

```sh
scripts/test.sh [path]     # plenary-busted specs
scripts/coverage.sh [path] # the same under luacov, lcov report in .tests/coverage/
scripts/check-startup.sh   # load everything, open a file of each language
scripts/keymaps-doc.sh     # regenerate doc/dyneo-keymaps.txt
pre-commit run --all-files # all of the above, and more
```

```
init.lua                globals, per-machine settings, version gate, lazy.nvim
lua/
├── config/             options, keymaps, autocmds, DyNeo.* globals
│   └── languages.lua   one entry per language: parser, servers, tools, dap
├── plugins/<group>/    lazy.nvim specs; lang/ holds per-language extras
├── tools/              features built here (runbook, kube, tfplan, sbom…)
│   └── mason-registry/ Mason packages dytoy installs (the rest: dynamotn/mason-registry)
├── util/               shared helpers (sensitive, ai_guard, root, system…)
├── lint/linters/       custom nvim-lint linters
├── overseer/template/  task templates
├── per_machine/        rendered by chezmoi, never in a clone
└── dyneo/health.lua    :checkhealth dyneo
plugin/                 thin startup shims: commands that require a tool
lsp/                    per-server settings
ftplugin/ ftdetect/     per-filetype options and detection
after/ queries/         tree-sitter queries, extended or overridden
prompts/                AI prompts
snippets/ spell/        snippets and word lists
doc/                    :help dyneo, and the generated keymap reference
tests/spec/             plenary-busted specs mirroring lua/
scripts/                checks and benchmarks run by pre-commit and CI
```

</details>

## Benchmark

<details>
<summary>Startup and per-filetype timings</summary>

`nvim --clean --headless -l scripts/bench.lua` (startup) and
`scripts/bench-filetypes.lua` (opening a file) rewrite the tables below when a
number really moves. Single rows are noisy: compare before and after, not
against these.

<!-- bench:start -->
<!-- Generated by scripts/bench.lua; edit that, not this. -->

Measured with `nvim --startuptime` over 10 runs on AMD Ryzen 9 5950X 16-Core
Processor (Linux x86_64), Neovim 0.13.0, 2026-10-09.

| Command | Median | Mean ± σ | Min | Max | Wall clock |
| ------- | -----: | -------: | --: | --: | ---------: |
| `nvim --headless +q` | 42.3 ms | 41.6 ± 1.9 ms | 37.5 ms | 43.7 ms | 44.5 ms |
| `nvim --headless README.md +q` | 265.0 ms | 266.2 ± 6.3 ms | 258.8 ms | 276.3 ms | 349.3 ms |
| `nvim --headless init.lua +q` | 144.8 ms | 145.3 ± 3.2 ms | 139.9 ms | 150.6 ms | 213.3 ms |

Slowest steps of `nvim --headless +q` (self + sourced, mean):

```
step                            time percent  plot
init.lua                       38.46   92.44  ████████████████████████
config.lazy                    37.37   89.82  ███████████████████████▍
catppuccin.vim                  2.49    5.97  █▌
catppuccin                      1.81    4.36  █▏
vim.filetype                    1.62    3.89  █
lazy.core.handler.event         1.36    3.26  ▉
filetype.lua                    1.02    2.44  ▋
lazy.core.loader                1.00    2.41  ▋
config.globals                  0.95    2.27  ▋
vim._core.defaults              0.90    2.15  ▌
```
<!-- bench:end -->

<!-- bench-filetypes:start -->
<!-- Generated by scripts/bench-filetypes.lua; edit that, not this. -->

### Filetypes

Opening a file of each of the 136 filetypes, one Neovim per filetype, fastest of
5 runs on Apple M4 Pro (Darwin arm64), Neovim 0.13.0, 2026-10-18.

| | `open` | `ready` | `reopen` | `plugins` |
| --- | -----: | ------: | -------: | --------: |
| median | 91.7 ms | 112.7 ms | 15.8 ms | 22 |
| 90th percentile | 134.6 ms | 161.4 ms | 25.2 ms | 24 |

`open` is the blocking `:edit`, `ready` runs on to the last plugin load or
server attach it set off, and `reopen` is the same file once its filetype is
loaded. `plugins` is how many lazy.nvim loaded for it, and is the same number
every run where the milliseconds are not: two sweeps of the same tree put a
single filetype anywhere from 0.6x to 2.7x of each other here, so read a row as
an order of magnitude and the summary above as the figure that moves when
something real does.

The 15 slowest to open:

| Filetype | Open | Ready | Reopen | Plugins | Language |
| -------- | ---: | ----: | -----: | ------: | -------- |
| `typescript` | 183.9 ms | 209.9 ms | 20.0 ms | 25 | typescript |
| `mysql` | 177.7 ms | 200.3 ms | 16.3 ms | 25 | sql |
| `sql` | 164.2 ms | 180.3 ms | 14.8 ms | 25 | sql |
| `plsql` | 159.4 ms | 177.9 ms | 12.8 ms | 25 | sql |
| `ruby` | 158.5 ms | 193.4 ms | 19.7 ms | 23 | ruby |
| `markdown.mdx` | 153.0 ms | 180.2 ms | 29.6 ms | 22 | markdown |
| `markdown` | 145.0 ms | 170.7 ms | 30.9 ms | 23 | markdown |
| `yaml.az-pl` | 144.4 ms | 172.5 ms | 24.0 ms | 22 | yaml |
| `java` | 141.6 ms | 167.7 ms | 20.5 ms | 38 | java |
| `yaml.gh-action` | 140.8 ms | 173.7 ms | 23.8 ms | 22 | yaml |
| `sh.eclass` | 140.0 ms | 162.1 ms | 26.5 ms | 22 | bash |
| `javascriptreact` | 139.8 ms | 160.1 ms | 18.4 ms | 22 | javascript |
| `javascript` | 135.3 ms | 152.9 ms | 17.1 ms | 22 | javascript |
| `yaml.docker-compose` | 134.6 ms | 161.4 ms | 22.0 ms | 22 | yaml |
| `sh.PKGBUILD` | 133.0 ms | 154.8 ms | 24.2 ms | 22 | bash |

Opened as another filetype, and timed under the one asked for: `plaintex` as
`tex`, `ipynb` as `python`.
<!-- bench-filetypes:end -->

</details>
