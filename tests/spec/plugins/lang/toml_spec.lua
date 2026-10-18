local h = require('helpers')

describe('plugins.lang.toml', function()
  before_each(function() h.globals() end)

  it('shows and upgrades the crates of a Cargo.toml', function()
    local calls = {}
    local restore = h.stub(
      package.loaded,
      'crates',
      setmetatable({}, {
        __index = function(_, name)
          return function() table.insert(calls, name) end
        end,
      })
    )
    local crates = dofile(h.root .. '/lua/plugins/lang/toml.lua')[1]
    assert.same({ 'BufRead Cargo.toml' }, crates.event)
    for _, key in ipairs(crates.keys) do
      assert.are.equal('toml', key.ft)
      key[2]()
    end
    restore()
    assert.same({ 'show_popup', 'upgrade_all_crates' }, calls)
    assert.is_true(crates.opts.lsp.enabled)
  end)
end)
