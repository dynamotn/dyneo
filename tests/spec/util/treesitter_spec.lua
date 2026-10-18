local h = require('helpers')

describe('util.treesitter', function()
  local ts, restores
  before_each(function()
    h.unload('util.treesitter')
    ts = require('util.treesitter')
    ts._installed = { lua = true }
    restores = {
      h.stub(vim.treesitter.query, 'get_files', function(lang, query)
        if lang == 'lua' and query == 'folds' then return { 'folds.scm' } end
        return {}
      end),
      -- Parsing a query only to see whether it is there is what is avoided
      h.stub(
        vim.treesitter.query,
        'get',
        function() error('parsed a query to check it exists') end
      ),
    }
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.cmd('silent! %bwipeout!')
  end)

  it('knows the installed parsers by filetype', function()
    assert.is_true(ts.have('lua'))
    assert.is_false(ts.have('python'))
  end)

  it('asks the buffer for its filetype', function()
    local bufnr = h.buffer({ filetype = 'lua' })
    assert.is_true(ts.have(bufnr))
  end)

  it('checks a query when one is named', function()
    assert.is_true(ts.have('lua', 'folds'))
    assert.is_false(ts.have('lua', 'indents'))
  end)

  it('reads the installed parsers again only when asked', function()
    restores[#restores + 1] = h.stub(package.loaded, 'nvim-treesitter', {
      get_installed = function(what)
        assert.are.equal('parsers', what)
        return { 'python', 'go' }
      end,
    })
    assert.are.same({ lua = true }, ts.get_installed())
    assert.are.same({ python = true, go = true }, ts.get_installed(true))
    -- The query cache went with the old list
    ts._queries['lua:folds'] = nil
    assert.is_false(ts.have('lua'))
    assert.is_true(ts.have('go'))
  end)

  it('answers nothing of a parser nobody installed', function()
    ts._installed = nil
    assert.are.same({}, ts.get_installed())
    assert.is_false(ts.have('lua'))
  end)

  describe('fold and indent expressions', function()
    before_each(function()
      restores[#restores + 1] = h.stub(
        vim.treesitter,
        'foldexpr',
        function() return '>1' end
      )
      restores[#restores + 1] = h.stub(
        package.loaded,
        'nvim-treesitter',
        { indentexpr = function() return 4 end }
      )
      -- `lua` has `folds` but no `indents` here
      ts._installed = { lua = true, vim = true }
    end)

    it('fold through tree-sitter when the buffer has the query', function()
      vim.api.nvim_set_current_buf(h.buffer({ filetype = 'lua' }))
      assert.are.equal('>1', ts.foldexpr())
      assert.are.equal(-1, ts.indentexpr())
    end)

    it('leave a buffer without the query to Vim', function()
      vim.api.nvim_set_current_buf(h.buffer({ filetype = 'python' }))
      assert.are.equal('0', ts.foldexpr())
      assert.are.equal(-1, ts.indentexpr())
      restores[#restores + 1] = h.stub(
        vim.treesitter.query,
        'get_files',
        function() return { 'indents.scm' } end
      )
      vim.api.nvim_set_current_buf(h.buffer({ filetype = 'vim' }))
      assert.are.equal(4, ts.indentexpr())
    end)
  end)

  describe('build requirements', function()
    local missing, notified
    before_each(function()
      missing = {}
      notified = {}
      restores[#restores + 1] = h.stub(
        vim.fn,
        'executable',
        function(name) return missing[name] and 0 or 1 end
      )
      restores[#restores + 1] = h.stub(vim.env, 'CC', nil)
      restores[#restores + 1] = h.stub(
        vim,
        'notify',
        function(msg, level, opts)
          table.insert(notified, { msg = msg, level = level, opts = opts })
        end
      )
    end)

    it('are met when every tool is on the path', function()
      local ok, health = ts.check()
      assert.is_true(ok)
      assert.is_true(health['tree-sitter (CLI)'])
      assert.is_true(health['C compiler'])
      assert.is_true(health.tar)
      assert.is_true(health.curl)
    end)

    it('take the compiler of $CC', function()
      missing.cc = true
      assert.is_false((ts.check()))
      vim.env.CC = 'clang'
      assert.is_true((ts.check()))
    end)

    it('build right away when met', function()
      local built = 0
      ts.build(function() built = built + 1 end)
      assert.are.equal(1, built)
      assert.are.same({}, notified)
    end)

    it('say which tool is missing instead of building', function()
      missing.curl = true
      local built = 0
      ts.build(function() built = built + 1 end)
      assert.are.equal(0, built)
      assert.are.equal(1, #notified)
      assert.are.equal(vim.log.levels.ERROR, notified[1].level)
      assert.are.equal('DyNeo Treesitter', notified[1].opts.title)
      local lines = vim.split(notified[1].msg, '\n')
      assert.is_true(vim.list_contains(lines, '- ❌ `curl`'))
      assert.is_true(vim.list_contains(lines, '- ✅ `tar`'))
      assert.are.equal(
        'Run `:checkhealth nvim-treesitter` for more information.',
        lines[#lines]
      )
    end)

    it('add why the CLI could not be installed', function()
      missing['tree-sitter'] = true
      ts.build(function() error('built without the CLI') end)
      local lines = vim.split(notified[1].msg, '\n')
      assert.are.equal(
        '`mason.nvim` is not available to install it with.',
        lines[#lines]
      )
    end)
  end)

  describe('tree-sitter CLI from Mason', function()
    local answers, executable, pkg, installs
    before_each(function()
      answers = {}
      installs = {}
      executable = { ['tree-sitter'] = 0 }
      pkg = {
        installed = false,
        is_installed = function(self) return self.installed end,
        install = function(_, _, cb) table.insert(installs, cb) end,
      }
      restores[#restores + 1] = h.stub(
        vim.fn,
        'executable',
        function(name) return executable[name] or 1 end
      )
      restores[#restores + 1] = h.stub(package.loaded, 'mason', {})
      restores[#restores + 1] = h.stub(package.loaded, 'mason-registry', {
        refresh = function(cb) cb() end,
        get_package = function(name)
          assert.are.equal('tree-sitter-cli', name)
          if pkg.missing then error('no such package') end
          return pkg
        end,
      })
      restores[#restores + 1] = h.stub(vim, 'notify', function() end)
      ts.ensure_treesitter_cli(
        function(ok, err) table.insert(answers, { ok = ok, err = err }) end
      )
    end)

    it('installs the package and says so once it landed', function()
      assert.are.same({}, answers)
      assert.are.equal(1, #installs)
      installs[1](true)
      vim.wait(100, function() return #answers > 0 end, 10)
      assert.are.same({ { ok = true } }, answers)
    end)

    it('reports a failed install', function()
      installs[1](false)
      vim.wait(100, function() return #answers > 0 end, 10)
      assert.are.same({
        {
          ok = false,
          err = 'Failed to install `tree-sitter-cli` with `mason.nvim`.',
        },
      }, answers)
    end)

    it('says when Mason has it but the path does not', function()
      pkg.installed = true
      answers = {}
      ts.ensure_treesitter_cli(
        function(ok, err) table.insert(answers, { ok = ok, err = err }) end
      )
      -- The one install is the first call's; this one starts none
      assert.are.equal(1, #installs)
      assert.are.equal(
        '`tree-sitter-cli` is installed by Mason but `tree-sitter` is not on PATH.',
        answers[1].err
      )
    end)

    it('says when the registry lacks the package', function()
      pkg.missing = true
      answers = {}
      ts.ensure_treesitter_cli(
        function(ok, err) table.insert(answers, { ok = ok, err = err }) end
      )
      assert.are.equal(
        'The Mason registry has no `tree-sitter-cli`.',
        answers[1].err
      )
    end)

    it('is satisfied once loading Mason put the CLI on the path', function()
      local asked = 0
      executable['tree-sitter'] = nil
      restores[#restores + 1] = h.stub(vim.fn, 'executable', function()
        asked = asked + 1
        return asked == 1 and 0 or 1
      end)
      answers = {}
      ts.ensure_treesitter_cli(
        function(ok, err) table.insert(answers, { ok = ok, err = err }) end
      )
      assert.are.same({ { ok = true } }, answers)
      assert.are.equal(2, asked)
    end)
  end)
end)
