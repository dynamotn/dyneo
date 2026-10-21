local h = require('helpers')

describe('lint.linters.dyshellint', function()
  local linter
  before_each(function()
    h.unload('lint.linters.dyshellint')
    linter = require('lint.linters.dyshellint')
  end)

  it('passes the buffer on stdin with its file name', function()
    assert.are.equal('dyshellint', linter.cmd)
    assert.is_true(linter.stdin)
    assert.is_false(linter.append_fname)
    assert.is_true(linter.ignore_exitcode)
    assert.are.same(
      { '--format', 'json', '--stdin-filename' },
      vim.list_slice(linter.args, 1, 3)
    )
    assert.are.equal('-', linter.args[5])
  end)

  it('names an unnamed buffer stdin.sh', function()
    vim.api.nvim_set_current_buf(h.buffer())
    assert.are.equal('stdin.sh', linter.args[4]())
  end)

  it('names a buffer by its path', function()
    -- A folder no machine has: Neovim resolves the name of one that exists,
    -- and on macOS `/tmp` is a link into `/private`
    local name = '/nonexistent-dyneo/x/script.sh'
    vim.api.nvim_set_current_buf(h.buffer({ name = name }))
    assert.are.equal(name, linter.args[4]())
  end)

  describe('parser', function()
    it('maps findings to diagnostics', function()
      local output = vim.json.encode({
        findings = {
          {
            line = 4,
            column = 7,
            severity = 'error',
            message = 'Quote this',
            rule = 'SC2086',
            source = 'shellcheck',
            section = 'Quoting',
          },
          {
            line = 1,
            column = 1,
            severity = 'warning',
            message = 'm',
            rule = 'DY001',
          },
          { message = 'no position', rule = 'DY002', severity = 'style' },
        },
      })
      local diagnostics = linter.parser(output)
      assert.are.same({
        lnum = 3,
        col = 6,
        end_lnum = 3,
        end_col = 7,
        severity = vim.diagnostic.severity.ERROR,
        message = 'Quote this',
        code = 'SC2086',
        source = 'shellcheck',
        user_data = { lsp = { code = 'SC2086' }, section = 'Quoting' },
      }, diagnostics[1])
      assert.are.equal(vim.diagnostic.severity.WARN, diagnostics[2].severity)
      assert.are.equal('dyshellint', diagnostics[2].source)
      -- An unknown severity is a warning, a missing position the first char
      assert.are.equal(vim.diagnostic.severity.WARN, diagnostics[3].severity)
      assert.are.equal(0, diagnostics[3].lnum)
      assert.are.equal(0, diagnostics[3].col)
    end)

    it('clamps a position of 0 to the first character', function()
      local output = vim.json.encode({
        findings = { { line = 0, column = 0, message = 'm' } },
      })
      local d = linter.parser(output)[1]
      assert.are.equal(0, d.lnum)
      assert.are.equal(0, d.col)
    end)

    it(
      'is empty for a clean report',
      function() assert.are.same({}, linter.parser('{"findings": []}')) end
    )

    it(
      'reports output that is not a report, rather than a clean run',
      function()
        for _, output in ipairs({ '', 'not json', '"x"', '{"findings": "x"}' }) do
          local diagnostics = linter.parser(output)
          assert.are.equal(1, #diagnostics, output)
          assert.are.equal('unreadable-report', diagnostics[1].code)
          assert.are.equal(
            vim.diagnostic.severity.ERROR,
            diagnostics[1].severity
          )
        end
        assert.are.equal('unreadable-report', linter.parser(nil)[1].code)
      end
    )
  end)
end)
