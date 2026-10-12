--- IPv4 ranges: what one holds, and which of a module's overlap
---
--- `:DyCidr` reads out the range under the cursor: its network and
--- broadcast address, its first and last host, its size and its mask.
--- `:DyCidr overlaps` reads every `.tf` and `.tfvars` file beside the buffer
--- and lists in the quickfix list the ranges that collide. Only keys that
--- define a network count (`cidr_block`, `private_subnets`, `address_space`,
--- ...), never the `cidr_blocks` a rule lets in. A range inside a whole
--- network (`M.NETWORK_KEYS`) is a subnet of it and fine; two ranges the
--- same, a subnet inside another, or a network inside another, are not.
local M = {}

local notify = require('util.notify').titled('CIDR')

--- Endings of the keys that define a network rather than allow one
M.KEYS = {
  'cidr',
  'cidr_block',
  'cidr_range',
  'address_prefix',
  'address_prefixes',
  'address_space',
  'subnets',
}

--- Files read by `overlaps`, and the bytes read of each
M.MAX_FILES = 200
M.MAX_BYTES = 1024 * 1024

---@class DyCidr
---@field text string As written, `10.0.0.0/16`
---@field address integer
---@field prefix integer
---@field first integer The network address
---@field last integer The broadcast address

--- `text` read as an IPv4 range, or nil when it is none
---@param text string
---@return DyCidr?
function M.parse(text)
  local a, b, c, d, prefix = text:match('^(%d+)%.(%d+)%.(%d+)%.(%d+)/(%d+)$')
  if not a then return nil end
  local octets = { tonumber(a), tonumber(b), tonumber(c), tonumber(d) }
  prefix = tonumber(prefix)
  if prefix > 32 then return nil end
  local address = 0
  for _, octet in ipairs(octets) do
    if octet > 255 then return nil end
    address = address * 256 + octet
  end
  -- Arithmetic, not `bit`: LuaJIT's bit operations are signed 32-bit
  local size = 2 ^ (32 - prefix)
  local first = math.floor(address / size) * size
  return {
    text = text,
    address = address,
    prefix = prefix,
    first = first,
    last = first + size - 1,
  }
end

--- `n` as a dotted address
---@param n integer
---@return string
function M.dotted(n)
  local parts = {}
  for i = 3, 0, -1 do
    table.insert(parts, math.floor(n / 256 ^ i) % 256)
  end
  return table.concat(parts, '.')
end

--- What `cidr` holds, a line each
---@param cidr DyCidr
---@return string[]
function M.describe(cidr)
  local size = cidr.last - cidr.first + 1
  -- /31 and /32 have no network or broadcast address to set aside
  local hosts = cidr.prefix >= 31 and size or size - 2
  local low = cidr.prefix >= 31 and cidr.first or cidr.first + 1
  local high = cidr.prefix >= 31 and cidr.last or cidr.last - 1
  local lines = {
    ('Network   %s/%d'):format(M.dotted(cidr.first), cidr.prefix),
    ('Netmask   %s'):format(M.dotted(2 ^ 32 - 2 ^ (32 - cidr.prefix))),
    ('Hosts     %s – %s (%d)'):format(M.dotted(low), M.dotted(high), hosts),
    ('Broadcast %s'):format(M.dotted(cidr.last)),
    ('Addresses %d'):format(size),
  }
  if cidr.address ~= cidr.first then
    table.insert(lines, ('%s is not the network address'):format(cidr.text))
  end
  return lines
end

--- The range written around byte `col` (1-based) of `line`
---@param line string
---@param col integer
---@return string?
function M.at(line, col)
  for s, text, e in line:gmatch('()(%d+%.%d+%.%d+%.%d+/%d+)()') do
    if col >= s and col < e then return text end
  end
  return nil
end

--- Whether `key` defines a network
---@param key string
---@return boolean
local function defining(key)
  for _, ending in ipairs(M.KEYS) do
    if key == ending or vim.endswith(key, '_' .. ending) then return true end
  end
  return false
end

--- Endings of the keys of `M.KEYS` that define a whole network (a VPC, a
--- VNet), the only ranges others may lie inside
M.NETWORK_KEYS = { 'cidr', 'cidr_block', 'address_space' }

--- Whether `key`, under a resource of type `resource`, defines a whole
--- network rather than a subnet of one
---@param key string
---@param resource? string
---@return boolean
local function network(key, resource)
  -- `aws_subnet` names its range `cidr_block` too, as does a variable
  -- `subnet_cidr_block`
  if (key .. ' ' .. (resource or '')):find('subnet') then return false end
  for _, ending in ipairs(M.NETWORK_KEYS) do
    if key == ending or vim.endswith(key, '_' .. ending) then return true end
  end
  return false
end

---@class DyCidrEntry: DyCidr
---@field filename string
---@field lnum integer
---@field col integer
---@field network boolean Whether it defines a whole network

--- The ranges `lines` define, under a key of `M.KEYS`; a list may run over
--- several lines
---@param lines string[]
---@param filename string
---@return DyCidrEntry[]
---@return integer ipv6 The IPv6 ranges under those keys, not read
function M.collect(lines, filename)
  local found, ipv6, list_key, resource = {}, 0, nil, nil
  for lnum, line in ipairs(lines) do
    resource = line:match('^resource%s+"([%w_]+)"')
      or (not line:match('^}') and resource or nil)
    local key = line:match('^%s*"?([%w_]+)"?%s*[=:]')
    if key then
      list_key = defining(key)
          and line:find('[', 1, true) ~= nil
          and not line:find(']', 1, true)
          and key
        or nil
    end
    local owner = key and defining(key) and key or (not key and list_key)
    if owner then
      for col, text in line:gmatch('()(%d+%.%d+%.%d+%.%d+/%d+)') do
        local cidr = M.parse(text)
        if cidr then
          cidr.filename, cidr.lnum, cidr.col = filename, lnum, col
          cidr.network = network(owner, resource)
          table.insert(found, cidr)
        end
      end
      for _ in line:gmatch('[%x:]*:[%x:]*/%d+') do
        ipv6 = ipv6 + 1
      end
    end
    if not key and list_key and line:find(']', 1, true) then list_key = nil end
  end
  return found, ipv6
end

---@class DyCidrOverlap
---@field entry DyCidrEntry
---@field other DyCidrEntry
---@field kind 'same'|'inside'

--- The pairs of `entries` that collide: the same range twice, or one inside
--- another that is no whole network -- or that is one itself, as two VPCs
---@param entries DyCidrEntry[]
---@return DyCidrOverlap[]
function M.overlaps(entries)
  ---@param a DyCidrEntry
  ---@param b DyCidrEntry
  local function nested(a, b)
    return a.first >= b.first
      and a.last <= b.last
      and (a.first ~= b.first or a.last ~= b.last)
      and (a.network or not b.network)
  end
  local found = {}
  for i, a in ipairs(entries) do
    for j = i + 1, #entries do
      local b = entries[j]
      if a.first == b.first and a.last == b.last then
        table.insert(found, { entry = b, other = a, kind = 'same' })
      elseif nested(a, b) then
        table.insert(found, { entry = a, other = b, kind = 'inside' })
      elseif nested(b, a) then
        table.insert(found, { entry = b, other = a, kind = 'inside' })
      end
    end
  end
  return found
end

--- Read out the range under the cursor
function M.under_cursor()
  local _, col = unpack(vim.api.nvim_win_get_cursor(0))
  local text = M.at(vim.api.nvim_get_current_line(), col + 1)
  local cidr = text and M.parse(text)
  if not cidr then
    return notify('No IPv4 range under the cursor', vim.log.levels.WARN)
  end
  notify(table.concat(M.describe(cidr), '\n'))
end

--- The lines of `file`: the buffer's when it is loaded, else what is on disk
---@param file string
---@return string[]
local function lines_of(file)
  -- By name, not `bufnr(file)`: that is a pattern, and `prod.tf` would
  -- match a loaded `prod.tfvars`
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if
      vim.api.nvim_buf_is_loaded(bufnr)
      and vim.api.nvim_buf_get_name(bufnr) == file
    then
      return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    end
  end
  local fd = io.open(file, 'r')
  if not fd then return {} end
  local text = fd:read(M.MAX_BYTES) or ''
  fd:close()
  return vim.split(text, '\n', { plain = true })
end

--- List the colliding ranges of the module of the current buffer
function M.check()
  local file = vim.api.nvim_buf_get_name(0)
  local files = {}
  if file == '' then
    return notify('This buffer holds no file', vim.log.levels.WARN)
  end
  for name, kind in vim.fs.dir(vim.fs.dirname(file)) do
    if kind == 'file' and (name:match('%.tf$') or name:match('%.tfvars$')) then
      table.insert(files, vim.fs.joinpath(vim.fs.dirname(file), name))
    end
  end
  if not vim.list_contains(files, file) then table.insert(files, file) end
  table.sort(files)
  local cut = #files > M.MAX_FILES
  local entries, ipv6 = {}, 0
  for i = 1, math.min(#files, M.MAX_FILES) do
    local found, skipped = M.collect(lines_of(files[i]), files[i])
    vim.list_extend(entries, found)
    ipv6 = ipv6 + skipped
  end
  if ipv6 > 0 then
    notify(
      ('%d IPv6 ranges not checked: only IPv4 is read'):format(ipv6),
      vim.log.levels.WARN
    )
  end
  local items = {}
  for _, overlap in ipairs(M.overlaps(entries)) do
    local e, o = overlap.entry, overlap.other
    table.insert(items, {
      filename = e.filename,
      lnum = e.lnum,
      col = e.col,
      type = 'W',
      text = ('%s %s %s (%s:%d)'):format(
        e.text,
        overlap.kind == 'same' and 'is the same range as' or 'is inside',
        o.text,
        vim.fn.fnamemodify(o.filename, ':t'),
        o.lnum
      ),
    })
  end
  local suffix = cut and (', only the first %d files read'):format(M.MAX_FILES)
    or ''
  if #items == 0 then
    return notify(
      ('No overlap among %d ranges%s'):format(#entries, suffix),
      cut and vim.log.levels.WARN or nil
    )
  end
  vim.fn.setqflist({}, ' ', { title = 'Overlapping ranges', items = items })
  vim.cmd('botright copen')
  notify(
    ('%d overlapping ranges%s'):format(#items, suffix),
    vim.log.levels.WARN
  )
end

--- `:DyCidr [overlaps]`
---@param args { fargs: string[] }
function M.command(args)
  local sub = args.fargs[1]
  if not sub then return M.under_cursor() end
  if sub == 'overlaps' then return M.check() end
  notify('Unknown subcommand: ' .. sub, vim.log.levels.ERROR)
end

return M
