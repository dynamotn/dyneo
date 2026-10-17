--- What git says about a change, read for an AI: the staged diff of a
--- commit, or the diff of a branch for its pull request
---
--- Read from git rather than from a buffer, and checked by `tools.ai.check`
--- before it is handed on.
local M = {}

--- Bytes of diff read; a larger one is cut and the caller says so
M.MAX_DIFF = 512 * 1024

---@class DyAiChange
---@field root string The work tree
---@field paths string[] Files changed, relative to `root`
---@field diff string
---@field cut boolean Whether `diff` was cut at `M.MAX_DIFF`

--- The work tree of `bufnr`, handed to `on_done`
---
--- A commit message lives in the git directory, outside the work tree: in
--- `.git` of a plain repository, in `.git/worktrees/<name>` of a linked work
--- tree, which names the work tree in its `gitdir` file, or in
--- `.git/modules/<name>` of a submodule, whose `core.worktree` names it. Any
--- other buffer is in its work tree already, and an unnamed one is taken to
--- be where Neovim runs.
---@param bufnr integer
---@param on_done fun(root?: string, err?: string)
function M.root(bufnr, on_done)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name:match('^%a[%w+.-]*://') then name = '' end
  local dir = name ~= '' and vim.fs.dirname(name) or vim.uv.cwd() or '.'
  local args = { 'git', 'rev-parse', '--show-toplevel' }
  if name:find('/%.git/') then
    local ok, gitdir = pcall(vim.fn.readfile, dir .. '/gitdir', '', 1)
    if ok and gitdir[1] then
      return on_done(vim.fs.dirname(vim.trim(gitdir[1])))
    elseif dir:match('/%.git$') then
      return on_done(vim.fs.dirname(dir))
    end
    args = { 'git', '--git-dir=' .. dir, 'rev-parse', '--show-toplevel' }
  end
  local system = require('util.system')
  system.run(args, { cwd = dir }, function(result)
    local root = vim.trim(result.stdout)
    if result.code ~= 0 or root == '' then
      return on_done(
        nil,
        'Not in a git work tree: ' .. system.failure(result, 'git')
      )
    end
    on_done(root)
  end)
end

--- The change staged in `root`, or the one of the branch since `base`, once
--- `tools.ai.check` has let it through
---@param root string
---@param base? string Compared from the merge base with it; staged unless
--- given
---@param on_done fun(change?: DyAiChange, err?: string)
function M.change(root, base, on_done)
  local system = require('util.system')
  local which = base and { base .. '...HEAD' } or { '--cached' }
  -- A rename lists the old path too: `.env` moved to `config.txt` is a
  -- sensitive file leaving under a plain name
  local names = vim.list_extend(
    { 'git', 'diff', '--no-renames', '--name-only', '-z' },
    which
  )
  system.run(names, { cwd = root }, function(listed)
    if listed.code ~= 0 then
      return on_done(nil, system.failure(listed, 'git diff'))
    end
    local paths = vim.split(listed.stdout, '\0', { trimempty = true })
    if #paths == 0 then
      return on_done(
        nil,
        base and ('Nothing changed since %s'):format(base)
          or 'Nothing is staged'
      )
    end
    local diff = vim.list_extend(
      { 'git', 'diff', '--no-color', '--no-ext-diff', '--no-renames' },
      which
    )
    system.run(diff, { cwd = root, max_bytes = M.MAX_DIFF }, function(read)
      if read.code ~= 0 and not read.cut then
        return on_done(nil, system.failure(read, 'git diff'))
      end
      require('tools.ai.check').text(root, paths, read.stdout, function(why)
        if why then return on_done(nil, why) end
        on_done({
          root = root,
          paths = paths,
          diff = read.stdout,
          cut = read.cut,
        })
      end)
    end)
  end)
end

--- The branch a pull request of `root` would go into: the remote's default
--- branch, else a local `main` or `master`
---@param root string
---@param on_done fun(base?: string, err?: string)
function M.base(root, on_done)
  local system = require('util.system')
  system.run(
    { 'git', 'rev-parse', '--abbrev-ref', 'origin/HEAD' },
    { cwd = root },
    function(head)
      local remote = vim.trim(head.stdout)
      if head.code == 0 and remote ~= '' and remote ~= 'origin/HEAD' then
        return on_done(remote)
      end
      system.run({
        'git',
        'for-each-ref',
        '--format=%(refname:short)',
        'refs/heads/main',
        'refs/heads/master',
      }, { cwd = root }, function(refs)
        local first = vim.split(refs.stdout, '\n', { trimempty = true })[1]
        if refs.code ~= 0 or not first then
          return on_done(nil, 'No main branch to compare with: name one')
        end
        on_done(first)
      end)
    end
  )
end

--- Lines of `git log` in `root`, as many as `args` ask for; none when it
--- fails, as on a repository with no commit yet
---@param root string
---@param args string[] After `git log`
---@param on_done fun(lines: string[])
function M.log(root, args, on_done)
  require('util.system').run(
    vim.list_extend({ 'git', 'log' }, args),
    { cwd = root, max_bytes = 64 * 1024 },
    function(result)
      on_done(
        result.code == 0
            and vim.split(result.stdout, '\n', { trimempty = true })
          or {}
      )
    end
  )
end

--- Whether `root` enforces Conventional Commits
---@param root string
---@return boolean
function M.conventional(root)
  return vim.uv.fs_stat(root .. '/.gitlint') ~= nil
    or #vim.fn.glob(root .. '/{.,}commitlint*', true, true) > 0
end

return M
