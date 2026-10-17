--- A Terraform or OpenTofu plan, shown on the blocks it changes
---
--- `plan` prints what it would do as a long list of addresses, far from the
--- code that asks for it. Here the same plan lands on the `resource`, `data`
--- and `module` blocks of the module being edited, as diagnostics: what is
--- created, changed, replaced and why, and destroyed, each on its own line,
--- with `]d` to walk them and the quickfix list holding all of it.
---
--- The plan is saved to a private temporary file only to be read back with
--- `show -json`, then deleted: a plan file holds every value it planned,
--- secrets included, in plain text.
---
--- The same flow answers two more questions: what changed outside the code
--- (`drift`, a `-refresh-only` plan), and what the planned resources cost a
--- month (`cost`, the plan handed to `infracost`), shown at the end of the
--- line of each block.
local M = {}

local ns = vim.api.nvim_create_namespace('dy_tfplan')
local cost_ns = vim.api.nvim_create_namespace('dy_tfplan_cost')

--- Milliseconds a plan may run before it is stopped
M.TIMEOUT = 15 * 60 * 1000

--- Milliseconds `infracost` may take to price a plan
M.COST_TIMEOUT = 5 * 60 * 1000

--- The most of `show -json` read; the plan of a large state runs to many MiB
M.MAX_PLAN = 256 * 1024 * 1024

---@alias DyTfAction 'create'|'update'|'replace'|'destroy'|'read'|'forget'

---@class DyTfChange
---@field action DyTfAction
---@field address string
---@field mode 'managed'|'data'
---@field type string
---@field name string
---@field module? string The first `module.<name>` of its address, if any
---@field forces string[] Attributes that force a replacement

--- The action of a `change.actions` list
---@param actions string[]
---@return DyTfAction?
local function action_of(actions)
  local joined = table.concat(actions or {}, ',')
  if joined == 'create' then return 'create' end
  if joined == 'update' then return 'update' end
  if joined == 'delete' then return 'destroy' end
  if joined == 'read' then return 'read' end
  -- A `removed` block (Terraform 1.7): out of the state, left in place
  if joined == 'forget' then return 'forget' end
  if joined == 'delete,create' or joined == 'create,delete' then
    return 'replace'
  end
  return nil
end

--- A `replace_paths` entry as an attribute path: `tags.Name`, `ingress[0]`
---@param path (string|integer)[]
---@return string
local function path_string(path)
  local out = ''
  for _, step in ipairs(path) do
    if type(step) == 'number' then
      out = out .. ('[%d]'):format(step)
    else
      out = out == '' and tostring(step) or out .. '.' .. tostring(step)
    end
  end
  return out
end

--- The changes of a plan, from the output of `show -json`
---@param plan table
---@param field? 'resource_changes'|'resource_drift' Which list to read: what
--- the plan does (the default), or what changed outside the code
---@return DyTfChange[]
function M.changes(plan, field)
  local changes = {}
  for _, rc in ipairs(plan[field or 'resource_changes'] or {}) do
    local action = action_of(vim.tbl_get(rc, 'change', 'actions'))
    if action then
      local forces = {}
      for _, path in ipairs(vim.tbl_get(rc, 'change', 'replace_paths') or {}) do
        table.insert(forces, path_string(path))
      end
      table.insert(changes, {
        action = action,
        address = rc.address,
        mode = rc.mode,
        type = rc.type,
        name = rc.name,
        module = rc.module_address
          and rc.module_address:match('^module%.([^.%[]+)'),
        forces = forces,
      })
    end
  end
  return changes
end

--- Where each block of the `.tf` files of `dir` starts, by what it declares:
--- `resource.aws_s3_bucket.logs`, `data.aws_iam_policy.read`, `module.vpc`
---@param dir string
---@return table<string, { file: string, line: integer }>
function M.index(dir)
  local blocks = {}
  for name, kind in vim.fs.dir(dir) do
    -- A symlinked `providers.tf` is as much a part of the module
    local is_file = kind == 'file' or kind == 'link'
    if is_file and (name:match('%.tf$') or name:match('%.tofu$')) then
      local file = vim.fs.joinpath(dir, name)
      local ok, lines = pcall(vim.fn.readfile, file)
      for number, line in ipairs(ok and lines or {}) do
        local block, first, second =
          line:match('^%s*(%a+)%s+"([^"]+)"%s*"?([^"%s{]*)"?%s*{')
        if block == 'resource' or block == 'data' then
          blocks[block .. '.' .. first .. '.' .. second] =
            { file = file, line = number }
        elseif block == 'module' then
          blocks['module.' .. first] = { file = file, line = number }
        end
      end
    end
  end
  return blocks
end

--- What each action is called, how it is marked and how loud it is
local ACTIONS = {
  create = {
    sign = '+',
    word = 'create',
    severity = vim.diagnostic.severity.HINT,
  },
  read = { sign = '<=', word = 'read', severity = vim.diagnostic.severity.HINT },
  update = {
    sign = '~',
    word = 'update in place',
    severity = vim.diagnostic.severity.INFO,
  },
  replace = {
    sign = '-/+',
    word = 'replace',
    severity = vim.diagnostic.severity.WARN,
  },
  destroy = {
    sign = '-',
    word = 'destroy',
    severity = vim.diagnostic.severity.WARN,
  },
  forget = {
    sign = '.',
    word = 'forget (removed from state)',
    severity = vim.diagnostic.severity.WARN,
  },
}

--- How drift is told: a `-refresh-only` plan only ever finds an object
--- changed or deleted outside the code
local DRIFT = {
  update = {
    sign = '~',
    word = 'changed outside the code',
    severity = vim.diagnostic.severity.WARN,
  },
  destroy = {
    sign = '-',
    word = 'deleted outside the code',
    severity = vim.diagnostic.severity.WARN,
  },
}

--- The order the actions of one block are listed in, loudest first
local ORDER = { 'destroy', 'forget', 'replace', 'update', 'create', 'read' }

---@class DyTfEntry
---@field file? string
---@field line? integer
---@field text string
---@field severity integer

--- One entry per block the plan touches, and one for each change whose block
--- is not in `blocks` -- one of a nested module, or of a file not read
---@param changes DyTfChange[]
---@param blocks table<string, { file: string, line: integer }>
---@param drift? boolean Tell the changes as drift
---@return DyTfEntry[]
function M.entries(changes, blocks, drift)
  ---@type table<string, { where: table?, label: string, counts: table, forces: table }>
  local groups, order = {}, {}
  for _, change in ipairs(changes) do
    local key = change.module and ('module.' .. change.module)
      or (
        (change.mode == 'data' and 'data' or 'resource')
        .. '.'
        .. change.type
        .. '.'
        .. change.name
      )
    local group = groups[key]
    if not group then
      group = {
        where = blocks[key],
        label = change.module and key or change.address:gsub('%[.*%]$', ''),
        counts = {},
        forces = {},
      }
      groups[key] = group
      table.insert(order, key)
    end
    group.counts[change.action] = (group.counts[change.action] or 0) + 1
    for _, force in ipairs(change.forces) do
      if not vim.list_contains(group.forces, force) then
        table.insert(group.forces, force)
      end
    end
  end

  local entries = {}
  for _, key in ipairs(order) do
    local group = groups[key]
    local parts, severity = {}, vim.diagnostic.severity.HINT
    for _, action in ipairs(ORDER) do
      local count = group.counts[action]
      if count then
        local info = drift and DRIFT[action] or ACTIONS[action]
        table.insert(
          parts,
          ('%s %s%s'):format(
            info.sign,
            info.word,
            count > 1 and (' ×' .. count) or ''
          )
        )
        severity = math.min(severity, info.severity)
      end
    end
    local text = table.concat(parts, ', ')
    if #group.forces > 0 then
      text = text .. ' (forced by ' .. table.concat(group.forces, ', ') .. ')'
    end
    if not group.where then text = group.label .. ': ' .. text end
    table.insert(entries, {
      file = group.where and group.where.file,
      line = group.where and group.where.line,
      text = text,
      severity = severity,
    })
  end
  return entries
end

--- The one-line summary `plan` itself ends with
---@param changes DyTfChange[]
---@return string
function M.summary(changes)
  local counts =
    { create = 0, update = 0, destroy = 0, replace = 0, forget = 0 }
  for _, change in ipairs(changes) do
    if counts[change.action] then
      counts[change.action] = counts[change.action] + 1
    end
  end
  local total = counts.create
    + counts.update
    + counts.destroy
    + counts.replace
    + counts.forget
  if total == 0 then return 'No changes' end
  local line = ('Plan: %d to add, %d to change, %d to destroy, %d to replace'):format(
    counts.create,
    counts.update,
    counts.destroy,
    counts.replace
  )
  if counts.forget > 0 then
    line = line .. (', %d to forget'):format(counts.forget)
  end
  return line
end

--- The one-line summary of a `-refresh-only` plan
---@param changes DyTfChange[]
---@return string
function M.drift_summary(changes)
  local changed, deleted = 0, 0
  for _, change in ipairs(changes) do
    if change.action == 'destroy' then
      deleted = deleted + 1
    else
      changed = changed + 1
    end
  end
  if changed + deleted == 0 then return 'No drift' end
  return ('Drift: %d changed, %d deleted outside the code'):format(
    changed,
    deleted
  )
end

--- The block an address of `infracost` belongs to, keyed the way `M.index`
--- keys them: `module.vpc` for anything in a module, else `resource.T.N`
---@param address string
---@return string
function M.cost_key(address)
  local module = address:match('^module%.([^.%[]+)')
  if module then return 'module.' .. module end
  return 'resource.' .. address:gsub('%[.*%]$', '')
end

---@class DyTfCosts
---@field blocks table<string, number> Monthly cost by block key
---@field total number
---@field currency string

--- The monthly cost of each block, from `infracost breakdown --format json`.
--- A resource priced only by usage has no `monthlyCost` and adds nothing.
---@param breakdown table
---@return DyTfCosts
function M.costs(breakdown)
  local blocks, total = {}, 0
  for _, project in ipairs(breakdown.projects or {}) do
    local resources = vim.tbl_get(project, 'breakdown', 'resources') or {}
    for _, resource in ipairs(resources) do
      local monthly = tonumber(resource.monthlyCost)
      if monthly and type(resource.name) == 'string' then
        local key = M.cost_key(resource.name)
        blocks[key] = (blocks[key] or 0) + monthly
        total = total + monthly
      end
    end
  end
  return {
    blocks = blocks,
    total = total,
    currency = type(breakdown.currency) == 'string' and breakdown.currency
      or 'USD',
  }
end

--- How a monthly cost reads: `≈ 12.30 USD/month`
---@param amount number
---@param currency string
---@return string
function M.cost_text(amount, currency)
  return ('≈ %.2f %s/month'):format(amount, currency)
end

---@type table<string, { line: integer, text: string }[]> Costs shown, by file
local shown_costs = {}

--- Put the costs known for its file on a loaded buffer
---@param bufnr integer
local function place_costs(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, cost_ns, 0, -1)
  local marks = shown_costs[vim.api.nvim_buf_get_name(bufnr)]
  local count = vim.api.nvim_buf_line_count(bufnr)
  for _, mark in ipairs(marks or {}) do
    if mark.line <= count then
      vim.api.nvim_buf_set_extmark(bufnr, cost_ns, mark.line - 1, 0, {
        virt_text = { { '  ' .. mark.text, 'Comment' } },
        virt_text_pos = 'eol',
      })
    end
  end
end

--- Show the cost of each block found in `blocks`, on the buffers loaded now
--- and on those opened later
---@param costs DyTfCosts
---@param blocks table<string, { file: string, line: integer }>
function M.show_costs(costs, blocks)
  shown_costs = {}
  for key, amount in pairs(costs.blocks) do
    local where = blocks[key]
    if where then
      shown_costs[where.file] = shown_costs[where.file] or {}
      table.insert(shown_costs[where.file], {
        line = where.line,
        text = M.cost_text(amount, costs.currency),
      })
    end
  end
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then place_costs(bufnr) end
  end
end

--- Forget the plan, drift and costs shown, in every buffer
function M.clear()
  vim.diagnostic.reset(ns)
  shown_costs = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      vim.api.nvim_buf_clear_namespace(bufnr, cost_ns, 0, -1)
    end
  end
  local qf = vim.fn.getqflist({ title = 0 })
  if qf.title and qf.title:find('^Terraform ') then
    vim.fn.setqflist({}, 'r')
  end
end

--- Show `entries` as diagnostics of their files and in the quickfix list
---@param entries DyTfEntry[]
---@param title string
---@param source? string `plan` unless given
function M.show(entries, title, source)
  vim.diagnostic.reset(ns)
  ---@type table<integer, vim.Diagnostic[]>
  local per_buffer = {}
  local items = {}
  for _, entry in ipairs(entries) do
    if entry.file then
      local bufnr = vim.fn.bufadd(entry.file)
      per_buffer[bufnr] = per_buffer[bufnr] or {}
      table.insert(per_buffer[bufnr], {
        lnum = entry.line - 1,
        col = 0,
        message = entry.text,
        severity = entry.severity,
        source = source or 'plan',
      })
    end
    table.insert(items, {
      filename = entry.file,
      lnum = entry.line or 0,
      text = entry.text,
      type = entry.severity == vim.diagnostic.severity.WARN and 'W' or 'I',
    })
  end
  for bufnr, diagnostics in pairs(per_buffer) do
    vim.diagnostic.set(ns, bufnr, diagnostics)
  end
  vim.fn.setqflist({}, ' ', { title = title, items = items })
end

local notify = require('util.notify').titled('Terraform plan')

--- The binary to plan with: OpenTofu when it is there
---@return string?
function M.binary()
  for _, name in ipairs({ 'tofu', 'terraform' }) do
    if vim.fn.executable(name) == 1 then return name end
  end
end

--- Write `text` to a new file only its owner can read: a plan in JSON holds
--- every value it planned
---@param path string
---@param text string
---@return boolean
local function write_private(path, text)
  local fd = vim.uv.fs_open(path, 'w', tonumber('600', 8))
  if not fd then return false end
  local ok = vim.uv.fs_write(fd, text) ~= nil
  vim.uv.fs_close(fd)
  return ok
end

--- The block a reference of an expression points at, as the root module
--- addresses it: `aws_instance.web.id` -> `aws_instance.web`,
--- `module.vpc.vpc_id` -> `module.vpc`, `data.aws_ami.x.id` ->
--- `data.aws_ami.x`; nil for `var.`, `local.` and the like
---@param ref string
---@return string?
function M.ref_address(ref)
  -- In parentheses: the count `gsub` returns too is no separator
  local parts = vim.split((ref:gsub('%[.-%]', '')), '.', { plain = true })
  if parts[1] == 'module' and parts[2] then return 'module.' .. parts[2] end
  if parts[1] == 'data' and parts[3] then
    return ('data.%s.%s'):format(parts[2], parts[3])
  end
  -- A resource type is `provider_kind`: `var`, `local`, `each`, `count`,
  -- `path`, `self` and `terraform` are not
  if parts[2] and parts[1]:find('_', 1, true) then
    return parts[1] .. '.' .. parts[2]
  end
  return nil
end

--- Every `references` list inside `expressions`, however deep
---@param expressions any
---@param out string[]
local function references(expressions, out)
  if type(expressions) ~= 'table' then return end
  for key, value in pairs(expressions) do
    if key == 'references' and type(value) == 'table' then
      vim.list_extend(out, value)
    else
      references(value, out)
    end
  end
end

--- What depends on each block of the root module, from the `configuration`
--- of `show -json`: the blocks whose expressions refer to it, or that name
--- it in `depends_on`
---@param configuration table
---@return table<string, string[]> Address to the addresses depending on it
function M.dependents(configuration)
  local root = type(configuration) == 'table' and configuration.root_module
    or {}
  local blocks = {}
  for _, resource in
    ipairs(type(root.resources) == 'table' and root.resources or {})
  do
    if type(resource.address) == 'string' then
      table.insert(blocks, { address = resource.address, node = resource })
    end
  end
  for name, call in
    pairs(type(root.module_calls) == 'table' and root.module_calls or {})
  do
    table.insert(blocks, { address = 'module.' .. name, node = call })
  end
  local dependents = {}
  for _, block in ipairs(blocks) do
    local refs = {}
    references(block.node.expressions, refs)
    -- `count` and `for_each` are kept beside the expressions, not in them
    references(block.node.count_expression, refs)
    references(block.node.for_each_expression, refs)
    vim.list_extend(
      refs,
      type(block.node.depends_on) == 'table' and block.node.depends_on or {}
    )
    local seen = {}
    for _, ref in ipairs(refs) do
      local target = type(ref) == 'string' and M.ref_address(ref)
      if target and target ~= block.address and not seen[target] then
        seen[target] = true
        dependents[target] = dependents[target] or {}
        table.insert(dependents[target], block.address)
      end
    end
  end
  return dependents
end

--- The address of the block a change belongs to, in the root module
---@param change DyTfChange
---@return string
local function block_address(change)
  if change.module then return 'module.' .. change.module end
  if change.mode == 'data' then
    return ('data.%s.%s'):format(change.type, change.name)
  end
  return change.type .. '.' .. change.name
end

--- Every block reached from a replaced or destroyed one through what
--- depends on it, with the changes it is reached from
---@param changes DyTfChange[]
---@param dependents table<string, string[]>
---@return table<string, string[]> Block to the `address (action)` behind it
function M.affected(changes, dependents)
  local reached = {}
  for _, change in ipairs(changes) do
    if change.action == 'replace' or change.action == 'destroy' then
      local origin = ('%s (%s)'):format(block_address(change), change.action)
      local queue, seen = { block_address(change) }, {}
      seen[queue[1]] = true
      while #queue > 0 do
        local address = table.remove(queue, 1)
        for _, dependent in ipairs(dependents[address] or {}) do
          if not seen[dependent] then
            seen[dependent] = true
            table.insert(queue, dependent)
            reached[dependent] = reached[dependent] or {}
            if not vim.list_contains(reached[dependent], origin) then
              table.insert(reached[dependent], origin)
            end
          end
        end
      end
    end
  end
  return reached
end

--- One entry per block reached, on the block when it is in `blocks`
---@param reached table<string, string[]>
---@param blocks table<string, { file: string, line: integer }>
---@return DyTfEntry[]
function M.impact_entries(reached, blocks)
  local entries = {}
  local addresses = vim.tbl_keys(reached)
  table.sort(addresses)
  for _, address in ipairs(addresses) do
    local origins = reached[address]
    table.sort(origins)
    local key = (address:match('^module%.') or address:match('^data%.'))
        and address
      or ('resource.' .. address)
    local where = blocks[key]
    local text = '↳ depends on ' .. table.concat(origins, ', ')
    if not where then text = address .. ': ' .. text end
    table.insert(entries, {
      file = where and where.file,
      line = where and where.line,
      text = text,
      severity = vim.diagnostic.severity.INFO,
    })
  end
  return entries
end

--- The verdict on each directory this session; false while it is asked
---@type table<string, boolean>
local trusted = {}

--- Whether `dir` may be planned, or its state read: `plan` runs the
--- providers and the `external` data sources the project names, and `state`
--- the backend and the providers in its `.terraform`, as the user and with
--- their cloud credentials, so a directory is asked about once a session
---@param dir string
---@param bin string
---@param verb? string What is run, `plan` unless given
---@return boolean
function M.trusted(dir, bin, verb)
  if trusted[dir] ~= nil then return trusted[dir] end
  -- Pinned before asking: the prompt keeps handling events
  trusted[dir] = false
  local answer = vim.fn.confirm(
    ('Run `%s %s` in %s?\nIts backend, providers and external data sources run as you.'):format(
      bin,
      verb or 'plan',
      vim.fn.fnamemodify(dir, ':~')
    ),
    '&Run\n&Cancel',
    2
  )
  trusted[dir] = answer == 1 or nil
  return answer == 1
end

---@alias DyTfMode 'plan'|'drift'|'cost'|'impact'

--- Plan the module of the current buffer, and show on its blocks what the
--- plan does, what drifted, or what it costs
---@param mode? DyTfMode `plan` unless given
function M.run(mode)
  mode = mode or 'plan'
  local bin = M.binary()
  if not bin then
    return notify(
      'Neither tofu nor terraform is installed',
      vim.log.levels.ERROR
    )
  end
  if mode == 'cost' and vim.fn.executable('infracost') ~= 1 then
    return notify('infracost is not installed', vim.log.levels.ERROR)
  end
  local name = vim.api.nvim_buf_get_name(0)
  local dir = name ~= '' and vim.fs.dirname(name) or vim.uv.cwd() --[[@as string]]
  if not M.trusted(dir, bin) then return end
  local planfile = vim.fn.tempname()
  local jsonfile = planfile .. '.json'
  notify(
    ('%s %s with %s…'):format(
      mode == 'drift' and 'Looking for drift in' or 'Planning',
      vim.fn.fnamemodify(dir, ':~'),
      bin
    )
  )

  local function cleanup()
    vim.fn.delete(planfile)
    vim.fn.delete(jsonfile)
  end
  local function failed(what, result)
    cleanup()
    local err = vim.trim(result.stderr or '')
    if err == '' then err = vim.trim(result.stdout or '') end
    if result.timed_out then err = 'no answer in time' end
    if result.cut then err = 'more output than can be read' end
    if result.missing then err = result.stderr end
    notify(what .. ' failed:\n' .. err, vim.log.levels.ERROR)
  end

  --- Price the plan, as `show -json` printed it, block by block
  ---@param json string
  ---@param blocks table<string, { file: string, line: integer }>
  local function price(json, blocks)
    if not write_private(jsonfile, json) then
      cleanup()
      return notify(
        'Could not hand the plan to infracost',
        vim.log.levels.ERROR
      )
    end
    require('util.system').run({
      'infracost',
      'breakdown',
      '--path',
      jsonfile,
      '--format',
      'json',
      '--no-color',
    }, { cwd = dir, timeout = M.COST_TIMEOUT }, function(result)
      if result.code ~= 0 or result.cut then
        return failed('infracost', result)
      end
      cleanup()
      -- A `null` is nil, not a truthy `vim.NIL` that `ipairs` chokes on
      local ok, breakdown = pcall(
        vim.json.decode,
        result.stdout or '',
        { luanil = { object = true, array = true } }
      )
      if not ok or type(breakdown) ~= 'table' then
        return notify(
          'infracost printed something that is not JSON',
          vim.log.levels.ERROR
        )
      end
      local costs = M.costs(breakdown)
      M.show_costs(costs, blocks)
      notify('Monthly cost: ' .. M.cost_text(costs.total, costs.currency))
    end)
  end

  local command = { bin, 'plan', '-input=false', '-lock=false', '-no-color' }
  if mode == 'drift' then table.insert(command, '-refresh-only') end
  table.insert(command, '-out=' .. planfile)

  require('util.system').run(
    command,
    -- Never a prompt (a credential helper, say) fighting the editor for the
    -- terminal
    { cwd = dir, timeout = M.TIMEOUT, env = { TF_INPUT = '0' }, detach = true },
    function(result)
      if result.code ~= 0 or result.cut then return failed('plan', result) end
      require('util.system').run(
        { bin, 'show', '-json', planfile },
        { cwd = dir, timeout = M.TIMEOUT, max_bytes = M.MAX_PLAN },
        function(show)
          -- Half a plan would show fewer changes than there are
          if show.code ~= 0 or show.cut then return failed('show', show) end
          -- The binary plan is read; only `price` still needs the JSON
          vim.fn.delete(planfile)
          local ok, plan = pcall(vim.json.decode, show.stdout or '')
          if not ok or type(plan) ~= 'table' then
            cleanup()
            return notify(
              'show -json printed something that is not JSON',
              vim.log.levels.ERROR
            )
          end
          local blocks = M.index(dir)
          if mode == 'drift' then
            cleanup()
            local changes = M.changes(plan, 'resource_drift')
            local summary = M.drift_summary(changes)
            M.show(
              M.entries(changes, blocks, true),
              'Terraform drift: ' .. summary,
              'drift'
            )
            return notify(summary)
          end
          local changes = M.changes(plan)
          local summary = M.summary(changes)
          local entries = M.entries(changes, blocks)
          if mode == 'impact' then
            local reached =
              M.affected(changes, M.dependents(plan.configuration))
            local count = #vim.tbl_keys(reached)
            vim.list_extend(entries, M.impact_entries(reached, blocks))
            summary = summary
              .. ('; %d blocks depend on what is replaced or destroyed'):format(
                count
              )
          end
          M.show(entries, 'Terraform plan: ' .. summary)
          notify(summary)
          if mode == 'cost' then
            price(show.stdout, blocks)
          else
            cleanup()
          end
        end
      )
    end
  )
end

--- Plan the module of the current buffer, and show the plan on its blocks
function M.plan() M.run('plan') end

--- Show what changed outside the code, on the blocks it changed
function M.drift() M.run('drift') end

--- Plan, and show what each block will cost a month
function M.cost() M.run('cost') end

--- Plan, and show what depends on each block replaced or destroyed
function M.impact() M.run('impact') end

--- The subcommands of `:DyTfPlan`
M.SUBCOMMANDS = { 'clear', 'cost', 'drift', 'impact' }

--- `:DyTfPlan [clear|cost|drift|impact]`
---@param args { fargs: string[] }
function M.command(args)
  local sub = args.fargs[1]
  if not sub then return M.plan() end
  if sub == 'clear' then return M.clear() end
  if sub == 'cost' then return M.cost() end
  if sub == 'drift' then return M.drift() end
  if sub == 'impact' then return M.impact() end
  notify('Unknown subcommand: ' .. sub, vim.log.levels.ERROR)
end

--- The mappings of a Terraform buffer
---@param bufnr integer
function M.attach(bufnr)
  vim.keymap.set(
    'n',
    '<localleader>p',
    M.plan,
    { buffer = bufnr, desc = 'Plan (Terraform)' }
  )
  vim.keymap.set(
    'n',
    '<localleader>P',
    M.clear,
    { buffer = bufnr, desc = 'Clear Plan (Terraform)' }
  )
  vim.keymap.set(
    'n',
    '<localleader>d',
    M.drift,
    { buffer = bufnr, desc = 'Drift (Terraform)' }
  )
  vim.keymap.set(
    'n',
    '<localleader>c',
    M.cost,
    { buffer = bufnr, desc = 'Cost (Terraform)' }
  )
  vim.keymap.set(
    'n',
    '<localleader>i',
    M.impact,
    { buffer = bufnr, desc = 'Impact Of Replacements (Terraform)' }
  )
  place_costs(bufnr)
end

return M
