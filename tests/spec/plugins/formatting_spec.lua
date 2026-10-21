local h = require('helpers')

describe('plugins.executor.formatting', function()
  local by_ft

  ---@return table<string, any>
  local function load()
    local conform
    for _, spec in
      ipairs(dofile(h.root .. '/lua/plugins/executor/formatting.lua'))
    do
      if spec[1] == 'stevearc/conform.nvim' then conform = spec end
    end
    return conform.opts(nil, {}).formatters_by_ft
  end

  before_each(function()
    h.globals()
    by_ft = load()
  end)

  ---@param ft string
  ---@return string[]
  local function common(ft)
    local bufnr = h.buffer({})
    vim.bo[bufnr].filetype = ft
    return by_ft['*'](bufnr)
  end

  it('formats injected languages only outside a held directory', function()
    local dir, cleanup = h.tmpdir()
    h.unload('util.untrusted')
    local untrusted = require('util.untrusted')
    local seen = 0
    local restore = h.stub(package.loaded, 'conform', {
      format = function() seen = seen + 1 end,
    })
    local key
    for _, spec in
      ipairs(dofile(h.root .. '/lua/plugins/executor/formatting.lua'))
    do
      if spec[1] == 'stevearc/conform.nvim' then
        for _, k in ipairs(spec.keys) do
          if k[1] == '<leader>cF' then key = k end
        end
      end
    end
    vim.api.nvim_set_current_buf(h.buffer({ name = dir .. '/a.md' }))
    untrusted.hold(dir)
    key[2]()
    assert.are.equal(0, seen)
    untrusted.forget(dir)
    key[2]()
    assert.are.equal(1, seen)
    restore()
    cleanup()
  end)

  it('leaves a filetype without a formatter to its language server', function()
    -- `formatting is left to the language server` in config.languages
    assert.same({ lsp_format = 'last' }, by_ft.astro)
    assert.same({ lsp_format = 'last' }, by_ft._)
  end)

  it('keeps the blank lines of a filetype with a formatter', function()
    assert.is_false(vim.list_contains(common('python'), 'condense_blank_lines'))
    assert.is_true(vim.list_contains(common('conf'), 'condense_blank_lines'))
  end)

  it('keeps the blank lines while the formatter is not installed', function()
    local restore = h.stub(
      require('util.languages'),
      'is_available',
      function() return false end
    )
    local ok, result = pcall(load)
    restore()
    assert(ok, result)
    by_ft = result
    -- The server formats in place of the missing `ruff`
    assert.same({ lsp_format = 'last' }, by_ft.python)
    assert.is_false(vim.list_contains(common('python'), 'condense_blank_lines'))
  end)

  it('keeps the trailing spaces that mean something', function()
    assert.is_false(vim.list_contains(common('markdown'), 'trim_whitespace'))
    assert.same({}, common('diff'))
    assert.is_true(vim.list_contains(common('lua'), 'trim_whitespace'))
  end)

  it('condenses runs of blank lines to one, without sed', function()
    local conform
    for _, spec in
      ipairs(dofile(h.root .. '/lua/plugins/executor/formatting.lua'))
    do
      if spec[1] == 'stevearc/conform.nvim' then conform = spec end
    end
    local formatter = conform.opts(nil, {}).formatters.condense_blank_lines
    assert.is_nil(formatter.command)
    local result
    formatter.format(
      nil,
      nil,
      { 'a', '', '', '', 'b', '', 'c', ' ', '', '' },
      function(err, lines) result = { err = err, lines = lines } end
    )
    assert.is_nil(result.err)
    assert.same({ 'a', '', 'b', '', 'c', ' ', '' }, result.lines)
  end)
end)

describe('plugins.executor.formatting: conform', function()
  local restores, conform, calls

  ---@param name string
  ---@return table
  local function spec(name)
    for _, plugin in
      ipairs(dofile(h.root .. '/lua/plugins/executor/formatting.lua'))
    do
      if plugin[1] == name then return plugin end
    end
    error('no spec ' .. name)
  end

  before_each(function()
    h.globals()
    calls = {}
    conform = {
      formatters_by_ft = {},
      format = function(opts) table.insert(calls, { format = opts }) end,
      setup = function(opts) table.insert(calls, { setup = opts }) end,
      list_formatters = function(bufnr)
        return { { name = 'stylua', bufnr = bufnr }, { name = 'injected' } }
      end,
    }
    restores = { h.stub(package.loaded, 'conform', conform) }
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.cmd('silent! %bwipeout!')
  end)

  it('formats the injected languages on a key', function()
    local plugin = spec('stevearc/conform.nvim')
    assert.are.equal('<leader>cF', plugin.keys[1][1])
    plugin.keys[1][2]()
    assert.are.same(
      { formatters = { 'injected' }, timeout_ms = 3000 },
      calls[1].format
    )
  end)

  it('registers with util.format ahead of the language server', function()
    local Plugin = require('util.plugin')
    restores[#restores + 1] = h.stub(
      Plugin,
      'on_very_lazy',
      function(fn) fn() end
    )
    h.unload('util.format')
    spec('stevearc/conform.nvim').init()
    local formatter = require('util.format').formatters[1]
    assert.are.equal('conform.nvim', formatter.name)
    assert.are.equal(100, formatter.priority)
    assert.is_true(formatter.primary)
    assert.are.same({ 'stylua', 'injected' }, formatter.sources(7))
    formatter.format(7)
    assert.are.same({ bufnr = 7 }, calls[1].format)
    h.unload('util.format')
  end)

  it('never lets conform format on save by itself', function()
    spec('stevearc/conform.nvim').config(nil, {
      format_on_save = {},
      format_after_save = {},
      formatters = { x = {} },
    })
    assert.are.same({ formatters = { x = {} } }, calls[1].setup)
  end)

  it('rebuilds the lists once Mason installs a formatter', function()
    local handlers = {}
    restores[#restores + 1] = h.stub(package.loaded, 'lazy.core.config', {
      spec = { plugins = {} },
      plugins = { ['mason.nvim'] = { _ = { loaded = {} } } },
    })
    restores[#restores + 1] = h.stub(package.loaded, 'mason-registry', {
      on = function(_, event, handler) handlers[event] = handler end,
    })
    local available = false
    restores[#restores + 1] = h.stub(
      require('util.languages'),
      'is_available',
      function() return available end
    )
    local opts = spec('stevearc/conform.nvim').opts(nil, {})
    -- Nothing is installed yet, so the server formats Lua
    assert.are.same({ lsp_format = 'last' }, opts.formatters_by_ft.lua)
    available = true
    handlers['package:install:success']()
    assert.is_true(
      vim.wait(
        500,
        function() return conform.formatters_by_ft.lua ~= nil end,
        10
      )
    )
    assert.are.same({ 'stylua' }, conform.formatters_by_ft.lua)
  end)

  describe('missing parsers of injected blocks', function()
    local injected, parsers, blocks, notified, formatted, bufnr, get_lang

    before_each(function()
      -- The parsers this machine "has", and the languages of the blocks of
      -- the buffer, as the injections query reports them
      parsers, blocks, notified, formatted = {}, {}, {}, {}
      conform.formatters_by_ft = {
        sh = { 'shfmt' },
        python = { 'ruff_format' },
        json5 = { 'prettier' },
        lua = { lsp_format = 'last' },
      }
      get_lang = vim.treesitter.language.get_lang
      restores[#restores + 1] =
        h.stub(package.loaded, 'conform.formatters.injected', {
          format = function(_, ctx, lines, callback)
            table.insert(formatted, { ctx = ctx, lines = lines })
            callback(nil, lines)
          end,
        })
      restores[#restores + 1] = h.stub(
        vim.treesitter.language,
        'add',
        function(lang) return parsers[lang] and true or nil end
      )
      -- `json` names `json5`'s parser here, as `LanguageTree` would find
      restores[#restores + 1] = h.stub(
        vim.treesitter.language,
        'get_lang',
        function(name)
          if name == 'json' then return 'json5' end
          return get_lang(name)
        end
      )
      restores[#restores + 1] = h.stub(
        vim.treesitter.query,
        'get',
        function(lang, name)
          assert.are.equal('injections', name)
          if lang ~= 'markdown' then return nil end
          return {
            captures = { 'injection.content', 'injection.language' },
            iter_matches = function()
              local i = 0
              return function()
                i = i + 1
                local block = blocks[i]
                if not block then return nil end
                -- A language named by a capture, or set by the query
                if block.capture then
                  return i, { [2] = { { text = block.capture } } }, {}
                end
                return i, {}, { ['injection.language'] = block.language }
              end
            end,
          }
        end
      )
      restores[#restores + 1] = h.stub(
        vim.treesitter,
        'get_parser',
        function(_, lang)
          if lang == 'markdown' then
            return {
              parse = function() end,
              trees = function()
                return { { root = function() return {} end } }
              end,
            }
          end
          error('no parser for ' .. lang)
        end
      )
      restores[#restores + 1] = h.stub(
        vim.treesitter,
        'get_node_text',
        function(node) return node.text end
      )
      restores[#restores + 1] = h.stub(
        vim,
        'notify',
        function(msg, level, opts)
          table.insert(notified, { msg = msg, level = level, opts = opts })
        end
      )
      injected = spec('stevearc/conform.nvim').opts(nil, {}).formatters.injected
      bufnr = h.buffer({ filetype = 'markdown' })
    end)

    --- Format the buffer, and return the languages reported missing
    ---@return string[]
    local function report()
      local done
      injected.format(
        injected,
        { buf = bufnr },
        { 'x' },
        function() done = true end
      )
      assert.is_true(done)
      vim.wait(100, function() return #notified > 0 end, 10)
      return vim.tbl_map(
        function(n) return n.msg:match('parser for `([^`]+)`') end,
        notified
      )
    end

    it(
      'keeps the maps of the languages that part from their filetype',
      function()
        assert.are.equal('sh', injected.options.lang_to_ft.bash)
        assert.are.equal('sh', injected.options.lang_to_ext.bash)
        assert.is_true(injected.options.ignore_errors)
      end
    )

    it('reports a block whose formatter waits for a parser', function()
      parsers.python = true
      blocks = {
        { language = 'python' },
        -- Named by a capture, and the way `LanguageTree` normalises it
        { capture = ' Bash\n' },
        -- Its formatter is there, but the block cannot be found
        { language = 'bash' },
      }
      assert.are.same({ 'bash' }, report())
      local n = notified[1]
      assert.are.equal(vim.log.levels.WARN, n.level)
      assert.are.equal('DyNeo Format', n.opts.title)
      assert.is_not_nil(n.msg:find('`:TSInstall bash`', 1, true))
      assert.are.equal(1, #formatted)
      assert.are.same({ 'x' }, formatted[1].lines)
    end)

    it(
      'says nothing of a block nobody formats, or that has a parser',
      function()
        parsers.json5 = true
        blocks = {
          -- An alias of a parser that is there
          { language = 'json' },
          -- No formatter waits for these
          { language = 'mermaid' },
          { language = 'lua' },
          { capture = 'C++' },
          { capture = '' },
        }
        assert.are.same({}, report())
      end
    )

    it('reports each language once, in order', function()
      blocks = {
        { language = 'python' },
        { language = 'bash' },
        { language = 'python' },
      }
      assert.are.same({ 'bash', 'python' }, report())
      notified = {}
      report()
      assert.are.same({}, notified)
    end)

    it('leaves a buffer without injections alone', function()
      blocks = { { language = 'python' } }
      vim.bo[bufnr].filetype = 'lua'
      assert.are.same({}, report())
      vim.bo[bufnr].filetype = ''
      assert.are.same({}, report())
      -- The query is there, the parser is not
      restores[#restores + 1] = h.stub(vim.treesitter.query, 'get', function()
        return {
          captures = {},
          iter_matches = function()
            return function() end
          end,
        }
      end)
      vim.bo[bufnr].filetype = 'lua'
      assert.are.same({}, report())
      assert.are.equal(3, #formatted)
    end)
  end)
end)

describe('plugins.executor.formatting: a stubbed language list', function()
  local restores, conform, by_ft, formatters

  before_each(function()
    h.globals()
    conform = { formatters_by_ft = {} }
    restores = {
      h.stub(package.loaded, 'conform', conform),
      h.stub(package.loaded, 'config.languages', {
        sh = {
          filetypes = { 'sh', 'zsh' },
          parser = 'bash',
          ext = 'sh',
          formatters = {
            'shfmt',
            {
              'beautysh',
              filetypes = { 'zsh' },
              opts = { args = { '-i', '2' } },
            },
            { 'sysfmt', mason = { enabled = false } },
          },
        },
        -- A parser named after neither filetype nor extension
        cs = {
          filetypes = { 'cs' },
          parser = 'c_sharp',
          ext = 'cs',
          formatters = { 'csharpier' },
        },
        -- Borrows the `json` parser, and must not speak for ```json blocks
        jupyter = {
          filetypes = { 'jupyter' },
          parser = { 'json' },
          formatters = { 'jupytext' },
        },
        json = {
          filetypes = { 'json' },
          parser = 'json',
          formatters = { { 'prettier', mason = { package = 'prettierd' } } },
        },
        -- A parser and no formatter: no entry in the injected maps
        toml = { filetypes = { 'toml' }, parser = 'toml' },
        ['*'] = {
          filetypes = { '*' },
          formatters = {
            'trim_whitespace',
            'condense_blank_lines',
            'trim_newlines',
            'injected',
            'typos',
          },
        },
      }),
      -- `util.languages` read the languages when it loaded
      function() h.unload('util.languages') end,
    }
    h.unload('util.languages')
    restores[#restores + 1] = h.stub(
      require('util.languages'),
      'is_available',
      function(command) return command ~= 'jupytext' end
    )
    for _, plugin in
      ipairs(dofile(h.root .. '/lua/plugins/executor/formatting.lua'))
    do
      if plugin[1] == 'stevearc/conform.nvim' then
        local opts = plugin.opts(nil, {})
        by_ft, formatters = opts.formatters_by_ft, opts.formatters
      end
    end
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.cmd('silent! %bwipeout!')
  end)

  it('keeps a common formatter it does not know about', function()
    local bufnr = h.buffer({ filetype = 'lua' })
    assert.are.same({
      'trim_whitespace',
      'condense_blank_lines',
      'trim_newlines',
      'injected',
      'typos',
    }, by_ft['*'](bufnr))
  end)

  it('gives a formatter only to the filetypes it names', function()
    assert.are.same({ 'shfmt', 'sysfmt' }, by_ft.sh)
    assert.are.same({ 'shfmt', 'beautysh', 'sysfmt' }, by_ft.zsh)
    assert.are.same({ 'csharpier' }, by_ft.cs)
    assert.are.same({ lsp_format = 'last' }, by_ft.jupyter)
    assert.are.same({ args = { '-i', '2' } }, formatters.beautysh)
  end)

  it('maps a parser to its filetype and extension for injected', function()
    local options = formatters.injected.options
    assert.are.same({ bash = 'sh', c_sharp = 'cs' }, options.lang_to_ft)
    assert.are.same({ bash = 'sh', c_sharp = 'cs' }, options.lang_to_ext)
  end)

  it('installs the formatters through Mason', function()
    local installed, handlers = {}, {}
    restores[#restores + 1] = h.stub(package.loaded, 'util.lazy_install', {
      on_filetype = function(filetypes, handler)
        table.insert(handlers, { filetypes = filetypes, handler = handler })
      end,
      install_once = function(package) table.insert(installed, package) end,
    })
    local mason
    for _, plugin in
      ipairs(dofile(h.root .. '/lua/plugins/executor/formatting.lua'))
    do
      if plugin[1] == 'mason-org/mason.nvim' then mason = plugin end
    end
    DyNeo.bundle_languages = { 'json' }
    DyNeo.enabled_languages = { 'sh', 'json' }
    local opts = { ensure_installed = {} }
    mason.opts(nil, opts)
    -- The common ones and the bundle up front, under their package names
    assert.are.same({
      'trim_whitespace',
      'condense_blank_lines',
      'trim_newlines',
      'injected',
      'typos',
      'prettierd',
    }, opts.ensure_installed)
    -- The rest with their first buffer, the system formatter never
    assert.are.equal(3, #handlers)
    assert.are.same({ 'json' }, handlers[1].filetypes)
    for _, handler in ipairs(handlers) do
      handler.handler()
    end
    assert.are.same({ 'prettierd', 'shfmt', 'beautysh' }, installed)
  end)
end)
