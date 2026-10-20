--- The history of the function under the cursor, not of its whole file
---
--- `:DyHistory` finds, with tree-sitter, the definition the cursor is in --
--- a function, a method, a class, a Terraform block -- and shows what
--- `git log -L` says of its lines: each commit that changed them, with the
--- change. `:'<,'>DyHistory` does the same for the lines selected. Lines are
--- those of the file as written, which git compares with its history; an
--- unsaved buffer is said to be.
local M = {}

local system = require('util.system')
local notify = require('util.notify').titled('History')

--- Commits shown
M.LIMIT = 30
--- Milliseconds git may take
M.TIMEOUT = 30 * 1000
--- Bytes of history kept
M.MAX_BYTES = 4 * 1024 * 1024

--- What a definition is called, the first part of its node type:
--- `function_declaration`, `method_definition`, `impl_item`
M.KINDS = {
  'function',
  'method',
  'class',
  'struct',
  'impl',
  'interface',
  'trait',
  'enum',
  'module',
  'type',
  'object',
  'record',
  'namespace',
}

--- How grammars end the type of a definition node; a call, an index or an
--- expression ends otherwise (`method_index_expression`, `method_invocation`)
local SUFFIXES = { 'definition', 'declaration', 'item', 'spec' }

--- Definition node types no suffix gives away
local EXACT = {
  arrow_function = true,
  function_expression = true,
  -- Lua's anonymous `function() ... end`
  ['function'] = true,
}

--- Whether a node of `kind` is a definition. `block` is Terraform's (and
--- HCL's), and Lua's `do ... end` is not one: only a top-level one counts.
---@param kind string
---@param parent? string
---@return boolean
local function definition(kind, parent)
  if kind == 'block' then return parent == 'body' or parent == 'config_file' end
  if EXACT[kind] then return true end
  local head, tail = kind:match('^(.-)_?([%a]+)$')
  if not head or not vim.list_contains(SUFFIXES, tail) then return false end
  for _, word in ipairs(M.KINDS) do
    -- `function_definition`, `local_function_declaration`, `struct_item`
    if head == word or head:sub(-#word - 1) == '_' .. word then return true end
  end
  return false
end

--- The lines (1-based, inclusive) of the definition at `row` of `bufnr`,
--- and its node type; nil when tree-sitter has no parser for it or the
--- cursor is in none
---@param bufnr integer
---@param row integer 1-based
---@return integer? first
---@return integer? last
---@return string? kind
function M.definition_at(bufnr, row)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then return nil end
  parser:parse()
  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ''
  local col = #(line:match('^%s*') or '')
  return M.enclosing(vim.treesitter.get_node({
    bufnr = bufnr,
    pos = { row - 1, col },
    ignore_injections = false,
  }))
end

--- The lines (1-based, inclusive) and type of the innermost definition
--- holding `node`, `node` itself included
---@param node? TSNode
---@return integer? first
---@return integer? last
---@return string? kind
function M.enclosing(node)
  while node do
    local parent = node:parent()
    if definition(node:type(), parent and parent:type()) then
      local first, _, last, last_col = node:range()
      -- A range ending at column 0 ends on the line before
      if last_col == 0 and last > first then last = last - 1 end
      return first + 1, last + 1, node:type()
    end
    node = parent
  end
  return nil
end

--- The `git log -L` of lines `first` to `last` of `path` in `root`
---@param root string
---@param path string Relative to `root`
---@param first integer
---@param last integer
---@return string[]
function M.log_command(root, path, first, last)
  return {
    'git',
    '-C',
    root,
    'log',
    '--no-color',
    '--date=short',
    '--format=commit %h  %ad  %an%n%n    %s%n',
    ('--max-count=%d'):format(M.LIMIT),
    ('-L%d,%d:%s'):format(first, last, path),
  }
end

--- The repository of `file`, and the path git knows it by, both with links
--- resolved: in a chezmoi home a file may be a link into the repository
---@param file string
---@return string? root
---@return string? path
function M.locate(file)
  local real = vim.uv.fs_realpath(file)
  if not real then return nil end
  local root = vim.fs.root(real, '.git')
  if not root then return nil end
  root = vim.uv.fs_realpath(root) or root
  if real:sub(1, #root + 1) ~= root .. '/' then return nil end
  return root, real:sub(#root + 2)
end

--- Show the history of lines `first` to `last` of the current buffer
---@param first integer
---@param last integer
---@param what string What the lines are, for the title
---@param on_done? fun() For the specs
function M.show(first, last, what, on_done)
  local function finish(msg, level)
    if msg then notify(msg, level) end
    if on_done then on_done() end
  end
  local file = vim.api.nvim_buf_get_name(0)
  local root, path = M.locate(file)
  if not root then
    return finish('Not a file of a git repository', vim.log.levels.WARN)
  end
  local modified = vim.bo.modified
  local opts = { cwd = root, timeout = M.TIMEOUT, max_bytes = M.MAX_BYTES }
  local function log(head_first, head_last)
    system.run(
      M.log_command(root, assert(path), head_first, head_last),
      opts,
      function(result)
        if result.code ~= 0 and not result.cut then
          return finish(system.failure(result, 'git log'), vim.log.levels.ERROR)
        end
        local lines = {
          ('# %s, lines %d-%d of %s'):format(what, first, last, path),
          '',
        }
        if head_first ~= first or head_last ~= last then
          vim.list_extend(lines, {
            ('Lines %d-%d at HEAD: the file has changes not committed.'):format(
              head_first,
              head_last
            ),
            '',
          })
        end
        if modified then
          vim.list_extend(lines, {
            'The buffer is not written: these are the lines of the file on disk.',
            '',
          })
        end
        local body = vim.split(result.stdout or '', '\n', { plain = true })
        if #body == 1 and body[1] == '' then
          table.insert(
            lines,
            'No commit changed these lines: they are not committed yet.'
          )
        else
          vim.list_extend(lines, body)
        end
        if result.cut then
          table.insert(
            lines,
            ('… cut at %d MiB'):format(M.MAX_BYTES / 1024 / 1024)
          )
        end
        require('util.scratch').open(lines, {
          filetype = 'git',
          name = ('history://%s:%d-%d'):format(path, first, last),
        })
        finish()
      end
    )
  end
  -- A file git does not track has no history, and `-L` would fail on it
  system.run(
    { 'git', 'ls-files', '--error-unmatch', '--', path },
    opts,
    function(tracked)
      if tracked.code ~= 0 then
        if tracked.missing or tracked.timed_out then
          return finish(system.failure(tracked, 'git'), vim.log.levels.ERROR)
        end
        return finish(
          ('%s is not committed yet: it has no history'):format(path)
        )
      end
      -- `-L` reads lines of HEAD; the file on disk may have moved them
      system.run(
        {
          'git',
          'diff',
          '--no-color',
          '--no-ext-diff',
          '-U0',
          'HEAD',
          '--',
          path,
        },
        opts,
        function(diff)
          if diff.code ~= 0 or diff.cut then
            return finish(
              system.failure(diff, 'git diff'),
              vim.log.levels.ERROR
            )
          end
          local head_first, head_last =
            M.map_range(diff.stdout or '', first, last)
          if not head_first then
            return finish(
              'These lines are not committed yet: they have no history'
            )
          end
          log(head_first, assert(head_last))
        end
      )
    end
  )
end

--- Lines `first` to `last` of the file on disk as they were at HEAD, from
--- `git diff -U0 HEAD`: lines added since are left out, the others moved by
--- what was added and removed above them; nil when every one is new
---@param diff string
---@param first integer
---@param last integer
---@return integer? head_first
---@return integer? head_last
function M.map_range(diff, first, last)
  local hunks = {}
  for old_start, old_count, new_start, new_count in
    diff:gmatch('\n@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@')
  do
    table.insert(hunks, {
      old_start = tonumber(old_start),
      old_count = old_count == '' and 1 or tonumber(old_count),
      new_start = tonumber(new_start),
      new_count = new_count == '' and 1 or tonumber(new_count),
    })
  end
  local function at_head(line)
    local delta = 0
    for _, hunk in ipairs(hunks) do
      -- A hunk that only removes lines sits after line `new_start`
      local before = line < hunk.new_start
        or (hunk.new_count == 0 and line <= hunk.new_start)
      if before then break end
      if line < hunk.new_start + hunk.new_count then
        local offset = line - hunk.new_start
        -- A changed line was some line at HEAD; an added one was none
        if offset < hunk.old_count then return hunk.old_start + offset end
        return nil
      end
      delta = delta + hunk.old_count - hunk.new_count
    end
    return line + delta
  end
  local head_first, head_last
  for line = first, last do
    local mapped = at_head(line)
    if mapped then
      head_first = head_first and math.min(head_first, mapped) or mapped
      head_last = head_last and math.max(head_last, mapped) or mapped
    end
  end
  return head_first, head_last
end

--- `:[range]DyHistory`
---@param args { range: integer, line1: integer, line2: integer }
function M.command(args)
  if args.range > 0 then return M.show(args.line1, args.line2, 'Selection') end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local first, last, kind = M.definition_at(vim.api.nvim_get_current_buf(), row)
  if not first then
    return notify(
      'No definition under the cursor that tree-sitter knows: select the lines',
      vim.log.levels.WARN
    )
  end
  M.show(first, assert(last), (kind:gsub('_', ' ')))
end

return M
