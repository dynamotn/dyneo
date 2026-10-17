--- A jq or yq expression tried against the buffer as it is typed
---
--- Getting a filter right is a loop of editing it on a command line and
--- reading what comes back. Here the expression has a line of its own above
--- the result, and the result follows each change of the expression, and of
--- the document, a moment after the typing stops.
---
--- One run at a time: a new one stops the last, every run has a timeout,
--- and what it prints is cut at `M.MAX_OUTPUT`. The result of a buffer held
--- back from AI is held back too.
local M = {}

--- Milliseconds a run may take
M.TIMEOUT = 5000
--- Bytes of a result kept
M.MAX_OUTPUT = 1024 * 1024
--- Milliseconds of quiet before a run
M.DEBOUNCE = 300

---@class DyQuery
---@field source integer The buffer queried
---@field expr integer The buffer of the expression
---@field result integer The buffer of the result
---@field tool string `jq` or `yq`
---@field group integer
---@field timer uv.uv_timer_t
---@field job? vim.SystemObj
---@field generation integer Which run the result on screen comes from

--- The open playgrounds, by the buffer of their expression
---@type table<integer, DyQuery>
M.open_queries = {}

--- The tool that reads a filetype, or nil
---@param filetype string
---@return string?
function M.tool(filetype)
  local base = filetype:match('^[^.]+') or ''
  if base == 'json' or base == 'jsonc' or base == 'json5' then return 'jq' end
  if base == 'yaml' then return 'yq' end
end

--- The command that runs `expr`, reading the document from stdin
---@param tool string
---@param expr string
---@return string[]
function M.argv(tool, expr)
  if tool == 'yq' then return { 'yq', 'eval', expr, '-' } end
  return { 'jq', expr }
end

local notify = require('util.notify').titled('Query')

--- Lines to show for what a run printed, cut at `M.MAX_OUTPUT`
---@param text string
---@return string[] lines
---@return boolean cut
function M.output(text)
  local cut = #text > M.MAX_OUTPUT
  if cut then text = text:sub(1, M.MAX_OUTPUT) end
  local lines = vim.split(text, '\n', { plain = true })
  if lines[#lines] == '' then table.remove(lines) end
  return lines, cut
end

--- Run the expression of `query` against its document, now
---@param query DyQuery
function M.run(query)
  if not vim.api.nvim_buf_is_valid(query.source) then return M.close(query) end
  if query.job then query.job:kill('sigterm') end
  local expr =
    table.concat(vim.api.nvim_buf_get_lines(query.expr, 0, -1, false), '\n')
  if vim.trim(expr) == '' then expr = '.' end
  local input = table.concat(
    vim.api.nvim_buf_get_lines(query.source, 0, -1, false),
    '\n'
  ) .. '\n'
  query.generation = query.generation + 1
  local generation = query.generation
  -- Read no further than is shown: `repeat(.)` prints for as long as it may
  query.job = require('util.system').run(
    M.argv(query.tool, expr),
    { stdin = input, timeout = M.TIMEOUT, max_bytes = M.MAX_OUTPUT + 1 },
    function(result)
      vim.schedule(function()
        -- A later run took over, or the playground was closed
        if query.generation ~= generation or not M.open_queries[query.expr] then
          return
        end
        query.job = nil
        local status
        local lines, cut
        if result.code == 0 or result.cut then
          lines, cut = M.output(result.stdout or '')
          cut = cut or result.cut
          status = ('%s: %d lines'):format(query.tool, #lines)
          if cut then
            status = status .. (', cut at %d KiB'):format(M.MAX_OUTPUT / 1024)
          end
        else
          lines = M.output(result.stderr or '')
          status = result.timed_out and query.tool .. ': timed out'
            or query.tool .. ': error'
        end
        require('util.scratch').set(query.result, lines)
        for _, win in ipairs(vim.fn.win_findbuf(query.result)) do
          vim.wo[win].winbar = ' ' .. status
        end
      end)
    end
  )
end

--- Run once the typing has stopped
---@param query DyQuery
local function later(query)
  query.timer:stop()
  query.timer:start(
    M.DEBOUNCE,
    0,
    vim.schedule_wrap(function()
      if M.open_queries[query.expr] then M.run(query) end
    end)
  )
end

--- Close the playground: both of its windows, its handlers, its run
---@param query DyQuery
function M.close(query)
  if not M.open_queries[query.expr] then return end
  M.open_queries[query.expr] = nil
  if query.job then query.job:kill('sigterm') end
  query.timer:stop()
  query.timer:close()
  pcall(vim.api.nvim_del_augroup_by_id, query.group)
  for _, bufnr in ipairs({ query.expr, query.result }) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end
end

--- Open a playground on the current buffer, `expr` in it to start with
---@param expr? string
---@return DyQuery?
function M.open(expr)
  local source = vim.api.nvim_get_current_buf()
  local tool = M.tool(vim.bo[source].filetype)
  if not tool then
    return notify(
      'Not a JSON or YAML buffer: jq and yq read nothing else',
      vim.log.levels.WARN
    )
  end
  if vim.fn.executable(tool) ~= 1 then
    return notify(tool .. ' is not installed', vim.log.levels.ERROR)
  end
  local sensitive = require('util.sensitive').is_sensitive(source)
  -- Held back from AI whatever the document: an expression reads the
  -- environment (jq `$ENV`, `env`; yq `env()`) and yq `load()` any file
  local result = require('util.scratch').open({}, {
    split = 'vertical',
    filetype = tool == 'jq' and 'json' or 'yaml',
    sensitive = sensitive and 'the result of a query of a sensitive buffer'
      or 'the result of a query, which can read the environment and files',
  })
  vim.cmd('aboveleft 1new')
  local expr_buf = vim.api.nvim_get_current_buf()
  vim.bo[expr_buf].buftype = 'nofile'
  vim.bo[expr_buf].bufhidden = 'wipe'
  vim.bo[expr_buf].swapfile = false
  vim.bo[expr_buf].filetype = 'jq'
  vim.wo.winfixheight = true
  vim.wo.winbar = ' ' .. tool .. ' expression, <CR> to run now'
  vim.api.nvim_buf_set_lines(expr_buf, 0, -1, false, { expr or '.' })

  ---@type DyQuery
  local query = {
    source = source,
    expr = expr_buf,
    result = result,
    tool = tool,
    group = vim.api.nvim_create_augroup(
      'dy_query_' .. expr_buf,
      { clear = true }
    ),
    timer = assert(vim.uv.new_timer()),
    generation = 0,
  }
  M.open_queries[expr_buf] = query

  for _, bufnr in ipairs({ expr_buf, source }) do
    vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
      group = query.group,
      buffer = bufnr,
      callback = function() later(query) end,
    })
  end
  for _, bufnr in ipairs({ expr_buf, result, source }) do
    vim.api.nvim_create_autocmd({ 'BufWipeout', 'BufUnload' }, {
      group = query.group,
      buffer = bufnr,
      callback = function()
        vim.schedule(function() M.close(query) end)
      end,
    })
  end
  local function close() M.close(query) end
  for _, bufnr in ipairs({ expr_buf, result }) do
    vim.keymap.set(
      'n',
      'q',
      close,
      { buffer = bufnr, nowait = true, desc = 'Close the Query' }
    )
  end
  vim.keymap.set(
    { 'n', 'i' },
    '<CR>',
    function() M.run(query) end,
    { buffer = expr_buf, desc = 'Run the Query' }
  )

  M.run(query)
  vim.cmd('startinsert!')
  return query
end

--- `:DyQuery [{expr}]`
---@param args { args: string }
function M.command(args) M.open(args.args ~= '' and args.args or nil) end

return M
