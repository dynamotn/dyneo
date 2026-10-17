local h = require('helpers')

describe('per_machine', function()
  local notify, messages
  before_each(function()
    messages = {}
    notify = h.stub(
      vim,
      'notify',
      function(msg, level) table.insert(messages, { msg, level }) end
    )
    h.unload('per_machine', 'per_machine.config')
  end)
  after_each(function()
    notify()
    package.preload['per_machine.config'] = nil
    h.unload('per_machine', 'per_machine.config')
  end)

  it('is quiet when no config was rendered', function()
    -- What `require` raises on a plain clone, without touching whatever
    -- config this machine has rendered
    package.preload['per_machine.config'] = function()
      error("module 'per_machine.config' not found:\n\tno file", 0)
    end
    require('per_machine')
    assert.are.same({}, messages)
  end)

  it('loads a rendered config', function()
    local loaded = false
    package.preload['per_machine.config'] = function() loaded = true end
    require('per_machine')
    assert.is_true(loaded)
    assert.are.same({}, messages)
  end)

  it('sorts the languages a config enables', function()
    local restore = h.stub(DyNeo, 'enabled_languages', {})
    package.preload['per_machine.config'] = function()
      DyNeo.enabled_languages = { 'sql', 'bash', 'gitcommit' }
    end
    require('per_machine')
    local got = DyNeo.enabled_languages
    restore()
    assert.are.same({ 'bash', 'gitcommit', 'sql' }, got)
  end)

  it('reports an error raised inside the config', function()
    package.preload['per_machine.config'] = function() error('boom') end
    require('per_machine')
    assert.are.equal(1, #messages)
    assert.truthy(
      messages[1][1]:find('per_machine: failed to load config', 1, true)
    )
    assert.truthy(messages[1][1]:find('boom', 1, true))
    assert.are.equal(vim.log.levels.ERROR, messages[1][2])
  end)

  it('reports a missing module the config itself requires', function()
    package.preload['per_machine.config'] = function()
      require('no.such.module.here')
    end
    require('per_machine')
    assert.are.equal(1, #messages)
    assert.truthy(messages[1][1]:find('no.such.module.here', 1, true))
  end)
end)
