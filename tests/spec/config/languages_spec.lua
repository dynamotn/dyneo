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
