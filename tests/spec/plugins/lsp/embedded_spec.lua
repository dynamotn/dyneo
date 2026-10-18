local h = require('helpers')

describe('plugins.lsp.embedded', function()
  local spec, restores, otter, activated, dir, cleanup

  before_each(function()
    h.globals()
    dir, cleanup = h.tmpdir()
    activated = {}
    otter = {
      activate = function()
        table.insert(activated, vim.api.nvim_get_current_buf())
      end,
      deactivate = function() table.insert(activated, 'off') end,
      setup = function(opts) otter.opts = opts end,
      rafts = {},
    }
    restores = {
      h.stub(package.loaded, 'otter', otter),
      h.stub(package.loaded, 'otter.lsp', {}),
      h.stub(package.loaded, 'otter.keeper', { rafts = otter.rafts }),
    }
    spec = dofile(h.root .. '/lua/plugins/lsp/embedded.lua')[1]
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    pcall(vim.api.nvim_del_augroup_by_name, 'dy_otter_exit')
    pcall(vim.api.nvim_del_augroup_by_name, 'dy_otter_activate')
    vim.cmd('silent! %bwipeout!')
    cleanup()
  end)

  --- Wait for the activation `activate` schedules
  local function settle()
    vim.wait(50, function() return false end)
  end

  it('loads on the filetypes that embed another language', function()
    local languages = require('config.languages')
    for name, language in pairs(languages) do
      for _, ft in ipairs(language.filetypes) do
        assert.are.equal(
          language.otter == true,
          vim.list_contains(spec.ft, ft),
          name .. ' ' .. ft
        )
      end
    end
    assert.is_true(#spec.ft > 0)
  end)

  it('maps otter under its own group', function()
    local by_lhs = {}
    for _, key in ipairs(spec.keys) do
      by_lhs[key[1]] = key
    end
    assert.are.equal('+embedded', by_lhs['<leader>ce'].desc)
    by_lhs['<leader>cea'][2]()
    by_lhs['<leader>ced'][2]()
    assert.same({ vim.api.nvim_get_current_buf(), 'off' }, activated)
  end)

  it('keeps blink.cmp from loading while otter does', function()
    assert.is_nil(package.loaded['blink.cmp'])
    local loaded_while
    package.loaded['otter.lsp'] = nil
    package.preload['otter.lsp'] = function()
      loaded_while = pcall(require, 'blink.cmp')
      return {}
    end
    local ok, err = pcall(spec.config, nil, spec.opts)
    package.preload['otter.lsp'] = nil
    assert.is_true(ok, err)
    assert.is_false(loaded_while)
    assert.is_nil(package.preload['blink.cmp'])
    assert.is_nil(package.loaded['blink.cmp'])
    assert.are.equal(spec.opts, otter.opts)
  end)

  it('reports otter failing to load', function()
    package.loaded['otter.lsp'] = nil
    package.preload['otter.lsp'] = function() error('otter is broken', 0) end
    local ok, err = pcall(spec.config, nil, spec.opts)
    package.preload['otter.lsp'] = nil
    assert.is_false(ok)
    assert.are.equal('otter is broken', err)
    assert.is_nil(package.preload['blink.cmp'])
  end)

  it('leaves a loaded blink.cmp alone', function()
    local blink = {}
    table.insert(restores, h.stub(package.loaded, 'blink.cmp', blink))
    spec.config(nil, spec.opts)
    assert.are.equal(blink, package.loaded['blink.cmp'])
  end)

  it('activates otter on a file of a supported filetype, once', function()
    spec.config(nil, spec.opts)
    local ft = spec.ft[1]
    local bufnr = h.buffer({ name = dir .. '/a.' .. ft, filetype = ft })
    settle()
    assert.same({ bufnr }, activated)
    -- A buffer otter already manages is not activated again
    otter.rafts[bufnr] = {}
    vim.bo[bufnr].filetype = ft
    settle()
    assert.same({ bufnr }, activated)
  end)

  it('activates the buffers already open when it loads', function()
    local ft = spec.ft[1]
    local bufnr = h.buffer({ name = dir .. '/a.' .. ft, filetype = ft })
    spec.config(nil, spec.opts)
    settle()
    assert.same({ bufnr }, activated)
  end)

  it('leaves scratch, unnamed and otter buffers alone', function()
    local ft = spec.ft[1]
    spec.config(nil, spec.opts)
    h.buffer({ filetype = ft })
    h.buffer({ name = dir .. '/a.' .. ft .. '.otter.' .. ft, filetype = ft })
    local scratch = h.buffer({ name = dir .. '/b.' .. ft })
    vim.bo[scratch].buftype = 'nofile'
    vim.bo[scratch].filetype = ft
    local deleted = h.buffer({ name = dir .. '/c.' .. ft })
    vim.api.nvim_buf_delete(deleted, { force = true })
    settle()
    assert.same({}, activated)
  end)

  it('lets :qa go without tearing the otter buffers down', function()
    spec.config(nil, spec.opts)
    local otter_nr = h.buffer({ lines = { 'x = 1' } })
    vim.bo[otter_nr].modified = true
    local gone = h.buffer({})
    vim.api.nvim_buf_delete(gone, { force = true })
    local path = dir .. '/a.otter.py'
    h.write(path, { 'x = 1' })
    vim.api.nvim_create_augroup('OtterAutocloseOnQuit' .. otter_nr, {})
    otter.rafts[1] = {
      buffers = { python = otter_nr, gone = gone },
      paths = { python = path },
    }
    otter.rafts[2] = {}
    vim.api.nvim_exec_autocmds('ExitPre', {})
    assert.is_false(vim.bo[otter_nr].modified)
    assert.is_nil(vim.uv.fs_stat(path))
    assert.is_false(
      pcall(
        vim.api.nvim_del_augroup_by_name,
        'OtterAutocloseOnQuit' .. otter_nr
      )
    )
  end)
end)
