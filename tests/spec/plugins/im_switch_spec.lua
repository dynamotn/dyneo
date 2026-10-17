local h = require('helpers')

describe('plugins.integration.other: im-switch', function()
  local dir, cleanup, im, restores, notes, get

  before_each(function()
    dir, cleanup = h.tmpdir()
    im, notes = {}, {}
    restores = {
      h.stub(package.loaded, 'im-switch.im', im),
      h.stub(package.loaded, 'im-switch.utils.im_command', {
        get_im_command = function(kind) return kind == 'get' and get end,
      }),
      h.stub(package.loaded, 'im-switch', { setup = function() end }),
      h.stub(vim, 'notify', function(msg) table.insert(notes, msg) end),
    }
    local spec
    for _, plugin in
      ipairs(dofile(h.root .. '/lua/plugins/integration/other.lua'))
    do
      if plugin[1] and plugin[1]:find('im%-switch') then spec = plugin end
    end
    spec.config(nil, {})
  end)
  after_each(function()
    for _, restore in ipairs(restores) do
      restore()
    end
    cleanup()
  end)

  it('reads the input method, and keeps it for the buffer', function()
    h.write(dir .. '/get', { '#!/bin/sh', 'echo Vietnamese' })
    vim.fn.setfperm(dir .. '/get', 'rwxr-xr-x')
    get = { dir .. '/get' }
    assert.is_true(im.save_im_state())
    assert.equals('Vietnamese', vim.b.im_switch_last_state)
  end)

  it('gives up on a daemon that does not answer, and says so once', function()
    h.write(dir .. '/get', { '#!/bin/sh', 'sleep 5' })
    vim.fn.setfperm(dir .. '/get', 'rwxr-xr-x')
    get = { dir .. '/get' }
    local started = vim.uv.hrtime()
    assert.is_false(im.save_im_state())
    assert.is_true((vim.uv.hrtime() - started) / 1e6 < 3000)
    -- Not asked again: the next `InsertLeave` does not wait
    started = vim.uv.hrtime()
    assert.is_false(im.save_im_state())
    assert.is_true((vim.uv.hrtime() - started) / 1e6 < 100)
    assert.equals(1, #notes)
  end)
end)
