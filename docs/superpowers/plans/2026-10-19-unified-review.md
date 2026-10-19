# `:DyReview` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One review UI for GitHub, GitLab and Azure DevOps pull requests in
DyNeo: triage, reviewed marks that survive pushes, local drafts sent as one
review, AI draft comments marked as such, LSP on the new side once trusted.

**Architecture:** A session module (`tools.review`) drives three forge
adapters with one interface, a pure triage module, an on-disk store, a draft
model drawn as extmarks on codediff.nvim buffers, a file panel, an AI pass,
and a resumable submit. Code comes from local git (private refs and a
detached worktree), never from the forge's diff API.

**Tech Stack:** Lua on Neovim (nightly and 0.12), lazy.nvim, codediff.nvim,
`gh` / `glab` / `az` CLIs through `util.forge`, plenary-busted specs.

**Spec:** `docs/superpowers/specs/2026-10-19-unified-review-design.md`

## Global Constraints

- Every external command through `util.system.run` / `each` (deadline,
  output cap, `detach = true` for forge CLIs); nothing on the UI path waits.
- Forge calls through `util.forge`; no token is ever read or passed.
- AI text through `require('tools.ai').headless(text, root, label, cb)` after
  `tools.ai.check.text`; pending and dropped AI drafts are never sent.
- Posted comments carry no AI label; the AI marker is editor-only.
- LSP and the worktree's `.nvim` stay off until the PR is trusted, asked once
  per PR and head SHA through `util.trust.ask('review:' .. head_sha, worktree,
  question, true)`.
- Augroup `dy_review` with `clear = true`; namespace `dy_review`.
- Notifications through `require('util.notify').titled('Review')`.
- Classes `DyReview*`, never `DyReviewFinding` / `DyReviewGroup` (taken).
- Mappings through `map` / plugin `keys`; group `<leader>pv` "review".
- Store at `stdpath('state') .. '/dyneo/review/<host>/<slug>/<id>.json'`,
  written to a temp file then renamed.
- Private refs under `refs/dyneo/review/<forge>-<id>/` (`head`, `base`,
  `reviewed`); worktree at `<repo>/.worktrees/dyreview-<forge>-<id>`.
- Commits: Conventional, scope `review` (or `forge`, `lsp`), committed with
  `SKIP=bench`, no trailers.
- When everything is done: rebase on `main`, delete `docs/superpowers/`.

## Review Focus

1. A forge answering an error or cut JSON mid-pagination: the list or thread
   view says it failed or was capped, never shows a short list as complete.
   (Task 6, `threads` spec.)
2. Submit failing on the third of five comments: the first two are marked
   posted with their forge ids, the rest stay drafts, the verdict is not sent,
   and a second submit sends only the three. (Task 9.)
3. Neovim quit or crash with unsaved drafts: every draft change is on disk
   before the next event, so reopening the PR shows them. (Task 4.)
4. A buffer of the review worktree opened before the trust verdict (session
   restore, `:e` by hand): no server attaches and `.nvim` is not loaded.
   (Task 2.)
5. A PR force-pushed between open and submit: submit refetches the head SHA
   and refuses with a message when it moved, since line positions would be
   wrong. (Task 9.)

---

### Task 1: Forge writes

**Files:**
- Modify: `lua/util/forge.lua` (`M.command`, new `M.write`)
- Test: `tests/spec/util/forge_spec.lua`

**Interfaces:**
- Produces: `DyForgeAzureCall` gains `method?: 'GET'|'POST'|'PATCH'|'PUT'|'DELETE'`
  and `body?: table`.
- Produces: `M.write(remote, method, endpoint, body, on_done(data?, err?))`
  where `endpoint` is a path for gh/glab or a `DyForgeAzureCall` for az
  (its `method`/`body` are set from the arguments).

- [ ] **Step 1: Failing tests**
  - `builds an Azure call with its method and body file`:
    `forge.command(azure_remote, { area = 'git', resource = 'pullRequestThreads', method = 'POST', body = { a = 1 } })`
    contains `'--http-method', 'POST'` and `'--in-file', <path>`, and the file
    at `<path>` decodes to `{ a = 1 }`.
  - `keeps GET when no method is given` (existing behaviour).
  - `writes through gh with the body on stdin`: fake `gh` on a private PATH
    records argv and stdin; `forge.write(gh_remote, 'POST', 'repos/o/r/pulls/1/reviews', { event = 'COMMENT' }, cb)`
    runs `gh api --hostname github.com --method POST --input - repos/o/r/pulls/1/reviews`
    with stdin `{"event":"COMMENT"}` and hands `cb` the decoded answer.
  - `removes the Azure body file after the call` whether it succeeded or failed.
  - `fails closed`: exit code 1 gives `cb(nil, reason)`; non-JSON gives an error.
- [ ] **Step 2:** `scripts/test.sh tests/spec/util/forge_spec.lua` -> the new tests FAIL.
- [ ] **Step 3: Implement.** `M.command(remote, endpoint)` returns a third
  value `cleanup?: fun()` for the temp file; `--http-method` takes
  `call.method or 'GET'`; `--in-file` only with a body, written with
  `vim.fn.writefile({ vim.json.encode(body) }, vim.fn.tempname())`. `M.write`
  shares `json_call` (pass method/body through), gh/glab get
  `--method <m> --input -` inserted before the endpoint and `stdin` set.
  `json_call` calls `cleanup` in the run callback before anything else.
  An empty 204 answer decodes to `{}`, not an error.
- [ ] **Step 4:** spec passes; `scripts/check-startup.sh` passes.
- [ ] **Step 5:** commit `feat(forge): send writes through each forge's CLI`.

### Task 2: Hold untrusted directories

**Files:**
- Create: `lua/util/untrusted.lua`
- Modify: `lua/plugins/lsp/server.lua` (`configure`), `lua/util/project_rtp.lua` (`setup_project_rtp`)
- Test: `tests/spec/util/untrusted_spec.lua`, add a case to `tests/spec/util/project_rtp_spec.lua`

**Interfaces:**
- Produces:
  - `M.hold(dir: string, on_first?: fun(bufnr: integer))` -- buffers under
    `dir` are held; `on_first` runs once, scheduled, on the first held buffer
    a server or `.nvim` asks about.
  - `M.release(dir: string)` -- un-hold and re-run
    `nvim_exec_autocmds('FileType', { group = 'nvim.lsp.enable', buffer = b })`
    for each loaded buffer under `dir` (only that group, so ftplugins do not
    run again; if the group name differs on stable, find it in
    `runtime/lua/vim/lsp.lua` of that version and handle both).
  - `M.forget(dir: string)` -- un-hold without restarting anything.
  - `M.held(bufnr_or_path: integer|string): boolean` -- one table lookup
    when nothing is held; paths normalized and real-pathed, compared with a
    separator.

- [ ] **Step 1: Failing tests** in `untrusted_spec.lua`:
  `holds a buffer under the directory and not a sibling` (`/x/wt` vs
  `/x/wt-other`), `calls on_first once for many buffers`, `release reruns
  only the lsp enable group` (stub `nvim_exec_autocmds`, assert the `group`),
  `held answers false fast when nothing is held`.
  In `project_rtp_spec.lua`: `skips a held project's .nvim without asking`
  (stub `vim.secure.read`, assert it is not called).
- [ ] **Step 2:** run both specs -> FAIL.
- [ ] **Step 3: Implement** the module; in `server.lua` wrap **every**
  server's `root_dir` (not only conditional ones) so a held buffer never calls
  `on_dir` and calls `require('util.untrusted').held` lazily (the module is
  tiny and loaded at first FileType); keep the existing `enabled(bufnr)`
  check. In `project_rtp.lua`, a held root is treated as untrusted without
  calling `vim.secure.read`.
- [ ] **Step 4:** specs pass; `scripts/check-startup.sh` passes (a sample of
  every language still attaches its servers).
- [ ] **Step 5:** commit `feat(lsp): hold servers off a directory until trusted`.

### Task 3: Triage

**Files:** Create `lua/tools/review/triage.lua`; Test `tests/spec/tools/review/triage_spec.lua`

**Interfaces:**
- Produces:
  ```lua
  ---@alias DyReviewKind 'source'|'tests'|'config'|'docs'|'generated'
  ---@class DyReviewFile
  ---@field path string
  ---@field old_path? string
  ---@field status 'A'|'M'|'D'|'R'
  ---@field added integer
  ---@field removed integer
  ---@field kind DyReviewKind
  ---@field risk integer 0 = none, higher reads first
  ---@field binary boolean
  ---@class DyReviewBucket
  ---@field kind DyReviewKind
  ---@field files DyReviewFile[]
  ---@field added integer
  ---@field removed integer
  ```
  `M.ORDER = { 'source', 'tests', 'config', 'docs', 'generated' }`,
  `M.classify(path: string, attrs?: { generated?: boolean, vendored?: boolean }): DyReviewKind`,
  `M.risk(path: string): integer`,
  `M.buckets(files: DyReviewFile[], ai_order?: string[]): DyReviewBucket[]`
  -- buckets in `M.ORDER`, empty ones left out; source sorted by `ai_order`
  position when given, then risk descending, then removed + added descending,
  then path; other buckets by path.

- [ ] **Step 1: Failing tests:** `classify` table: `package-lock.json`,
  `go.sum`, `lazy-lock.stable.json`, `vendor/x.go`, `dist/a.js`, `a.min.js`,
  `api.pb.go`, `x_generated.go`, `__snapshots__/a.snap` -> generated;
  `attrs.generated = true` on `src/a.go` -> generated; `foo_test.go`,
  `tests/spec/a_spec.lua`, `src/a.test.ts` -> tests; `README.md`,
  `doc/x.txt` -> docs; `.github/workflows/ci.yml`, `Dockerfile`,
  `infra/main.tf`, `k8s/deploy.yaml` -> config; `src/a.go` -> source.
  `risk`: `src/auth/token.go` > `db/migrations/0042.sql` > `src/util/str.go` (= 0).
  `buckets`: order, totals, AI order wins over risk, empty buckets dropped.
- [ ] **Step 2:** run -> FAIL. **Step 3:** implement (pattern tables as
  upper-case fields `M.GENERATED`, `M.TESTS`, `M.DOCS`, `M.CONFIG`,
  `M.RISK = { { pattern, weight } }`). **Step 4:** pass.
- [ ] **Step 5:** commit `feat(review): group a pull request's files by kind and risk`.

### Task 4: Store

**Files:** Create `lua/tools/review/store.lua`; Test `tests/spec/tools/review/store_spec.lua`

**Interfaces:**
- Produces:
  ```lua
  ---@class DyReviewDraft
  ---@field id string            local, `vim.fn.sha256(time .. counter)`:sub(1, 12)
  ---@field origin 'user'|'ai'|'forge'
  ---@field state 'ready'|'pending'|'kept'|'edited'|'dropped'
  ---@field path string
  ---@field side 'old'|'new'
  ---@field line integer
  ---@field start_line? integer
  ---@field body string
  ---@field suggestion? string[]
  ---@field severity? 'blocker'|'suggestion'|'question'|'nit'
  ---@field reply_to? string     forge thread id
  ---@field resolve? boolean
  ---@field file_level? boolean  line outside every hunk
  ---@field posted? string       forge id once sent
  ---@class DyReviewState
  ---@field reviewed table<string, string>  path -> blob SHA
  ---@field last_head? string
  ---@field drafts DyReviewDraft[]
  ```
  `M.path(remote: DyForgeRemote, id: string): string`,
  `M.load(remote, id): DyReviewState` (missing or corrupt file -> empty state,
  a corrupt one is renamed `<file>.bad` and notified, never overwritten
  silently), `M.save(remote, id, state)` (synchronous temp + `vim.uv.fs_rename`).
- [ ] Steps: failing tests `round-trips a state`, `starts empty`, `keeps a
  corrupt file aside`, `writes atomically` (stub `fs_rename`, assert the temp
  file is complete before it), `keeps slugs with slashes as directories`;
  run -> FAIL; implement; pass; commit `feat(review): keep a review's drafts and marks on disk`.

### Task 5: Git side

**Files:** Create `lua/tools/review/git.lua`; Test `tests/spec/tools/review/git_spec.lua` (real `git` in `h.tmpdir`)

**Interfaces:**
- Consumes: `util.system.run`.
- Produces (all async, `cb(result?, err?)` on the main loop):
  - `M.fetch(root, remote_name, refspecs: string[], cb)` -- `git fetch --no-tags --quiet <remote> <specs>`.
  - `M.merge_base(root, a, b, cb)` -> sha.
  - `M.files(root, base, head, cb)` -> `DyReviewFile[]` without `kind`/`risk`,
    from `git diff --numstat -z -M` plus `--name-status -z -M`, plus
    `git check-attr -z linguist-generated linguist-vendored --stdin`.
  - `M.blobs(root, rev, paths, cb)` -> `table<path, sha>` via `git ls-tree -z`.
  - `M.hunks(root, base, head, path, cb)` -> `{ old = {{s,e}...}, new = {{s,e}...} }` from `git diff -U0`.
  - `M.interdiff(root, base_old, head_old, base_new, head_new, cb)` -> paths
    whose patch-id (`git diff A B -- p | git patch-id --stable`) differs.
  - `M.worktree_add(root, dir, rev, cb)` / `M.worktree_remove(root, dir, cb)`
    (no `--force`; `cb(false, stderr)` when git refuses).
  - `M.delete_refs(root, prefix, keep: string[], cb)`.
- [ ] Steps: failing tests building a repo with two branches, a rename, a
  binary file and a rebase (for `interdiff`: a rebase onto a new base changes
  no patch id; an edited file does); worktree removal refusing on a dirty
  tree; run -> FAIL; implement; pass; commit `feat(review): read a pull request's change from local git`.

### Task 6: GitHub adapter and the adapter contract

**Files:** Create `lua/tools/review/forge/init.lua` (contract + `M.for_remote(remote)`),
`lua/tools/review/forge/github.lua`; Test `tests/spec/tools/review/forge/github_spec.lua` (fake `gh`).

**Interfaces:**
- Produces:
  ```lua
  ---@class DyReviewPull
  ---@field id string                 number or iid, as text
  ---@field title string
  ---@field author string
  ---@field body string
  ---@field url string
  ---@field base_ref string
  ---@field head_ref string
  ---@field base_sha string
  ---@field head_sha string
  ---@field fetch string[]            refspecs giving head (and base)
  ---@field fork boolean
  ---@field requested? boolean        my review is requested
  ---@class DyReviewComment
  ---@field author string
  ---@field body string
  ---@field time string
  ---@class DyReviewThread
  ---@field id string
  ---@field path? string
  ---@field side 'old'|'new'
  ---@field line? integer
  ---@field start_line? integer
  ---@field resolved boolean
  ---@field comments DyReviewComment[]
  ---@class DyReviewForge
  ---@field verdicts { id: string, label: string }[]
  ---@field list fun(remote, cb: fun(pulls?: DyReviewPull[], err?: string, capped?: boolean))
  ---@field for_branch fun(remote, branch: string, cb: fun(pull?: DyReviewPull, err?: string))
  ---@field get fun(remote, id: string, cb: fun(pull?: DyReviewPull, err?: string))
  ---@field threads fun(remote, pull, cb: fun(threads?: DyReviewThread[], err?: string, capped?: boolean))
  ---@field pending fun(remote, pull, cb: fun(drafts?: DyReviewDraft[], err?: string))
  ---@field submit fun(remote, pull, drafts: DyReviewDraft[], verdict: string, progress: fun(draft: DyReviewDraft, forge_id: string), cb: fun(err?: string))
  ---@field suggestion fun(lines: string[]): string?
  ```
  `M.MAX_PAGES = 20` (100 per page); hitting it sets `capped`.
- GitHub specifics: `list` from `repos/{slug}/pulls?state=open&per_page=100`
  and `requested` from `requested_reviewers` containing `gh api user`'s login
  (cached per session); `fetch = { '+refs/pull/<n>/head:refs/dyneo/review/github-<n>/head' }`;
  threads and resolving through GraphQL (`gh api graphql`, `reviewThreads`,
  `resolveReviewThread`); `pending` reads the user's `PENDING` review's
  comments; `submit`: if a pending review exists, add comments to it
  (`addPullRequestReviewThread`) then `submitPullRequestReview`, else one
  `POST repos/{slug}/pulls/{n}/reviews` with `commit_id = head_sha`,
  `event` = `APPROVE`|`REQUEST_CHANGES`|`COMMENT`, comments with
  `path, line, side = 'LEFT'|'RIGHT', start_line, start_side`; a file-level
  draft uses `subject_type = 'file'` and its body starts with `L<line>: `.
  Replies (`POST .../comments/{id}/replies`) and resolutions are sent after
  the review, each reported through `progress`. `suggestion` returns
  "```suggestion\n" .. lines .. "\n```".
- [ ] Steps: failing tests per function against canned JSON in
  `tests/fixtures/review/github/*.json` (pagination with a cut page -> err,
  20 pages -> capped, requested flag, pending import, the exact body of the
  review POST for a mix of line, range, old-side and file-level drafts);
  run -> FAIL; implement; pass; commit `feat(review): review GitHub pull requests`.

### Task 7: Drafts and their marks

**Files:** Create `lua/tools/review/drafts.lua`; Test `tests/spec/tools/review/drafts_spec.lua`

**Interfaces:**
- Consumes: `store` (Task 4), `git.hunks` result shape (Task 5).
- Produces:
  - `M.HL = { draft = 'DyReviewDraft', ai = 'DyReviewAi', ai_pending = 'DyReviewAiPending', ai_sign = 'DyReviewAiSign', thread = 'DyReviewThread' }`,
    defined with `default = true` linked to `DiagnosticInfo`, `DiagnosticHint`,
    `DiagnosticWarn`, `DiagnosticWarn`, `Comment`; `M.AI_SIGN = '󰚩'`.
  - `M.add(state, fields): DyReviewDraft` (sets id, origin `user`, state `ready`).
  - `M.set_state(draft, state)`; editing an AI draft's body makes it `edited`.
  - `M.in_hunk(hunks, side, line, start_line?): boolean`.
  - `M.sendable(state): DyReviewDraft[], integer` -- drafts to send (not
    posted, `ready`/`kept`/`edited`, origin `forge` included) and the count of
    skipped `pending` AI drafts.
  - `M.draw(bufnr, path, side, state, threads)` -- clears namespace
    `dy_review` on `bufnr` and draws signs and end-of-line virtual text: AI
    pending `󰚩 AI <severity>: <first line>` in `ai_pending`, AI kept/edited in
    `ai`, user drafts in `draft`, threads in `thread` with comment counts.
  - `M.replace_ai(state, drafts)` -- drop pending AI drafts, append new ones,
    keep kept and edited.
- [ ] Steps: failing tests for `sendable` (pending skipped and counted,
  dropped never, posted never), `replace_ai`, editing flips to `edited`,
  `in_hunk` on both sides and ranges, `draw` puts the AI sign and
  `DyReviewAiPending` on the right line (read back with
  `nvim_buf_get_extmarks(..., { details = true })`); run -> FAIL; implement;
  pass; commit `feat(review): draw drafts with AI ones marked apart`.

### Task 8: Session, panel, diff and command

**Files:** Create `lua/tools/review/init.lua`, `lua/tools/review/panel.lua`,
`lua/tools/review/diff.lua` (the only module touching codediff internals),
`plugin/review.lua`; Modify `lua/plugins/coding/keys.lua` (group),
`lua/config/keymaps.lua` (global keys), `lua/dyneo/health.lua`;
Test `tests/spec/tools/review/init_spec.lua`, `tests/spec/tools/review/panel_spec.lua`.

**Interfaces:**
- Consumes: Tasks 2-7.
- Produces:
  - `M.SUBCOMMANDS = { 'pick', 'branch', 'ai', 'submit', 'since', 'drafts', 'trust', 'close' }`, `M.command(args)`.
  - `M.current(): DyReviewSession?` with
    `{ remote, forge, pull, root, worktree, merge_base, files, buckets, hunks, threads, state, trusted }`.
  - `M.open(remote, pull)`, `M.close()`, `M.mark(path)`, `M.comment(opts)` (normal/visual, opens a Markdown float; saving closes it and stores the draft), `M.reply()`, `M.toggle_resolve()`, `M.ai_action('keep'|'edit'|'drop')`, `M.jump_ai(dir)`.
  - `panel.render(session): string[]` (pure; spec it) and `panel.open(session)`.
  - `diff.open(session, path)`, `diff.on_buffer(fn(bufnr, path, side))`, `diff.close()`. Wrap every codediff internal in `pcall`; on failure notify "codediff changed: <what>" and fall back to `:CodeDiff file <merge_base> <head> -- <path>`.
- Behaviour pinned by the spec:
  - `pick` lists PRs of every remote whose `util.forge.kind_of(host)` is
    known, requested first, through `util.pick` (Snacks), forge shown.
  - `open` order: fetch refs -> merge-base -> files/hunks -> worktree at head
    (held via `util.untrusted.hold(worktree, ask)` *before* any buffer opens)
    -> threads and `pending` import (an import failure sets
    `session.blocked = reason`) -> panel and first file.
  - The trust question: `('Review %s !%s by %s%s: let language servers and the project\'s .nvim run its code?'):format(forge, id, author, fork and ' (from a fork)' or '')`.
    Yes -> `untrusted.release`; once servers start, notify once "Dependencies are not installed in the review worktree: some servers answer only in part".
  - Reopening the same PR reuses the session; augroup `dy_review` cleared.
  - `close` deletes `head`/`base` refs (keeps `reviewed`), removes the
    worktree (kept with a message when git refuses), `untrusted.forget`.
  - `since` lists files from `git.interdiff` against `refs/.../reviewed`,
    or says the ref is gone and lists files whose blob differs from `reviewed`.
  - A file whose blob changed since marked shows `⟳`, not `✓`.
  - `comment` on a line outside every hunk (`drafts.in_hunk` false) warns at
    once ("Outside the diff: sent as a file comment naming line N") and sets
    `file_level = true`.
  - `drafts` opens a Snacks picker over all drafts with columns origin
    (`AI`, `me`, `forge`), state, severity, `path:line`, first line;
    `<CR>` jumps to it in the diff.
- Keys: `<leader>pv` group "review"; `pvv` pick, `pvb` branch, `pva` ai,
  `pvd` drafts, `pvs` submit, `pvq` close. Buffer-local `<localleader>` in
  diff buffers: `c` (n, x), `s`, `r`, `R`, `m`, `k`, `e`, `x`; `]a` / `[a`.
- Health: `gh`, `glab`, `az` on demand entries name `:DyReview`; codediff
  installed is required by `:DyReview`.
- [ ] Steps: failing specs for `panel.render` (the layout in the spec, `!`,
  `✓`, `⟳`, AI count, collapsed generated), for `open`'s order and the hold
  happening before the first buffer (stub forge and git), for reuse without a
  second autocmd, for `close` keeping a refused worktree; run -> FAIL;
  implement; pass; `scripts/check-startup.sh` and `scripts/keymaps-doc.sh`
  pass; manual run against a real GitHub PR (record what was checked in the
  commit body); commit `feat(review): review a pull request in one UI`.

### Task 9: Submit

**Files:** Create `lua/tools/review/submit.lua`; Test `tests/spec/tools/review/submit_spec.lua`

**Interfaces:**
- Consumes: `drafts.sendable`, adapter `submit`, `store.save`, `forge.get`.
- Produces: `M.run(session)`: refuse when `session.blocked`; refetch the PR
  and refuse when `head_sha` moved ("The pull request moved to <short>:
  reopen it before submitting"); pick a verdict from `forge.verdicts`; show a
  confirmation float listing forge, PR, verdict, counts of comments, replies,
  resolutions, skipped pending AI drafts; on confirm call `adapter.submit`,
  storing each `progress` (`draft.posted = forge_id`, `store.save`) as it
  comes; on success set `last_head`, update the `reviewed` ref, notify.
- [ ] Steps: failing tests with a fake adapter: partial failure keeps the
  rest and sends no verdict; a resubmit sends only the unposted; pending AI
  drafts are not passed to the adapter and are counted in the confirmation
  text; head moved refuses; blocked refuses; run -> FAIL; implement; pass;
  commit `feat(review): send a review once, resuming where it failed`.

### Task 10: GitLab adapter

**Files:** Create `lua/tools/review/forge/gitlab.lua`; Test `tests/spec/tools/review/forge/gitlab_spec.lua` (fake `glab`).

- Endpoints under `projects/<forge.encode(slug)>/merge_requests`. `fetch = { '+refs/merge-requests/<iid>/head:refs/dyneo/review/gitlab-<iid>/head' }`.
  `diff_refs` give `base_sha`, `start_sha`, `head_sha`. Threads from
  `/discussions` (paginated). `pending` from `/draft_notes` of the current
  user. `submit`: one `POST /draft_notes` per draft with
  `position = { position_type = 'text'|'file', base_sha, start_sha, head_sha, old_path, new_path, new_line|old_line, line_range? }`
  (or `in_reply_to_discussion_id`), then `POST /draft_notes/bulk_publish`,
  resolutions via `PUT /discussions/:id?resolved=true`, then
  `POST /approve` or `POST /unapprove`. Verdicts: approve, revoke approval,
  comment. `suggestion`: "```suggestion:-0+0\n" .. lines .. "\n```".
- [ ] Steps: failing tests for each payload shape and for publishing only
  after every draft note was created; run -> FAIL; implement; pass; commit
  `feat(review): review GitLab merge requests`.

### Task 11: Azure DevOps adapter

**Files:** Create `lua/tools/review/forge/azure.lua`; Test `tests/spec/tools/review/forge/azure_spec.lua` (fake `az`).

- Calls are `DyForgeAzureCall`s, area `git`: `pullRequests` (list, get),
  `pullRequestThreads` (threads, POST per draft with
  `threadContext = { filePath = '/' .. path, rightFileStart/End | leftFileStart/End = { line, offset = 1 } }`
  and `pullRequestThreadContext.iterationContext` from the last
  `pullRequestIterations` id), `pullRequestThreadComments` (replies),
  thread `PATCH status = 'fixed'` (resolve), `pullRequestReviewers` `PUT`
  with `vote` 10 / 5 / 0 / -5 / -10 for approve, approve with suggestions, no
  vote, wait for author, reject; the reviewer id comes from
  `az devops invoke --area Location --resource connectionData` (`authenticatedUser.id`), cached.
- `fetch`: `+refs/pull/<n>/merge:refs/dyneo/review/azure-<n>/merge`, head =
  `merge^2`; when that ref is missing, `+refs/heads/<source>:…/head` checked
  against `lastMergeSourceCommit.commitId`; a fork source that cannot be
  fetched opens read-only (`session.blocked`). `pending` returns `{}`
  (Azure has no draft comments). `suggestion` returns nil (plain code block
  instead).
- [ ] Steps: failing tests for the vote mapping, thread payloads on both
  sides, missing merge ref fallback, fork read-only; run -> FAIL; implement;
  pass; commit `feat(review): review Azure DevOps pull requests`.

### Task 12: AI pass

**Files:** Create `lua/tools/review/ai.lua`, `prompts/review/pr.md`; Test `tests/spec/tools/review/ai_spec.lua`

**Interfaces:**
- Consumes: `tools.ai.headless`, `tools.ai.check` (through headless),
  `tools.ai.prompts.template/fence`, `tools.ai.git.MAX_DIFF`, `drafts.replace_ai`, `drafts.in_hunk`.
- Produces: `M.chunks(files, diffs: table<path,string>, max: integer): { paths: string[], text: string }[]`
  (generated files left out; one file larger than `max` is its own chunk,
  cut and said so), `M.parse(answer: string, hunks): { summary?, order?, drafts: DyReviewDraft[], outside: integer }`
  (first balanced JSON object; unknown severity -> `suggestion`; lines
  outside hunks counted in `outside`, dropped), `M.run(session)` (chunks
  two at a time through `util.system.each`, merges results, notifies failed
  chunks by their paths, `drafts.replace_ai`, saves, redraws, shows the
  summary in the panel header).
- Prompt asks for JSON only: `{"summary": str, "order": [path], "comments": [{"path", "side": "new"|"old", "line", "start_line"?, "severity", "body", "suggestion"?}]}`;
  the diff goes in `prompts.fence(diff)`.
- [ ] Steps: failing tests for `chunks` (split, generated left out),
  `parse` (prose around JSON, invalid JSON -> error, outside lines counted,
  severity default), `run` replacing only pending drafts (stub `headless`);
  run -> FAIL; implement; pass; commit `feat(review): let an AI draft comments to keep or drop`.

### Task 13: Docs, checks on both channels, cleanup

**Files:** Modify `doc/dyneo.txt` (section `*dyneo-review*`, `:DyReview` in
`|dyneo-commands|`), `doc/tags` (`:helptags doc`), `README.md` (one row),
`doc/dyneo-keymaps.txt` (regenerated). Delete `docs/superpowers/`.

- [ ] **Step 1:** write the help section: what it is, subcommands, keys,
  the AI marker, the trust question, where state lives, what each forge
  supports (suggestions, verdicts, drafts). Dashes for rules, no `=====`,
  78 columns.
- [ ] **Step 2:** `:helptags doc`, `scripts/keymaps-doc.sh`.
- [ ] **Step 3 (latest):** `scripts/test.sh`, `scripts/check-startup.sh`,
  `nvim --clean --headless -l scripts/validate-tools.lua`,
  `scripts/keymaps-doc.sh`, `SKIP=bench prek run --all-files` -> all pass.
- [ ] **Step 4 (stable):** the same under
  `NVIM_APPNAME=nvim-stable mise exec neovim@stable -- …`, then
  `git diff --exit-code doc/` -> clean. Report each channel separately.
- [ ] **Step 5:** commit `docs(review): document :DyReview`.
- [ ] **Step 6:** `git rm -r docs/superpowers`, commit
  `chore(review): drop the design notes`, `git rebase main`, rerun Step 3's
  specs; `git diff main --stat` shows no `docs/superpowers` path.
