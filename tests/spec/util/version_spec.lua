local h = require('helpers')

describe('util.version', function()
  local mt = getmetatable(vim.version)
  local restore = {} ---@type function[]
  local asked ---@type integer

  before_each(function()
    h.unload('util.version')
    asked = 0
    restore = {
      h.stub(mt, '__call', mt.__call),
      h.stub(mt, '__dy_memoized', nil),
      h.stub(vim.fn, 'api_info', function()
        asked = asked + 1
        return {
          version = { major = 0, minor = 13, patch = 0, prerelease = true },
        }
      end),
    }
  end)

  after_each(function()
    for _, undo in ipairs(restore) do
      undo()
    end
  end)

  it('asks Neovim once however often it is called', function()
    require('util.version').memoize()
    for _ = 1, 3 do
      vim.version()
    end
    assert.are.equal(1, asked)
    assert.are.equal('0.13.0-dev', tostring(vim.version()))
  end)

  it('hands out copies that still compare as versions', function()
    require('util.version').memoize()
    vim.version().minor = 99
    assert.are.equal(13, vim.version().minor)
    assert.is_true(vim.version() >= vim.version.parse('0.12.0'))
  end)

  it('wraps only once when set up twice', function()
    require('util.version').memoize()
    h.unload('util.version')
    require('util.version').memoize()
    vim.version()
    vim.version()
    assert.are.equal(1, asked)
  end)
end)
