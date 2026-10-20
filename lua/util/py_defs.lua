--- The decorated functions and calls of a Python file, read from its text
---
--- What a data pipeline names its tasks, flows, DAGs, assets and jobs by is
--- mostly a decorator (`@task`, `@flow(name=...)`, `@dag`, `@asset`) or a
--- call (`DAG("id")`, `BashOperator(task_id="x")`). Reading them from lines
--- keeps the answer instant and needs no Python: a name built at run time is
--- not found, and its runs are shown on no line.
local M = {}

--- Lines a decorator's arguments may span
M.MAX_SPAN = 30

---@class DyPyDef
---@field decorator string The decorator, without its module: `task`, `flow`
---@field args string What its parentheses hold, `''` when there are none
---@field func string The function it decorates
---@field line integer 1-based, the decorator's
---@field def_line integer 1-based, the `def`'s
---@field indent integer The decorator's indent

--- What follows `(` at column `col` of line `first`, up to its balancing
--- `)`, across lines; strings are skipped, so a `)` inside one ends nothing
---@param lines string[]
---@param first integer
---@param col integer Where `(` is
---@return string args
---@return integer last The line the parenthesis closes on
function M.balanced(lines, first, col)
  local depth, quote, out = 0, nil, {}
  for number = first, math.min(#lines, first + M.MAX_SPAN) do
    local line = lines[number]
    local start = number == first and col or 1
    local i = start
    -- Where the code of the line ends: a comment is no argument
    local stop = #line
    while i <= #line do
      local char = line:sub(i, i)
      if quote then
        if char == '\\' then
          i = i + 1
        elseif char == quote then
          quote = nil
        end
      elseif char == '"' or char == "'" then
        quote = char
      elseif char == '#' then
        stop = i - 1
        break
      elseif char == '(' then
        depth = depth + 1
      elseif char == ')' then
        depth = depth - 1
        if depth == 0 then
          table.insert(out, line:sub(start, i))
          local text = table.concat(out, ' ')
          return text:sub(2, -2), number
        end
      end
      i = i + 1
    end
    table.insert(out, line:sub(start, stop))
  end
  return table.concat(out, ' '):sub(2), math.min(#lines, first + M.MAX_SPAN)
end

--- The string a keyword argument of `args` is given: `name="x"`
---@param args string
---@param key string
---@return string?
function M.kwarg(args, key)
  local _, value = args:match('%f[%w_]' .. key .. '%s*=%s*[rbuf]?(["\'])(.-)%1')
  if value then return value end
  return nil
end

--- The first argument of `args`, when it is a string: `DAG("id", ...)`
---@param args string
---@return string?
function M.first_string(args)
  local _, value = vim.trim(args):match('^[rbuf]?(["\'])(.-)%1')
  return value
end

--- The decorated functions of `lines` whose decorator is one of `names`:
--- `@task`, `@task(...)`, `@task.docker(...)` (a task of Airflow's) and
--- `@prefect.flow`, `@dg.asset` (a module's)
---@param lines string[]
---@param names string[]
---@return DyPyDef[]
function M.decorated(lines, names)
  local wanted = {}
  for _, name in ipairs(names) do
    wanted[name] = true
  end
  local defs = {}
  local number = 1
  while number <= #lines do
    local indent, path, after =
      lines[number]:match('^(%s*)@([%w_][%w_%.]*)(.*)$')
    local parts = path and vim.split(path, '.', { plain = true }) or {}
    local name = wanted[parts[1]] and parts[1]
      or (#parts > 1 and wanted[parts[#parts]] and parts[#parts])
    if name then
      local args, last = '', number
      local open = after:find('^%s*%(')
      if open then
        local col = #lines[number] - #after + after:find('%(')
        args, last = M.balanced(lines, number, col)
      end
      -- The `def` below, past any other decorator
      for at = last + 1, math.min(#lines, last + M.MAX_SPAN) do
        local func = lines[at]:match('^%s*async%s+def%s+([%w_]+)')
          or lines[at]:match('^%s*def%s+([%w_]+)')
        if func then
          table.insert(defs, {
            decorator = name,
            args = args,
            func = func,
            line = number,
            def_line = at,
            indent = #indent,
          })
          break
        end
        if not lines[at]:match('^%s*@') and lines[at]:match('%S') then break end
      end
    end
    number = number + 1
  end
  return defs
end

--- The calls of `lines` to one of `names` (`DAG(`, `define_asset_job(`),
--- with what their parentheses hold
---@param lines string[]
---@param names string[]
---@return { name: string, args: string, line: integer }[]
function M.calls(lines, names)
  local found = {}
  for number, line in ipairs(lines) do
    if not line:match('^%s*#') then
      for _, name in ipairs(names) do
        local at = 1
        while true do
          local s, e = line:find(name .. '%s*%(', at)
          if not s then break end
          -- `DAG(` and not `MyDAG(`
          local before = s > 1 and line:sub(s - 1, s - 1) or ''
          if not before:match('[%w_]') then
            local args = M.balanced(lines, number, e)
            table.insert(found, { name = name, args = args, line = number })
          end
          at = e + 1
        end
      end
    end
  end
  return found
end

--- Whether `lines` import `module`
---@param lines string[]
---@param module string
---@return boolean
function M.imports(lines, module)
  for _, line in ipairs(lines) do
    if
      line:match('^%s*from%s+' .. module .. '[%.%s]')
      or line:match('^%s*import%s+' .. module .. '[%.%s,]')
      or line:match('^%s*import%s+' .. module .. '$')
    then
      return true
    end
  end
  return false
end

return M
