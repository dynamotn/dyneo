local h = require('helpers')

describe('util.languages', function()
  local languages, restore, enabled_calls

  --- Load `util.languages` over a made-up `config.languages`
  ---@param list table
  ---@param enabled string[]
  local function load(list, enabled)
    h.unload('util.languages')
    package.loaded['config.languages'] = list
    table.insert(restore, h.stub(DyNeo, 'enabled_languages', enabled))
    languages = require('util.languages')
  end

  before_each(function()
    restore = {}
    enabled_calls = 0
    load({
      ['*'] = {
        filetypes = { '*' },
        formatters = { { 'trim', command = 'lua' } },
        linters = { 'vale' },
        null_ls = { { 'dictionary', command = 'curl' } },
        lsp_servers = { 'copilot' },
      },
      ['_'] = { filetypes = {} },
      lua = {
        filetypes = { 'lua' },
        formatters = { 'stylua', 'vale' },
        linters = { { 'selene', command = 'selene-bin' }, { 'luacheck' } },
        lsp_servers = {
          'lua_ls',
          'harper_ls',
          'not_configured',
          'lua_ls',
          {
            'emmylua_ls',
            enabled = function(bufnr)
              enabled_calls = enabled_calls + 1
              return vim.api.nvim_buf_get_name(bufnr):find('emmy') ~= nil
            end,
          },
        },
      },
      yaml = { filetypes = { 'yaml', 'yaml.gitlab' } },
      disabled = { filetypes = { 'disabled' } },
    }, { '*', '_', 'lua', 'yaml' })
  end)
  after_each(function()
    for i = #restore, 1, -1 do
      restore[i]()
    end
    h.unload('util.languages', 'config.languages')
  end)

  describe('get_language_from_filetype', function()
    it('maps each filetype to its language', function()
      assert.equals('lua', languages.get_language_from_filetype('lua'))
      assert.equals('yaml', languages.get_language_from_filetype('yaml.gitlab'))
    end)

    it(
      'ignores a language that is not enabled',
      function() assert.is_nil(languages.get_language_from_filetype('disabled')) end
    )

    it(
      'is nil for an unknown filetype',
      function() assert.is_nil(languages.get_language_from_filetype('cobol')) end
    )
  end)

  describe('get_tools_by_filetype', function()
    it(
      'lists the common tools first, without duplicates',
      function()
        assert.same(
          { 'lua', 'stylua', 'vale', 'selene-bin', 'luacheck', 'curl' },
          languages.get_tools_by_filetype('lua')
        )
      end
    )

    it(
      'gives only the common tools for an unknown filetype',
      function()
        assert.same(
          { 'lua', 'vale', 'curl' },
          languages.get_tools_by_filetype('cobol')
        )
      end
    )

    it(
      'caches the answer per language',
      function()
        assert.equals(
          languages.get_tools_by_filetype('lua'),
          languages.get_tools_by_filetype('lua')
        )
      end
    )
  end)

  describe('get_mason_package', function()
    it(
      'takes a string as the package',
      function() assert.equals('stylua', languages.get_mason_package('stylua')) end
    )
    it('prefers mason.package, then command, then the name', function()
      assert.equals(
        'biome',
        languages.get_mason_package({
          'biomejs',
          command = 'x',
          mason = { package = 'biome' },
        })
      )
      assert.equals(
        'ruff',
        languages.get_mason_package({ 'ruff_fix', command = 'ruff' })
      )
      assert.equals('taplo', languages.get_mason_package({ 'taplo' }))
      assert.equals(
        't',
        languages.get_mason_package({ 't', mason = { enabled = false } })
      )
    end)
  end)

  describe('get_mason_package_by_command', function()
    it('finds the package of the tool running a command', function()
      assert.equals(
        'selene-bin',
        languages.get_mason_package_by_command('lua', 'selene-bin')
      )
      assert.equals(
        'stylua',
        languages.get_mason_package_by_command('lua', 'stylua')
      )
      assert.is_nil(languages.get_mason_package_by_command('lua', 'nothing'))
    end)
  end)

  describe('is_available', function()
    it('counts lua as there without an interpreter on $PATH', function()
      local restore = h.stub(vim.fn, 'executable', function() return 0 end)
      local lua, other =
        languages.is_available('lua'), languages.is_available('stylua')
      restore()
      assert.is_true(lua)
      assert.is_false(other)
    end)
    it('asks executable() for any other command', function()
      local restore = h.stub(
        vim.fn,
        'executable',
        function(name) return name == 'stylua' and 1 or 0 end
      )
      local found = languages.is_available('stylua')
      restore()
      assert.is_true(found)
    end)
  end)

  describe('get_lsp_servers_by_filetype', function()
    local configs
    before_each(function()
      configs = {
        lua_ls = { filetypes = { 'lua' } },
        harper_ls = { filetypes = '*' },
        emmylua_ls = { filetypes = { 'lua' } },
        copilot = {},
      }
      table.insert(restore, h.stub(vim.lsp, 'config', configs))
    end)

    it('splits expected and optional servers', function()
      local bufnr = h.buffer({ name = '/tmp/plain.lua' })
      local expected, optional =
        languages.get_lsp_servers_by_filetype('lua', bufnr)
      assert.same({ 'lua_ls', 'harper_ls' }, expected)
      assert.same({ 'copilot' }, optional)
    end)

    it('leaves out a server whose filetypes do not match', function()
      configs.lua_ls.filetypes = { 'luau' }
      local expected = languages.get_lsp_servers_by_filetype('lua', h.buffer())
      assert.same({ 'harper_ls' }, expected)
    end)

    it('asks the enabled check once per buffer name', function()
      local bufnr = h.buffer({ name = '/tmp/emmy.lua' })
      local expected = languages.get_lsp_servers_by_filetype('lua', bufnr)
      assert.is_true(vim.list_contains(expected, 'emmylua_ls'))
      languages.get_lsp_servers_by_filetype('lua', bufnr)
      assert.equals(1, enabled_calls)

      vim.api.nvim_buf_set_name(bufnr, '/tmp/other.lua')
      expected = languages.get_lsp_servers_by_filetype('lua', bufnr)
      assert.is_false(vim.list_contains(expected, 'emmylua_ls'))
      assert.equals(2, enabled_calls)
    end)

    it('defaults to the current buffer', function()
      vim.api.nvim_set_current_buf(h.buffer({ name = '/tmp/emmy2.lua' }))
      local expected = languages.get_lsp_servers_by_filetype('lua')
      assert.is_true(vim.list_contains(expected, 'emmylua_ls'))
    end)
  end)

  describe('with the real config.languages', function()
    before_each(function()
      h.unload('util.languages', 'config.languages')
      table.insert(
        restore,
        h.stub(
          DyNeo,
          'enabled_languages',
          vim.tbl_keys(require('config.languages'))
        )
      )
      languages = require('util.languages')
    end)

    it('finds the language of common filetypes', function()
      assert.equals('lua', languages.get_language_from_filetype('lua'))
      assert.equals('bash', languages.get_language_from_filetype('sh'))
      assert.equals(
        'yaml',
        languages.get_language_from_filetype('yaml.docker-compose')
      )
    end)

    it('lists stylua for lua and handles an unknown filetype', function()
      assert.is_true(
        vim.list_contains(languages.get_tools_by_filetype('lua'), 'stylua')
      )
      assert.is_table(languages.get_tools_by_filetype('no-such-filetype'))
    end)
  end)
  it('names every language in sorted order', function()
    local names = languages.names()
    assert.same({ '*', '_' }, { names[1], names[2] })
    assert.is_true(vim.list_contains(names, 'lua'))
    for i = 2, #names do
      assert.is_true(names[i - 1] < names[i])
    end
  end)
end)
