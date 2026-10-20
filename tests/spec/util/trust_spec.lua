local h = require('helpers')

describe('util.trust', function()
  local trust, dir, cleanup, restore, answers, asked

  before_each(function()
    h.unload('util.trust')
    trust = require('util.trust')
    dir, cleanup = h.tmpdir()
    answers, asked = {}, 0
    restore = h.stub(vim.fn, 'confirm', function()
      asked = asked + 1
      return table.remove(answers, 1) or 2
    end)
  end)
  after_each(function()
    restore()
    cleanup()
  end)

  it('asks once per root and purpose, and keeps a yes', function()
    answers = { 1 }
    assert.is_true(trust.ask('deps', dir, 'Run?'))
    assert.is_true(trust.ask('deps', dir .. '/', 'Run?'))
    assert.equals(1, asked)
    assert.is_false(trust.ask('likec4', dir, 'Run?'))
    assert.equals(2, asked)
  end)

  it('knows a root by its real path', function()
    vim.uv.fs_symlink(dir, dir .. '-link')
    answers = { 1 }
    assert.is_true(trust.ask('deps', dir, 'Run?'))
    assert.is_true(trust.ask('deps', dir .. '-link', 'Run?'))
    assert.equals(1, asked)
    os.remove(dir .. '-link')
  end)

  it('asks again after a no, unless sticky', function()
    assert.is_false(trust.ask('deps', dir, 'Run?'))
    assert.is_false(trust.ask('deps', dir, 'Run?'))
    assert.equals(2, asked)
    assert.is_false(trust.ask('likec4', dir, 'Run?', true))
    assert.is_false(trust.ask('likec4', dir, 'Run?', true))
    assert.equals(3, asked)
  end)

  it('says no, without asking, to a held directory', function()
    h.unload('util.untrusted')
    local untrusted = require('util.untrusted')
    answers = { 1, 1 }
    untrusted.hold(dir)
    assert.is_false(trust.ask('deps', dir, 'Run?'))
    assert.is_false(trust.ask('deps', dir .. '/sub', 'Run?'))
    assert.equals(0, asked)
    untrusted.release(dir)
    assert.is_true(trust.ask('deps', dir, 'Run?'))
    assert.equals(1, asked)
  end)

  it('says no to a call made while the question is open', function()
    local inner
    restore()
    restore = h.stub(vim.fn, 'confirm', function()
      asked = asked + 1
      inner = trust.ask('deps', dir, 'Run?')
      return 1
    end)
    assert.is_true(trust.ask('deps', dir, 'Run?'))
    assert.is_false(inner)
    assert.equals(1, asked)
  end)
end)
