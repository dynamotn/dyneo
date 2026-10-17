local h = require('helpers')

describe('plugins.lang.ansible', function()
  local restores, dir, cleanup, looked_up

  before_each(function()
    h.globals()
    dir, cleanup = h.tmpdir()
    looked_up = 0
    restores = {
      h.stub(vim.fn, 'executable', function(name)
        if name == 'ansible-config' then looked_up = looked_up + 1 end
        return 0
      end),
      h.stub(vim.fn, 'stdpath', function() return dir end),
      h.stub(package.loaded, 'codesettings', {
        with_local_settings = function(_, config)
          config.settings.ansible.local_read = true
        end,
      }),
    }
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    cleanup()
  end)

  --- The `ansiblels` options of the spec, loaded anew
  local function ansiblels()
    for _, spec in ipairs(dofile(h.root .. '/lua/plugins/lang/ansible.lua')) do
      if spec[1] == 'neovim/nvim-lspconfig' then
        return spec.opts.servers.ansiblels
      end
    end
  end

  it("names Mason's ansible-lint Python only as the server starts", function()
    local python = dir .. '/mason/packages/ansible-lint/venv/bin/python'
    h.write(python)
    local server = ansiblels()
    assert.are.equal(0, looked_up)

    local settings = vim.deepcopy(server.settings)
    local config = { name = 'ansiblels', settings = settings }
    server.before_init({}, config)
    assert.are.equal(1, looked_up)
    assert.are.equal(settings, config.settings)
    assert.are.equal(python, settings.ansible.python.interpreterPath)
    assert.is_true(settings.ansible.local_read)
  end)

  it('leaves the interpreter alone without that Python', function()
    local server = ansiblels()
    local config =
      { name = 'ansiblels', settings = vim.deepcopy(server.settings) }
    server.before_init({}, config)
    assert.is_nil(config.settings.ansible.python)
    assert.is_true(config.settings.ansible.local_read)
  end)
end)
