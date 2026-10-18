local h = require('helpers')

describe('plugins.integration.other: im-switch', function()
  local dir, cleanup, im, restores, notes, get, set, setup_opts

  --- A script on the private `$PATH` of this spec
  ---@param name string
  ---@param lines string[]
  ---@return string path
  local function script(name, lines)
    local path = dir .. '/' .. name
    h.write(path, vim.list_extend({ '#!/bin/sh' }, lines))
    vim.fn.setfperm(path, 'rwxr-xr-x')
    return path
  end

  before_each(function()
    dir, cleanup = h.tmpdir()
    im, notes, get, set = {}, {}, nil, nil
    restores = {
      h.stub(package.loaded, 'im-switch.im', im),
      h.stub(package.loaded, 'im-switch.utils.im_command', {
        get_im_command = function(kind, value)
          local cmd
          if kind == 'get' then
            cmd = get
          else
            cmd = set
          end
          if not cmd then return nil, 'no ' .. kind .. ' command' end
          cmd = vim.deepcopy(cmd)
          if value then table.insert(cmd, value) end
          return cmd
        end,
      }),
      h.stub(package.loaded, 'im-switch', {
        setup = function(opts) setup_opts = opts end,
      }),
      h.stub(vim, 'notify', function(msg) table.insert(notes, msg) end),
    }
    local spec
    for _, plugin in
      ipairs(dofile(h.root .. '/lua/plugins/integration/other.lua'))
    do
      if plugin[1] and plugin[1]:find('im%-switch') then spec = plugin end
    end
    spec.config(nil, { macos = {} })
  end)
  after_each(function()
    for _, restore in ipairs(restores) do
      restore()
    end
    vim.b.im_switch_last_state = nil
    cleanup()
  end)

  it(
    'hands the options to im-switch',
    function() assert.same({ macos = {} }, setup_opts) end
  )

  it('reads the input method, and keeps it for the buffer', function()
    get = { script('get', { 'echo Vietnamese' }) }
    assert.is_true(im.save_im_state())
    assert.equals('Vietnamese', vim.b.im_switch_last_state)
  end)

  it('gives up on a daemon that does not answer, and says so once', function()
    get = { script('get', { 'sleep 5' }) }
    local started = vim.uv.hrtime()
    assert.is_false(im.save_im_state())
    assert.is_true((vim.uv.hrtime() - started) / 1e6 < 3000)
    -- Not asked again: the next `InsertLeave` does not wait
    started = vim.uv.hrtime()
    assert.is_false(im.save_im_state())
    assert.is_true((vim.uv.hrtime() - started) / 1e6 < 100)
    assert.equals(1, #notes)
  end)

  it('keeps asking a command that merely failed, but says so once', function()
    get = { script('get', { 'echo broken >&2', 'exit 3' }) }
    assert.is_false(im.save_im_state())
    assert.is_false(im.save_im_state())
    assert.equals(1, #notes)
    assert.truthy(notes[1]:find('broken', 1, true))
    -- A command that starts answering is read again
    get = { script('get', { 'echo English' }) }
    assert.is_true(im.save_im_state())
    assert.equals('English', vim.b.im_switch_last_state)
  end)

  it('reports a platform with no `get` command', function()
    assert.is_false(im.save_im_state())
    assert.truthy(notes[1]:find('no get command', 1, true))
  end)

  describe('switching', function()
    local has, sync_result, ran, run_result

    before_each(function()
      has = { mac = 0 }
      ran, sync_result, run_result = {}, nil, nil
      local vim_has = vim.fn.has
      table.insert(
        restores,
        h.stub(vim.fn, 'has', function(feature)
          if has[feature] then return has[feature] end
          return vim_has(feature)
        end)
      )
      local system = require('util.system')
      local sync = system.sync
      -- Only macOS's `list` is faked; a `get` still runs its script
      table.insert(
        restores,
        h.stub(system, 'sync', function(cmd, opts)
          if sync_result then return sync_result(cmd) end
          return sync(cmd, opts)
        end)
      )
      table.insert(
        restores,
        h.stub(system, 'run', function(cmd, _, on_done)
          table.insert(ran, cmd)
          vim.schedule(function() on_done(run_result or { code = 0 }) end)
        end)
      )
      set = { 'im-select' }
    end)

    it('reports a platform with no `set` command', function()
      set = nil
      assert.is_false(im.set_default_im())
      assert.truthy(notes[1]:find('no set command', 1, true))
    end)

    it('switches in the background, in order', function()
      assert.is_true(im.set_default_im())
      vim.b.im_switch_last_state = 'Vietnamese'
      assert.is_true(im.restore_im())
      vim.wait(500, function() return #ran == 2 end, 5)
      assert.same({ { 'im-select' }, { 'im-select', 'Vietnamese' } }, ran)
      assert.same({}, notes)
    end)

    it('says when a switch fails', function()
      run_result = { code = 1, stderr = 'no such layout' }
      assert.is_true(im.set_default_im())
      vim.wait(500, function() return #notes == 1 end, 5)
      assert.truthy(notes[1]:find('no such layout', 1, true))
    end)

    it('reads the input method before restoring an unknown one', function()
      -- No `get` command: nothing to restore
      assert.is_false(im.restore_im())
      assert.same({}, ran)
      get = { script('get', { 'echo Japanese' }) }
      assert.is_true(im.restore_im())
      vim.wait(500, function() return #ran == 1 end, 5)
      assert.same({ { 'im-select', 'Japanese' } }, ran)
    end)

    it('skips an input method macOS cannot select, warning once', function()
      has.mac = 1
      local listed = 0
      sync_result = function(cmd)
        assert.same({ 'im-select', 'list' }, cmd)
        listed = listed + 1
        return { code = 0, stdout = 'com.apple.keylayout.US\n  org.vi\n' }
      end
      vim.b.im_switch_last_state = 'org.unknown'
      assert.is_false(im.restore_im())
      assert.is_false(im.restore_im())
      assert.equals(1, #notes)
      assert.truthy(notes[1]:find('org.unknown', 1, true))
      -- Listed once per session, and a listed one goes through
      vim.b.im_switch_last_state = 'org.vi'
      assert.is_true(im.restore_im())
      assert.equals(1, listed)
      vim.wait(500, function() return #ran == 1 end, 5)
      assert.same({ { 'im-select', 'org.vi' } }, ran)
    end)

    it('trusts the input method when macOS cannot list them', function()
      has.mac = 1
      sync_result = function() return { code = 1 } end
      assert.is_true(im.set_default_im())
      vim.wait(500, function() return #ran == 1 end, 5)
      assert.same({}, notes)
    end)
  end)
end)
