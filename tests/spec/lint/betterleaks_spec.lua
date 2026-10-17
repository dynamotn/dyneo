local h = require('helpers')

describe('lint.linters.betterleaks', function()
  local linter
  before_each(function()
    h.unload('lint.linters.betterleaks')
    vim.api.nvim_set_current_buf(h.buffer())
    linter = require('lint.linters.betterleaks')()
  end)

  it('reads the buffer from stdin and reports to stdout', function()
    assert.are.equal('betterleaks', linter.cmd)
    assert.is_true(linter.stdin)
    assert.are.equal('stdout', linter.stream)
    assert.are.equal('stdin', linter.args[1])
  end)

  it('never validates findings online and redacts them', function()
    assert.is_true(vim.list_contains(linter.args, '--validation=false'))
    assert.is_true(vim.list_contains(linter.args, '--redact'))
    assert.is_true(vim.list_contains(linter.args, '--exit-code=0'))
  end)

  it('runs from the project root of a named buffer', function()
    local dir, cleanup = h.tmpdir()
    vim.fn.mkdir(dir .. '/.git', 'p')
    h.write(dir .. '/sub/file.txt')
    vim.cmd.edit(dir .. '/sub/file.txt')
    local cwd = require('lint.linters.betterleaks')().cwd
    vim.cmd.bwipeout({ bang = true })
    cleanup()
    assert.are.equal(dir, cwd)
  end)

  describe('with rules of the project', function()
    local dir, cleanup, restores, asked, trust

    before_each(function()
      dir, cleanup = h.tmpdir()
      vim.fn.mkdir(dir .. '/.git', 'p')
      h.write(dir .. '/.gitleaks.toml', { '[allowlist]', 'regexes = [".*"]' })
      h.write(dir .. '/file.txt')
      asked = 0
      restores = {
        h.stub(vim.secure, 'read', function()
          asked = asked + 1
          return trust and 'rules' or nil
        end),
        h.stub(vim, 'notify', function() end),
      }
      vim.cmd.edit(dir .. '/file.txt')
    end)
    after_each(function()
      vim.cmd.bwipeout({ bang = true })
      for _, restore in ipairs(restores) do
        restore()
      end
      cleanup()
    end)

    it('runs away from them while they are not trusted', function()
      trust = false
      local cwd = require('lint.linters.betterleaks')().cwd
      assert.is_not_nil(cwd)
      assert.are_not.equal(dir, cwd)
      assert.is_nil(vim.uv.fs_stat(cwd .. '/.gitleaks.toml'))
      -- Asked once, not on every lint
      require('lint.linters.betterleaks')()
      assert.are.equal(1, asked)
    end)

    it('reads them once `:trust` is given, without a restart', function()
      local state, clean_state = h.tmpdir()
      local stdpath = vim.fn.stdpath
      table.insert(
        restores,
        h.stub(
          vim.fn,
          'stdpath',
          function(what) return what == 'state' and state or stdpath(what) end
        )
      )
      trust = false
      assert.are_not.equal(dir, require('lint.linters.betterleaks')().cwd)
      -- What `:trust` does: write the database `vim.secure` keeps
      trust = true
      h.write(state .. '/trust', { 'hash ' .. dir .. '/.gitleaks.toml' })
      local cwd = require('lint.linters.betterleaks')().cwd
      clean_state()
      assert.are.equal(dir, cwd)
      assert.are.equal(2, asked)
    end)

    it('reads them once they are trusted', function()
      trust = true
      assert.are.equal(dir, require('lint.linters.betterleaks')().cwd)
    end)
  end)

  it(
    'has no working directory for an unnamed buffer',
    function() assert.is_nil(linter.cwd) end
  )

  describe('parser', function()
    it('turns findings into 0-based warnings', function()
      local output = vim.json.encode({
        {
          RuleID = 'generic-api-key',
          Description = 'Generic API Key',
          StartLine = 3,
          EndLine = 3,
          StartColumn = 5,
          EndColumn = 20,
        },
      })
      assert.are.same({
        {
          bufnr = 7,
          lnum = 2,
          end_lnum = 2,
          col = 4,
          end_col = 20,
          severity = vim.diagnostic.severity.WARN,
          source = 'betterleaks',
          code = 'generic-api-key',
          message = 'Generic API Key',
        },
      }, linter.parser(output, 7))
    end)

    it(
      'is empty for an empty report',
      function() assert.are.same({}, linter.parser('[]', 1)) end
    )

    it(
      'reports output that is not a report, rather than a clean run',
      function()
        for _, output in ipairs({ 'panic: oops', '', '"text"' }) do
          local diagnostics = linter.parser(output, 1)
          assert.are.equal(1, #diagnostics, output)
          assert.are.equal('unreadable-report', diagnostics[1].code)
          assert.are.equal(
            vim.diagnostic.severity.ERROR,
            diagnostics[1].severity
          )
          assert.are.equal('betterleaks', diagnostics[1].source)
        end
      end
    )
  end)
end)
