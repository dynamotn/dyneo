# `:DyReview` -- one review UI for GitHub, GitLab and Azure DevOps

Status: design, awaiting approval. Branch `feat/review`.

## Intent

Review a pull request (GitHub), merge request (GitLab) or pull request
(Azure DevOps) in one place, the same way on every forge, and post the review
from the editor. The hard part of reviewing today is not typing a comment: it
is that AI-written changes run to thousands of lines, and a reviewer needs to
know what to read first, what to skip, where they stopped, and what changed
since they last looked. An AI first pass writes draft comments the reviewer
keeps, edits or drops; those drafts are unmistakable in the editor.

Octo and gitlab.nvim stay for everything that is not reviewing (issues,
merging, creating PRs). Their review features are not removed, just no longer
the path we build for.

## Goals

1. **One entry point.** `:DyReview` picks an open PR of the current repository
   on any of the three forges (review requested from me first), or the PR of
   the current branch, and opens the same UI.
2. **Triage before reading.** Files are grouped -- source, tests, config and
   infrastructure, docs, generated and lockfiles -- with line counts per group;
   the generated group is collapsed. Within source, files are ordered by risk.
3. **Reviewed state that survives pushes.** Marking a file reviewed records the
   blob it had. A later push that changes the file un-marks it; one that does
   not leaves it marked. "Since my last review" shows only what changed after
   the head I last reviewed.
4. **Drafts, then one submit.** Comments (line, range, either side, with a
   suggested change where the forge supports it), replies to and resolving of
   existing threads are kept as local drafts and sent together with a verdict.
5. **LSP on the new side.** Hover, go to definition and diagnostics work in the
   new version of each file.
6. **AI first pass.** A summary, a reading order, and draft line comments with
   a severity (blocker, suggestion, question, nit), shown with their own sign,
   colour and label, never sent until the reviewer has touched them.
7. **Three forges**: GitHub (`gh`), GitLab (`glab`), Azure DevOps Services
   (`az`), each through its own CLI, which holds the token.

## Non-goals

- Issues, merging, creating PRs, pipelines (Octo, gitlab.nvim, `:DyProject`,
  `ci_inline` and `:DyJira` already cover them).
- Bitbucket; Azure DevOps Server (on-premises).
- Syncing GitHub's own "viewed" checkboxes.
- Marking posted comments as AI-assisted on the forge: the user decided the AI
  marker lives only in the editor. A posted comment looks like the reviewer's.
- Removing Octo or gitlab.nvim, or their keys.

## Anti-goals (a failure even if it works)

- A draft lost: to a failed submit, a crash, a quit, or a reopened PR.
- AI text posted that the reviewer never looked at, or a vote cast by AI.
- The UI freezing while a forge, git or the AI answers.
- A token read, passed on, or sent to a host taken from a repository.
- The user's working tree, index or current branch touched by a review.
- A failed fetch shown as "no comments" or "no files".

## Constraints (from DyNeo's AGENTS.md, binding)

- External calls through `util.system.run` / `each` with a deadline and an
  output cap; nothing on the UI path waits. `detach = true` for every CLI.
- Text handed to AI passes `tools.ai.check.text` first, and AI runs through
  `tools.ai`'s headless runner, so `util.ai_policy` (local-only projects) and
  `util.ai_audit` apply.
- Mappings through `map` / plugin `keys`; regenerate `doc/dyneo-keymaps.txt`.
- `plugin/review.lua` is a thin shim; nothing heavy at startup; works under
  `nvim --clean`.
- Augroups `dy_review`, `clear = true`; reopening a PR adds no second handler.
- LuaLS classes `DyReview*`. `DyReviewFinding` and `DyReviewGroup` are already
  taken in `lua/tools/plugin-review.lua`; use other names.
- Feature lands with spec files, `doc/dyneo.txt` section and `:helptags`,
  a README row, health checks for `gh`, `glab`, `az` and codediff.

## Decided

### Shape

```
plugin/review.lua                 :DyReview command + completion
lua/tools/review/init.lua         session: open, close, state, commands
lua/tools/review/forge/github.lua adapter
lua/tools/review/forge/gitlab.lua adapter
lua/tools/review/forge/azure.lua  adapter
lua/tools/review/triage.lua       grouping and risk order (pure, testable)
lua/tools/review/store.lua        per-PR state on disk
lua/tools/review/drafts.lua       draft model, extmarks, AI marker
lua/tools/review/panel.lua        file list panel
lua/tools/review/ai.lua           AI pass: prompt, chunking, parsing
lua/tools/review/submit.lua       confirmation and resumable submit
prompts/review/pr.md              AI prompt template
```

Every adapter implements the same table, `DyReviewForge`:

- `list(remote, cb)` -- open PRs, with whether my review is requested.
- `for_branch(remote, branch, cb)` -- the PR of a branch, or nil.
- `get(remote, id, cb)` -- title, author, description, base and head SHAs,
  base and head refs, the git ref to fetch the head from, web URL.
- `threads(remote, pr, cb)` -- existing threads with path, side, line range,
  resolved state, comments (author, body, time). Paginated to the end, capped,
  and says when it was capped.
- `submit(remote, pr, drafts, verdict, progress, cb)` -- see Submit.
- `verdicts` -- the verdicts the forge has: GitHub approve, request changes,
  comment; GitLab approve, revoke approval, comment; Azure approve, approve
  with suggestions, wait for author, reject, no vote.
- `suggestion(lines)` -- the forge's suggestion syntax, or nil.

### Getting the code

The diff is read from local git, not the forge API, so no API file or size
limits apply and nothing is fetched twice.

- The head is fetched into private refs, `refs/dyneo/review/<id>/head` (and
  base), from the forge's PR ref: GitHub `pull/<n>/head`, GitLab
  `merge-requests/<n>/head`, Azure `pull/<n>/merge` and its second parent.
  Refs are deleted when the session closes.
- The new side lives in a detached worktree at
  `.worktrees/dyreview-<forge>-<id>` of the repository (where this machine
  keeps worktrees), so the new side is a real file and LSP attaches with that
  worktree as root. The user's checkout is never touched. Closing the session
  removes the worktree with plain `git worktree remove` (no force); if that
  refuses, it is kept and the user is told the path.
- The diff shown is merge-base(base, head) to head: what the PR changes.

### Diff display

codediff.nvim, already in the config, opened through `:CodeDiff` with the two
revisions (or `--repo <worktree> <merge-base>` so the modified side is the
worktree file). Comments and drafts are extmarks placed on its buffers through
`codediff.ui.lifecycle.get_buffers` on its `CodeDiffFileSelect` and
`CodeDiffVirtualFileLoaded` events. codediff has no public open API and these
are internals: wrap every call in one module and fail with a clear message if
the internals change.

### Panel

A left side panel (`util.panel` options) is the file list for triage:

```
 PR !412  feat: add billing export          (12 of 87 files reviewed)
 AI: 9 drafts to look at   ⟳ 3 files changed since last review
 ▾ Source            31 files  +2140 -310
   ! ✓ src/auth/token.go            +120 -4   2 AI
   !   db/migrations/0042_bill.sql  +88       1 AI
       src/billing/export.go        +612
 ▸ Tests             22 files  +1800
 ▸ Config & infra     6 files  +90 -12
 ▸ Docs               4 files  +60
 ▸ Generated & locks 24 files  +9000 -7000   (collapsed)
```

`!` risky, `✓` reviewed, `⟳` changed since it was reviewed. `<CR>` opens the
file in the diff; the panel follows the current file.

### Triage

`triage.lua` is pure (paths, numstat, attributes in; groups out) so it is
fully specced.

- Generated: `git check-attr linguist-generated linguist-vendored`, lockfiles
  by name (`*.lock`, `package-lock.json`, `go.sum`, `lazy-lock*.json`, ...),
  `vendor/`, `dist/`, `*.min.*`, `*.pb.go`, `*_generated.*`, snapshots.
- Tests, docs, config and infrastructure by path and extension.
- Risk (source only, highest first): auth, crypto, security, permissions,
  secrets handling; migrations and schemas; CI workflows, Dockerfiles,
  Terraform, Kubernetes manifests; public API definitions; then by lines
  removed and added. The AI reading order, when it exists, wins over this.

### Store

One JSON file per PR under
`stdpath('state')/dyneo/review/<host>/<slug>/<id>.json`:

- `reviewed`: path -> blob SHA at the head when marked.
- `last_head`: head SHA of the last submitted review.
- `drafts`: every draft, with origin and state (below), and per draft whether
  it has been posted and the forge's id for it.

Written after every change to drafts, atomically (temp file, then rename). It
holds review text, never tokens.

### Drafts and the AI marker

A draft has `path`, `side` (old/new), `line`, optional `start_line`, `body`,
optional suggested replacement, optional `reply_to` thread and `resolve`, and:

- `origin`: `user` or `ai` (kept for good, local only).
- `state`: for AI drafts `pending` -> `kept` | `edited` | `dropped`; user
  drafts are always ready.

AI drafts have their own highlight groups (`DyReviewAi`, `DyReviewAiSign`),
a robot sign in the sign column, and end-of-line virtual text
`AI <severity>: <first line>`, distinct from the reviewer's drafts
(`DyReviewDraft`) and from existing threads (`DyReviewThread`). Pending AI
drafts are brighter than kept ones. The draft list (a picker over all drafts)
has a column for origin and state.

### AI pass

- Input: the PR title and description, and the diff of source, test and config
  files; generated files are left out and named as left out.
- Passed through `tools.ai.check.text(root, paths, diff)`; refused means no AI
  pass, with the reason shown.
- A diff larger than `tools.ai.git.MAX_DIFF` is split by file into chunks,
  run two at a time with `util.system.each`, each with `DyNeo.ai.commit_timeout`;
  a failed chunk is named, the rest are kept.
- The prompt asks for JSON: `summary`, `order` (paths), `comments` (path,
  side, line, optional start_line, severity, body, optional suggestion). The
  first JSON object in the answer is parsed; a comment whose line is not in the
  diff is dropped and counted ("2 AI comments pointed outside the diff").
- Running it again replaces pending AI drafts, keeps kept and edited ones.

### Submit

`:DyReview submit` (or its key) opens a confirmation listing exactly what
will be sent: forge, PR, verdict, the number of comments, replies and
resolutions, and how many pending AI drafts are skipped. Only what was
confirmed is sent; pending and dropped AI drafts never are.

- GitHub: one `POST /repos/{o}/{r}/pulls/{n}/reviews` with all comments and
  the verdict; replies and resolutions through their own calls.
- GitLab: each draft as a draft note (`/merge_requests/:iid/draft_notes`,
  position from base, start and head SHAs), then `bulk_publish`, then
  approve or unapprove.
- Azure DevOps: one thread per comment (`git/pullRequests/threads`, thread
  context with path and right or left line range, iteration context), then the
  vote through the reviewer entry of the signed-in user.
- Each draft is marked posted as soon as its call succeeds, so a failure
  midway leaves the rest as drafts and submitting again sends only those. The
  verdict goes last, only once every comment is posted.
- `last_head` is set when the whole submit succeeds.

### Forge writes

`util.forge` gains write support: `gh api` and `glab api` with `--method`
and `--input -`, the JSON body on stdin. For Azure, the
`feat/azure-devops` branch (commit `3600e71`, not yet on `main`) adds
`kind = 'azure'` with `org`, `project`, `repo` on the remote, `M.CLIS`,
`M.AZURE_API_VERSION`, and `M.command(remote, endpoint) -> argv, name`, where
an Azure endpoint is a `DyForgeAzureCall` `{ area, resource, route, query }`
run through `az devops invoke`; `M.api` and `M.api_text` take it. It is GET
only by choice. This branch adds optional `method` and `body` to
`DyForgeAzureCall`, mapped in `M.command` (the one place every call goes
through) to `--http-method` and `--in-file <temp JSON>`, the temp file
removed in the run callback. This branch is rebased onto `feat/azure-devops`
(or onto `main` once it is merged) before any forge work starts, so the
GitHub, GitLab and Azure write paths are written once, together.

### Commands and keys

`:DyReview` with subcommands `pick` (default), `branch`, `ai`, `submit`,
`since`, `drafts`, `close`. Global group `<leader>pv` ("review"):

| Key | Does |
|-----|------|
| `<leader>pvv` | pick a PR to review |
| `<leader>pvb` | review the PR of the current branch |
| `<leader>pva` | run the AI pass |
| `<leader>pvd` | list drafts |
| `<leader>pvs` | submit |
| `<leader>pvq` | close the review |

In diff buffers of a session, `<localleader>`: `c` comment (normal and
visual), `s` suggest a change, `r` reply to the thread under the cursor, `R`
toggle resolving it, `m` mark the file reviewed, `k` keep the AI draft, `e`
edit it, `x` drop it; `]a` / `[a` next and previous pending AI draft. Hunk and
file motions stay codediff's.

## Calls made by the designer (not discussed with the user)

- **Every forge remote.** `pick` lists open PRs from every remote whose host
  is a known forge, in one picker with the forge shown; `branch` takes the PR
  of the branch on the remote it tracks, and asks when two forges have one.
- **Drafts already on the forge.** Opening a PR imports the user's own
  pending drafts there (GitHub pending review, GitLab draft notes) as local
  drafts with origin `forge`, shown in the confirmation and sent with the
  review: GitHub adds the comments to that pending review and submits it,
  GitLab's `bulk_publish` then publishes only what was confirmed. Nothing on
  the forge is deleted. An import that fails blocks submit, with the reason.
- **Since my last review is an interdiff.** For each file, the diff of
  merge-base to the last reviewed head is compared with merge-base to the
  current head, so a rebase onto a newer base does not show the base's
  changes. `refs/dyneo/review/<id>/reviewed` keeps the last reviewed head
  past session close and is removed only when the PR is merged or closed.
  When it is gone, `since` says so and falls back to the reviewed-blob marks.
- **Comments outside a hunk.** Placing one warns at once; it is sent as a
  file-level comment that names the line (GitHub `subject_type = file`,
  GitLab file position, Azure takes any line as is).
- **Azure PR without a merge ref.** The head is fetched from the source
  branch, the base from the target branch, and checked against
  `lastMergeSourceCommit` / `lastMergeTargetCommit`; when the source is a
  fork that cannot be fetched, the PR opens read-only with the reason.

## Left to the builder

- Whether codediff's own explorer is hidden in favour of the panel, or kept.
- How the comment editor looks (float or split), as long as it is a Markdown
  buffer and a draft is saved when it closes.
- Exact risk path patterns and their weights, and the prompt wording.
- Pagination caps per forge, with a message when hit.
- Order of work. A sensible one: rebase, forge writes, store, triage, GitHub
  adapter and the UI end to end; then GitLab; then Azure; then AI.
