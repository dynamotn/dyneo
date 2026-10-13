local h = require('helpers')
local stub = require('spec.tools.null_ls_stub')

describe('tools.code_actions.ltcc', function()
  local builtin
  before_each(function()
    stub.install('tools.code_actions.ltcc')
    builtin = require('tools.code_actions.ltcc')
  end)
  after_each(stub.uninstall)

  it('is a code action source running ltcc', function()
    assert.are.equal('ltcc', builtin.name)
    assert.are.equal('NULL_LS_CODE_ACTION', builtin.method)
    assert.are.equal('ltcc', builtin.generator_opts.command)
    assert.are.same(
      { 'check', '-l', 'en-US', '-f', '$FILENAME' },
      builtin.generator_opts.args
    )
  end)

  it('accepts exit codes 0 and 1 only', function()
    local check = builtin.generator_opts.check_exit_code
    assert.is_true(check(0))
    assert.is_true(check(1))
    assert.is_false(check(2))
  end)

  describe('on_output', function()
    local on_output
    before_each(function() on_output = builtin.generator_opts.on_output end)

    ---@param line integer
    ---@param offset integer
    ---@param length integer
    ---@param values string[]|userdata
    local function match(line, offset, length, values)
      return {
        moreContext = { line_number = line, line_offset = offset },
        length = length,
        replacements = values == vim.NIL and vim.NIL
          or vim.tbl_map(function(v) return { value = v } end, values),
      }
    end

    it('offers one action per replacement on the asked row', function()
      local actions = on_output({
        row = 2,
        bufnr = 0,
        output = { match(2, 0, 3, { 'the', 'a' }), match(3, 0, 3, { 'x' }) },
      })
      assert.are.same(
        { 'Replace with “the”', 'Replace with “a”' },
        vim.tbl_map(function(a) return a.title end, actions)
      )
    end)

    it('skips a match without replacements', function()
      local actions =
        on_output({ row = 1, bufnr = 0, output = { match(1, 0, 3, vim.NIL) } })
      assert.are.same({}, actions)
    end)

    it('skips a match that leaves its replacements out', function()
      local without = match(1, 0, 3, {})
      without.replacements = nil
      local actions = on_output({ row = 1, bufnr = 0, output = { without } })
      assert.are.same({}, actions)
    end)

    it('skips the placeholder for replacements not shown', function()
      local actions = on_output({
        row = 1,
        bufnr = 0,
        output = { match(1, 0, 3, { '(10 more not shown)', 'fix' }) },
      })
      assert.are.equal(1, #actions)
      assert.are.equal('Replace with “fix”', actions[1].title)
    end)

    it('replaces the matched span when run', function()
      local bufnr = h.buffer({ lines = { 'first', '-- teh word' } })
      local actions = on_output({
        row = 2,
        bufnr = bufnr,
        output = { match(2, 3, 3, { 'the' }) },
      })
      actions[1].action()
      assert.are.same(
        { 'first', '-- the word' },
        vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      )
    end)
  end)
end)
