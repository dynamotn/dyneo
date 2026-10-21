local h = require('helpers')

describe('plugins.lang.blade', function()
  local restores, loaded, dir, cleanup, specs

  --- The spec of `name` among those `plugins.lang.blade` returns
  local function spec(name)
    for _, s in ipairs(specs) do
      if s[1] == name then return s end
    end
  end

  before_each(function()
    h.globals()
    loaded = {}
    dir, cleanup = h.tmpdir()
    restores = {
      h.stub(package.loaded, 'lazy', {
        load = function(opts) vim.list_extend(loaded, opts.plugins) end,
      }),
    }
    specs = dofile(h.root .. '/lua/plugins/lang/blade.lua')
    spec('adalessa/laravel.nvim').init()
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    pcall(vim.api.nvim_del_augroup_by_name, 'dyneo_laravel')
    vim.cmd('silent! %bwipeout!')
    cleanup()
  end)

  it('loads on Blade templates, not on every PHP file', function()
    h.buffer({ name = dir .. '/lib/x.php', filetype = 'php' })
    assert.same({}, loaded)
    h.buffer({ name = dir .. '/lib/a.blade.php', filetype = 'blade' })
    assert.same({ 'laravel.nvim', 'blade-nav.nvim' }, loaded)
  end)

  it('waits for a held directory, then loads for its buffers', function()
    -- The module `init` registered its release starter with
    local untrusted = require('util.untrusted')
    h.write(dir .. '/app/artisan')
    untrusted.hold(dir .. '/app')
    local php =
      h.buffer({ name = dir .. '/app/routes/web.php', filetype = 'php' })
    h.buffer({ name = dir .. '/app/views/a.blade.php', filetype = 'blade' })
    assert.same({}, loaded)
    vim.api.nvim_set_current_buf(php)
    untrusted.release(dir .. '/app')
    assert.same({ 'laravel.nvim', 'blade-nav.nvim' }, loaded)
  end)

  it('labels the completion sources of both plugins', function()
    spec('ricardoramirezr/blade-nav.nvim').init()
    assert.are.equal('「BLADE」', DyNeo.completion_sources['blade-nav'])
    assert.are.equal('「LARAVEL」', DyNeo.completion_sources.laravel)
    local sources = spec('blink.cmp').opts.sources
    assert.same({ 'laravel' }, sources.compat)
    assert.are.equal(
      'blade-nav.integrations.blink',
      sources.providers['blade-nav'].module
    )
  end)

  it('loads for the PHP files of a Laravel project', function()
    h.write(dir .. '/app/artisan')
    h.buffer({ name = dir .. '/lib/x.php', filetype = 'php' })
    assert.same({}, loaded)
    h.buffer({ name = dir .. '/app/routes/web.php', filetype = 'php' })
    assert.same({ 'laravel.nvim', 'blade-nav.nvim' }, loaded)
    h.buffer({ name = dir .. '/app/routes/api.php', filetype = 'php' })
    assert.are.equal(2, #loaded)
  end)
end)
