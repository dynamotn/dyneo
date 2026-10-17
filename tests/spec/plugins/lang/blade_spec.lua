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
    for _, name in ipairs({
      'adalessa/laravel.nvim',
      'ricardoramirezr/blade-nav.nvim',
    }) do
      assert.same({ 'blade' }, spec(name).ft)
    end
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
