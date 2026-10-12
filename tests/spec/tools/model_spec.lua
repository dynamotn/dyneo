local h = require('helpers')

--- `n` as `bytes` little-endian bytes
local function le(n, bytes)
  local out = {}
  for i = 1, bytes do
    out[i] = string.char(n % 256)
    n = math.floor(n / 256)
  end
  return table.concat(out)
end

--- A GGUF string: its length, then its bytes
local function str(s) return le(#s, 8) .. s end

--- A GGUF metadata entry
local function kv(key, kind, value) return str(key) .. le(kind, 4) .. value end

local tokens = {}
for i = 1, 10 do
  tokens[i] = str('tok' .. i)
end

local GGUF = table.concat({
  'GGUF',
  le(3, 4), -- version
  le(2, 8), -- tensors
  le(8, 8), -- metadata entries
  kv('general.architecture', 8, str('llama')),
  kv('llama.context_length', 4, le(4096, 4)),
  kv('llama.rope.freq_base', 6, '\0\64\28\70'), -- 10000.0 as f32
  kv('general.ratio', 12, '\0\0\0\0\0\0\224\63'), -- 0.5 as f64
  kv('general.offset', 5, le(2 ^ 32 - 2, 4)), -- -2 as i32
  kv('general.quantized', 7, '\1'),
  kv(
    'general.layers',
    9,
    le(5, 4) .. le(3, 8) .. le(1, 4) .. le(2, 4) .. le(3, 4)
  ),
  kv(
    'tokenizer.ggml.tokens',
    9,
    le(8, 4) .. le(#tokens, 8) .. table.concat(tokens)
  ),
  -- tensors: name, dimensions, type, offset
  str('token_embd.weight') .. le(2, 4) .. le(4096, 8) .. le(32000, 8) .. le(
    12,
    4
  ) .. le(0, 8),
  str('output_norm.weight') .. le(1, 4) .. le(4096, 8) .. le(0, 4) .. le(0, 8),
})

local SAFETENSORS_HEADER = vim.json.encode({
  __metadata__ = { format = 'pt' },
  ['model.embed.weight'] = {
    dtype = 'F32',
    shape = { 2, 3 },
    data_offsets = { 0, 24 },
  },
  ['model.norm.weight'] = {
    dtype = 'BF16',
    shape = { 4 },
    data_offsets = { 24, 32 },
  },
})
local SAFETENSORS = le(#SAFETENSORS_HEADER, 8)
  .. SAFETENSORS_HEADER
  .. ('\0'):rep(32)

describe('tools.model', function()
  local model, dir, cleanup

  before_each(function()
    h.unload('tools.model')
    model = require('tools.model')
    dofile(h.root .. '/plugin/model.lua')
    dir, cleanup = h.tmpdir()
  end)
  after_each(function()
    vim.cmd('silent! %bwipeout!')
    cleanup()
  end)

  --- Write `bytes` to a file of the scratch directory, and give its path
  local function file(name, bytes)
    local path = dir .. '/' .. name
    local fd = assert(io.open(path, 'wb'))
    fd:write(bytes)
    fd:close()
    return path
  end

  it('reads the metadata and tensors of a GGUF file', function()
    local header = assert(model.header(file('m.gguf', GGUF)))
    assert.equal('GGUF v3', header.format)
    assert.same({
      { 'general.architecture', 'llama' },
      { 'llama.context_length', '4096' },
      { 'llama.rope.freq_base', '10000' },
      { 'general.ratio', '0.5' },
      { 'general.offset', '-2' },
      { 'general.quantized', 'true' },
      { 'general.layers', '[1, 2, 3]' },
      -- A vocabulary is counted, not listed
      { 'tokenizer.ggml.tokens', '[10 string]' },
    }, header.metadata)
    assert.same({
      { name = 'token_embd.weight', dtype = 'Q4_K', shape = { 4096, 32000 } },
      { name = 'output_norm.weight', dtype = 'F32', shape = { 4096 } },
    }, header.tensors)
  end)

  it('reads the metadata and tensors of a safetensors file', function()
    local header = assert(model.header(file('m.safetensors', SAFETENSORS)))
    assert.same({ { 'format', 'pt' } }, header.metadata)
    assert.same({
      { name = 'model.embed.weight', dtype = 'F32', shape = { 2, 3 } },
      { name = 'model.norm.weight', dtype = 'BF16', shape = { 4 } },
    }, header.tensors)
  end)

  it('adds the parameters up', function()
    local path = file('m.gguf', GGUF)
    local lines = model.lines(path, assert(model.header(path)))
    assert.matches('GGUF v3', lines[1])
    assert.equal('131.08 M parameters in 2 tensors: Q4_K 1, F32 1', lines[2])
    assert.is_true(vim.list_contains(lines, '  general.architecture = llama'))
  end)

  it('says why a header does not read, rather than showing half', function()
    local cases = {
      ['cut.gguf'] = GGUF:sub(1, 200),
      ['magic.gguf'] = 'GGML' .. GGUF:sub(5),
      -- A string claiming more bytes than the file has
      ['long.gguf'] = 'GGUF' .. le(3, 4) .. le(0, 8) .. le(1, 8) .. le(
        2 ^ 50,
        8
      ),
      ['long.safetensors'] = le(2 ^ 40, 8) .. '{}',
      ['bad.safetensors'] = le(3, 8) .. 'abc',
    }
    for name, bytes in pairs(cases) do
      local header, err = model.header(file(name, bytes))
      assert.is_nil(header, name)
      assert.is_string(err, name)
    end
    local nested = le(9, 4) .. le(1, 8)
    local crafted = {
      ['v1.gguf'] = 'GGUF' .. le(1, 4) .. GGUF:sub(9),
      -- A tensor of 9 dimensions, beyond any GGML has
      ['dims.gguf'] = 'GGUF'
        .. le(3, 4)
        .. le(1, 8)
        .. le(0, 8)
        .. str('t')
        .. le(9, 4)
        .. ('\1\0\0\0\0\0\0\0'):rep(9)
        .. le(0, 4)
        .. le(0, 8),
      -- Arrays of arrays, five deep
      ['deep.gguf'] = 'GGUF'
        .. le(3, 4)
        .. le(0, 8)
        .. le(1, 8)
        .. str('k')
        .. le(9, 4)
        .. nested:rep(4)
        .. le(4, 4)
        .. le(1, 8)
        .. le(7, 4),
      ['list.safetensors'] = le(5, 8) .. '[1,2]',
    }
    for name, bytes in pairs(crafted) do
      local header, err = model.header(file(name, bytes))
      assert.is_nil(header, name)
      assert.is_string(err, name)
    end
    -- A header longer than the cap is not read whole
    model.MAX_HEADER = 64
    assert.matches('over', select(2, model.header(file('m.gguf', GGUF))))
  end)

  it(
    'opens a model as its header, in a buffer that cannot be written',
    function()
      local path = file('m.safetensors', SAFETENSORS)
      vim.cmd.edit(path)
      local bufnr = vim.api.nvim_get_current_buf()
      assert.matches(
        '^m%.safetensors  safetensors',
        vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
      )
      assert.equal('nofile', vim.bo[bufnr].buftype)
      assert.is_false(vim.bo[bufnr].modifiable)
      assert.is_false(pcall(vim.cmd.write))
      local fd = assert(io.open(path, 'rb'))
      assert.equal(SAFETENSORS, fd:read('*a'))
      fd:close()
    end
  )

  it('keeps a name holding a line break on one line', function()
    local json = vim.json.encode({
      ['a\nb'] = { dtype = 'F\n32', shape = { 2 } },
      __metadata__ = { ['k\ney'] = 'v' },
    })
    local path = file('n.safetensors', le(#json, 8) .. json)
    vim.cmd.edit(path)
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    assert.is_true(vim.list_contains(lines, '  k ey = v'))
    assert.matches('^  a b ', lines[#lines])
  end)

  it('shows why a model it opens does not read', function()
    vim.cmd.edit(file('cut.gguf', GGUF:sub(1, 30)))
    assert.matches(
      'cannot read its header: the file ends inside its header',
      vim.api.nvim_get_current_line()
    )
  end)
end)
