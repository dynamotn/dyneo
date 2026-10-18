local h = require('helpers')

describe('plugins.lsp.null_ls', function()
  local restores, setup_opts, sensitive

  before_each(function()
    h.globals()
    setup_opts, sensitive = nil, false
    local require_ = require
    restores = {
      h.stub(package.loaded, 'null-ls', {
        setup = function(opts) setup_opts = opts end,
      }),
      h.stub(package.loaded, 'null-ls.utils', {
        root_pattern = function()
          return function() end
        end,
      }),
      h.stub(package.loaded, 'util.sensitive', {
        is_sensitive = function() return sensitive end,
      }),
      -- Every source is a table naming itself and what `with` was given
      h.stub(_G, 'require', function(name)
        local source = name:match('^null%-ls%.builtins%.(.+)$')
          or name:match('^tools%.([%w_]+%..+)$')
        if not source then return require_(name) end
        return {
          with = function(opts)
            return vim.tbl_extend('force', opts, { name = source })
          end,
        }
      end),
    }
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
  end)

  --- The sources none-ls is set up with, by `type.name`
  ---@return table<string, table>
  local function sources()
    local spec
    for _, plugin in ipairs(dofile(h.root .. '/lua/plugins/lsp/null_ls.lua')) do
      if plugin[1] == 'nvimtools/none-ls.nvim' then spec = plugin end
    end
    spec.config(nil, {})
    local by_name = {}
    for _, source in ipairs(setup_opts.sources) do
      by_name[source.name] = source
    end
    return by_name
  end

  it('lists the sources in the sorted order of the languages', function()
    local languages = require('config.languages')
    local expected = {}
    for _, name in ipairs(require('util.languages').names()) do
      for _, tool in ipairs(languages[name].null_ls or {}) do
        local key = tool.type .. '.' .. tool[1]
        if not vim.list_contains(expected, key) then
          table.insert(expected, key)
        end
      end
    end
    sources()
    assert.same(
      expected,
      vim.tbl_map(function(source) return source.name end, setup_opts.sources)
    )
  end)

  it('looks words up online only in prose, never in a secret', function()
    local dictionary = sources()['hover.dictionary']
    -- Not every filetype, which none-ls reads an empty list as
    assert.is_true(#dictionary.filetypes > 0)
    assert.is_true(vim.list_contains(dictionary.filetypes, 'markdown'))
    assert.is_false(vim.list_contains(dictionary.filetypes, 'yaml'))
    assert.is_function(dictionary.runtime_condition)
    assert.is_true(dictionary.runtime_condition({ bufnr = 0 }))
    sensitive = true
    assert.is_false(dictionary.runtime_condition({ bufnr = 0 }))
  end)

  it(
    'gives a `*` source of no filetypes of its own every filetype',
    function() assert.same({}, sources()['diagnostics.trail_space'].filetypes) end
  )

  --- The none-ls spec of the file
  ---@return table
  local function none_ls()
    for _, plugin in ipairs(dofile(h.root .. '/lua/plugins/lsp/null_ls.lua')) do
      if plugin[1] == 'nvimtools/none-ls.nvim' then return plugin end
    end
    error('no none-ls spec')
  end

  it('formats through null-ls ahead of the other formatters', function()
    local Format = require('util.format')
    local formatted
    table.insert(restores, h.stub(Format, 'formatters', {}))
    table.insert(
      restores,
      h.stub(package.loaded, 'util.lsp', {
        format = function(opts) formatted = opts end,
      })
    )
    local available
    table.insert(
      restores,
      h.stub(package.loaded, 'null-ls.sources', {
        get_available = function(filetype, method)
          assert.are.equal('NULL_LS_FORMATTING', method)
          return available and available[filetype]
        end,
      })
    )
    none_ls().init()
    assert.same({}, Format.formatters)
    vim.api.nvim_exec_autocmds('User', { pattern = 'VeryLazy' })
    local formatter = Format.formatters[1]
    assert.are.equal('none-ls.nvim', formatter.name)
    assert.are.equal(200, formatter.priority)
    assert.is_true(formatter.primary)

    local bufnr = h.buffer({ filetype = 'lua' })
    formatter.format(bufnr)
    assert.are.equal(bufnr, formatted.bufnr)
    assert.is_true(formatted.filter({ name = 'null-ls' }))
    assert.is_false(formatted.filter({ name = 'lua_ls' }))

    assert.same({}, formatter.sources(bufnr))
    available = { lua = { { name = 'stylua' }, { name = 'trail_space' } } }
    assert.same({ 'stylua', 'trail_space' }, formatter.sources(bufnr))
  end)

  it('keeps what a spec before it set up', function()
    local root_dir = function() end
    local inited = {}
    none_ls().config(nil, {
      root_dir = root_dir,
      temp_dir = '/tmp/x',
      on_init = function(client, result) inited = { client, result } end,
    })
    assert.are.equal(root_dir, setup_opts.root_dir)
    assert.are.equal('/tmp/x', setup_opts.temp_dir)
    local client = { supports_method = function() return true end }
    setup_opts.on_init(client, 'result')
    assert.same({ client, 'result' }, inited)
  end)

  it('puts a temporary copy of the buffer in a private folder', function()
    sources()
    assert.are.equal(vim.fs.dirname(vim.fn.tempname()), setup_opts.temp_dir)
  end)

  it('answers supports_method from the buffer it is asked about', function()
    sources()
    local asked = {}
    local client = {
      supports_method = function(_, method)
        table.insert(asked, { method, vim.api.nvim_get_current_buf() })
        return method == 'textDocument/completion'
      end,
    }
    setup_opts.on_init(client)
    local current = h.buffer({ filetype = 'markdown' })
    vim.api.nvim_set_current_buf(current)
    local other = h.buffer({ filetype = 'python' })
    assert.is_true(client:supports_method('textDocument/completion', other))
    assert.is_false(
      client:supports_method('textDocument/hover', { bufnr = other })
    )
    -- The current buffer, or none, is answered from where it is
    assert.is_true(client:supports_method('textDocument/completion', 0))
    assert.is_true(client:supports_method('textDocument/completion', current))
    assert.is_true(client:supports_method('textDocument/completion'))
    local gone = h.buffer({})
    vim.api.nvim_buf_delete(gone, { force = true })
    assert.is_true(client:supports_method('textDocument/completion', gone))
    assert.same({
      { 'textDocument/completion', other },
      { 'textDocument/hover', other },
      { 'textDocument/completion', current },
      { 'textDocument/completion', current },
      { 'textDocument/completion', current },
      { 'textDocument/completion', current },
    }, asked)
  end)

  describe('mason', function()
    local installs, on_filetype

    before_each(function()
      installs, on_filetype = {}, {}
      table.insert(
        restores,
        h.stub(package.loaded, 'config.languages', {
          ['*'] = {
            filetypes = { '*' },
            null_ls = { { 'trail_space', type = 'diagnostics' } },
          },
          ['_'] = {
            filetypes = { '_' },
            null_ls = { { 'dictionary', type = 'hover' } },
          },
          go = {
            filetypes = { 'go' },
            null_ls = { { 'gofmt', type = 'formatting' } },
          },
          python = {
            filetypes = { 'python' },
            null_ls = {
              { 'black', type = 'formatting', mason = { enabled = false } },
              {
                'ruff',
                type = 'diagnostics',
                mason = { package = 'ruff-pkg' },
              },
            },
          },
          rust = {
            filetypes = { 'rust' },
            null_ls = { { 'rustfmt', type = 'formatting' } },
          },
        })
      )
      table.insert(
        restores,
        h.stub(package.loaded, 'util.lazy_install', {
          on_filetype = function(filetypes, handler)
            table.insert(on_filetype, filetypes)
            handler()
          end,
          install_once = function(package) table.insert(installs, package) end,
        })
      )
      -- `util.languages` reads the languages once, as it loads
      h.unload('util.languages')
      table.insert(restores, function() h.unload('util.languages') end)
      DyNeo.bundle_languages = { 'python' }
      DyNeo.enabled_languages = { 'go', 'python' }
    end)

    it('installs the tools up front or on their first buffer', function()
      local opts = { ensure_installed = { 'already' } }
      for _, plugin in ipairs(dofile(h.root .. '/lua/plugins/lsp/null_ls.lua')) do
        if plugin[1] == 'mason-org/mason.nvim' then plugin.opts(nil, opts) end
      end
      -- `*`, `_` and the bundled language come first; a tool left to the
      -- system is not installed at all
      assert.same(
        { 'already', 'trail_space', 'dictionary', 'ruff-pkg' },
        opts.ensure_installed
      )
      assert.same({ { 'go' }, { 'python' } }, on_filetype)
      assert.same({ 'gofmt', 'ruff-pkg' }, installs)
    end)
  end)
end)
