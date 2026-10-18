local h = require('helpers')

describe('plugins.toolbox.refactoring', function()
  local restore, calls, refactoring

  before_each(function()
    h.globals()
    calls = {}
    restore = h.stub(
      package.loaded,
      'refactoring',
      setmetatable({}, {
        __index = function(_, name)
          return function()
            table.insert(calls, name)
            return 'g@' .. name
          end
        end,
      })
    )
    for _, spec in
      ipairs(dofile(h.root .. '/lua/plugins/toolbox/refactoring.lua'))
    do
      if spec[1] == 'ThePrimeagen/refactoring.nvim' then refactoring = spec end
    end
  end)
  after_each(function() restore() end)

  it('hands each refactor key its operator expression', function()
    assert.are.equal('Refactor', refactoring.cmd)
    local expressions = {}
    for _, key in ipairs(refactoring.keys) do
      if type(key[2]) == 'function' then
        expressions[key[1]] = key[2]()
        assert.same({ 'n', 'x' }, key.mode, key[1])
      else
        assert.are.equal('<leader>r', key[1])
      end
    end
    assert.same({
      ['<leader>rs'] = 'g@select_refactor',
      ['<leader>ri'] = 'g@inline_var',
      ['<leader>rf'] = 'g@extract_func',
      ['<leader>rF'] = 'g@extract_func_to_file',
      ['<leader>rx'] = 'g@extract_var',
    }, expressions)
    assert.are.equal(5, #calls)
  end)
end)
