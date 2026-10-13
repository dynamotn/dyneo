local h = require('helpers')

-- `plugin/asyncapi.lua` keeps its own copy of the detection, so a YAML or
-- JSON buffer that is no AsyncAPI document never loads `tools.asyncapi`;
-- the two must still agree on every buffer
describe('plugin/asyncapi', function()
  local asyncapi, attached, restore

  before_each(function()
    h.unload('tools.asyncapi')
    asyncapi = require('tools.asyncapi')
    attached = {}
    restore = h.stub(
      asyncapi,
      'attach',
      function(bufnr) attached[bufnr] = true end
    )
    dofile(h.root .. '/plugin/asyncapi.lua')
  end)
  after_each(function()
    restore()
    vim.cmd('silent! %bwipeout!')
  end)

  ---@param n integer
  ---@return string[]
  local function filler(n)
    local lines = {}
    for i = 1, n do
      lines[i] = ('x%d: 1'):format(i)
    end
    return lines
  end

  local head_lines = require('tools.asyncapi').HEAD_LINES
  local cases = {
    { 'asyncapi: 3.0.0', 'info:' },
    { '{', '  "asyncapi": "3.0.0",' },
    { 'openapi: 3.1.0' },
    { '  asyncapi: 3.0.0' },
    vim.list_extend(filler(head_lines - 1), { 'asyncapi: 3.0.0' }),
    vim.list_extend(filler(head_lines), { 'asyncapi: 3.0.0' }),
  }

  for i, lines in ipairs(cases) do
    for _, filetype in ipairs({ 'yaml', 'json' }) do
      it(
        ('agrees with the module on case %d (%s)'):format(i, filetype),
        function()
          local bufnr = h.buffer({ lines = lines })
          vim.bo[bufnr].filetype = filetype
          assert.equals(asyncapi.is_document(lines), attached[bufnr] == true)
        end
      )
    end
  end
end)
