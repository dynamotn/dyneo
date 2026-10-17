--- The Terraform state, from the block being edited
---
--- What the state holds for a resource, whether the state holds anything
--- the code no longer declares, and the `import` block that brings an
--- existing object under a resource: each is a `state` command away, with
--- the address typed out. Here it starts from the block under the cursor.
---
--- The state holds every attribute in plain text, secrets included, so what
--- is shown of it is held back from every AI integration. Nothing here
--- writes the state: `state list` and `state show` only read it, and an
--- import is a block written into the buffer for a plan to carry out.
local M = {}

--- Milliseconds a `state` command may take: it reads a remote backend
M.TIMEOUT = 2 * 60 * 1000

local notify = require('util.notify').titled('Terraform state')

---@class DyTfBlock
---@field kind 'resource'|'data'|'module'
---@field type? string
---@field name string
---@field address string As the state names it: `aws_s3_bucket.logs`
---@field row integer 1-based line of its header
---@field counted boolean Whether it has a `count` or a `for_each`

--- The top-level block `row` sits in, or nil
---@param lines string[]
---@param row integer 1-based
---@return DyTfBlock?
function M.block_at(lines, row)
  for i = row, 1, -1 do
    local line = lines[i]
    if i < row and line:match('^}') then return nil end
    local kind, first, second =
      line:match('^(%a+)%s+"([^"]+)"%s*"?([^"%s{]*)"?%s*{')
    if kind == 'resource' or kind == 'data' or kind == 'module' then
      local block = { kind = kind, row = i, counted = false }
      if kind == 'module' then
        block.name, block.address = first, 'module.' .. first
      else
        block.type, block.name = first, second
        block.address = (kind == 'data' and 'data.' or '')
          .. first
          .. '.'
          .. second
      end
      for j = i + 1, #lines do
        if lines[j]:match('^}') then break end
        if
          lines[j]:match('^%s+count%s*=') or lines[j]:match('^%s+for_each%s*=')
        then
          block.counted = true
        end
      end
      return block
    end
    if line:match('^%S') and i < row then return nil end
  end
end

--- What a state address stands for in the code: `resource.<type>.<name>`,
--- `data.<type>.<name>` or `module.<name>`, the instance keys dropped
---@param address string
---@return string
function M.declared(address)
  address = address:gsub('%b[]', '')
  local module = address:match('^module%.([^.]+)')
  if module then return 'module.' .. module end
  if address:match('^data%.') then return address end
  return 'resource.' .. address
end

--- The addresses of the state no block of `blocks` declares
---@param addresses string[] What `state list` printed
---@param blocks table<string, any> `tools.tfplan.index` of the module
---@return string[]
function M.orphans(addresses, blocks)
  local out = {}
  for _, address in ipairs(addresses) do
    if address ~= '' and not blocks[M.declared(address)] then
      out[#out + 1] = address
    end
  end
  return out
end

--- The `import` block that brings object `id` under `address`
---@param address string
---@param id string
---@return string[]
function M.import_block(address, id)
  return {
    'import {',
    '  to = ' .. address,
    '  id = ' .. vim.json.encode(id),
    '}',
    '',
  }
end

--- Run `terraform state <args>` in `dir`, and hand over what it printed on
--- the main loop; a failure is said, and `on_done` not called
---@param dir string
---@param args string[]
---@param on_done fun(stdout: string)
local function state(dir, args, on_done)
  local bin = require('tools.tfplan').binary()
  if not bin then
    return notify(
      'Neither tofu nor terraform is installed',
      vim.log.levels.ERROR
    )
  end
  -- The backend and the provider binaries of `.terraform` run as the user
  if not require('tools.tfplan').trusted(dir, bin, 'state') then return end
  local system = require('util.system')
  system.run(vim.list_extend({ bin, 'state' }, args), {
    cwd = dir,
    timeout = M.TIMEOUT,
    -- Never a prompt for backend input fighting the editor for the terminal
    env = { TF_INPUT = '0' },
    detach = true,
  }, function(result)
    if result.code ~= 0 or result.cut then
      return notify(
        ('%s state %s failed:\n%s'):format(
          bin,
          args[1],
          result.cut and 'more output than can be read'
            or system.failure(result, bin)
        ),
        vim.log.levels.ERROR
      )
    end
    on_done(result.stdout or '')
  end)
end

--- The block under the cursor and the directory of its module, or nil
---@return DyTfBlock? block
---@return string? dir
local function current()
  local file = vim.api.nvim_buf_get_name(0)
  if file == '' then
    notify('This buffer holds no file', vim.log.levels.WARN)
    return nil
  end
  local block = M.block_at(
    vim.api.nvim_buf_get_lines(0, 0, -1, false),
    vim.api.nvim_win_get_cursor(0)[1]
  )
  if not block then
    notify(
      'The cursor is in no resource, data or module block',
      vim.log.levels.WARN
    )
    return nil
  end
  return block, vim.fs.dirname(file)
end

--- Show `lines` in a split held back from every AI integration
---@param lines string[]
---@param name string
local function show(lines, name)
  require('util.scratch').open(lines, {
    split = 'horizontal',
    filetype = 'terraform',
    name = name,
    sensitive = 'Terraform state, which holds secrets in plain text',
  })
end

--- What the state holds for the block under the cursor: one instance as
--- `state show` prints it, picked first when there are several; every
--- address of a module
function M.show()
  local block, dir = current()
  if not block or not dir then return end
  state(dir, { 'list', block.address }, function(out)
    local instances = vim.split(out, '\n', { trimempty = true })
    if #instances == 0 then
      return notify(
        block.address
          .. ' is not in the state; <localleader>I writes an import block',
        vim.log.levels.WARN
      )
    end
    if block.kind == 'module' then
      return show(instances, 'tfstate://' .. block.address)
    end
    local function open(instance)
      if not instance then return end
      state(
        dir,
        { 'show', '-no-color', instance },
        function(text)
          show(
            vim.split(vim.trim(text), '\n', { plain = true }),
            'tfstate://' .. instance
          )
        end
      )
    end
    if #instances == 1 then return open(instances[1]) end
    vim.ui.select(instances, { prompt = 'Instance' }, open)
  end)
end

--- What the state holds that no block of this module declares any more:
--- the objects a plan would destroy
function M.list_orphans()
  local file = vim.api.nvim_buf_get_name(0)
  if file == '' then
    return notify('This buffer holds no file', vim.log.levels.WARN)
  end
  local dir = vim.fs.dirname(file)
  state(dir, { 'list' }, function(out)
    local orphans = M.orphans(
      vim.split(out, '\n', { trimempty = true }),
      require('tools.tfplan').index(dir)
    )
    if #orphans == 0 then
      return notify('Every object of the state is declared in ' .. dir)
    end
    show(
      vim.list_extend({
        ('# In the state, declared nowhere in %s'):format(
          vim.fn.fnamemodify(dir, ':~:.')
        ),
        '# A plan destroys them; a `removed` block forgets them instead,',
        '# and a `moved` block hands them to the block that took them over.',
        '',
      }, orphans),
      'tfstate://orphans'
    )
  end)
end

--- Write an `import` block above the resource under the cursor, for an
--- object the state does not hold yet
function M.import()
  local block, dir = current()
  if not block or not dir then return end
  if block.kind ~= 'resource' then
    return notify('Only a resource is imported', vim.log.levels.WARN)
  end
  local bufnr = vim.api.nvim_get_current_buf()
  state(dir, { 'list', block.address }, function(out)
    if vim.trim(out) ~= '' then
      return notify(block.address .. ' is in the state already')
    end
    vim.ui.input(
      { prompt = ('ID of the object to import as %s: '):format(block.address) },
      function(id)
        if not id or vim.trim(id) == '' then return end
        if not vim.api.nvim_buf_is_valid(bufnr) then return end
        -- The buffer may have moved on while the state was read
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        local header
        for i, line in ipairs(lines) do
          if
            line:find(
              ('resource "%s" "%s"'):format(block.type, block.name),
              1,
              true
            ) == 1
          then
            header = i
            break
          end
        end
        if not header then
          return notify(
            block.address .. ' is no longer in the buffer',
            vim.log.levels.WARN
          )
        end
        vim.api.nvim_buf_set_lines(
          bufnr,
          header - 1,
          header - 1,
          false,
          M.import_block(block.address, vim.trim(id))
        )
        if block.counted then
          notify(
            block.address
              .. ' has a count or a for_each: give `to` the key of the instance',
            vim.log.levels.WARN
          )
        end
      end
    )
  end)
end

M.SUBCOMMANDS = {
  show = M.show,
  orphans = M.list_orphans,
  import = M.import,
}

--- `:DyTfState [show|orphans|import]`
---@param args { fargs: string[] }
function M.command(args)
  local sub = args.fargs[1] or 'show'
  local fn = M.SUBCOMMANDS[sub]
  if not fn then
    return notify('Unknown subcommand: ' .. sub, vim.log.levels.ERROR)
  end
  fn()
end

--- The mappings of a Terraform buffer
---@param bufnr integer
function M.attach(bufnr)
  local function map(lhs, rhs, desc)
    vim.keymap.set('n', lhs, rhs, { buffer = bufnr, desc = desc })
  end
  map('<localleader>s', M.show, 'State Of Block (Terraform)')
  map('<localleader>o', M.list_orphans, 'State Not In Code (Terraform)')
  map('<localleader>I', M.import, 'Import Block (Terraform)')
end

return M
