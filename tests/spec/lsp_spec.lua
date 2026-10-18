local h = require('helpers')

--- Load `lsp/<name>.lua` as `vim.lsp.config` would, with `stdpath` pointed
--- at `dir` so nothing is written to the real data and state folders
---@param name string
---@param dir string
---@param subdir? string `lsp` unless given: `after/lsp` for an override
---@return vim.lsp.Config
local function load(name, dir, subdir)
  local restore = h.stub(vim.fn, 'stdpath', function() return dir end)
  local ok, config =
    pcall(dofile, h.root .. '/' .. (subdir or 'lsp') .. '/' .. name .. '.lua')
  restore()
  assert(ok, config)
  return config
end

local function is_string_list(value)
  if type(value) ~= 'table' or not vim.islist(value) then return false end
  for _, item in ipairs(value) do
    if type(item) ~= 'string' then return false end
  end
  return true
end

describe('lsp', function()
  local dir, cleanup, restores
  before_each(function()
    dir, cleanup = h.tmpdir()
    restores = {
      -- The merged dictionary is `util.harper`'s business, tested on its own
      h.stub(package.loaded, 'util.harper', {
        user_dict = function() return dir .. '/dictionary.txt' end,
      }),
    }
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    cleanup()
  end)

  local files = vim.fn.glob(h.root .. '/lsp/*.lua', false, true)

  it('finds the server configs', function() assert.is_true(#files >= 5) end)

  for _, file in ipairs(files) do
    local name = vim.fn.fnamemodify(file, ':t:r')
    it(name .. ' is a well-formed vim.lsp.Config', function()
      local config = load(name, dir)
      assert.are.equal('table', type(config))
      if config.cmd ~= nil then
        assert(
          is_string_list(config.cmd) or type(config.cmd) == 'function',
          'cmd'
        )
      end
      for _, field in ipairs({ 'filetypes', 'root_markers' }) do
        if config[field] ~= nil then
          assert(is_string_list(config[field]), field)
        end
      end
      for method, handler in pairs(config.handlers or {}) do
        assert.are.equal('function', type(handler), method)
      end
      for _, field in ipairs({ 'on_attach', 'get_language_id' }) do
        if config[field] ~= nil then
          assert.are.equal('function', type(config[field]), field)
        end
      end
    end)
  end

  it('starts the binary its own Mason package installs', function()
    local registry = h.root .. '/lua/tools/mason-registry/'
    for _, file in ipairs(vim.fn.glob(registry .. '*.lua', false, true)) do
      local spec = dofile(file)
      local server = type(spec) == 'table'
        and vim.tbl_get(spec, 'neovim', 'lspconfig')
      if server and vim.uv.fs_stat(h.root .. '/lsp/' .. server .. '.lua') then
        local cmd = load(server, dir).cmd
        if type(cmd) == 'table' then
          assert.is_not_nil((spec.bin or {})[cmd[1]], server .. ': ' .. cmd[1])
        end
      end
    end
  end)

  -- `after/lsp/` overrides what nvim-lspconfig ships for a server, merged
  -- over the plugin's own file, so each is a partial config
  for _, file in ipairs(vim.fn.glob(h.root .. '/after/lsp/*.lua', false, true)) do
    local name = vim.fn.fnamemodify(file, ':t:r')
    it('after/lsp/' .. name .. ' is a well-formed override', function()
      local config = load(name, dir, 'after/lsp')
      assert.are.equal('table', type(config))
      if config.cmd ~= nil then assert(is_string_list(config.cmd), 'cmd') end
    end)
  end

  it(
    'starts yls without its request log',
    function() assert.same({ 'yls' }, load('yls', dir, 'after/lsp').cmd) end
  )

  it('termuxls only claims shell dialects', function()
    for _, ft in ipairs(load('termuxls', dir).filetypes) do
      assert.truthy(ft:match('^sh%.'), ft)
    end
  end)

  it('sonarlint answers a hung git as not ignored, in time', function()
    vim.fn.mkdir(dir .. '/bin', 'p')
    h.write(dir .. '/bin/git', { '#!/bin/sh', 'sleep 10' })
    vim.fn.setfperm(dir .. '/bin/git', 'rwxr-xr-x')
    local path = vim.env.PATH
    vim.env.PATH = dir .. '/bin:' .. path
    local handler = load('sonarlint', dir).handlers['sonarlint/isIgnoredByScm']
    local start = vim.uv.hrtime()
    local ignored = handler(nil, vim.uri_from_fname(dir .. '/a.py'))
    local took = (vim.uv.hrtime() - start) / 1e9
    vim.env.PATH = path
    assert.is_false(ignored)
    assert.is_true(took < 5, ('took %.1f s'):format(took))
  end)

  describe('harper_ls', function()
    local config
    before_each(function() config = load('harper_ls', dir) end)

    it(
      'points Harper at the merged dictionary',
      function()
        assert.are.equal(
          dir .. '/dictionary.txt',
          config.settings['harper-ls'].userDictPath
        )
      end
    )

    it('translates filetypes Harper spells differently', function()
      local id = config.get_language_id
      assert.are.equal('shellscript', id(nil, 'sh'))
      assert.are.equal('shellscript', id(nil, 'sh.PKGBUILD'))
      assert.are.equal('csharp', id(nil, 'cs'))
      assert.are.equal('typescriptreact', id(nil, 'typescript.tsx'))
      assert.are.equal('html', id(nil, 'vue'))
      assert.are.equal('lua', id(nil, 'lua'))
    end)

    describe('publishDiagnostics filter', function()
      local published
      before_each(function()
        published = nil
        table.insert(
          restores,
          h.stub(
            vim.lsp.diagnostic,
            'on_publish_diagnostics',
            function(_, result) published = result end
          )
        )
      end)

      --- Publish one diagnostic per `{line, col, message?}` against `lines`
      --- and return the columns of those that survive the filter
      local function survivors(lines, positions)
        local bufnr = h.buffer({ name = dir .. '/f.txt', lines = lines })
        vim.fn.bufload(bufnr)
        local diagnostics = {}
        for _, pos in ipairs(positions) do
          table.insert(diagnostics, {
            range = {
              start = { line = pos[1], character = pos[2] },
              ['end'] = { line = pos[1], character = pos[2] + 1 },
            },
            message = pos[3] or 'Did you mean to spell this?',
          })
        end
        config.handlers['textDocument/publishDiagnostics'](
          nil,
          { uri = vim.uri_from_bufnr(bufnr), diagnostics = diagnostics },
          { client_id = -1 }
        )
        vim.api.nvim_buf_delete(bufnr, { force = true })
        return vim.tbl_map(
          function(d) return { d.range.start.line, d.range.start.character } end,
          published.diagnostics
        )
      end

      it('answers the same for a line seen before', function()
        local line = 'x = 1  # noqa: E501 tralala'
        local positions = { { 0, 0 }, { 0, line:find('noqa') - 1 } }
        local first = survivors({ line }, positions)
        assert.are.same(first, survivors({ line }, positions))
        -- The same column in another line is prose again
        assert.are.same(
          positions,
          survivors({ 'x = 1  # a comment about something' }, positions)
        )
      end)

      it('drops a diagnostic inside another tool directive', function()
        local line = 'x = 1  # noqa: E501 tralala'
        assert.are.same(
          { { 0, 0 } },
          survivors({ line }, { { 0, 0 }, { 0, line:find('noqa') - 1 } })
        )
      end)

      it(
        'drops shellcheck and dyshellint directives',
        function()
          assert.are.same(
            {},
            survivors({
              '# shellcheck disable=SC2086',
              '# dyshellint disable=DY001 reason',
            }, { { 0, 2 }, { 1, 2 } })
          )
        end
      )

      it(
        'requires a comment leader before the directive',
        function()
          assert.are.same(
            { { 0, 4 } },
            survivors({ 'see noqa here' }, { { 0, 4 } })
          )
        end
      )

      it(
        'drops a Go directive only without a space',
        function()
          assert.are.same(
            { { 1, 3 } },
            survivors({ '//go:generate foo', '// go:generate foo' }, {
              { 0, 2 },
              { 1, 3 },
            })
          )
        end
      )

      it(
        'drops the tag and names of a sh-docs line, keeps its prose',
        function()
          local line = '# @arg $1 string The nmae'
          assert.are.same(
            { { 0, line:find('nmae') - 1 } },
            survivors({ line }, {
              { 0, line:find('%$1') - 1 },
              { 0, line:find('nmae') - 1 },
            })
          )
        end
      )

      it('drops the spellings of a sh-docs @option', function()
        local line = '# @option -v<value> | --value=<value> The valeu'
        assert.are.same(
          { { 0, line:find('valeu') - 1 } },
          survivors({ line }, {
            { 0, line:find('%-%-value') - 1 },
            { 0, line:find('valeu') - 1 },
          })
        )
      end)

      it(
        'drops what sits in a sh-docs @example block',
        function()
          assert.are.same(
            {},
            survivors({
              '# @example',
              '#   foo --barr',
            }, { { 1, 6 } })
          )
        end
      )

      it(
        'drops a capitalization complaint on a continued annotation',
        function()
          local message = 'This sentence does not start with a capital letter'
          assert.are.same(
            {},
            survivors({
              '---@type string The name of the',
              '--- thing it holds',
            }, { { 1, 4, message } })
          )
        end
      )

      it('keeps one after a finished sentence', function()
        local message = 'This sentence does not start with a capital letter'
        assert.are.same(
          { { 1, 4 } },
          survivors({
            '---@type string The name.',
            '--- thing it holds',
          }, { { 1, 4, message } })
        )
      end)
    end)
  end)

  describe('likec4', function()
    local config, root, asked, answer, restore_confirm

    before_each(function()
      h.unload('util.trust', 'tools.c4')
      config = load('likec4', dir)
      root = dir .. '/model'
      h.write(root .. '/likec4.config.json', { '{}' })
      h.write(root .. '/views/a.c4', {})
      h.write(root .. '/node_modules/x/likec4.config.js', {})
      asked, answer = 0, 2
      restore_confirm = h.stub(vim.fn, 'confirm', function()
        asked = asked + 1
        return answer
      end)
    end)
    after_each(function()
      restore_confirm()
      vim.cmd('silent! %bwipeout!')
    end)

    ---@return string?
    local function root_of()
      vim.cmd.edit(root .. '/views/a.c4')
      local found
      config.root_dir(0, function(path) found = path end)
      return found
    end

    it('starts on a JSON config without asking', function()
      assert.equals(root, root_of())
      assert.equals(0, asked)
    end)

    it('asks once before a root whose code config it would run', function()
      h.write(root .. '/sub/likec4.config.ts', {})
      assert.is_nil(root_of())
      assert.is_nil(root_of())
      assert.equals(1, asked)
    end)

    it('starts once a code config is trusted', function()
      h.write(root .. '/likec4.config.mjs', {})
      answer = 1
      assert.equals(root, root_of())
      assert.equals(1, asked)
    end)
  end)

  describe('sonarlint', function()
    local config
    before_each(function() config = load('sonarlint', dir) end)

    it('keeps its token folder private', function()
      local stat = vim.uv.fs_stat(dir .. '/sonarlint/tokens')
      assert.is_not_nil(stat)
      assert.are.equal(
        tonumber('700', 8),
        bit.band(stat.mode, tonumber('777', 8))
      )
    end)

    it('starts on stdio and turns telemetry off', function()
      assert.are.same(
        { 'sonarlint-language-server', '-stdio' },
        vim.list_slice(config.cmd, 1, 2)
      )
      assert.is_true(config.init_options.sonarlint.disableTelemetry)
    end)

    it('reads a stored token for an organization', function()
      h.write(dir .. '/sonarlint/tokens/acme', { 'fake-token' })
      local token =
        config.handlers['sonarlint/getTokenForServer'](nil, { 'acme' })
      assert.are.equal('fake-token', token)
    end)

    it('lists only the files of a folder', function()
      h.write(dir .. '/folder/a.txt')
      vim.fn.mkdir(dir .. '/folder/sub', 'p')
      local result = config.handlers['sonarlint/listFilesInFolder'](
        nil,
        { folderUri = vim.uri_from_fname(dir .. '/folder') }
      )
      assert.are.same(
        { { fileName = 'a.txt', filePath = dir .. '/folder' } },
        result.foundFiles
      )
    end)

    it('hands the files to analyze back untouched', function()
      local params = { fileUris = { 'file:///x' } }
      assert.are.equal(
        params,
        config.handlers['sonarlint/filterOutExcludedFiles'](nil, params)
      )
    end)

    it('asks git whether a file is ignored', function()
      if vim.fn.executable('git') == 0 then
        assert(not vim.env.CI, 'no git on CI')
        pending('git is not installed')
        return
      end
      vim.system({ 'git', 'init', '-q', dir .. '/repo' }):wait()
      h.write(dir .. '/repo/.gitignore', { '*.log' })
      h.write(dir .. '/repo/a.log')
      h.write(dir .. '/repo/a.txt')
      local ignored = config.handlers['sonarlint/isIgnoredByScm']
      assert.is_true(ignored(nil, vim.uri_from_fname(dir .. '/repo/a.log')))
      assert.is_false(ignored(nil, vim.uri_from_fname(dir .. '/repo/a.txt')))
    end)

    it('adds its buffer commands on attach', function()
      local bufnr = h.buffer()
      config.on_attach({ notify = function() end }, bufnr)
      local commands = vim.api.nvim_buf_get_commands(bufnr, {})
      assert.is_not_nil(commands.DySonarlintDeactivateRule)
      assert.is_not_nil(commands.DySonarlintToken)
    end)
  end)
end)
