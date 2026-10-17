--- Markdown runbooks whose code blocks run where they are written
---
--- A runbook is a Markdown file of steps, each a fenced block of commands --
--- `kubectl`, `helm`, `psql`, a curl against a health endpoint. Running one
--- used to mean copying it into a terminal and its output back into the
--- notes. Here the block under the cursor runs as it is, from the directory
--- of the file, and what it printed lands right under it in an `output`
--- fence, replaced on the next run, so the file is the record of what was
--- done and what came back.
---
--- A file is asked about once before any of its blocks runs: Markdown is
--- also the README of a repository just cloned, whose blocks are somebody
--- else's commands. A block that deletes, destroys or reaches for root asks
--- again: a runbook is read in a hurry, and `<localleader>r` is a short key.
local M = {}

local notify = require('util.notify').titled('Runbook')

--- The command a block of each language runs with, its code appended
---@type table<string, string[]>
M.RUNNERS = {
  sh = { 'sh', '-c' },
  shell = { 'bash', '-c' },
  bash = { 'bash', '-c' },
  console = { 'bash', '-c' },
  zsh = { 'zsh', '-c' },
  fish = { 'fish', '-c' },
  python = { 'python3', '-c' },
  py = { 'python3', '-c' },
  javascript = { 'node', '-e' },
  js = { 'node', '-e' },
}

--- Milliseconds a block may run before it is stopped
M.TIMEOUT = 5 * 60 * 1000

--- Most bytes of output a run keeps, both streams together. Past it the run
--- is stopped: `yes` or `kubectl logs -f` would otherwise fill memory, and
--- then the Markdown file, for the whole of `M.TIMEOUT`.
M.MAX_OUTPUT = 1024 * 1024

--- What a block is asked about before it runs, by Lua pattern, matched
--- against each line in lower case. Flags may come before the verb
--- (`kubectl -n prod delete`), so the verb is looked for anywhere after the
--- command on its line.
M.DANGEROUS = {
  '%f[%w]sudo%f[%W]',
  '%f[%w]doas%f[%W]',
  '%f[%w]rm%f[%W].-%s%-%a*[rf]',
  '%f[%w]rm%f[%W].-%-%-recursive',
  '%f[%w]rm%f[%W].-%-%-force',
  '%f[%w]mkfs',
  '%f[%w]dd%f[%W].-of=',
  '%f[%w]find%f[%W].-%-delete',
  'kubectl%f[%W].-%f[%w]delete%f[%W]',
  'kubectl%f[%W].-%f[%w]drain%f[%W]',
  'kubectl%f[%W].-%-%-replicas[=%s]+0%f[%D]',
  'helm%f[%W].-%f[%w]uninstall%f[%W]',
  'helm%f[%W].-%f[%w]delete%f[%W]',
  '%f[%w]destroy%f[%W]',
  '%f[%w]apply%f[%W].-%-destroy',
  'git%f[%W].-%f[%w]push%f[%W].-%-%-force',
  'git%f[%W].-%f[%w]push%f[%W].-%s%-f%f[%W]',
  'git%f[%W].-%f[%w]push%f[%W].-%s%+',
  'git%f[%W].-%f[%w]reset%f[%W].-%-%-hard',
  'git%f[%W].-%f[%w]clean%f[%W].-%s%-%a*f',
  '%f[%w]drop%s+table',
  '%f[%w]drop%s+database',
  '%f[%w]drop%s+schema',
  '%f[%w]truncate%f[%W]',
  '%f[%w]delete%s+from%f[%W]',
}

---@class DyRunbookBlock
---@field open integer Line of the opening fence, 1-based
---@field close integer Line of the closing fence
---@field lang string
---@field code string[]
---@field indent string

--- Every closed fenced block of `lines`, fences included, in order
---
--- One pass over the lines: `blocks` and `block_at` both read from it, so
--- running each block of a long runbook does not read it again per block.
---@param lines string[]
---@return DyRunbookBlock[]
function M.fences(lines)
  local found = {}
  local open, fence, indent, lang
  for index, line in ipairs(lines) do
    if not open then
      local i, f, info = line:match('^(%s*)(```+)%s*([^%s`]*)')
      -- ```js``` opening a prose line is inline code, not a fence: a
      -- backtick fence's info string has no backtick
      if f and line:sub(#i + #f + 1):find('`', 1, true) then f = nil end
      if not f then
        i, f, info = line:match('^(%s*)(~~~+)%s*(%S*)')
      end
      if f then
        open, fence, indent, lang = index, f, i, info:lower()
      end
    else
      local f = line:match('^%s*([`~]+)%s*$')
      if f and f:sub(1, 1) == fence:sub(1, 1) and #f >= #fence then
        table.insert(found, {
          open = open,
          close = index,
          lang = lang,
          code = vim.list_slice(lines, open + 1, index - 1),
          indent = indent,
        })
        open = nil
      end
    end
  end
  return found
end

--- The fenced block `row` is in, fences included
---@param lines string[]
---@param row integer 1-based
---@return DyRunbookBlock?
function M.block_at(lines, row)
  for _, block in ipairs(M.fences(lines)) do
    if row < block.open then return nil end
    if row <= block.close then return block end
  end
  return nil
end

--- Every fenced block of `lines` whose language has a runner, in order
---@param lines string[]
---@return DyRunbookBlock[]
function M.blocks(lines)
  return vim.tbl_filter(
    function(block) return M.RUNNERS[block.lang] ~= nil end,
    M.fences(lines)
  )
end

--- The code of `block` as it runs: a `console` block keeps only its `$ `
--- lines, without the prompt, since the rest is the output it once printed
---@param block DyRunbookBlock
---@return string
function M.code_of(block)
  -- A fence inside a list item is indented, and Python takes that indent
  -- for an `unexpected indent`
  local indent = block.indent or ''
  local code = vim.tbl_map(
    function(line)
      return line:sub(1, #indent) == indent and line:sub(#indent + 1) or line
    end,
    block.code
  )
  if block.lang ~= 'console' then return table.concat(code, '\n') end
  local commands = {}
  for _, line in ipairs(code) do
    local command = line:match('^%s*%$%s?(.*)$')
    if command then table.insert(commands, command) end
  end
  return table.concat(commands, '\n')
end

--- The inputs `code` asks for, `${input:name}`, each once, in order
---
--- Spelled so it can be nothing else: `${VAR}` is the shell's, `{{ }}` a
--- template's, and `<<NAME` a heredoc.
---@param code string
---@return string[]
function M.inputs(code)
  local names, seen = {}, {}
  for name in code:gmatch('%${input:([%w_%-%.]+)}') do
    if not seen[name] then
      seen[name] = true
      table.insert(names, name)
    end
  end
  return names
end

--- `code` with each input replaced by its value, as typed
---@param code string
---@param values table<string, string>
---@return string
function M.expand(code, values)
  return (
    code:gsub('%${input:([%w_%-%.]+)}', function(name) return values[name] end)
  )
end

--- The environment variable an input is handed over in: `RUNBOOK_` and its
--- name in upper case, with anything a variable name cannot hold made `_`
---@param name string
---@return string
function M.env_name(name) return 'RUNBOOK_' .. name:upper():gsub('[^%w]', '_') end

--- Where each `${input:…}` of `code` sits, by the quoting a shell, Python or
--- JavaScript reads there, keyed by the offset it starts at
---
--- A context is `none` (bare code), `single`, `double`, `heredoc` (a body
--- the shell expands), `literal` (one it does not), `template` (a JS
--- template literal) or `fstring`; a Python or JS string also gives where
--- the literal opens and closes, its quote and prefix, so it can be rebuilt.
---@class DyRunbookSpot
---@field context string
---@field quote? string
---@field prefix? string
---@field from? integer Offset of the literal's first character, prefix included
---@field to? integer Offset of its last character

---@param code string
---@param family 'shell'|'python'|'js'
---@return table<integer, DyRunbookSpot>
local function spots(code, family)
  local found = {}
  local i, n = 1, #code
  -- Shell: a stack of frames, since `$(` opens a fresh quoting context
  -- inside a double-quoted string
  local stack = { { state = 'none', depth = 0 } }
  local heredocs, heredoc = {}, nil
  -- Python and JS: the string being read
  local str
  while i <= n do
    local frame = stack[#stack]
    if code:find('^%${input:[%w_%-%.]+}', i) then
      local spot
      if family == 'shell' then
        spot = {
          context = heredoc and (heredoc.quoted and 'literal' or 'heredoc')
            or frame.state,
        }
      elseif str then
        spot = {
          context = str.kind,
          quote = str.quote,
          prefix = str.prefix,
          from = str.from,
        }
        table.insert(str.spots, spot)
      else
        spot = { context = 'none' }
      end
      found[i] = spot
      i = code:find('}', i, true) + 1
    elseif family == 'shell' and heredoc then
      local eol = code:find('\n', i, true) or n + 1
      local line = code:sub(i, eol - 1)
      local bol = i == 1 or code:sub(i - 1, i - 1) == '\n'
      if
        bol
        and (heredoc.strip and line:gsub('^\t+', '') or line) == heredoc.word
      then
        heredoc = table.remove(heredocs, 1)
        i = eol + 1
      else
        -- A placeholder within the line is found on the next pass
        local at = line:find('${input:', 1, true)
        i = at and i + at - 1 or eol + 1
      end
    elseif family == 'shell' then
      local c = code:sub(i, i)
      if frame.state == 'single' then
        if c == "'" then frame.state = 'none' end
        i = i + 1
      elseif c == '\\' then
        i = i + 2
      elseif frame.state == 'double' then
        if c == '"' then
          frame.state = 'none'
        elseif code:sub(i, i + 2) == '$((' then
          table.insert(stack, { state = 'none', depth = 2, arith = true })
          i = i + 2
        elseif code:sub(i, i + 1) == '$(' then
          table.insert(stack, { state = 'none', depth = 1 })
          i = i + 1
        end
        i = i + 1
      elseif c == "'" then
        frame.state = 'single'
        i = i + 1
      elseif c == '"' then
        frame.state = 'double'
        i = i + 1
      elseif c == '#' and (i == 1 or code:sub(i - 1, i - 1):match('%s')) then
        i = code:find('\n', i, true) or n + 1
      elseif code:sub(i, i + 2) == '<<<' then
        -- A here-string: the word after it is an argument, not a delimiter
        i = i + 3
      elseif code:sub(i, i + 2) == '$((' or code:sub(i, i + 1) == '((' then
        -- Arithmetic, where `<<` is a shift
        table.insert(stack, { state = 'none', depth = 2, arith = true })
        i = i + (c == '$' and 3 or 2)
      elseif code:sub(i, i + 1) == '<<' and not frame.arith then
        local strip, quote, word, rest =
          code:match('^<<(%-?)%s*([\'"]?)([%w_]+)[\'"]?()', i)
        if word then
          table.insert(heredocs, {
            word = word,
            strip = strip == '-',
            quoted = quote ~= '',
          })
          i = rest
        else
          i = i + 2
        end
      elseif c == '\n' and #heredocs > 0 then
        heredoc = table.remove(heredocs, 1)
        i = i + 1
      elseif c == '(' and #stack > 1 then
        frame.depth = frame.depth + 1
        i = i + 1
      elseif c == ')' and #stack > 1 then
        frame.depth = frame.depth - 1
        if frame.depth == 0 then table.remove(stack) end
        i = i + 1
      else
        i = i + 1
      end
    elseif str then
      local c = code:sub(i, i)
      if c == '\\' then
        i = i + 2
      elseif code:sub(i, i + #str.quote - 1) == str.quote then
        for _, spot in ipairs(str.spots) do
          spot.to = i + #str.quote - 1
        end
        i = i + #str.quote
        str = nil
      elseif c == '\n' and #str.quote == 1 and str.kind ~= 'template' then
        str = nil
        i = i + 1
      else
        i = i + 1
      end
    else
      local c = code:sub(i, i)
      if
        (family == 'python' and c == '#')
        or (family == 'js' and code:sub(i, i + 1) == '//')
      then
        i = code:find('\n', i, true) or n + 1
      elseif family == 'js' and code:sub(i, i + 1) == '/*' then
        local close = code:find('*/', i + 2, true)
        i = close and close + 2 or n + 1
      elseif c == '"' or c == "'" or (family == 'js' and c == '`') then
        local quote = c
        if family == 'python' and code:sub(i, i + 2) == c:rep(3) then
          quote = c:rep(3)
        end
        local prefix = ''
        if family == 'python' then
          prefix = code:sub(1, i - 1):match('([rRbBfFuU]?[rRbBfFuU]?)$')
          -- `xr"…"` is a name followed by a string, not a prefix
          if prefix ~= '' and code:sub(1, i - 1 - #prefix):match('[%w_]$') then
            prefix = ''
          end
        end
        local kind = c == '`' and 'template'
          or prefix:lower():find('f') and 'fstring'
          or 'string'
        str = {
          kind = kind,
          quote = quote,
          prefix = prefix,
          from = i - #prefix,
          spots = {},
        }
        i = i + #quote
      else
        i = i + 1
      end
    end
  end
  return found
end

--- Which quoting a language reads its blocks with
---@type table<string, 'shell'|'python'|'js'>
local FAMILIES = {
  sh = 'shell',
  shell = 'shell',
  bash = 'shell',
  console = 'shell',
  zsh = 'shell',
  fish = 'shell',
  python = 'python',
  py = 'python',
  javascript = 'js',
  js = 'js',
}

--- `code` with each input read from the environment, and that environment
---
--- A typed value never becomes code: in `ps` it would show to every user
--- of the machine, and a quote or a `$(…)` in it would be run. Each input
--- is the variable `M.env_name` gives, read as one word where it stands --
--- bare, inside quotes, in a heredoc, in a Python or JS string -- so
--- `${input:flags}` is one argument, never split. Only a heredoc the shell
--- does not expand (`<<'EOF'`) gets the value as text, since nothing there
--- reads a variable; those inputs are named in the third result, so a
--- caller can refuse to write a secret into the code.
---@param code string
---@param lang string
---@param values table<string, string>
---@return string code
---@return table<string, string> env
---@return string[] literal Inputs written into the code as text
---@return string? problem Why the code cannot be run with its inputs
function M.bind(code, lang, values)
  local family = FAMILIES[lang] or 'shell'
  local env, owner, literal = {}, {}, {}
  local function var(name)
    local base = M.env_name(name)
    local var, n = base, 1
    while owner[var] and owner[var] ~= name do
      n = n + 1
      var = base .. '_' .. n
    end
    owner[var], env[var] = name, values[name]
    return var
  end
  -- Named in the order they appear, so a clash is numbered the same way
  -- every run
  for _, name in ipairs(M.inputs(code)) do
    var(name)
  end
  ---@param name string
  ---@return string
  local function read(name)
    local v = var(name)
    if family == 'python' then
      return ("__import__('os').environ['%s']"):format(v)
    end
    return ("process.env['%s']"):format(v)
  end
  -- Non-overlapping `{ from, to, text }`, applied from the end
  local edits, rebuilt, problem = {}, {}, nil
  for at, spot in pairs(spots(code, family)) do
    local name, e = code:match('^%${input:([%w_%-%.]+)}()', at)
    if spot.context == 'string' and spot.to and not rebuilt[spot.from] then
      rebuilt[spot.from] = true
      local open = #spot.prefix + #spot.quote
      local body = code:sub(spot.from + open, spot.to - #spot.quote)
      local prefix = spot.prefix:lower()
      local before = code:sub(1, spot.from - 1):match('(%S?)%s*$')
      local after = code:sub(spot.to + 1):match('^%s*(%S?)')
      if family == 'python' and not prefix:find('b') then
        -- Python: an f-string, still a literal, so one next to another
        -- (`'a' 'b${input:x}'`) is joined to it as before
        local pieces, last = {}, 1
        local function lit(text)
          -- `\N{NAME}` is an escape, not a field, outside a raw string
          if prefix:find('r') then return (text:gsub('[{}]', '%0%0')) end
          local out, from = {}, 1
          for s, f in text:gmatch('()\\N{[^}]*}()') do
            table.insert(out, (text:sub(from, s - 1):gsub('[{}]', '%0%0')))
            table.insert(out, text:sub(s, f - 1))
            from = f
          end
          table.insert(out, (text:sub(from):gsub('[{}]', '%0%0')))
          return table.concat(out)
        end
        for s, n, f in body:gmatch('()%${input:([%w_%-%.]+)}()') do
          table.insert(pieces, lit(body:sub(last, s - 1)))
          local field = '{' .. read(n) .. '}'
          -- The other quote than the string's: Python before 3.12 allows
          -- no reuse of it inside
          if spot.quote:sub(1, 1) == "'" then field = field:gsub("'", '"') end
          table.insert(pieces, field)
          last = f
        end
        table.insert(pieces, lit(body:sub(last)))
        local quote = spot.quote
        local fprefix = prefix:find('r') and 'rf' or 'f'
        table.insert(edits, {
          spot.from,
          spot.to,
          fprefix .. quote .. table.concat(pieces) .. quote,
        })
      elseif
        family == 'python'
        and (
          before:match('[\'"]')
          or code:sub(spot.to + 1):match('^%s*[rRbBfFuU]*[\'"]')
        )
      then
        -- Bytes have no f-string, and a sum next to another literal
        -- would be called by it
        problem = problem
          or 'a bytes literal next to another literal cannot hold '
            .. ('`${input:%s}`'):format(body:match('%${input:([%w_%-%.]+)}'))
      else
        -- A JS string or Python bytes holding an input is rebuilt whole,
        -- as concatenated pieces in parentheses
        local lit = function(text)
          return spot.prefix .. spot.quote .. text .. spot.quote
        end
        local pieces, last = {}, 1
        for s, n, f in body:gmatch('()%${input:([%w_%-%.]+)}()') do
          if s > last then table.insert(pieces, lit(body:sub(last, s - 1))) end
          local bytes = family == 'python' and '.encode()' or ''
          table.insert(pieces, read(n) .. bytes)
          last = f
        end
        if last <= #body then table.insert(pieces, lit(body:sub(last))) end
        local sum = table.concat(pieces, ' + ')
        -- A quoted key of a JS object (`{ 'k${input:x}': 1 }`) becomes
        -- a computed one, the only kind an expression may name
        if family == 'js' and before:match('^[{,]$') and after == ':' then
          sum = '[' .. sum .. ']'
        else
          sum = '(' .. sum .. ')'
        end
        table.insert(edits, { spot.from, spot.to, sum })
      end
    elseif spot.context == 'string' and spot.to then
      -- The rest of a string already rebuilt
    else
      local text
      local v = family == 'shell' and var(name)
      if spot.context == 'fstring' then
        -- The other quote than the string's: Python before 3.12 allows
        -- no reuse of it inside
        text = '{' .. read(name) .. '}'
        if spot.quote:sub(1, 1) == "'" then text = text:gsub("'", '"') end
      elseif spot.context == 'template' then
        text = '${' .. read(name) .. '}'
      elseif family ~= 'shell' then
        text = read(name)
      elseif spot.context == 'literal' then
        text = values[name]
        if not vim.tbl_contains(literal, name) then
          table.insert(literal, name)
        end
      elseif lang == 'fish' then
        -- Fish never splits a variable; a quote ends a string around it
        text = spot.context == 'single' and ([['"$%s"']]):format(v)
          or ('"$%s"'):format(v)
      elseif spot.context == 'double' or spot.context == 'heredoc' then
        text = ('${%s}'):format(v)
      elseif spot.context == 'single' then
        text = ([['"${%s}"']]):format(v)
      else
        text = ('"${%s}"'):format(v)
      end
      table.insert(edits, { at, e - 1, text })
    end
  end
  table.sort(edits, function(x, y) return x[1] > y[1] end)
  for _, edit in ipairs(edits) do
    code = code:sub(1, edit[1] - 1) .. edit[3] .. code:sub(edit[2] + 1)
  end
  table.sort(literal)
  return code, env, literal, problem
end

--- `text` with every value of `secrets` replaced by `***`
---@param text string
---@param secrets string[]
---@return string
function M.redact(text, secrets)
  for _, secret in ipairs(secrets) do
    if secret ~= '' then
      text = text:gsub(vim.pesc(secret), function() return '***' end)
    end
  end
  return text
end

--- Whether an input named `name` is typed hidden and kept out of the output
---@param name string
---@return boolean
function M.is_hidden(name)
  local lower = name:lower()
  -- `db_pass`, `ssh_key`: shorter than any key pattern of `util.sensitive`
  return require('util.sensitive').is_secret_key(name)
    or lower:find('pass') ~= nil
    or lower:find('key') ~= nil
end

--- Hand `on_values` a value for each of `names`: kept from earlier in this
--- buffer, else asked for. Nil when one is not given.
---@param bufnr integer
---@param names string[]
---@param on_values fun(values: table<string, string>?)
function M.ask_inputs(bufnr, names, on_values)
  local values = vim.b[bufnr].dy_runbook_inputs or {}
  local index = 0
  local function next_input()
    index = index + 1
    local name = names[index]
    if not name then return on_values(values) end
    if values[name] ~= nil then return next_input() end
    -- `vim.ui.input` (Snacks) and `input()` both keep a history on disk;
    -- `inputsecret` keeps none, and shows nothing while it is typed
    local hidden = M.is_hidden(name)
    local function got(value)
      if value == nil then return on_values(nil) end
      values[name] = value
      -- `vim.b` hands out copies: the whole table goes back
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.b[bufnr].dy_runbook_inputs = values
      end
      next_input()
    end
    if hidden then
      -- Empty on `<Esc>`, as on nothing typed: both end the run
      local typed = vim.fn.inputsecret(name .. ': ')
      got(typed ~= '' and typed or nil)
    else
      vim.ui.input({ prompt = name .. ': ' }, got)
    end
  end
  next_input()
end

--- The first line of `code` a dangerous pattern matches, trimmed, or nil
---@param code string
---@return string?
function M.danger(code)
  -- `kubectl -n prod \` with `delete deploy api` on the next line is one
  -- command, and has to be matched as one
  code = code:gsub('\\\r?\n%s*', ' ')
  for _, line in ipairs(vim.split(code, '\n', { plain = true })) do
    local lower = line:lower()
    for _, pattern in ipairs(M.DANGEROUS) do
      if lower:find(pattern) then return vim.trim(line) end
    end
  end
end

--- Whether the blocks of `bufnr` may run: a file of its own, which can take
--- the output, and that was agreed to once for this session
---@param bufnr integer
---@return boolean
function M.allowed(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == '' or vim.bo[bufnr].buftype ~= '' then
    notify('Only the blocks of a Markdown file run', vim.log.levels.WARN)
    return false
  end
  if not vim.bo[bufnr].modifiable then
    notify('The buffer cannot take the output', vim.log.levels.WARN)
    return false
  end
  if vim.b[bufnr].dy_runbook_allowed then return true end
  local answer = vim.fn.confirm(
    ('Run the code blocks of %s?\nThey run as you, from its directory.'):format(
      vim.fn.fnamemodify(name, ':~:.')
    ),
    '&Run\n&Cancel',
    2
  )
  if answer ~= 1 then return false end
  vim.b[bufnr].dy_runbook_allowed = true
  return true
end

--- The `output` fence that follows the block closing at `close`, if any:
--- right after it, or after one blank line
---@param lines string[]
---@param close integer
---@return integer? first
---@return integer? last
function M.output_after(lines, close)
  local first = close + 1
  if lines[first] and vim.trim(lines[first]) == '' then first = first + 1 end
  local fence = lines[first] and lines[first]:match('^%s*(```+)%s*output%s*$')
  if not fence then return nil end
  for index = first + 1, #lines do
    local f = lines[index]:match('^%s*(`+)%s*$')
    if f and #f >= #fence then return close + 1, index end
  end
  return nil
end

--- The lines of an `output` fence holding `output`, indented like its block
---
--- The fence is longer than any run of backticks the output starts a line
--- with, so a command printing Markdown cannot close it early.
---@param output string[]
---@param indent string
---@param info? string The info string of the fence, `output` unless given
---@return string[]
function M.fence(output, indent, info)
  local longest = 2
  for _, line in ipairs(output) do
    local run = line:match('^%s*(`+)')
    if run then longest = math.max(longest, #run) end
  end
  local fence = ('`'):rep(longest + 1)
  local lines = { '', indent .. fence .. (info or 'output') }
  for _, line in ipairs(output) do
    table.insert(lines, line == '' and '' or indent .. line)
  end
  table.insert(lines, indent .. fence)
  return lines
end

--- What a finished run shows: its output, then how it ended unless well
---@param result vim.SystemCompleted|{ cut?: boolean, timed_out?: boolean }
---@return string[]
function M.render(result)
  -- stdout, then stderr: `vim.system` keeps them apart, so how they
  -- interleaved is lost, but neither is
  local output = {}
  for _, stream in ipairs({ result.stdout or '', result.stderr or '' }) do
    local text = stream:gsub('\n+$', '')
    if text ~= '' then
      vim.list_extend(output, vim.split(text, '\n', { plain = true }))
    end
  end
  if result.cut then
    table.insert(
      output,
      ('[output cut at %d KiB, the run was stopped]'):format(
        M.MAX_OUTPUT / 1024
      )
    )
  elseif result.timed_out then
    -- The deadline stops it with a signal too: say which stop it was
    table.insert(
      output,
      ('[stopped after %d min, the run took too long]'):format(
        M.TIMEOUT / 60000
      )
    )
  elseif result.signal and result.signal ~= 0 then
    table.insert(output, ('[stopped: signal %d]'):format(result.signal))
  elseif result.code ~= 0 then
    table.insert(output, ('[exit %d]'):format(result.code))
  end
  if #output == 0 then output = { '[no output]' } end
  return output
end

local ns = vim.api.nvim_create_namespace('dy_runbook')

-- Defined further down, next to what they belong with
local start, record

--- The processes running per buffer, to stop them
---@type table<integer, vim.SystemObj[]>
local running = {}

--- Stop `process` and whatever it started: a block runs in a session of its
--- own (`detach`), so its whole process group is signalled. Signalling the
--- shell alone leaves `kubectl logs -f` running, holding the pipes open, and
--- the run never ends.
---@param process vim.SystemObj
local function kill(process)
  if not process.pid then return end
  -- `vim.uv.kill` returns an error rather than raising one
  if not vim.uv.kill(-process.pid, 'sigterm') then
    pcall(process.kill, process, 'sigterm')
  end
end

--- Stop every block a buffer is running
---@param bufnr integer
local function stop_buffer(bufnr)
  for _, process in ipairs(running[bufnr] or {}) do
    kill(process)
  end
end

-- A buffer wiped, or the editor quitting, takes its runs along
vim.api.nvim_create_autocmd({ 'BufWipeout', 'VimLeavePre' }, {
  group = vim.api.nvim_create_augroup('dy_runbook', { clear = true }),
  callback = function(event)
    if event.event == 'VimLeavePre' then
      for bufnr in pairs(running) do
        stop_buffer(bufnr)
      end
    else
      stop_buffer(event.buf)
      running[event.buf] = nil
    end
  end,
})

--- Put `output` under the block whose closing fence the extmark `mark`
--- follows, replacing what an earlier run left there
---@param bufnr integer
---@param mark integer
---@param indent string
---@param output string[]
local function place(bufnr, mark, indent, output)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  local position = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, mark, {})
  vim.api.nvim_buf_del_extmark(bufnr, ns, mark)
  if not position[1] then return end
  local close = position[1] + 1
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local first, last = M.output_after(lines, close)
  local start, finish = close, close
  if first and last then
    start, finish = first - 1, last
  end
  vim.api.nvim_buf_set_lines(
    bufnr,
    start,
    finish,
    false,
    M.fence(output, indent)
  )
end

---@class DyRunbookRun
---@field line integer Where the block opens
---@field lang string
---@field code string As written, `${input:…}` left in
---@field output string[] As `M.render` made it
---@field code_status integer
---@field signal? integer
---@field cut? boolean
---@field timed_out? boolean
---@field started integer Seconds since the epoch
---@field ms integer How long it ran

--- One run, as the record of a session has it
---@param run DyRunbookRun
---@return string[]
function M.log_entry(run)
  local how = run.cut and 'output cut'
    or run.timed_out and 'timed out'
    or ((run.signal or 0) ~= 0 and ('signal %d'):format(run.signal))
    or ('exit %d'):format(run.code_status)
  local lines = {
    ('## %s line %d (%s): %s, %.1f s'):format(
      os.date('%H:%M:%S', run.started),
      run.line,
      run.lang,
      how,
      run.ms / 1000
    ),
  }
  vim.list_extend(
    lines,
    M.fence(vim.split(run.code, '\n', { plain = true }), '', run.lang)
  )
  vim.list_extend(lines, M.fence(run.output, ''))
  table.insert(lines, '')
  return lines
end

--- Append `lines` to the file at `path`, made only its owner can read
---@param path string
---@param lines string[]
---@return boolean
local function append(path, lines)
  local fd = vim.uv.fs_open(path, 'a', tonumber('600', 8))
  if not fd then return false end
  local ok = vim.uv.fs_write(fd, table.concat(lines, '\n') .. '\n') ~= nil
  vim.uv.fs_close(fd)
  return ok
end

--- Add `run` to the record of `bufnr`, when it is being recorded
---@param bufnr integer
---@param run DyRunbookRun
record = function(bufnr, run)
  local path = vim.api.nvim_buf_is_valid(bufnr) and vim.b[bufnr].dy_runbook_log
  if not path then return end
  if not append(path, M.log_entry(run)) then
    notify('Could not add to the record ' .. path, vim.log.levels.ERROR)
  end
end

--- Where the record of a session of `file` started at `now` goes
---@param file string
---@param now integer
---@return string
function M.log_path(file, now)
  return vim.fs.joinpath(
    vim.fn.stdpath('state') --[[@as string]],
    'dyneo',
    'runbook',
    ('%s-%s.md'):format(
      vim.fn.fnamemodify(file, ':t:r'),
      os.date('%Y%m%d-%H%M%S', now)
    )
  )
end

--- Start recording every run of the buffer, or stop
function M.record()
  local bufnr = vim.api.nvim_get_current_buf()
  local path = vim.b[bufnr].dy_runbook_log
  if path then
    vim.b[bufnr].dy_runbook_log = nil
    return notify(
      'Recording stopped: ' .. vim.fn.fnamemodify(path, ':~'),
      vim.log.levels.INFO
    )
  end
  local file = vim.api.nvim_buf_get_name(bufnr)
  if file == '' then
    return notify(
      'Only the runs of a Markdown file are recorded',
      vim.log.levels.WARN
    )
  end
  local now = os.time()
  path = M.log_path(file, now)
  vim.fn.mkdir(vim.fs.dirname(path), 'p', tonumber('700', 8))
  local header = {
    '# ' .. vim.fn.fnamemodify(file, ':~'),
    '',
    'Recorded from ' .. os.date('%Y-%m-%d %H:%M:%S', now),
    '',
  }
  if not append(path, header) then
    return notify('Could not start the record ' .. path, vim.log.levels.ERROR)
  end
  vim.b[bufnr].dy_runbook_log = path
  notify('Recording to ' .. vim.fn.fnamemodify(path, ':~'), vim.log.levels.INFO)
end

--- Forget the inputs typed for the buffer, so the next run asks again
function M.forget_inputs()
  vim.b[vim.api.nvim_get_current_buf()].dy_runbook_inputs = nil
  notify('Inputs forgotten', vim.log.levels.INFO)
end

--- Run `block` of `bufnr`, and call `on_done` with whether it went well
---@param bufnr integer
---@param block DyRunbookBlock
---@param on_done? fun(ok: boolean)
function M.run_block(bufnr, block, on_done)
  on_done = on_done or function() end
  local runner = M.RUNNERS[block.lang]
  if not runner then
    notify(
      ('No runner for a `%s` block'):format(block.lang),
      vim.log.levels.WARN
    )
    return on_done(false)
  end
  if vim.fn.executable(runner[1]) ~= 1 then
    notify(runner[1] .. ' is not installed', vim.log.levels.ERROR)
    return on_done(false)
  end
  if not M.allowed(bufnr) then return on_done(false) end

  local code = M.code_of(block)
  M.ask_inputs(bufnr, M.inputs(code), function(values)
    -- The buffer may have gone while an input was being typed
    if not values or not vim.api.nvim_buf_is_valid(bufnr) then
      return on_done(false)
    end
    local bound, env, literal, problem = M.bind(code, block.lang, values)
    if problem then
      notify('Not run: ' .. problem, vim.log.levels.ERROR)
      return on_done(false)
    end
    for _, name in ipairs(literal) do
      -- Written into the code, a secret would show in `ps`; a line break
      -- could end the heredoc and run the rest
      local why = M.is_hidden(name) and 'is a secret'
        or values[name]:find('[\r\n]') and 'holds a line break'
      if why then
        notify(
          (
            "`%s` %s, and a quoted heredoc (`<<'EOF'`) would hold it as "
            .. 'text: use `<<EOF` or pass it otherwise'
          ):format(name, why),
          vim.log.levels.ERROR
        )
        return on_done(false)
      end
    end
    local secrets = {}
    for name, value in pairs(values) do
      if M.is_hidden(name) then table.insert(secrets, value) end
    end
    -- Longest first, so one secret holding another is hidden whole
    table.sort(secrets, function(a, b) return #a > #b end)
    start(bufnr, block, runner, {
      code = bound,
      env = env,
      -- What is checked is what runs, values filled in
      checked = M.expand(code, values),
      -- The record keeps the code as written, so no typed value -- a
      -- password, a token -- is written to disk
      written = code,
      secrets = secrets,
    }, on_done)
  end)
end

---@class DyRunbookCode
---@field code string As it runs, inputs read from `env`
---@field env table<string, string>
---@field checked string Inputs filled in, what the danger check reads
---@field written string As written, what the record keeps
---@field secrets string[] The values of hidden inputs, kept out of the output

--- Run `code` of `block`, once its inputs are in
---@param bufnr integer
---@param block DyRunbookBlock
---@param runner string[]
---@param code DyRunbookCode
---@param on_done fun(ok: boolean)
start = function(bufnr, block, runner, code, on_done)
  local danger = M.danger(code.checked)
  if danger then
    local answer = vim.fn.confirm(
      ('This block runs `%s`. Run it?'):format(danger),
      '&Run\n&Cancel',
      2
    )
    if answer ~= 1 then return on_done(false) end
  end

  local started, clock = os.time(), vim.uv.hrtime()
  local mark = vim.api.nvim_buf_set_extmark(bufnr, ns, block.close - 1, 0, {
    virt_text = { { ' running…', 'DiagnosticInfo' } },
    virt_text_pos = 'eol',
  })
  local name = vim.api.nvim_buf_get_name(bufnr)
  local cwd = name ~= '' and vim.fs.dirname(name) or vim.uv.cwd()
  local command = vim.list_extend(vim.deepcopy(runner), { code.code })

  -- Declared ahead, so the exit callback can find itself in `running`
  ---@type vim.SystemObj?
  local process
  -- Read as it comes, so a run printing without end is stopped at
  -- `M.MAX_OUTPUT` rather than kept whole; a session of its own, so
  -- stopping it reaches what it started
  process = require('util.system').run(command, {
    cwd = cwd,
    env = code.env,
    detach = true,
    timeout = M.TIMEOUT,
    max_bytes = M.MAX_OUTPUT,
  }, function(result)
    -- Never started: said below, where `process` comes back nil
    if result.missing then return end
    running[bufnr] = vim.tbl_filter(
      -- `vim.SystemCompleted` carries no pid: compare the object itself
      function(p) return p ~= process end,
      running[bufnr] or {}
    )
    -- What a command echoes of a hidden input lands in the Markdown file
    -- and the record otherwise
    for _, stream in ipairs({ 'stdout', 'stderr' }) do
      if result[stream] then
        result[stream] = M.redact(result[stream], code.secrets)
      end
    end
    local output = M.render(result)
    local done = pcall(place, bufnr, mark, block.indent, output)
    record(bufnr, {
      line = block.open,
      lang = block.lang,
      code = code.written,
      output = output,
      code_status = result.code,
      signal = result.signal,
      cut = result.cut,
      timed_out = result.timed_out,
      started = started,
      ms = math.floor((vim.uv.hrtime() - clock) / 1e6),
    })
    on_done(
      done and not result.cut and result.code == 0 and (result.signal or 0) == 0
    )
  end)
  if not process then
    vim.api.nvim_buf_del_extmark(bufnr, ns, mark)
    notify(('%s cannot run'):format(command[1]), vim.log.levels.ERROR)
    return on_done(false)
  end
  running[bufnr] = running[bufnr] or {}
  table.insert(running[bufnr], process)
end

--- Run the block under the cursor
function M.run()
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local block = M.block_at(lines, vim.api.nvim_win_get_cursor(0)[1])
  if not block then
    return notify('The cursor is in no code block', vim.log.levels.WARN)
  end
  M.run_block(bufnr, block)
end

--- Run every block that has a runner, top to bottom, one after the other,
--- stopping at the first that fails
---
--- The blocks are found again before each one runs, since the output of the
--- one before has moved everything below it.
---@param first? integer The block to start at, 1 unless given
function M.run_all(first)
  first = first or 1
  local bufnr = vim.api.nvim_get_current_buf()
  local count = #M.blocks(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  if count < first then
    return notify('No block to run', vim.log.levels.WARN)
  end
  if not M.allowed(bufnr) then return end
  local question = first == 1
      and ('Run all %d blocks, one after the other?'):format(count)
    or ('Run the %d blocks from block %d, one after the other?'):format(
      count - first + 1,
      first
    )
  local answer = vim.fn.confirm(question, '&Run\n&Cancel', 2)
  if answer ~= 1 then return end
  local index = first - 1
  local function next_block()
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    index = index + 1
    local blocks = M.blocks(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    local block = blocks[index]
    if not block then
      return notify(
        ('Ran %d blocks'):format(index - first),
        vim.log.levels.INFO
      )
    end
    M.run_block(bufnr, block, function(ok)
      if ok then return next_block() end
      notify(
        ('Stopped at block %d, on line %d'):format(index, block.open),
        vim.log.levels.WARN
      )
    end)
  end
  next_block()
end

--- Run every block from the one under the cursor down, as `run_all` does:
--- where to pick a runbook up after a step failed and was fixed
function M.run_from()
  local bufnr = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  for index, block in
    ipairs(M.blocks(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)))
  do
    -- The block under the cursor, or the first one below it
    if block.close >= row then return M.run_all(index) end
  end
  notify('No block from the cursor down', vim.log.levels.WARN)
end

--- Remove every `output` fence of the buffer
function M.clear()
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  -- From the bottom up, so the line numbers above stay where they are
  local blocks = M.blocks(lines)
  for index = #blocks, 1, -1 do
    local first, last = M.output_after(lines, blocks[index].close)
    if first and last then
      vim.api.nvim_buf_set_lines(bufnr, first - 1, last, false, {})
    end
  end
end

--- Stop whatever the buffer is running; its output so far is shown as usual
function M.stop() stop_buffer(vim.api.nvim_get_current_buf()) end

--- The subcommands of `:DyRunbook`
M.SUBCOMMANDS = { 'run', 'all', 'from', 'clear', 'stop', 'record', 'inputs' }

--- `:DyRunbook [run|all|from|clear|stop|record|inputs]`
---@param args { fargs: string[] }
function M.command(args)
  local sub = args.fargs[1] or 'run'
  local actions = {
    run = M.run,
    all = function() M.run_all() end,
    from = M.run_from,
    clear = M.clear,
    stop = M.stop,
    record = M.record,
    inputs = M.forget_inputs,
  }
  if not actions[sub] then
    return notify('Unknown subcommand: ' .. sub, vim.log.levels.ERROR)
  end
  actions[sub]()
end

return M
