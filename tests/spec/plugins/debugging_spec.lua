local h = require('helpers')

describe('plugins.executor.debugging: run with args', function()
  local restores, typed, args_of

  before_each(function()
    h.globals()
    local before
    restores = {
      h.stub(package.loaded, 'dap', {
        continue = function(opts) before = opts.before end,
      }),
      h.stub(package.loaded, 'dap.utils', {
        splitstr = function(str)
          return vim.split(str, ' ', { trimempty = true })
        end,
      }),
      h.stub(vim.fn, 'input', function() return typed end),
    }
    for _, plugin in
      ipairs(dofile(h.root .. '/lua/plugins/executor/debugging.lua'))
    do
      if plugin[1] == 'mfussenegger/nvim-dap' then
        for _, key in ipairs(plugin.keys) do
          if key[1] == '<leader>da' then key[2]() end
        end
      end
    end
    --- The arguments a run gets from what is typed
    ---@param config table
    ---@return string[]|string
    args_of = function(config) return before(config).args() end
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
  end)

  it('expands each argument on its own', function()
    typed = '% -v ~/x *.nomatch'
    local bufnr = h.buffer({ name = '/tmp/dy/prog.py' })
    vim.api.nvim_set_current_buf(bufnr)
    assert.same(
      { '/tmp/dy/prog.py', '-v', vim.fs.normalize('~/x'), '*.nomatch' },
      args_of({})
    )
  end)

  it('keeps the line whole for Java', function()
    typed = '-v "a b" ~/x'
    assert.are.equal(
      '-v "a b" ' .. vim.fs.normalize('~/x'),
      args_of({ type = 'java' })
    )
  end)
end)
