local h = require('helpers')
local stub = require('spec.tools.null_ls_stub')

describe('tools.diagnostics.terragrunt_validate', function()
  local builtin, opts
  before_each(function()
    stub.install('tools.diagnostics.terragrunt_validate')
    builtin = require('tools.diagnostics.terragrunt_validate')
    opts = builtin.generator_opts
  end)
  after_each(stub.uninstall)

  it('runs `terragrunt hcl validate --json` on save', function()
    assert.are.equal('terragrunt_validate', builtin.name)
    assert.are.equal('NULL_LS_DIAGNOSTICS_ON_SAVE', builtin.method)
    assert.are.equal('terragrunt', opts.command)
    assert.are.same({ 'hcl', 'validate', '--json' }, opts.args)
    assert.is_true(opts.multiple_files)
  end)

  it(
    'runs in the directory of the buffer',
    function()
      assert.are.equal(
        '/repo/live/app',
        opts.cwd({ bufname = '/repo/live/app/terragrunt.hcl' })
      )
    end
  )

  it('runs only in a project trusted to run its code', function()
    local asked = {}
    local answer = false
    local restore = h.stub(package.loaded, 'util.trust', {
      ask = function(purpose, root, question, sticky)
        table.insert(asked, { purpose, root, sticky })
        assert.is_truthy(question:find('run_cmd', 1, true))
        return answer
      end,
    })
    local dir, cleanup = h.tmpdir()
    h.write(dir .. '/live/terragrunt.hcl', { 'locals {}' })
    local bufnr = h.buffer({ name = dir .. '/live/terragrunt.hcl' })
    local params = { bufnr = bufnr, bufname = dir .. '/live/terragrunt.hcl' }
    assert.is_false(opts.runtime_condition(params))
    answer = true
    assert.is_true(opts.runtime_condition(params))
    restore()
    vim.api.nvim_buf_delete(bufnr, { force = true })
    cleanup()
    assert.same({ 'terragrunt', dir .. '/live', true }, asked[1])
  end)

  -- none-ls hands stdout to `on_output` only for an exit it was told is fine;
  -- any other, with nothing on stderr, has its stdout taken for the error
  it('reads the output whatever the exit code', function()
    assert.is_true(opts.check_exit_code(0, ''))
    assert.is_true(opts.check_exit_code(1, 'boom'))
  end)

  describe('on_output', function()
    it('places a diagnostic with a range where it points', function()
      local result = opts.on_output({
        bufname = '/repo/a/terragrunt.hcl',
        cwd = '/repo/a',
        output = {
          {
            summary = 'Unsupported argument',
            detail = 'An argument named "foo" is not expected here.',
            severity = 'error',
            range = {
              filename = '/repo/a/child/terragrunt.hcl',
              start = { line = 3, column = 2 },
              ['end'] = { line = 3, column = 5 },
            },
          },
        },
      })
      assert.are.same({
        {
          message = 'Unsupported argument - An argument named "foo" is not expected here.',
          row = 3,
          col = 2,
          end_row = 3,
          end_col = 5,
          source = 'terragrunt validate',
          severity = stub.severities.error,
          filename = '/repo/a/child/terragrunt.hcl',
        },
      }, result)
    end)

    it('puts a diagnostic without a range at the top of the buffer', function()
      local result = opts.on_output({
        bufname = '/repo/a/terragrunt.hcl',
        cwd = '/repo/a',
        output = { { summary = 'Deprecated', severity = 'warning' } },
      })
      assert.are.same({
        {
          message = 'Deprecated',
          row = 0,
          col = 0,
          source = 'terragrunt validate',
          severity = stub.severities.warning,
          filename = '/repo/a/terragrunt.hcl',
        },
      }, result)
    end)

    it('decodes the JSON itself, and answers a clean run too', function()
      local answered
      local result = opts.on_output({
        bufname = '/repo/a/terragrunt.hcl',
        cwd = '/repo/a',
        output = '[]',
      }, function(diagnostics) answered = diagnostics end)
      assert.are.same({}, result)
      assert.are.same({}, answered)
      assert.are.same(
        { 'Deprecated' },
        vim.tbl_map(
          function(d) return d.message end,
          opts.on_output({
            bufname = '/repo/a/terragrunt.hcl',
            cwd = '/repo/a',
            output = '[{"summary":"Deprecated","severity":"warning"}]',
          })
        )
      )
    end)

    it(
      'reports output that is not a report, rather than a clean run',
      function()
        local result = opts.on_output({
          bufname = '/repo/a/terragrunt.hcl',
          cwd = '/repo/a',
          output = 'ERRO[0000] no such file\nmore',
        })
        assert.are.equal(1, #result)
        assert.are.equal('/repo/a/terragrunt.hcl', result[1].filename)
        assert.are.equal(
          'terragrunt hcl validate gave no JSON report: ERRO[0000] no such file',
          result[1].message
        )
        assert.are.same(
          {},
          opts.on_output({ bufname = '/repo/a/x', cwd = '/repo/a', output = '' })
        )
      end
    )

    it('keeps earlier diagnostics of other directories only', function()
      package.loaded['null-ls.diagnostics'] = {
        get_namespace = function(id) return 'ns' .. id end,
      }
      local asked
      local restore = h.stub(vim.diagnostic, 'get', function(bufnr, o)
        asked = { bufnr, o }
        return {
          {
            filename = '/repo/ab/terragrunt.hcl',
            message = 'kept',
            lnum = 2,
            col = 4,
            end_lnum = 2,
            end_col = 9,
          },
          {
            filename = '/repo/a/terragrunt.hcl',
            message = 'replaced',
            lnum = 0,
            col = 0,
          },
        }
      end)
      local ok, result = pcall(opts.on_output, {
        source_id = 7,
        bufname = '/repo/a/terragrunt.hcl',
        cwd = '/repo/a',
        output = {},
      })
      restore()
      assert.is_true(ok, result)
      assert.are.same({ nil, { namespace = 'ns7' } }, asked)
      -- Handed back 1-based, as none-ls reads them, so they stay in place
      assert.are.same({
        {
          filename = '/repo/ab/terragrunt.hcl',
          message = 'kept',
          row = 3,
          col = 5,
          end_row = 3,
          end_col = 10,
        },
      }, result)
    end)
  end)
end)
