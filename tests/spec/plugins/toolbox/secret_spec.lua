local h = require('helpers')

describe('plugins.toolbox.secret', function()
  local restores, camouflage, sensitive_buffers, secret_keys, formats

  before_each(function()
    h.globals()
    sensitive_buffers, secret_keys, formats = {}, {}, {}
    local sensitive = require('util.sensitive')
    restores = {
      h.stub(
        sensitive,
        'is_sensitive',
        function(bufnr) return sensitive_buffers[bufnr] == true end
      ),
      h.stub(
        sensitive,
        'is_secret_key',
        function(key) return secret_keys[key] == true end
      ),
      h.stub(
        sensitive,
        'secret_format',
        function(value) return formats[value] end
      ),
    }
    for _, spec in ipairs(dofile(h.root .. '/lua/plugins/toolbox/secret.lua')) do
      if spec[1] == 'zeybek/camouflage.nvim' then camouflage = spec end
    end
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
  end)

  it('masks every value of a sensitive file', function()
    local detected = camouflage.opts.hooks.on_variable_detected
    sensitive_buffers[7] = true
    assert.is_true(detected(7, { key = 'replicas', value = '3' }))
    assert.is_false(detected(8, { key = 'replicas', value = '3' }))
  end)

  it('masks only the secrets of any other file', function()
    local detected = camouflage.opts.hooks.on_variable_detected
    secret_keys.password = true
    formats['ghp_abcdef0123456789abcdef0123456789abcdef'] = 'github'
    assert.is_true(detected(8, { key = 'password', value = 'hunter2' }))
    assert.is_true(detected(8, {
      key = 'note',
      value = 'ghp_abcdef0123456789abcdef0123456789abcdef',
    }))
    assert.is_false(detected(8, { key = 'image', value = 'nginx:1.27' }))
  end)

  it('keeps completion on and reads a project config once trusted', function()
    assert.is_false(camouflage.opts.integrations.cmp.disable_in_masked)
    assert.is_false(camouflage.opts.integrations.blink.disable_in_masked)
    assert.is_true(camouflage.opts.project_config.secure)
    assert.are.equal('LazyFile', camouflage.event)
  end)
end)
