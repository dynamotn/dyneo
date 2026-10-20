local h = require('helpers')

describe('tools.review.store', function()
  local store, state_dir, cleanup, restore
  local remote = { name = 'origin', host = 'github.com', slug = 'o/r' }

  before_each(function()
    state_dir, cleanup = h.tmpdir()
    restore = h.stub(vim.fn, 'stdpath', function() return state_dir end)
    h.unload('tools.review.store')
    store = require('tools.review.store')
  end)

  after_each(function()
    restore()
    cleanup()
  end)

  it('starts empty', function()
    local state = store.load(remote, 'pr-1')
    assert.same({}, state.reviewed)
    assert.same({}, state.drafts)
    assert.is_nil(state.last_head)
  end)

  it('round-trips a state', function()
    local state = {
      reviewed = { ['a.lua'] = 'abc123' },
      last_head = 'deadbeef',
      drafts = {
        {
          id = '0123456789ab',
          origin = 'user',
          state = 'ready',
          path = 'a.lua',
          side = 'new',
          line = 3,
          body = 'why?',
          suggestion = { 'x', 'y' },
        },
      },
    }
    store.save(remote, 'pr-1', state)
    assert.same(state, store.load(remote, 'pr-1'))
  end)

  it('keeps an empty reviewed map an object on disk', function()
    store.save(remote, 'pr-1', { reviewed = {}, drafts = {} })
    local raw = table.concat(vim.fn.readfile(store.path(remote, 'pr-1')), '')
    assert.truthy(raw:find('"reviewed":%s*{}'))
    assert.same({}, store.load(remote, 'pr-1').reviewed)
  end)

  it('keeps slugs with slashes as directories', function()
    local azure = { name = 'origin', host = 'dev.azure.com', slug = 'o/p/r' }
    local path = store.path(azure, 'pr-7')
    assert.equal(
      vim.fs.joinpath(
        state_dir,
        'dyneo',
        'review',
        'dev.azure.com',
        'o',
        'p',
        'r',
        'pr-7.json'
      ),
      path
    )
    store.save(azure, 'pr-7', { reviewed = {}, drafts = {} })
    assert.equal(1, vim.fn.filereadable(path))
  end)

  it('refuses a slug or id that leaves the review directory', function()
    local function bad(r, id)
      assert.has_error(function() store.path(r, id) end)
    end
    bad({ host = 'h', slug = '../x' }, 'a')
    bad({ host = 'h', slug = 'o/../../x' }, 'a')
    bad({ host = 'h', slug = '/etc' }, 'a')
    bad({ host = '..', slug = 'o/r' }, 'a')
    bad(remote, '../a')
    bad(remote, 'a/b')
    bad(remote, '..')
  end)

  it('keeps a corrupt file aside', function()
    local path = store.path(remote, 'pr-1')
    h.write(path, { '{ not json SECRET-BODY' })
    local seen
    local undo = h.stub(vim, 'notify', function(msg) seen = msg end)
    local state = store.load(remote, 'pr-1')
    undo()
    assert.same({}, state.drafts)
    assert.equal(0, vim.fn.filereadable(path))
    assert.equal(1, vim.fn.filereadable(path .. '.bad'))
    assert.truthy(seen:find('pr-1.json', 1, true))
    assert.is_nil(seen:find('SECRET-BODY', 1, true))
  end)

  it('treats a file of the wrong shape as corrupt', function()
    local path = store.path(remote, 'pr-1')
    h.write(path, { '[1,2]' })
    local undo = h.stub(vim, 'notify', function() end)
    local state = store.load(remote, 'pr-1')
    undo()
    assert.same({}, state.reviewed)
    assert.equal(1, vim.fn.filereadable(path .. '.bad'))
  end)

  it('writes atomically', function()
    local path = store.path(remote, 'pr-1')
    store.save(remote, 'pr-1', { reviewed = { a = 'old' }, drafts = {} })
    local calls = 0
    local original = vim.uv.fs_rename
    local undo = h.stub(vim.uv, 'fs_rename', function(from, to)
      calls = calls + 1
      assert.equal(path, to)
      assert.not_equal(path, from)
      assert.equal(vim.fs.dirname(path), vim.fs.dirname(from))
      -- the temp file is complete while the target still holds the old state
      local temp = vim.json.decode(table.concat(vim.fn.readfile(from), '\n'))
      assert.equal('new', temp.reviewed.a)
      local old = vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
      assert.equal('old', old.reviewed.a)
      return original(from, to)
    end)
    store.save(remote, 'pr-1', { reviewed = { a = 'new' }, drafts = {} })
    undo()
    assert.equal(1, calls)
    assert.equal('new', store.load(remote, 'pr-1').reviewed.a)
    assert.same({ 'pr-1.json' }, vim.fn.readdir(vim.fs.dirname(path)))
  end)
end)
