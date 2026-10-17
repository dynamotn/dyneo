local h = require('helpers')

describe('plugin/predicates', function()
  local restores, handlers

  --- The answer of predicate `name` for `bufnr`
  ---@param name string
  ---@param bufnr integer
  ---@return boolean
  local function ask(name, bufnr) return handlers[name]({}, 1, bufnr) end

  before_each(function()
    handlers = {}
    restores = {
      h.stub(
        require('vim.treesitter.query'),
        'add_predicate',
        function(name, handler) handlers[name] = handler end
      ),
      -- No language of the configuration is enabled: the queries still run
      h.stub(_G, 'DyNeo', { enabled_languages = {}, enabled_plugins = {} }),
    }
    dofile(h.root .. '/plugin/predicates.lua')
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.cmd('silent! %bwipeout!')
  end)

  it(
    'registers nothing before the first filetype',
    function() assert.same({}, handlers) end
  )

  it('registers every predicate the queries name', function()
    h.buffer({ filetype = 'text' })
    local named = {}
    for _, file in ipairs({
      'queries/yaml/injections.scm',
      'after/queries/toml/injections.scm',
      'after/queries/gotmpl/injections.scm',
    }) do
      local text = table.concat(vim.fn.readfile(h.root .. '/' .. file), '\n')
      for name in text:gmatch('%(#([%w-]+%?)') do
        named[name] = true
      end
    end
    -- Neovim's own
    for _, builtin in ipairs({
      'eq?',
      'any-of?',
      'lua-match?',
      'not-lua-match?',
      'match?',
    }) do
      named[builtin] = nil
    end
    assert.is_true(next(named) ~= nil)
    for name in pairs(named) do
      assert.is_function(handlers[name], name)
    end
  end)

  it('tells a CI flavour by its filetype', function()
    local workflow = h.buffer({ filetype = 'yaml.gh-action' })
    local gitlab = h.buffer({ filetype = 'yaml.gitlab' })
    assert.is_true(ask('is-gh-action?', workflow))
    assert.is_false(ask('is-gh-action?', gitlab))
    assert.is_true(ask('is-ci-pipeline?', gitlab))
  end)

  it('tells the language of a template by its name', function()
    local script = h.buffer({ name = '/p/run.sh.tmpl', filetype = 'gotmpl' })
    assert.is_true(ask('is-bash-file?', script))
    assert.is_false(ask('is-yaml-file?', script))
  end)
  it('tells a file of mise by its path', function()
    local paths = {
      ['/p/mise.toml'] = true,
      ['/p/.mise.local.toml'] = true,
      ['/home/u/.config/mise/config.toml'] = true,
      ['/p/.mise/config.local.toml'] = true,
      ['/home/u/.config/mise/conf.d/node.toml'] = true,
      ['/p/promise.toml'] = false,
      ['/p/mise/Cargo.toml'] = false,
      ['/p/pyproject.toml'] = false,
    }
    for path, expected in pairs(paths) do
      local bufnr = h.buffer({ name = path, filetype = 'toml' })
      assert.are.equal(expected, ask('is-mise?', bufnr), path)
    end
  end)
end)
