-- `config.languages` is the one table nearly every plugin spec reads from,
-- and it is read by field name, so a typo there makes a tool quietly vanish
-- instead of failing. Each entry is checked against `DyLangSpec`.
local languages = require('config.languages')

local known_fields = {
  filetypes = true,
  parser = true,
  injected_parsers = true,
  ext = true,
  lsp_servers = true,
  linters = true,
  formatters = true,
  null_ls = true,
  dap = true,
  test = true,
  neogen = true,
  dial = true,
  autopairs = true,
  endwise = true,
  otter = true,
}

local null_ls_types = {
  diagnostics = true,
  formatting = true,
  code_actions = true,
  hover = true,
  completion = true,
}

-- none-ls sources that send buffer text to a server
local sends_text = { jira = true, ltcc = true, ai_fix = true }

local function is_string_list(value)
  if type(value) ~= 'table' or not vim.islist(value) then return false end
  for _, item in ipairs(value) do
    if type(item) ~= 'string' or item == '' then return false end
  end
  return true
end

---@param mason any
local function assert_mason(mason, where)
  if mason == nil then return end
  assert.are.equal('table', type(mason), where)
  if mason.enabled ~= nil then
    assert.are.equal('boolean', type(mason.enabled), where)
  end
  if mason.package ~= nil then
    assert.are.equal('string', type(mason.package), where)
  end
end

---@param tool any Entry of `linters` or `formatters`
local function assert_tool(tool, where)
  if type(tool) == 'string' then return end
  assert.are.equal('table', type(tool), where)
  assert.are.equal('string', type(tool[1]), where)
  if tool.command ~= nil then
    assert.are.equal('string', type(tool.command), where)
  end
  if tool.opts ~= nil then assert.are.equal('table', type(tool.opts), where) end
  assert_mason(tool.mason, where)
end

--- A stand-in for the objects `dial` and `autopairs` are handed: any field is
--- another stand-in, and calling one returns a fresh one, so whatever chain of
--- builder calls a spec makes, it gets something back.
local function chainable()
  local proxy
  proxy = setmetatable({}, {
    __index = function() return chainable() end,
    __call = function() return chainable() end,
  })
  return proxy
end

local names = vim.tbl_keys(languages)
table.sort(names)

describe('config.languages', function()
  it(
    'has the catch-all `*` entry',
    function() assert.are.same({ '*' }, languages['*'].filetypes) end
  )

  it('has the languages other modules index by name', function()
    for _, name in ipairs({ 'cpp', 'bash', 'yaml', 'lua', 'markdown' }) do
      assert.is_not_nil(languages[name], name)
    end
  end)

  it('gives each filetype to a single language', function()
    local owner = {}
    for _, name in ipairs(names) do
      for _, ft in ipairs(languages[name].filetypes) do
        assert(
          owner[ft] == nil,
          ft .. ' is claimed by both ' .. tostring(owner[ft]) .. ' and ' .. name
        )
        owner[ft] = name
      end
    end
  end)

  -- `command` is what decides whether a tool is set up at all, so it has to
  -- be the binary conform or nvim-lint really starts
  it('names the binary each tool runs', function()
    local runs = {
      html_beautify = 'html-beautify',
      erb_lint = 'erblint',
      condense_blank_lines = 'lua',
      nix = 'nix-instantiate',
      csharpier = 'csharpier',
    }
    local seen = {}
    for _, name in ipairs(names) do
      for _, field in ipairs({ 'linters', 'formatters' }) do
        for _, tool in ipairs(languages[name][field] or {}) do
          if type(tool) == 'table' and runs[tool[1]] then
            seen[tool[1]] = true
            assert.are.equal(
              runs[tool[1]],
              tool.command,
              name .. ' ' .. tool[1]
            )
          end
          if type(tool) == 'table' and tool.opts and tool.opts.cmd then
            assert.are.equal(tool.opts.cmd, tool.command, tool[1])
          end
        end
      end
    end
    assert.are.same(vim.tbl_map(function() return true end, runs), seen)
  end)

  for _, name in ipairs(names) do
    local spec = languages[name]
    describe(name, function()
      it('only uses known fields', function()
        for field in pairs(spec) do
          assert(known_fields[field], 'unknown field ' .. tostring(field))
        end
      end)

      it('lists its filetypes', function()
        assert.is_true(is_string_list(spec.filetypes))
        assert.is_true(#spec.filetypes > 0)
      end)

      it('names its parser', function()
        local parser = spec.parser
        if parser == nil then return end
        if type(parser) == 'table' then
          assert.are.equal('string', type(parser[1]))
          assert.are.equal('table', type(parser.install_info))
          assert.are.equal('string', type(parser.install_info.url))
          assert.is_truthy(parser.install_info.url:match('^https?://'))
          -- A commit, so a push to the grammar never lands unreviewed
          assert.is_truthy(
            (parser.install_info.revision or ''):match('^%x+$'),
            'revision'
          )
          assert.are.equal(40, #parser.install_info.revision)
        else
          assert.are.equal('string', type(parser))
          assert.is_truthy(parser:match('^[%w_]+$'))
        end
      end)

      it('has fields of the right type', function()
        for _, field in ipairs({ 'injected_parsers', 'test' }) do
          if spec[field] ~= nil then
            assert(is_string_list(spec[field]), field)
          end
        end
        if spec.ext ~= nil then assert.is_truthy(spec.ext:match('^[%w_]+$')) end
        if spec.neogen ~= nil then
          assert.is_truthy(spec.neogen:match('^[%w_]+$'), 'neogen')
        end
        for _, field in ipairs({ 'dial', 'autopairs' }) do
          if spec[field] ~= nil then
            assert.are.equal('function', type(spec[field]), field)
          end
        end
        for _, field in ipairs({ 'endwise', 'otter' }) do
          if spec[field] ~= nil then
            assert.are.equal('boolean', type(spec[field]), field)
          end
        end
      end)

      it('builds its dial augends and autopairs rules', function()
        if spec.dial then
          local augends = spec.dial(chainable())
          assert.is_true(vim.islist(augends) and #augends > 0)
        end
        if spec.autopairs then
          local rules = spec.autopairs(
            spec.filetypes,
            chainable(),
            chainable(),
            chainable()
          )
          assert.is_true(vim.islist(rules) and #rules > 0)
        end
      end)

      it('describes its language servers', function()
        for i, server in ipairs(spec.lsp_servers or {}) do
          local where = 'lsp_servers[' .. i .. ']'
          if type(server) == 'table' then
            assert.are.equal('string', type(server[1]), where)
            if server.enabled ~= nil then
              assert.are.equal('function', type(server.enabled), where)
            end
            if server.filetypes ~= nil then
              assert(is_string_list(server.filetypes), where)
              for _, ft in ipairs(server.filetypes) do
                assert(
                  vim.list_contains(spec.filetypes, ft),
                  where .. ': ' .. ft .. ' is not a filetype of ' .. name
                )
              end
            end
          else
            assert.are.equal('string', type(server), where)
          end
        end
      end)

      it('describes its linters and formatters', function()
        for _, field in ipairs({ 'linters', 'formatters' }) do
          for i, tool in ipairs(spec[field] or {}) do
            assert_tool(tool, field .. '[' .. i .. ']')
          end
        end
      end)

      it('describes its none-ls sources', function()
        for i, source in ipairs(spec.null_ls or {}) do
          local where = 'null_ls[' .. i .. ']'
          assert.are.equal('string', type(source[1]), where)
          assert(
            null_ls_types[source.type],
            where .. ': type ' .. tostring(source.type)
          )
          assert.are.equal('string', type(source.command), where)
          if source.custom ~= nil then
            assert.are.equal('boolean', type(source.custom), where)
          end
          assert_mason(source.mason, where)
          -- Their text leaves the machine, so sensitive buffers must skip them
          if sends_text[source[1]] then
            assert.is_true(source.remote, where .. ': not marked remote')
          end
        end
      end)

      it('describes its debug adapters', function()
        for i, adapter in ipairs(spec.dap or {}) do
          local where = 'dap[' .. i .. ']'
          if type(adapter) == 'table' then
            assert.are.equal('string', type(adapter[1]), where)
            assert.are.equal('table', type(adapter.mason), where)
            assert_mason(adapter.mason, where)
          else
            assert.are.equal('string', type(adapter), where)
          end
        end
      end)
    end)
  end
end)

-- The functions the specs carry: a server's `enabled`, a formatter's
-- arguments or condition, and the autopairs rules, each given the buffer or
-- the line it would see
describe('config.languages callbacks', function()
  local h = require('helpers')
  local dir, cleanup

  before_each(function()
    dir, cleanup = h.tmpdir()
  end)
  after_each(function()
    vim.cmd('silent! %bwipeout!')
    cleanup()
  end)

  --- The first entry of `list` named `name`
  ---@param list table[]
  ---@param name string
  ---@return table
  local function entry(list, name)
    for _, item in ipairs(list) do
      if type(item) == 'table' and item[1] == name then return item end
    end
    error('no entry ' .. name)
  end

  --- A buffer named `path` with `lines`, set up as `filetype`
  local function buffer(path, lines, filetype)
    return h.buffer({ name = path, lines = lines, filetype = filetype })
  end

  it('hands djlint the profile of the buffer', function()
    local djlint = entry(languages.htmldjango.formatters, 'djlint')
    local django = buffer(dir .. '/a.html', {}, 'htmldjango')
    assert.same(
      { '--profile', 'django' },
      djlint.opts.prepend_args(nil, { buf = django })
    )
    local jinja = buffer(dir .. '/b.j2', {}, 'jinja')
    assert.same(
      { '--profile', 'jinja' },
      djlint.opts.prepend_args(nil, { buf = jinja })
    )
  end)

  describe('servers of every buffer', function()
    local servers = languages['*'].lsp_servers

    it('start sonarlint where a project asks for it and java runs', function()
      local sonarlint = entry(servers, 'sonarlint')
      local restore = h.stub(
        vim.fn,
        'executable',
        function(name) return name == 'java' and 1 or 0 end
      )
      local outside = buffer(dir .. '/a.lua', {})
      assert.is_false(sonarlint.enabled(outside))
      h.write(dir .. '/proj/sonar-project.properties', { '' })
      local inside = buffer(dir .. '/proj/a.lua', {})
      assert.is_true(sonarlint.enabled(inside))
      restore()
      restore = h.stub(vim.fn, 'executable', function() return 0 end)
      assert.is_false(sonarlint.enabled(inside))
      restore()
    end)

    it('start typos and ast-grep only with their config', function()
      local typos = entry(servers, 'typos_lsp')
      local ast_grep = entry(servers, 'ast_grep')
      local plain = buffer(dir .. '/a.lua', {})
      assert.is_false(typos.enabled(plain))
      assert.is_false(ast_grep.enabled(plain))
      h.write(dir .. '/proj/_typos.toml', { '' })
      h.write(dir .. '/proj/sgconfig.yml', { '' })
      local configured = buffer(dir .. '/proj/a.lua', {})
      assert.is_true(typos.enabled(configured))
      assert.is_true(ast_grep.enabled(configured))
    end)
  end)

  it('runs jq and jsonlint on strict JSON only', function()
    local jq = entry(languages.json.formatters, 'jq')
    local jsonlint = entry(languages.json.linters, 'jsonlint')
    local strict = buffer(dir .. '/a.json', {}, 'json')
    local loose = buffer(dir .. '/b.jsonc', {}, 'jsonc')
    assert.is_true(jq.opts.condition(nil, { buf = strict }))
    assert.is_false(jq.opts.condition(nil, { buf = loose }))
    vim.api.nvim_set_current_buf(strict)
    assert.is_true(jsonlint.opts.condition())
    vim.api.nvim_set_current_buf(loose)
    assert.is_false(jsonlint.opts.condition())
  end)

  it('gives sqlfluff a dialect only without a project config', function()
    local sqlfluff = entry(languages.sql.formatters, 'sqlfluff')
    local cases = { mysql = 'mysql', plsql = 'oracle', sql = 'ansi' }
    for filetype, dialect in pairs(cases) do
      local bufnr = buffer(dir .. '/q.' .. filetype, {}, filetype)
      assert.same(
        { 'format', '--dialect=' .. dialect, '-' },
        sqlfluff.opts.args(nil, { buf = bufnr, dirname = dir }),
        filetype
      )
    end
    h.write(dir .. '/proj/.sqlfluff', { '[sqlfluff]', 'dialect = postgres' })
    local bufnr = buffer(dir .. '/proj/q.sql', {}, 'mysql')
    assert.same(
      { 'format', '-' },
      sqlfluff.opts.args(nil, { buf = bufnr, dirname = dir .. '/proj' })
    )
  end)

  it('lints a Postgres migration with squawk, and nothing else', function()
    local squawk = entry(languages.sql.linters, 'squawk')
    local cases = {
      { '/app/db/migrations/0001_init.sql', 'sql', true },
      { '/app/db/migrate/20260101_add.sql', 'sql', true },
      { '/app/queries/report.sql', 'sql', false },
      { '/app/db/migrations/0001_init.sql', 'mysql', false },
      -- A file merely named so is no migration folder, nor a folder whose
      -- name only starts so
      { '/app/migrations.sql', 'sql', false },
      { '/src/migrator/reports/q.sql', 'sql', false },
      { '/data_migration/queries/x.sql', 'sql', false },
      -- Flyway's
      { '/app/src/main/resources/db/migration/V1__init.sql', 'sql', true },
    }
    for index, case in ipairs(cases) do
      vim.api.nvim_set_current_buf(buffer(dir .. '/x' .. index, {}, case[2]))
      assert.equals(
        case[3],
        squawk.opts.condition({ filename = case[1] }),
        case[1] .. ' ' .. case[2]
      )
    end
  end)

  it('runs the Markdown formatters only where they have work', function()
    local toc = entry(languages.markdown.formatters, 'markdown-toc')
    local lint = entry(languages.markdown.formatters, 'markdownlint-cli2')
    local plain = buffer(dir .. '/a.md', { '# Title', 'text' })
    assert.is_nil(toc.opts.condition(nil, { buf = plain }))
    assert.is_false(lint.opts.condition(nil, { buf = plain }))
    local with_toc = buffer(dir .. '/b.md', { '# Title', '<!-- toc -->' })
    assert.is_true(toc.opts.condition(nil, { buf = with_toc }))
    local ns = vim.api.nvim_create_namespace('dy_test_markdownlint')
    vim.diagnostic.set(ns, plain, {
      { lnum = 1, col = 0, message = 'MD001', source = 'markdownlint' },
    })
    assert.is_true(lint.opts.condition(nil, { buf = plain }))
    vim.diagnostic.reset(ns, plain)
  end)

  describe('autopairs rules', function()
    --- A `rule` that records every builder call made on it, and a `cond`
    --- whose every condition is a marker, so the rules can be looked up by
    --- their start and their callbacks run
    local function recorder()
      local rules = {}
      local function rule(start, finish, filetypes)
        local r = { start = start, finish = finish, filetypes = filetypes }
        local calls = {}
        r.calls = calls
        return setmetatable(r, {
          __index = function(_, method)
            return function(self, ...)
              calls[method] = calls[method] or {}
              table.insert(calls[method], { ... })
              return self
            end
          end,
        }),
          table.insert(rules, r)
      end
      local cond = setmetatable({}, {
        __index = function(_, name)
          return function(...) return { cond = name, ... } end
        end,
      })
      return rule, cond, rules
    end

    --- The rules of `spec`, by their start, and all of them in order
    ---@param spec DyLangSpec
    ---@return table<string, table>
    ---@return table[]
    local function rules_of(spec)
      local rule, cond, rules = recorder()
      spec.autopairs(spec.filetypes, rule, cond, nil)
      local by_start = {}
      for _, r in ipairs(rules) do
        by_start[r.start] = r
      end
      return by_start, rules
    end

    it('space out an arrow function body typed after )', function()
      local arrow = rules_of(languages.javascript)['=>']
      local replace = arrow.calls.replace_endpair[1][1]
      assert.equals('<BS><BS> => {  }', replace({ line = '() =', col = 4 }))
      assert.equals(' {  }', replace({ line = 'x =', col = 3 }))
      assert.same({ { 2 } }, arrow.calls.set_end_pair_length)
    end)

    describe('of every buffer', function()
      local rules
      before_each(function() rules = rules_of(languages['*']) end)

      it('pad a bracket pair with spaces, and delete both', function()
        local space = rules[' ']
        local replace = space.calls.replace_endpair[1][1]
        assert.equals(' ', replace({ line = '()', col = 2 }))
        assert.equals(' ', replace({ line = 'f{}', col = 3 }))
        assert.equals('', replace({ line = 'ab', col = 2 }))
        local del = space.calls.with_del[1][1]
        vim.api.nvim_set_current_buf(h.buffer({ lines = { '(  )' } }))
        vim.api.nvim_win_set_cursor(0, { 1, 2 })
        assert.is_true(del({ line = '(  )' }))
        assert.is_false(del({ line = 'abcd' }))
        assert.equals('done', space.calls.with_pair[1][1].cond)
      end)

      it('move over a closing bracket typed before its space', function()
        local _, all = rules_of(languages['*'])
        for _, close in ipairs({ ')', '}', ']' }) do
          -- Rules sharing the empty start are told apart by their end
          local found
          for _, candidate in ipairs(all) do
            if candidate.finish == ' ' .. close then found = candidate end
          end
          assert.is_not_nil(found, close)
          assert.is_true(found.calls.with_move[1][1]({ char = close }))
          assert.is_false(found.calls.with_move[1][1]({ char = 'x' }))
          assert.same({ { close } }, found.calls.use_key)
        end
      end)

      it('add a space after a comma followed by text', function()
        local replace = rules[','].calls.replace_endpair[1][1]
        assert.equals(' ', replace({ line = ',a', col = 2 }))
        assert.equals('', replace({ line = ', ', col = 2 }))
      end)

      it('space out an equals sign', function()
        local equal = rules['=']
        assert.equals('not_inside_quote', equal.calls.with_pair[1][1].cond)
        local pair = equal.calls.with_pair[2][1]
        assert.is_true(pair({ line = 'a=', col = 2 }))
        assert.is_false(pair({ line = '(=', col = 2 }))
        local replace = equal.calls.replace_endpair[1][1]
        assert.equals('<BS> = ', replace({ line = 'a=', col = 2 }))
        assert.equals(' ', replace({ line = 'a ==', col = 4 }))
        assert.equals('<BS><BS>= ', replace({ line = 'a= =', col = 4 }))
        assert.equals('', replace({ line = '( =', col = 3 }))
        assert.is_true(vim.list_contains(equal.filetypes, '-sh'))
      end)
    end)

    it('close LaTeX environments, fractions and ConTeXt starts', function()
      local rules = rules_of(languages.latex)
      -- Closed with `\end{` as `{` is typed, before the name is there
      local begin = rules['\\begin{']
      assert.equals('\\end{', begin.finish)
      assert.is_nil(begin.calls.replace_endpair)
      assert.same({ { 5 } }, begin.calls.set_end_pair_length)
      assert.is_true(rules['\\frac{'].calls.with_move[1][1]({ char = '}' }))
      assert.is_false(rules['\\frac{'].calls.with_move[1][1]({ char = 'x' }))
      local start = rules['\\start(%w*) $'].calls.replace_endpair[1][1]
      assert.equals(
        ' \\stopitemize',
        start({ line = '\\startitemize ', col = 14 })
      )
      assert.equals('', start({ line = '\\start ', col = 7 }))
      assert.equals('<space>', rules['\\start(%w*) $'].calls.use_key[1][1])
    end)
  end)
end)
