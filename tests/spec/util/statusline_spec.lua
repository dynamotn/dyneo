local h = require('helpers')

describe('util.statusline', function()
  local statusline, restore, lang, clients, configs, executables, picked, notes, commands

  before_each(function()
    lang = { lsp = {}, optional = {}, tools = {} }
    clients, configs, executables, notes, commands = {}, {}, {}, {}, {}
    picked = nil
    restore = {
      h.stub(vim.lsp, 'get_clients', function() return clients end),
      h.stub(vim.lsp, 'config', configs),
      h.stub(vim.lsp, 'is_enabled', function(name) return name == 'lua_ls' end),
      h.stub(
        vim.fn,
        'executable',
        function(name) return executables[name] and 1 or 0 end
      ),
      h.stub(
        vim.fn,
        'exepath',
        function(name) return executables[name] or '' end
      ),
      h.stub(
        vim,
        'notify',
        function(msg, level) table.insert(notes, { msg, level }) end
      ),
      h.stub(
        _G,
        'Snacks',
        { picker = { pick = function(opts) picked = opts end } }
      ),
    }
    for _, cmd in ipairs({ 'lsp', 'MasonInstall', 'Mason' }) do
      table.insert(
        restore,
        h.stub(
          vim.cmd,
          cmd,
          function(arg) table.insert(commands, { cmd, arg }) end
        )
      )
    end
    package.loaded['util.languages'] = {
      get_lsp_servers_by_filetype = function() return lang.lsp, lang.optional end,
      get_tools_by_filetype = function() return lang.tools end,
      get_mason_package_by_command = function(_, command)
        return (lang.packages or {})[command]
      end,
    }
    package.loaded['lualine'] = { refresh = function() end }
    h.unload('util.statusline')
    statusline = require('util.statusline')
  end)
  after_each(function()
    for i = #restore, 1, -1 do
      restore[i]()
    end
    h.unload('util.languages', 'lualine', 'mason-registry', 'mason-lspconfig')
  end)

  describe('lsp_candidates', function()
    it('lists expected servers, then the extras attached, sorted', function()
      lang.lsp = { 'lua_ls', 'harper_ls' }
      clients = {
        { name = 'zeta', id = 3 },
        { name = 'lua_ls', id = 1 },
        { name = 'copilot', id = 2 },
      }
      local result = statusline.lsp_candidates(0)
      assert.same(
        { 'lua_ls', 'harper_ls', 'copilot', 'zeta' },
        vim.tbl_map(function(c) return c.name end, result)
      )
      assert.equals(1, result[1].client.id)
      assert.is_nil(result[2].client)
      assert.same(
        { true, true, false, false },
        vim.tbl_map(function(c) return c.expected end, result)
      )
    end)
  end)

  describe('tool_candidates', function()
    it('skips system tools and resolves paths', function()
      lang.tools = { 'lua', 'stylua', 'git', 'selene', 'curl', 'sed' }
      executables.stylua = '/bin/stylua'
      assert.same(
        { { name = 'stylua', path = '/bin/stylua' }, { name = 'selene' } },
        statusline.tool_candidates('lua')
      )
    end)
  end)

  describe('lsp_status', function()
    it(
      'shows only the icon without servers',
      function() assert.equals('L', statusline.lsp_status('L ')) end
    )

    it('shows the total when all are up', function()
      lang.lsp = { 'lua_ls' }
      clients = { { name = 'lua_ls', id = 1 }, { name = 'copilot', id = 2 } }
      assert.equals('L 1', statusline.lsp_status('L '))
    end)

    it('flags servers that are down', function()
      lang.lsp = { 'lua_ls', 'harper_ls' }
      clients = { { name = 'lua_ls', id = 1 } }
      assert.equals('L 1/2!', statusline.lsp_status('L '))
    end)

    it('keeps the count of a buffer until it is forgotten', function()
      lang.lsp = { 'lua_ls' }
      assert.equals('L 0/1!', statusline.lsp_status('L '))
      clients = { { name = 'lua_ls', id = 1 } }
      assert.equals('L 0/1!', statusline.lsp_status('L '))
      statusline.forget(vim.api.nvim_get_current_buf())
      assert.equals('L 1', statusline.lsp_status('L '))
    end)
  end)

  describe('tools_status', function()
    it('counts the executables found', function()
      lang.tools = { 'lua', 'stylua', 'selene' }
      assert.equals('T 0/2!', statusline.tools_status('T '))
      executables.stylua, executables.selene = '/x', '/y'
      statusline.forget()
      assert.equals('T 2', statusline.tools_status('T '))
      lang.tools = { 'git' }
      assert.equals('T', statusline.tools_status('T '))
    end)

    it('asks `executable()` once per tool until forgotten', function()
      lang.tools = { 'stylua' }
      local asked = 0
      local inner = vim.fn.executable
      vim.fn.executable = function(name)
        asked = asked + 1
        return inner(name)
      end
      statusline.tools_status('T ')
      statusline.tools_status('T ')
      assert.equals(1, asked)
      statusline.forget()
      statusline.tools_status('T ')
      assert.equals(2, asked)
      vim.fn.executable = inner
    end)
  end)

  describe('setup', function()
    after_each(
      function() vim.api.nvim_create_augroup('dyneo_statusline', {}) end
    )

    it('forgets a buffer on the events that change its count', function()
      package.loaded['util.plugin'] = { on_load = function() end }
      statusline.setup()
      lang.lsp = { 'lua_ls' }
      assert.equals('L 0/1!', statusline.lsp_status('L '))
      clients = { { name = 'lua_ls', id = 1 } }
      vim.api.nvim_exec_autocmds('FileType', {
        group = 'dyneo_statusline',
        buffer = vim.api.nvim_get_current_buf(),
      })
      assert.equals('L 1', statusline.lsp_status('L '))
      h.unload('util.plugin')
    end)

    it('forgets a buffer again once its client has detached', function()
      package.loaded['util.plugin'] = { on_load = function() end }
      statusline.setup()
      lang.lsp = { 'lua_ls' }
      clients = { { name = 'lua_ls', id = 1 } }
      assert.equals('L 1', statusline.lsp_status('L '))
      -- Still listed while the event runs, as Neovim has it
      vim.api.nvim_exec_autocmds('LspDetach', {
        group = 'dyneo_statusline',
        buffer = vim.api.nvim_get_current_buf(),
      })
      clients = {}
      vim.wait(100, function() return statusline.lsp_status('L ') ~= 'L 1' end)
      assert.equals('L 0/1!', statusline.lsp_status('L '))
      h.unload('util.plugin')
    end)

    it('forgets the tools on focus and on a Mason install', function()
      local listeners = {}
      package.loaded['util.plugin'] = { on_load = function(_, fn) fn() end }
      package.loaded['mason-registry'] = {
        on = function(_, event, fn) listeners[event] = fn end,
      }
      statusline.setup()
      lang.tools = { 'stylua' }
      assert.equals('T 0/1!', statusline.tools_status('T '))
      executables.stylua = '/x'
      vim.api.nvim_exec_autocmds('FocusGained', { group = 'dyneo_statusline' })
      assert.equals('T 1', statusline.tools_status('T '))
      executables.stylua = nil
      listeners['package:uninstall:success']()
      vim.wait(
        100,
        function() return statusline.tools_status('T ') ~= 'T 1' end
      )
      assert.equals('T 0/1!', statusline.tools_status('T '))
      h.unload('util.plugin')
    end)
  end)

  --- Find a picker item by name
  local function item(name)
    for _, it in ipairs(picked.items) do
      if it.name == name then return it end
    end
  end

  --- Confirm `it` through the picker
  local function confirm(it)
    local closed = false
    picked.confirm({ close = function() closed = true end }, it)
    assert.is_true(closed)
  end

  describe('pick_lsp', function()
    it('redraws the statusline once a choice is made', function()
      local refreshed = {}
      package.loaded['lualine'] =
        { refresh = function(opts) table.insert(refreshed, opts) end }
      lang.lsp = { 'lua_ls' }
      clients = { { name = 'lua_ls', id = 1 } }
      statusline.pick_lsp()
      confirm(item('lua_ls'))
      assert.is_true(vim.wait(500, function() return #refreshed > 0 end))
      assert.are.same({ { place = { 'statusline' } } }, refreshed)
    end)

    it('says so when there is no server', function()
      statusline.pick_lsp()
      assert.is_nil(picked)
      assert.matches('No language server', notes[1][1])
    end)

    it('shows the state of each server', function()
      lang.lsp = { 'lua_ls', 'harper_ls', 'missing_ls', 'fn_ls' }
      clients = {
        {
          name = 'lua_ls',
          id = 1,
          root_dir = '/proj',
          config = { cmd = { 'lua-ls' }, filetypes = { 'lua' } },
        },
        { name = 'copilot', id = 2, config = { cmd = function() end } },
      }
      configs.harper_ls = { cmd = { 'harper' } }
      configs.missing_ls = { cmd = { 'nope' } }
      configs.fn_ls = { cmd = function() end }
      executables.harper = '/bin/harper'
      statusline.pick_lsp(0)

      assert.equals('Language servers', picked.title)
      assert.same(
        { '● ', 'DiagnosticOk', '/proj' },
        { item('lua_ls').sign, item('lua_ls').hl, item('lua_ls').detail }
      )
      assert.equals('○ ', item('copilot').sign)
      assert.equals('single file', item('copilot').detail)
      assert.equals('not attached', item('harper_ls').detail)
      assert.equals('DiagnosticError', item('missing_ls').hl)
      assert.equals('not attached', item('fn_ls').detail)

      local preview = item('lua_ls').preview.text
      assert.matches('attached, id 1', preview)
      assert.matches('Enabled: yes', preview)
      assert.matches('Command: `lua%-ls`', preview)
      assert.matches('Root: `/proj`', preview)
      assert.matches('Filetypes: lua', preview)
      assert.matches('Expected: no', item('copilot').preview.text)
      assert.matches('Command: `%(function%)`', item('copilot').preview.text)
      assert.matches('Installed: unknown', item('copilot').preview.text)
      assert.matches('Installed: no', item('missing_ls').preview.text)
      assert.matches('Filetypes: any', item('harper_ls').preview.text)

      local line = picked.format(item('fn_ls'))
      assert.equals('fn_ls     ', line[2][1]) -- padded to `missing_ls`
    end)

    it('restarts, installs or starts on confirm', function()
      lang.lsp = { 'lua_ls', 'missing_ls', 'other_ls', 'unknown_ls' }
      clients = { { name = 'lua_ls', id = 1, config = {} } }
      configs.missing_ls = { cmd = { 'nope' } }
      configs.unknown_ls = { cmd = { 'nope2' } }
      package.loaded['mason-registry'] = {
        has_package = function(p) return p == 'missing-pkg' end,
      }
      package.loaded['mason-lspconfig'] = {
        get_mappings = function()
          return { lspconfig_to_package = { missing_ls = 'missing-pkg' } }
        end,
      }
      statusline.pick_lsp()

      confirm(item('lua_ls'))
      confirm(item('missing_ls'))
      confirm(item('other_ls'))
      confirm(item('unknown_ls'))
      confirm(nil)
      assert.same({
        { 'lsp', { args = { 'restart', 'lua_ls' } } },
        { 'MasonInstall', 'missing-pkg' },
        { 'lsp', { args = { 'enable', 'other_ls' } } },
      }, commands)
      assert.matches('No Mason package for `unknown_ls`', notes[1][1])
    end)

    it('stops an attached server with the stop action', function()
      lang.lsp = { 'lua_ls', 'other_ls' }
      clients = { { name = 'lua_ls', id = 1, config = {} } }
      statusline.pick_lsp()
      assert.equals('lsp_stop', picked.win.input.keys['<M-s>'][1])
      local close = { close = function() end }
      picked.actions.lsp_stop(close, item('other_ls'))
      picked.actions.lsp_stop(close, nil)
      picked.actions.lsp_stop(close, item('lua_ls'))
      assert.same({ { 'lsp', { args = { 'stop', 'lua_ls' } } } }, commands)
    end)
  end)

  describe('pick_tools', function()
    it('says so when there is no tool', function()
      lang.tools = { 'lua' }
      statusline.pick_tools()
      assert.is_nil(picked)
      assert.matches('No formatter or linter', notes[1][1])
    end)

    it('opens Mason or installs on confirm', function()
      lang.tools = { 'stylua', 'selene' }
      executables.stylua = '/bin/stylua'
      package.loaded['mason-registry'] =
        { has_package = function() return true end }
      statusline.pick_tools(0)

      assert.same({
        { '● ', 'DiagnosticOk' },
        { 'stylua', 'SnacksPickerLabel' },
        { '  ' },
        { '/bin/stylua', 'SnacksPickerComment' },
      }, picked.format(item('stylua')))
      local line = picked.format(item('selene'))
      assert.same({ '! ', 'DiagnosticError' }, line[1])
      assert.equals('not installed', line[4][1])
      assert.matches('Installed: yes', item('stylua').preview.text)
      assert.matches('not on %$PATH', item('selene').preview.text)

      confirm(item('stylua'))
      confirm(item('selene'))
      assert.same({ { 'Mason' }, { 'MasonInstall', 'selene' } }, commands)
    end)

    it('installs the package of a command, not the command', function()
      lang.tools = { 'forge' }
      lang.packages = { forge = 'foundry' }
      package.loaded['mason-registry'] =
        { has_package = function(p) return p == 'foundry' end }
      statusline.pick_tools(0)

      confirm(item('forge'))
      assert.same({ { 'MasonInstall', 'foundry' } }, commands)
      lang.packages = nil
    end)
  end)
end)
