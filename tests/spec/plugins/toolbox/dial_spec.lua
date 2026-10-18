local h = require('helpers')

describe('plugins.toolbox.dial', function()
  local restores, spec

  --- A stand-in for `dial.augend`: what each rule was built from, in place
  --- of the rule
  local augend = setmetatable({}, {
    __index = function(_, kind)
      return {
        new = function(opts) return { kind = kind, opts = opts } end,
        alias = setmetatable({}, {
          __index = function(_, name) return { kind = kind, alias = name } end,
        }),
      }
    end,
  })

  before_each(function()
    h.globals()
    h.unload('util.languages')
    restores = {
      h.stub(
        package.loaded,
        'dial.map',
        setmetatable({}, {
          __index = function(_, name)
            return function(group) return name .. ':' .. group end
          end,
        })
      ),
      h.stub(package.loaded, 'dial.augend', augend),
    }
    spec = dofile(h.root .. '/lua/plugins/toolbox/dial.lua')
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.cmd('silent! %bwipeout!')
  end)

  --- What the `lhs` key maps to in the mode `vim.fn.mode` reports
  ---@param lhs string
  ---@param mode string
  ---@return string
  local function press(lhs, mode)
    local restore = h.stub(vim.fn, 'mode', function() return mode end)
    for _, key in ipairs(spec.keys) do
      if key[1] == lhs then
        assert.is_true(key.expr)
        local result = key[2]()
        restore()
        return result
      end
    end
    restore()
    error('no key ' .. lhs)
  end

  it("dials with the rules of the buffer's language", function()
    vim.bo.filetype = 'python'
    assert.are.equal('inc_normal:python', press('<C-a>', 'n'))
    assert.are.equal('dec_normal:python', press('<C-x>', 'n'))
    assert.are.equal('inc_gnormal:python', press('g<C-a>', 'n'))
    assert.are.equal('dec_gnormal:python', press('g<C-x>', 'n'))
  end)

  it('dials a selection in every visual mode', function()
    vim.bo.filetype = 'python'
    assert.are.equal('inc_visual:python', press('<C-a>', 'v'))
    assert.are.equal('dec_visual:python', press('<C-x>', 'V'))
    assert.are.equal('inc_gvisual:python', press('g<C-a>', '\22'))
  end)

  it('falls back to the default rules for an unknown filetype', function()
    vim.bo.filetype = 'nosuchft'
    assert.are.equal('inc_normal:default', press('<C-a>', 'n'))
  end)

  it('builds a group per language on top of the common rules', function()
    local opts = spec.opts()
    local groups = opts.groups
    assert.is_true(#groups.default > 0)
    assert.is_nil(groups['*'])
    local with_rules, without
    for name, language in pairs(require('config.languages')) do
      if name ~= '*' then
        if language.dial then
          with_rules = with_rules or name
        else
          without = without or name
        end
      end
    end
    assert.same({}, groups[without])
    assert.same(
      require('config.languages')[with_rules].dial(augend),
      groups[with_rules]
    )

    local registered
    table.insert(
      restores,
      h.stub(package.loaded, 'dial.config', {
        augends = {
          register_group = function(_, g) registered = g end,
        },
      })
    )
    spec.config(nil, {
      groups = { default = { 'd1', 'd2' }, lua = { 'l1' }, bash = {} },
    })
    assert.same({
      default = { 'd1', 'd2' },
      lua = { 'l1', 'd1', 'd2' },
      bash = { 'd1', 'd2' },
    }, registered)
  end)
end)
