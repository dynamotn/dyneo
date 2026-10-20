--- Who owns a file, as the repository's CODEOWNERS says
---
--- `:DyOwners` names the owners of the buffer's file and the line of
--- CODEOWNERS that makes them so; the statusline shows them too, read from a
--- cache that only a change of CODEOWNERS empties. `:DyOwners unowned` lists
--- every file git tracks that no line gives an owner, in the quickfix list.
---
--- GitHub's rules: the file is `.github/CODEOWNERS`, `CODEOWNERS` or
--- `docs/CODEOWNERS`, the first found; the last line that matches wins, and
--- one with no owners leaves the file unowned. GitLab's sections (`[Name]`,
--- `^[Optional]`, default owners after the header) are read too: each
--- section has its last match, and the owners of every section are summed.
local M = {}

local system = require('util.system')
local notify = require('util.notify').titled('Owners')

--- Where CODEOWNERS is looked for, in the order GitHub and GitLab look
M.FILES = {
  '.github/CODEOWNERS',
  'CODEOWNERS',
  'docs/CODEOWNERS',
  '.gitlab/CODEOWNERS',
}

--- Files listed as unowned at most
M.MAX_UNOWNED = 2000
--- Files matched against the rules before letting the editor breathe
M.CHUNK = 2000
--- Milliseconds of matching before letting the editor breathe
M.SLICE = 10
--- Milliseconds `git ls-files` may take
M.TIMEOUT = 30 * 1000
--- Milliseconds the statusline trusts what it found before looking again
M.RECHECK = 5000

---@class DyOwnersRule
---@field pattern string As written
---@field glob string Anchored, as `M.glob_match` reads it
---@field prefixes boolean Whether a directory it matches owns what is in it
---@field literal? string The path it names, when it has no wildcard
---@field finds? string[] Lua patterns it matches by, when it has wildcards
---@field anywhere? boolean Whether `literal` may sit at any depth
---@field needle string Text every path it matches holds
---@field owners string[]
---@field line integer 1-based, in CODEOWNERS
---@field section? string GitLab's

--- Whether glob `p` matches all of `s`: `*` and `?` stop at `/`, `**` does
--- not, `\` escapes the next character
---@param p string
---@param s string
---@return boolean
function M.glob_match(p, s)
  local memo = {}
  local function match(pi, si)
    local key = pi * 65536 + si
    if memo[key] ~= nil then return memo[key] end
    local result
    if pi > #p then
      result = si > #s
    elseif p:sub(pi, pi + 2) == '**/' then
      -- No directory, or any number of them
      result = match(pi + 3, si)
      if not result then
        for k = si, #s do
          if s:sub(k, k) == '/' and match(pi + 3, k + 1) then
            result = true
            break
          end
        end
      end
    elseif p:sub(pi, pi + 1) == '**' and pi + 1 == #p then
      -- At the end: everything below. Elsewhere `**` is a plain `*`, as
      -- gitignore reads it, and falls through
      result = true
    else
      local c = p:sub(pi, pi)
      if c == '*' then
        result = false
        for k = si, #s + 1 do
          if match(pi + 1, k) then
            result = true
            break
          end
          if s:sub(k, k) == '/' then break end
        end
      elseif c == '?' then
        result = si <= #s and s:sub(si, si) ~= '/' and match(pi + 1, si + 1)
      else
        if c == '\\' and pi < #p then
          pi = pi + 1
          c = p:sub(pi, pi)
        end
        result = s:sub(si, si) == c and match(pi + 1, si + 1)
      end
    end
    memo[key] = result
    return result
  end
  return match(1, 1)
end

--- A rule of `pattern`, read the way gitignore reads one -- or GitLab,
--- which anchors only a pattern that starts with `/`
---@param pattern string
---@param gitlab? boolean
---@return string glob
---@return boolean prefixes
local function compile(pattern, gitlab)
  local dir_only = pattern:sub(-1) == '/'
  if dir_only then pattern = pattern:sub(1, -2) end
  -- A `/` anywhere but at the end anchors it to the root
  local anchored = pattern:sub(1, 1) == '/'
    or (not gitlab and pattern:find('/', 1, true) ~= nil)
  pattern = pattern:gsub('^/', '')
  local glob = anchored and pattern or ('**/' .. pattern)
  -- `docs/*` owns the files right in `docs`, not those of its folders: a
  -- wildcard in the last part matches a file, not a directory to go into
  local last = pattern:match('[^/]*$')
  local prefixes = dir_only or not last:find('[*?]')
  if pattern == '**' or pattern:sub(-3) == '/**' then prefixes = true end
  return glob, prefixes
end

--- One part of a glob, with no `/**/` in it, as a Lua pattern: `*` (and a
--- `**` not beside a slash) within a folder, `?` one character of it
---@param part string
---@return string
local function part_pattern(part)
  local out, index = {}, 1
  while index <= #part do
    local c = part:sub(index, index)
    if c == '*' then
      while part:sub(index + 1, index + 1) == '*' do
        index = index + 1
      end
      table.insert(out, '[^/]*')
    elseif c == '?' then
      table.insert(out, '[^/]')
    else
      if c == '\\' and index < #part then
        index = index + 1
        c = part:sub(index, index)
      end
      table.insert(out, vim.pesc(c))
    end
    index = index + 1
  end
  return table.concat(out)
end

--- Most `/**/` a glob holds and still becomes Lua patterns: each is two
M.MAX_DEEP = 4

--- `glob` as Lua patterns, any of which it matches: a `/**/` in it -- no
--- folder or any -- is each way in turn, and a leading `**/` is what
--- `anywhere` says; nil past `M.MAX_DEEP` of them, for `M.glob_match` alone.
--- A trailing `/**` is left to the rule's `prefixes`.
---@param glob string
---@return string[]? patterns
---@return boolean anywhere
local function lua_patterns(glob)
  local anywhere = glob:sub(1, 3) == '**/'
  if anywhere then glob = glob:sub(4) end
  glob = glob:gsub('/%*%*$', '')
  if glob == '**' then return { '.*' }, false end
  local parts = vim.split(glob, '/**/', { plain = true })
  if #parts - 1 > M.MAX_DEEP then return nil, false end
  local patterns = { part_pattern(parts[1]) }
  for index = 2, #parts do
    local tail = part_pattern(parts[index])
    local grown = {}
    for _, head in ipairs(patterns) do
      table.insert(grown, head .. '/' .. tail)
      table.insert(grown, head .. '/.*/' .. tail)
    end
    patterns = grown
  end
  return patterns, anywhere
end

--- The rules of a CODEOWNERS file, GitLab's when it has a section or `gitlab`
--- says so
---@param lines string[]
---@param gitlab? boolean
---@return DyOwnersRule[]
function M.parse(lines, gitlab)
  if gitlab == nil then
    gitlab = false
    for _, line in ipairs(lines) do
      if vim.trim(line):match('^%^?%[[^%]]+%]') then
        gitlab = true
        break
      end
    end
  end
  local rules, section, defaults = {}, nil, {}
  for number, line in ipairs(lines) do
    local text = vim.trim((line:gsub('%s+#.*$', '')))
    local name, rest = text:match('^%^?%[([^%]]+)%](.*)$')
    if name then
      section = name
      -- `[Section][2] @owner`: the approvals, then the default owners
      rest = rest:gsub('^%[%d+%]', '')
      defaults = vim.split(vim.trim(rest), '%s+', { trimempty = true })
    elseif text ~= '' and not text:match('^#') then
      local pattern, owners_text = text:match('^(%S+)%s*(.*)$')
      -- `\ ` keeps a space in a pattern
      while pattern:sub(-1) == '\\' and owners_text ~= '' do
        local word, after = owners_text:match('^(%S+)%s*(.*)$')
        pattern, owners_text = pattern .. ' ' .. word, after
      end
      local owners = vim.split(owners_text, '%s+', { trimempty = true })
      if #owners == 0 and section then owners = defaults end
      local glob, prefixes = compile(pattern, gitlab)
      -- Most lines name a folder or a file outright: no glob to walk. Most
      -- others are a Lua pattern, read natively
      local plain = not glob:gsub('^%*%*/', ''):find('[*?\\]')
      local patterns, anywhere = lua_patterns(glob)
      -- Each pattern anchored the ways it may match: the whole path, or
      -- after any `/` of it; and with folders, anything below either
      local finds
      if not plain and patterns then
        finds = {}
        for _, lua in ipairs(patterns) do
          table.insert(finds, '^' .. lua .. '$')
          if prefixes then table.insert(finds, '^' .. lua .. '/') end
          if anywhere then
            table.insert(finds, '/' .. lua .. '$')
            if prefixes then table.insert(finds, '/' .. lua .. '/') end
          end
        end
      end
      -- The longest text it holds with no wildcard: a path without it is
      -- turned away by a plain search, before any pattern runs
      local needle = ''
      for run in glob:gsub('\\(.)', '%1'):gmatch('[^*?]+') do
        if #run > #needle then needle = run end
      end
      table.insert(rules, {
        pattern = pattern,
        glob = glob,
        prefixes = prefixes,
        literal = plain and glob:gsub('^%*%*/', '') or nil,
        finds = finds,
        needle = needle:gsub('^/', ''):gsub('/$', ''),
        anywhere = plain and glob:sub(1, 3) == '**/',
        owners = owners,
        line = number,
        section = section,
      })
    end
  end
  return rules
end

--- Whether `rule` matches `path`, relative to the root, or a folder of it
---@param rule DyOwnersRule
---@param path string
---@return boolean
function M.matches(rule, path)
  local literal = rule.literal
  if literal then
    if path == literal then return true end
    if rule.anywhere then
      if path:sub(-#literal - 1) == '/' .. literal then return true end
      if not rule.prefixes then return false end
      return path:sub(1, #literal + 1) == literal .. '/'
        or path:find('/' .. literal .. '/', 1, true) ~= nil
    end
    return rule.prefixes and path:sub(1, #literal + 1) == literal .. '/'
  end
  if rule.needle ~= '' and not path:find(rule.needle, 1, true) then
    return false
  end
  if rule.finds then
    for _, find in ipairs(rule.finds) do
      if path:find(find) then return true end
    end
    return false
  end
  if M.glob_match(rule.glob, path) then return true end
  -- What is in a folder it matches: one match of everything below
  return rule.prefixes == true and M.glob_match(rule.glob .. '/**', path)
end

--- The owners of `path`, and the rules that gave them: the last match, or
--- the last match of each GitLab section
---@param rules DyOwnersRule[]
---@param path string
---@return string[] owners
---@return DyOwnersRule[] matched
function M.owners(rules, path)
  local by_section, order = {}, {}
  for index = #rules, 1, -1 do
    local rule = rules[index]
    -- GitLab reads `[Docs]` and `[docs]` as one section
    local key = (rule.section or ''):lower()
    if by_section[key] == nil and M.matches(rule, path) then
      by_section[key] = rule
      table.insert(order, 1, key)
    end
  end
  local owners, seen, matched = {}, {}, {}
  for _, key in ipairs(order) do
    local rule = by_section[key]
    table.insert(matched, rule)
    for _, owner in ipairs(rule.owners) do
      if not seen[owner] then
        seen[owner] = true
        table.insert(owners, owner)
      end
    end
  end
  return owners, matched
end

---@class DyOwnersFile
---@field path string
---@field mtime integer
---@field rules DyOwnersRule[]

---@type table<string, DyOwnersFile|false>
local files = {}

--- The CODEOWNERS of the repository at `root`, parsed once per change of
--- the file; nil when it has none
---@param root string
---@return DyOwnersFile?
function M.codeowners(root)
  for _, name in ipairs(M.FILES) do
    local path = vim.fs.joinpath(root, name)
    local stat = vim.uv.fs_stat(path)
    if stat and stat.type == 'file' then
      local cached = files[root]
      if
        cached
        and cached.path == path
        and cached.mtime == stat.mtime.sec * 1e9 + stat.mtime.nsec
      then
        return cached
      end
      local ok, lines = pcall(vim.fn.readfile, path)
      local parsed = {
        path = path,
        mtime = stat.mtime.sec * 1e9 + stat.mtime.nsec,
        -- GitLab's own file reads as GitLab, sections or not
        rules = M.parse(
          ok and lines or {},
          name == '.gitlab/CODEOWNERS' or nil
        ),
      }
      files[root] = parsed
      return parsed
    end
  end
  files[root] = false
  return nil
end

--- The repository root of `file` and its path in it, links resolved
---@param file string
---@return string? root
---@return string? path
local function locate(file)
  local real = vim.uv.fs_realpath(file)
  if not real then return nil end
  local root = vim.fs.root(real, '.git')
  root = root and vim.uv.fs_realpath(root)
  if not root or real:sub(1, #root + 1) ~= root .. '/' then return nil end
  return root, real:sub(#root + 2)
end

--- The owners of `file`, and the line of CODEOWNERS that gave them
---@param file string
---@return string[]? owners Nil when the repository has no CODEOWNERS
---@return DyOwnersRule[]? matched
---@return string? codeowners
function M.for_file(file)
  local root, path = locate(file)
  if not root then return nil end
  local found = M.codeowners(root)
  if not found then return nil end
  local owners, matched = M.owners(found.rules, assert(path))
  return owners, matched, found.path
end

--- The owners of the buffer, for the statusline: empty when its repository
--- has no CODEOWNERS. Answered from the buffer's cache, which is looked at
--- again at most every `M.RECHECK` ms -- a stat of CODEOWNERS, and a parse
--- only when it changed.
---@param bufnr? integer
---@return string
function M.statusline(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].buftype ~= '' then return '' end
  local cached = vim.b[bufnr].dy_owners
  local now = vim.uv.now()
  if cached and now - cached.at < M.RECHECK then return cached.text end
  local name = vim.api.nvim_buf_get_name(bufnr)
  local text = ''
  if name ~= '' then
    local owners = M.for_file(name)
    if owners then
      text = #owners > 0 and table.concat(owners, ' ') or 'unowned'
    end
  end
  vim.b[bufnr].dy_owners = { at = now, text = text }
  return text
end

--- Say who owns the buffer's file, and why
function M.show()
  local file = vim.api.nvim_buf_get_name(0)
  local owners, matched, codeowners = M.for_file(file)
  if not owners then
    return notify(
      'No CODEOWNERS in the repository of this file',
      vim.log.levels.WARN
    )
  end
  local where = vim.fn.fnamemodify(assert(codeowners), ':~:.')
  if #owners == 0 then
    local rule = matched and matched[1]
    return notify(
      rule
          and ('Unowned: %s:%d `%s` names nobody'):format(
            where,
            rule.line,
            rule.pattern
          )
        or ('Unowned: no line of %s matches'):format(where),
      vim.log.levels.WARN
    )
  end
  local lines = { table.concat(owners, ' ') }
  for _, rule in ipairs(matched or {}) do
    table.insert(
      lines,
      ('%s:%d `%s`%s'):format(
        where,
        rule.line,
        rule.pattern,
        rule.section and (' [' .. rule.section .. ']') or ''
      )
    )
  end
  notify(table.concat(lines, '\n'))
end

--- List every file git tracks that no line of CODEOWNERS owns, a chunk at a
--- time so a large repository does not stall the editor
---@param on_done? fun() For the specs
function M.unowned(on_done)
  local function finish(msg, level)
    if msg then notify(msg, level) end
    if on_done then on_done() end
  end
  local file = vim.api.nvim_buf_get_name(0)
  local root = file ~= '' and locate(file)
    or (
      vim.fs.root(vim.uv.cwd() --[[@as string]], '.git')
    )
  if not root then
    return finish('Not in a git repository', vim.log.levels.WARN)
  end
  local found = M.codeowners(root)
  if not found then
    return finish(
      'No CODEOWNERS in ' .. vim.fn.fnamemodify(root, ':~'),
      vim.log.levels.WARN
    )
  end
  system.run(
    { 'git', '-C', root, 'ls-files', '-z' },
    { timeout = M.TIMEOUT, max_bytes = 64 * 1024 * 1024 },
    function(result)
      if result.code ~= 0 or result.cut then
        return finish(
          system.failure(result, 'git ls-files'),
          vim.log.levels.ERROR
        )
      end
      local paths = vim.split(result.stdout or '', '\0', { trimempty = true })
      local unowned, index = {}, 0
      local function step()
        -- At most `M.CHUNK` files, and no longer than `M.SLICE` ms, before
        -- the editor gets its turn: a rule file of hundreds of globs makes
        -- each file slow
        local started = vim.uv.hrtime()
        local stop = math.min(index + M.CHUNK, #paths)
        while index < stop do
          index = index + 1
          if #M.owners(found.rules, paths[index]) == 0 then
            table.insert(unowned, paths[index])
          end
          if (vim.uv.hrtime() - started) / 1e6 > M.SLICE then break end
        end
        if index < #paths then return vim.schedule(step) end
        local items = {}
        for i = 1, math.min(#unowned, M.MAX_UNOWNED) do
          table.insert(items, {
            filename = vim.fs.joinpath(root, unowned[i]),
            lnum = 1,
            text = 'no owner',
          })
        end
        vim.fn.setqflist({}, ' ', { title = 'Unowned files', items = items })
        if #unowned == 0 then
          return finish(('Every one of %d files has an owner'):format(#paths))
        end
        vim.cmd('botright copen')
        finish(
          ('%d of %d files have no owner%s'):format(
            #unowned,
            #paths,
            #unowned > M.MAX_UNOWNED
                and (', the first %d listed'):format(M.MAX_UNOWNED)
              or ''
          ),
          vim.log.levels.WARN
        )
      end
      step()
    end
  )
end

M.SUBCOMMANDS = { 'unowned' }

--- `:DyOwners [unowned]`
---@param args { fargs: string[] }
function M.command(args)
  local sub = args.fargs[1]
  if not sub then return M.show() end
  if sub == 'unowned' then return M.unowned() end
  notify('Unknown subcommand: ' .. sub, vim.log.levels.ERROR)
end

return M
