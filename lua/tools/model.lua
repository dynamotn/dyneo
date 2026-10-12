--- What a model file holds: the header of a `.safetensors` or `.gguf` file
---
--- Both formats put a header in front of the weights: safetensors a JSON
--- object behind its length, GGUF a binary list of metadata and tensors.
--- Opening one shows that header instead of gigabytes of bytes: the
--- metadata, every tensor with its type and shape, and how many parameters
--- they add up to. Only the header is read, a chunk at a time.
---
--- A model file usually comes from elsewhere, so nothing in it is trusted:
--- every length is checked against the file and against `M.MAX_HEADER`, and
--- a header that does not read says why instead of showing half of it.
local M = {}

--- Bytes of header read at most: safetensors caps its own at 100 MB, and
--- the tokenizer of a large GGUF vocabulary takes a few MiB
M.MAX_HEADER = 128 * 1024 * 1024
--- Bytes read from the file at a time
M.CHUNK = 1024 * 1024
--- Longest metadata string shown, and most array items listed
M.MAX_TEXT = 120
M.MAX_ITEMS = 8

--- Names of the GGML tensor types GGUF stores, by number
M.GGML_TYPES = {
  [0] = 'F32',
  [1] = 'F16',
  [2] = 'Q4_0',
  [3] = 'Q4_1',
  [6] = 'Q5_0',
  [7] = 'Q5_1',
  [8] = 'Q8_0',
  [9] = 'Q8_1',
  [10] = 'Q2_K',
  [11] = 'Q3_K',
  [12] = 'Q4_K',
  [13] = 'Q5_K',
  [14] = 'Q6_K',
  [15] = 'Q8_K',
  [16] = 'IQ2_XXS',
  [17] = 'IQ2_XS',
  [18] = 'IQ3_XXS',
  [19] = 'IQ1_S',
  [20] = 'IQ4_NL',
  [21] = 'IQ3_S',
  [22] = 'IQ2_S',
  [23] = 'IQ4_XS',
  [24] = 'I8',
  [25] = 'I16',
  [26] = 'I32',
  [27] = 'I64',
  [28] = 'F64',
  [29] = 'IQ1_M',
  [30] = 'BF16',
  [34] = 'TQ1_0',
  [35] = 'TQ2_0',
  [39] = 'MXFP4',
}

--- An unsigned little-endian integer of `n` bytes from `s` at `i`
---@param s string
---@param i integer
---@param n integer
---@return number
local function uint(s, i, n)
  local value = 0
  for k = n, 1, -1 do
    value = value * 256 + s:byte(i + k - 1)
  end
  return value
end

--- A signed little-endian integer of `n` bytes
local function int(s, i, n)
  local value = uint(s, i, n)
  if value >= 2 ^ (8 * n - 1) then value = value - 2 ^ (8 * n) end
  return value
end

--- An IEEE 754 float of 4 or 8 bytes, built from its bytes: a 64-bit
--- integer would round the mantissa
local function float(s, i, n)
  local b = { s:byte(i, i + n - 1) }
  local exp_bits, top = n == 4 and 8 or 11, b[n]
  local sign = top >= 128 and -1 or 1
  local exponent, mantissa, mant_bits
  if n == 4 then
    exponent = (top % 128) * 2 + math.floor(b[3] / 128)
    mantissa = (b[3] % 128) * 2 ^ 16 + b[2] * 2 ^ 8 + b[1]
    mant_bits = 23
  else
    exponent = (top % 128) * 16 + math.floor(b[7] / 16)
    mantissa = (b[7] % 16) * 2 ^ 48
    for k = 6, 1, -1 do
      mantissa = mantissa + b[k] * 2 ^ (8 * (k - 1))
    end
    mant_bits = 52
  end
  local bias = 2 ^ (exp_bits - 1) - 1
  if exponent == 2 ^ exp_bits - 1 then
    return mantissa == 0 and sign * math.huge or 0 / 0
  end
  if exponent == 0 then
    return sign * mantissa / 2 ^ mant_bits * 2 ^ (1 - bias)
  end
  return sign * (1 + mantissa / 2 ^ mant_bits) * 2 ^ (exponent - bias)
end

--- Reads the file from its start, a chunk at a time, never past its end or
--- `M.MAX_HEADER`
---@param fd integer
---@param size integer
local function reader(fd, size)
  local self = { pos = 0 }
  local chunk, start = '', 0

  local function check(n)
    if n < 0 or self.pos + n > size then
      error('the file ends inside its header', 0)
    end
    if self.pos + n > M.MAX_HEADER then
      error(('the header is over %d MiB'):format(M.MAX_HEADER / 1024 / 1024), 0)
    end
  end

  ---@param n integer
  ---@return string
  function self.read(n)
    check(n)
    -- Most reads are a few bytes inside the chunk already read
    local offset = self.pos - start
    if offset >= 0 and offset + n <= #chunk then
      self.pos = self.pos + n
      return chunk:sub(offset + 1, offset + n)
    end
    local parts = {}
    while n > 0 do
      local offset = self.pos - start
      if offset < 0 or offset >= #chunk then
        chunk = assert(vim.uv.fs_read(fd, M.CHUNK, self.pos))
        start, offset = self.pos, 0
        if chunk == '' then error('the file ends inside its header', 0) end
      end
      local piece = chunk:sub(offset + 1, offset + n)
      table.insert(parts, piece)
      self.pos, n = self.pos + #piece, n - #piece
    end
    return table.concat(parts)
  end

  ---@param n integer
  function self.skip(n)
    check(n)
    self.pos = self.pos + n
  end

  function self.u32() return uint(self.read(4), 1, 4) end
  function self.u64() return uint(self.read(8), 1, 8) end

  return self
end

--- `text` on one line, cut at `M.MAX_TEXT`
---@param text string
---@return string
local function short(text)
  text = text:gsub('[%c]+', ' ')
  if #text > M.MAX_TEXT then return text:sub(1, M.MAX_TEXT) .. '…' end
  return text
end

--- `n` with a unit: 8.03 B, 124.4 M, 512
---@param n number
---@return string
function M.count(n)
  for _, unit in ipairs({
    { 1e12, 'T' },
    { 1e9, 'B' },
    { 1e6, 'M' },
    { 1e3, 'K' },
  }) do
    if n >= unit[1] then return ('%.2f %s'):format(n / unit[1], unit[2]) end
  end
  return tostring(n)
end

--- `bytes` in binary units
---@param bytes number
---@return string
function M.size(bytes)
  for _, unit in ipairs({
    { 2 ^ 40, 'TiB' },
    { 2 ^ 30, 'GiB' },
    { 2 ^ 20, 'MiB' },
    { 2 ^ 10, 'KiB' },
  }) do
    if bytes >= unit[1] then
      return ('%.2f %s'):format(bytes / unit[1], unit[2])
    end
  end
  return ('%d B'):format(bytes)
end

---@class DyModelTensor
---@field name string
---@field dtype string
---@field shape number[]

---@class DyModelHeader
---@field format string
---@field metadata [string, string][] Key and value as shown, in file order
---@field tensors DyModelTensor[]

--- GGUF value types, by number: the reader of a scalar, or the name of one
local GGUF_SCALARS = {
  [0] = { 1, uint, 'u8' },
  [1] = { 1, int, 'i8' },
  [2] = { 2, uint, 'u16' },
  [3] = { 2, int, 'i16' },
  [4] = { 4, uint, 'u32' },
  [5] = { 4, int, 'i32' },
  [6] = { 4, float, 'f32' },
  [10] = { 8, uint, 'u64' },
  [11] = { 8, int, 'i64' },
  [12] = { 8, float, 'f64' },
}

--- One GGUF metadata value of type `kind`, as shown
---@param r table
---@param kind integer
---@return string
local function gguf_value(r, kind)
  local scalar = GGUF_SCALARS[kind]
  if scalar then
    local value = scalar[2](r.read(scalar[1]), 1, scalar[1])
    if scalar[2] == float then return ('%.6g'):format(value) end
    return ('%.0f'):format(value)
  end
  if kind == 7 then return r.read(1):byte() ~= 0 and 'true' or 'false' end
  if kind == 8 then return short(r.read(r.u64())) end
  if kind == 9 then
    local item, count = r.u32(), r.u64()
    local shown = {}
    for index = 1, count do
      if index <= M.MAX_ITEMS then
        table.insert(shown, gguf_value(r, item))
      elseif item == 8 then
        r.skip(r.u64())
      elseif GGUF_SCALARS[item] or item == 7 then
        -- The rest of the array at once: a vocabulary is 100k items
        local width = item == 7 and 1 or GGUF_SCALARS[item][1]
        r.skip(width * (count - index + 1))
        break
      else
        gguf_value(r, item)
      end
    end
    if count <= M.MAX_ITEMS then
      return '[' .. table.concat(shown, ', ') .. ']'
    end
    local name = item == 8 and 'string'
      or item == 7 and 'bool'
      or (GGUF_SCALARS[item] or { nil, nil, 'array' })[3]
    return ('[%s %s]'):format(M.count(count), name)
  end
  error(('unknown metadata type %d'):format(kind), 0)
end

--- The header of a GGUF file
---@param r table
---@return DyModelHeader
local function gguf(r)
  local version = r.u32()
  local tensor_count, kv_count = r.u64(), r.u64()
  local header =
    { format = ('GGUF v%d'):format(version), metadata = {}, tensors = {} }
  for _ = 1, kv_count do
    local key = r.read(r.u64())
    table.insert(header.metadata, { key, gguf_value(r, r.u32()) })
  end
  for _ = 1, tensor_count do
    local name = r.read(r.u64())
    local shape = {}
    for _ = 1, r.u32() do
      table.insert(shape, r.u64())
    end
    local kind = r.u32()
    r.skip(8) -- offset of the data
    table.insert(header.tensors, {
      name = name,
      dtype = M.GGML_TYPES[kind] or ('type %d'):format(kind),
      shape = shape,
    })
  end
  return header
end

--- The header of a safetensors file
---@param r table
---@return DyModelHeader
local function safetensors(r)
  local ok, json = pcall(vim.json.decode, r.read(r.u64()))
  if not ok or type(json) ~= 'table' then
    error('the header is no JSON object', 0)
  end
  local header = { format = 'safetensors', metadata = {}, tensors = {} }
  local names = vim.tbl_keys(json)
  table.sort(names)
  for _, name in ipairs(names) do
    local entry = json[name]
    if name == '__metadata__' and type(entry) == 'table' then
      local keys = vim.tbl_keys(entry)
      table.sort(keys)
      for _, key in ipairs(keys) do
        table.insert(header.metadata, { key, short(tostring(entry[key])) })
      end
    elseif type(entry) == 'table' and type(entry.shape) == 'table' then
      table.insert(header.tensors, {
        name = name,
        dtype = tostring(entry.dtype),
        shape = vim.tbl_filter(
          function(d) return type(d) == 'number' end,
          entry.shape
        ),
      })
    end
  end
  return header
end

--- Read the header of the model file at `path`
---@param path string
---@return DyModelHeader? header
---@return string? err Why it could not be read
function M.header(path)
  local fd, open_err = vim.uv.fs_open(path, 'r', 0)
  if not fd then return nil, open_err end
  local ok, result = pcall(function()
    local r = reader(fd, assert(vim.uv.fs_fstat(fd)).size)
    if path:lower():match('%.gguf$') then
      if r.read(4) ~= 'GGUF' then error('no GGUF magic at its start', 0) end
      return gguf(r)
    end
    return safetensors(r)
  end)
  vim.uv.fs_close(fd)
  if not ok then return nil, tostring(result) end
  return result
end

--- The lines describing `header`
---@param path string
---@param header DyModelHeader
---@return string[]
function M.lines(path, header)
  local stat = vim.uv.fs_stat(path)
  local params, dtypes, order = 0, {}, {}
  local width = 4
  for _, tensor in ipairs(header.tensors) do
    local n = 1
    for _, d in ipairs(tensor.shape) do
      n = n * d
    end
    params = params + n
    if not dtypes[tensor.dtype] then table.insert(order, tensor.dtype) end
    dtypes[tensor.dtype] = (dtypes[tensor.dtype] or 0) + 1
    width = math.max(width, math.min(#tensor.name, 60))
  end
  local by_type = vim.tbl_map(
    function(dtype) return ('%s %d'):format(dtype, dtypes[dtype]) end,
    order
  )
  local lines = {
    ('%s  %s  %s'):format(
      vim.fs.basename(path),
      header.format,
      stat and M.size(stat.size) or ''
    ),
    ('%s parameters in %d tensors: %s'):format(
      M.count(params),
      #header.tensors,
      table.concat(by_type, ', ')
    ),
  }
  if #header.metadata > 0 then
    vim.list_extend(lines, { '', 'Metadata' })
    for _, kv in ipairs(header.metadata) do
      table.insert(lines, ('  %s = %s'):format(kv[1], kv[2]))
    end
  end
  vim.list_extend(lines, { '', 'Tensors' })
  for _, tensor in ipairs(header.tensors) do
    local dims = vim.tbl_map(
      function(d) return ('%.0f'):format(d) end,
      tensor.shape
    )
    table.insert(
      lines,
      ('  %-' .. width .. 's  %-7s %s'):format(
        tensor.name,
        tensor.dtype,
        table.concat(dims, ' × ')
      )
    )
  end
  return lines
end

--- Show the header of a model file in its buffer, read through
--- `BufReadCmd`, in place of its bytes
---@param bufnr integer
function M.read(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  -- `fugitive://`, `scp://`, `oil://`: a buffer another plugin reads
  if name:match('^%a[%w+.-]*://') then return end
  local path = vim.fs.normalize(vim.fn.fnamemodify(name, ':p'))
  -- The summary is no copy of the file: it must never be written over it
  vim.bo[bufnr].buftype = 'nofile'
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].undofile = false
  local header, err = M.header(path)
  local lines = header and M.lines(path, header)
    or { ('%s: cannot read its header: %s'):format(vim.fs.basename(path), err) }
  require('util.scratch').set(bufnr, lines)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].filetype = 'dymodel'
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    vim.wo[win].wrap = false
  end
end

return M
