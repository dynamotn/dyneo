--- A Rego policy tried against an input as it is typed, and its tests
---
--- `:DyRego [{input}]` opens, beside a policy, the query to ask of it --
--- `data.<package>` to start with -- and what `opa eval` answers for the
--- JSON or YAML file given as input. The answer follows each change of the
--- policy, the query or the input, a moment after the typing stops. The
--- policy is evaluated as it is in the buffer, with the other `.rego` files
--- of its folder beside it; the input as it is in its buffer when one is
--- open, else from the file.
---
--- `:DyRego test` runs `opa test` over the policy's folder: a failing test
--- goes to the quickfix list, and once every one passes, the lines no test
--- reached are marked in the open policies, with the coverage of the whole.
---
--- A policy may come from any clone, and is run as it is typed: both run
--- with the capabilities of the `opa` installed, less `M.DENIED_BUILTINS`,
--- so a policy can neither reach the network nor read the environment.
local M = {}

local system = require('util.system')
local notify = require('util.notify').titled('Rego')

--- Milliseconds an evaluation may take
M.TIMEOUT = 10 * 1000
--- Milliseconds the tests of a folder may take
M.TEST_TIMEOUT = 2 * 60 * 1000
--- Bytes of an answer kept
M.MAX_OUTPUT = 1024 * 1024
--- Milliseconds of quiet before an evaluation
M.DEBOUNCE = 300

M.ns = vim.api.nvim_create_namespace('dy_rego')

--- Builtins a policy is not given: they reach the network or read the
--- environment. `net.cidr_*` only compute, and stay.
M.DENIED_BUILTINS = { 'http.send', 'net.lookup_ip_addr', 'opa.runtime' }

--- The capabilities file of this session, once written
---@type string?
M.capabilities_file = nil
--- Why the capabilities could not be written, once tried
---@type string?
M.capabilities_error = nil
--- Who waits for the capabilities being read
---@type fun(path: string?, err: string?)[]?
local capabilities_waiting

--- `capabilities`, an `opa capabilities` answer, less `M.DENIED_BUILTINS`
--- and with no host allowed to the network
---@param capabilities table
---@return table
function M.restrict(capabilities)
  local denied = {}
  for _, name in ipairs(M.DENIED_BUILTINS) do
    denied[name] = true
  end
  local builtins = {}
  for _, builtin in ipairs(capabilities.builtins or {}) do
    if type(builtin) == 'table' and not denied[builtin.name] then
      table.insert(builtins, builtin)
    end
  end
  local restricted = vim.deepcopy(capabilities)
  restricted.builtins = builtins
  -- An empty list allows no host, should a network builtin remain
  restricted.allow_net = {}
  return restricted
end

--- Hand `on_done` the capabilities file every `opa` run here is given, or
--- why there is none: then nothing is run. Written once a session, from
--- what the `opa` installed knows.
---@param on_done fun(path: string?, err: string?)
function M.capabilities(on_done)
  if M.capabilities_file then return on_done(M.capabilities_file) end
  if M.capabilities_error then return on_done(nil, M.capabilities_error) end
  if capabilities_waiting then
    return table.insert(capabilities_waiting, on_done)
  end
  capabilities_waiting = { on_done }
  local function answer(path, err)
    M.capabilities_file, M.capabilities_error = path, err
    local waiting = capabilities_waiting or {}
    capabilities_waiting = nil
    for _, waiter in ipairs(waiting) do
      waiter(path, err)
    end
  end
  system.run(
    { 'opa', 'capabilities', '--current' },
    { timeout = M.TIMEOUT, max_bytes = M.MAX_OUTPUT },
    function(result)
      local ok, data = false, nil
      if result.code == 0 and not result.cut then
        ok, data = pcall(vim.json.decode, result.stdout or '')
      end
      if not ok or type(data) ~= 'table' or type(data.builtins) ~= 'table' then
        return answer(
          nil,
          'Not run: the capabilities of opa could not be read, '
            .. 'so a policy cannot be kept off the network: '
            .. (
              result.code == 0 and 'no builtins listed'
              or system.failure(result, 'opa capabilities')
            )
        )
      end
      -- In the session's own temporary folder, removed when it ends
      local path = vim.fn.tempname() .. '-opa-capabilities.json'
      local written = vim.fn.writefile(
        { vim.json.encode(M.restrict(data)) },
        path
      ) == 0
      if not written then
        return answer(nil, 'Not run: could not write ' .. path)
      end
      answer(path)
    end
  )
end

--- The package `lines` of a policy declare, or nil
---@param lines string[]
---@return string?
function M.package_of(lines)
  for _, line in ipairs(lines) do
    local name = line:match('^%s*package%s+([%w_%.]+)')
    if name then return name end
  end
  return nil
end

--- The other policies of the folder of `file`, sorted
---@param file string
---@return string[]
function M.siblings(file)
  local dir, own = vim.fs.dirname(file), vim.fs.basename(file)
  local found = {}
  for name, kind in vim.fs.dir(dir) do
    if kind == 'file' and name:match('%.rego$') and name ~= own then
      table.insert(found, vim.fs.joinpath(dir, name))
    end
  end
  table.sort(found)
  return found
end

--- The `opa eval` of `query` over `policies`, the input on stdin when
--- `stdin` is set, else from `input`
---@param capabilities string The file of `M.capabilities`
---@param policies string[]
---@param query string
---@param input? string
---@param stdin? boolean
---@return string[]
function M.eval_command(capabilities, policies, query, input, stdin)
  local command = {
    'opa',
    'eval',
    '--capabilities',
    capabilities,
    '--format',
    'pretty',
  }
  for _, policy in ipairs(policies) do
    vim.list_extend(command, { '--data', policy })
  end
  if stdin then
    table.insert(command, '--stdin-input')
  elseif input then
    vim.list_extend(command, { '--input', input })
  end
  -- The query is the user's own, from the line above the answer
  return vim.list_extend(command, { '--', query })
end

---@class DyRego
---@field policy integer The buffer of the policy
---@field query integer The buffer of the query
---@field result integer The buffer of the answer
---@field input? string The input file
---@field dir string Private folder holding the policy as it is in its buffer
---@field group integer
---@field timer uv.uv_timer_t
---@field job? vim.SystemObj
---@field generation integer

--- The open playgrounds, by the buffer of their query
---@type table<integer, DyRego>
M.open_playgrounds = {}

--- The buffer holding `file`, when one is loaded
---@param file string
---@return integer?
local function loaded(file)
  local bufnr = vim.fn.bufnr(file)
  if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then return bufnr end
  return nil
end

--- Show `lines` as the answer of `playground`, `status` above them
---@param playground DyRego
---@param lines string[]
---@param status string
local function show(playground, lines, status)
  require('util.scratch').set(playground.result, lines)
  for _, win in ipairs(vim.fn.win_findbuf(playground.result)) do
    vim.wo[win].winbar = ' ' .. status
  end
end

--- Evaluate the query of `playground`, now
---@param playground DyRego
function M.run(playground)
  if not vim.api.nvim_buf_is_valid(playground.policy) then
    return M.close(playground)
  end
  if not M.capabilities_file then
    return M.capabilities(function(path, err)
      if not M.open_playgrounds[playground.query] then return end
      if not path then return show(playground, { err }, 'opa: not run') end
      M.run(playground)
    end)
  end
  if playground.job then playground.job:kill('sigterm') end
  local file = vim.api.nvim_buf_get_name(playground.policy)
  local copy = vim.fs.joinpath(playground.dir, vim.fs.basename(file))
  vim.fn.writefile(
    vim.api.nvim_buf_get_lines(playground.policy, 0, -1, false),
    copy
  )
  local query = vim.trim(
    table.concat(
      vim.api.nvim_buf_get_lines(playground.query, 0, -1, false),
      ' '
    )
  )
  if query == '' then query = 'data' end
  local input_buf = playground.input and loaded(playground.input)
  local command = M.eval_command(
    M.capabilities_file,
    vim.list_extend({ copy }, M.siblings(file)),
    query,
    playground.input,
    input_buf ~= nil
  )
  playground.generation = playground.generation + 1
  local generation = playground.generation
  playground.job = system.run(command, {
    stdin = input_buf and (table.concat(
      vim.api.nvim_buf_get_lines(input_buf, 0, -1, false),
      '\n'
    ) .. '\n') or nil,
    timeout = M.TIMEOUT,
    max_bytes = M.MAX_OUTPUT,
  }, function(result)
    if
      playground.generation ~= generation
      or not M.open_playgrounds[playground.query]
    then
      return
    end
    playground.job = nil
    local text, status
    if result.code == 0 and not result.cut then
      text, status = result.stdout or '', 'opa: answered'
    elseif result.cut then
      text = result.stdout or ''
      status = ('opa: cut at %d KiB'):format(M.MAX_OUTPUT / 1024)
    else
      text = system.failure(result, 'opa')
      status = result.timed_out and 'opa: timed out' or 'opa: error'
    end
    -- An error names the copy evaluated; the policy is what to go to
    text = text:gsub(vim.pesc(copy), function() return file end)
    local lines = vim.split(text, '\n', { plain = true })
    if lines[#lines] == '' then table.remove(lines) end
    show(playground, lines, status)
  end)
end

--- Close the playground: its windows, its handlers, its run, and the copy
--- of the policy
---@param playground DyRego
function M.close(playground)
  if not M.open_playgrounds[playground.query] then return end
  M.open_playgrounds[playground.query] = nil
  if playground.job then playground.job:kill('sigterm') end
  playground.timer:stop()
  playground.timer:close()
  pcall(vim.api.nvim_del_augroup_by_id, playground.group)
  vim.fn.delete(playground.dir, 'rf')
  for _, bufnr in ipairs({ playground.query, playground.result }) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end
end

--- Open a playground on the policy of the current buffer
---@param input? string The JSON or YAML file to evaluate it against
---@return DyRego?
function M.open(input)
  local policy = vim.api.nvim_get_current_buf()
  local file = vim.api.nvim_buf_get_name(policy)
  if not file:match('%.rego$') then
    return notify('Not a Rego policy', vim.log.levels.WARN)
  end
  if vim.fn.executable('opa') ~= 1 then
    return notify('opa is not installed', vim.log.levels.ERROR)
  end
  if input then
    input = vim.fn.fnamemodify(vim.fn.expand(input), ':p')
    if vim.fn.filereadable(input) ~= 1 and not loaded(input) then
      return notify('No such input: ' .. input, vim.log.levels.ERROR)
    end
  end
  local package = M.package_of(vim.api.nvim_buf_get_lines(policy, 0, -1, false))
  local sensitive = input
    and loaded(input)
    and require('util.sensitive').is_sensitive(assert(loaded(input)))
  local result = require('util.scratch').open({}, {
    split = 'vertical',
    filetype = 'json',
    -- A policy reads the whole input, and the policies of a clone
    sensitive = sensitive and 'what a policy answered of a sensitive input'
      or 'what a policy answered, from policies of a clone',
  })
  vim.cmd('aboveleft 1new')
  local query = vim.api.nvim_get_current_buf()
  vim.bo[query].buftype = 'nofile'
  vim.bo[query].bufhidden = 'wipe'
  vim.bo[query].swapfile = false
  vim.bo[query].filetype = 'rego'
  vim.wo.winfixheight = true
  vim.wo.winbar = ' query'
    .. (input and (' of ' .. vim.fn.fnamemodify(input, ':~:.')) or '')
    .. ', <CR> to run now'
  vim.api.nvim_buf_set_lines(
    query,
    0,
    -1,
    false,
    { package and ('data.' .. package) or 'data' }
  )

  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p', tonumber('700', 8))
  ---@type DyRego
  local playground = {
    policy = policy,
    query = query,
    result = result,
    input = input,
    dir = dir,
    group = vim.api.nvim_create_augroup('dy_rego_' .. query, { clear = true }),
    timer = assert(vim.uv.new_timer()),
    generation = 0,
  }
  M.open_playgrounds[query] = playground

  local function later()
    playground.timer:stop()
    playground.timer:start(
      M.DEBOUNCE,
      0,
      vim.schedule_wrap(function()
        if M.open_playgrounds[query] then M.run(playground) end
      end)
    )
  end
  local watched = { query, policy }
  local input_buf = input and loaded(input)
  if input_buf then table.insert(watched, input_buf) end
  for _, bufnr in ipairs(watched) do
    vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
      group = playground.group,
      buffer = bufnr,
      callback = later,
    })
  end
  for _, bufnr in ipairs({ query, result, policy }) do
    vim.api.nvim_create_autocmd({ 'BufWipeout', 'BufUnload' }, {
      group = playground.group,
      buffer = bufnr,
      callback = function()
        vim.schedule(function() M.close(playground) end)
      end,
    })
  end
  local function close() M.close(playground) end
  for _, bufnr in ipairs({ query, result }) do
    vim.keymap.set(
      'n',
      'q',
      close,
      { buffer = bufnr, nowait = true, desc = 'Close the Rego playground' }
    )
  end
  vim.keymap.set(
    { 'n', 'i' },
    '<CR>',
    function() M.run(playground) end,
    { buffer = query, desc = 'Evaluate the query' }
  )
  M.run(playground)
  return playground
end

--- Ask for the input, then open a playground on it
local function open_asking()
  vim.ui.input({
    prompt = 'Input to evaluate against (JSON or YAML, empty for none): ',
    completion = 'file',
  }, function(path)
    if path == nil then return end
    M.open(vim.trim(path) ~= '' and vim.trim(path) or nil)
  end)
end

---@class DyRegoTest
---@field name string `data.pkg.test_x`
---@field file? string
---@field row? integer
---@field fail boolean
---@field error? string

--- The tests of an `opa test --format json` answer
---@param results table[]
---@return DyRegoTest[]
function M.tests(results)
  local tests = {}
  for _, item in ipairs(results) do
    if type(item) == 'table' then
      local location = type(item.location) == 'table' and item.location or {}
      local err = type(item.error) == 'table' and item.error.message
        or (type(item.error) == 'string' and item.error)
        or nil
      table.insert(tests, {
        name = ('%s.%s'):format(item.package or '?', item.name or '?'),
        file = location.file,
        row = location.row,
        fail = item.fail == true or err ~= nil,
        error = err,
      })
    end
  end
  return tests
end

--- Mark the lines `report` says no test reached, in each open policy
---@param report table `opa test --coverage --format json`
---@return integer marked Lines marked
function M.mark_coverage(report)
  local marked = 0
  for file, coverage in
    pairs(type(report.files) == 'table' and report.files or {})
  do
    local bufnr = loaded(file)
    if bufnr then
      vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
      local count = vim.api.nvim_buf_line_count(bufnr)
      for _, range in
        ipairs(
          type(coverage.not_covered) == 'table' and coverage.not_covered or {}
        )
      do
        local first = vim.tbl_get(range, 'start', 'row')
        local last = vim.tbl_get(range, 'end', 'row') or first
        for row = first or 1, math.min(last or 0, count) do
          vim.api.nvim_buf_set_extmark(bufnr, M.ns, row - 1, 0, {
            sign_text = '▎',
            sign_hl_group = 'DiagnosticWarn',
            line_hl_group = 'DiffDelete',
          })
          marked = marked + 1
        end
      end
    end
  end
  return marked
end

--- Clear the coverage marks of every buffer
function M.clear()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
    end
  end
end

--- Decode the JSON `opa` printed, or nil
---@param text string
---@return table?
local function decode(text)
  local ok, data =
    pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
  return ok and type(data) == 'table' and data or nil
end

--- Run the tests of the policy's folder, then mark what they leave uncovered
---@param on_done? fun() For the specs
function M.test(on_done)
  local file = vim.api.nvim_buf_get_name(0)
  local function finish(msg, level)
    notify(msg, level)
    if on_done then on_done() end
  end
  if not file:match('%.rego$') then
    return finish('Not a Rego policy', vim.log.levels.WARN)
  end
  if vim.fn.executable('opa') ~= 1 then
    return finish('opa is not installed', vim.log.levels.ERROR)
  end
  if vim.bo.modified then
    return finish(
      'Write the policy first: opa test reads the files on disk',
      vim.log.levels.WARN
    )
  end
  M.capabilities(function(capabilities, err)
    if not capabilities then return finish(err, vim.log.levels.ERROR) end
    M.run_tests(vim.fs.dirname(file), capabilities, finish)
  end)
end

--- Run the tests of `dir`, then mark what they leave uncovered
---@param dir string
---@param capabilities string The file of `M.capabilities`
---@param finish fun(msg: string, level?: integer)
function M.run_tests(dir, capabilities, finish)
  local function opa_test(...)
    return vim.list_extend({
      'opa',
      'test',
      '--capabilities',
      capabilities,
      ...,
    }, { '--', dir })
  end
  system.run(
    opa_test('--format', 'json'),
    { timeout = M.TEST_TIMEOUT, max_bytes = M.MAX_OUTPUT },
    function(result)
      local results = not result.cut and decode(result.stdout or '')
      -- A parse error is printed, not given as JSON: it fails like a test
      if not results then
        return finish(
          'opa test failed: ' .. system.failure(result, 'opa'),
          vim.log.levels.ERROR
        )
      end
      local tests = M.tests(results)
      local failed = vim.tbl_filter(function(t) return t.fail end, tests)
      if #tests == 0 then return finish('No test in ' .. dir) end
      if #failed > 0 then
        vim.fn.setqflist({}, ' ', {
          title = 'opa test',
          items = vim.tbl_map(
            function(t)
              return {
                filename = t.file,
                lnum = t.row or 1,
                text = t.name .. ': ' .. (t.error or 'FAIL'),
                type = 'E',
              }
            end,
            failed
          ),
        })
        return finish(
          ('%d of %d tests failed: see the quickfix list'):format(
            #failed,
            #tests
          ),
          vim.log.levels.ERROR
        )
      end
      system.run(
        opa_test('--coverage', '--format', 'json'),
        { timeout = M.TEST_TIMEOUT, max_bytes = M.MAX_OUTPUT },
        function(covered)
          local report = not covered.cut and decode(covered.stdout or '')
          if not report then
            return finish(
              ('%d tests passed; coverage not read: %s'):format(
                #tests,
                system.failure(covered, 'opa')
              ),
              vim.log.levels.WARN
            )
          end
          local marked = M.mark_coverage(report)
          finish(
            ('%d tests passed, %.1f%% covered%s'):format(
              #tests,
              tonumber(report.coverage) or 0,
              marked > 0 and (', %d lines marked'):format(marked) or ''
            )
          )
        end
      )
    end
  )
end

M.SUBCOMMANDS = { 'test', 'clear' }

--- `:DyRego [{input}]`, `:DyRego test`, `:DyRego clear`
---@param args { fargs: string[] }
function M.command(args)
  local first = args.fargs[1]
  if first == 'test' then return M.test() end
  if first == 'clear' then return M.clear() end
  if first then return M.open(first) end
  open_asking()
end

return M
