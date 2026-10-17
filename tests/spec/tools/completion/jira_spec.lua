local h = require('helpers')
local stub = require('spec.tools.null_ls_stub')

describe('tools.completion.jira', function()
  local builtin, commands, options, replies, restore, restore_executable
  local installed

  before_each(function()
    stub.install('tools.completion.jira')
    builtin = require('tools.completion.jira')
    commands, options, replies = {}, {}, {}
    installed = true
    -- Answers by the first argument after `jira issue`, or by the JQL
    restore = h.stub(
      vim,
      'system',
      h.system_double(function(cmd, opts)
        table.insert(commands, cmd)
        table.insert(options, opts)
        return replies[cmd[#cmd]] or replies[cmd[3]] or { code = 1 }
      end)
    )
    local executable = vim.fn.executable
    restore_executable = h.stub(vim.fn, 'executable', function(name)
      if name == 'jira' then return installed and 1 or 0 end
      return executable(name)
    end)
  end)
  after_each(function()
    restore()
    restore_executable()
    stub.uninstall()
  end)

  ---@param word string
  ---@return table? response
  local function complete(word)
    local response
    builtin.generator.fn(
      { word_to_complete = word },
      function(r) response = r end
    )
    vim.wait(1000, function() return response ~= nil end)
    -- The read it started answers on the main loop
    vim.wait(50, function() return false end)
    return response
  end

  ---@param response table
  local function labels(response)
    local result = vim.tbl_map(
      function(i) return i.label end,
      response[1].items
    )
    table.sort(result)
    return result
  end

  it('completes in git commit messages, asynchronously', function()
    assert.are.equal('jira', builtin.name)
    assert.are.equal('NULL_LS_COMPLETION', builtin.method)
    assert.are.same({ 'gitcommit' }, builtin.filetypes)
    assert.is_true(builtin.generator.async)
  end)

  it('answers nothing for a word under two characters', function()
    local response = complete('A')
    assert.are.same({ { items = {}, isIncomplete = false } }, response)
    assert.are.same({}, commands)
  end)

  local function lists()
    return vim.tbl_filter(function(c) return c[3] == 'list' end, commands)
  end

  it('reads the recent issues once, in the background', function()
    replies.list = { code = 0, stdout = '' }
    complete('AB')
    complete('ABC')
    assert.are.equal(1, #lists())
    assert.are.same({
      'jira',
      'issue',
      'list',
      '--plain',
      '--columns',
      'KEY,SUMMARY,ASSIGNEE',
      '--paginate',
      '100',
    }, vim.list_slice(commands[1], 1, 8))
    assert.is_truthy(commands[1][#commands[1]]:find('updated', 1, true))
  end)

  it('completes keys and summaries from the issues kept', function()
    replies.list = {
      code = 0,
      stdout = 'AB-1\tFix login\tme\nAB-2\tAdd AB test\tyou\nCD-3\tOther\tx\n',
    }
    -- The first request starts the read and has nothing yet
    assert.are.same({}, labels(complete('ab')))
    local response = complete('ab')
    assert.are.same({ 'AB-1', 'AB-2', 'Add AB test' }, labels(response))
    assert.is_false(response[1].isIncomplete)
    for _, item in ipairs(response[1].items) do
      assert.are.equal(vim.lsp.protocol.CompletionItemKind.Reference, item.kind)
      assert.are.equal(item.detail, item.documentation.value)
    end
    -- Nothing is read per word, nor per issue
    assert.are.same({ 'Other' }, labels(complete('oth')))
    assert.are.equal(1, #commands)
  end)

  it('keeps at most a hundred issues and answers fifty items', function()
    local rows = {}
    for i = 1, 150 do
      table.insert(rows, ('AB-%d\tTask %d\tme'):format(i, i))
    end
    replies.list = { code = 0, stdout = table.concat(rows, '\n') }
    complete('AB')
    assert.are.equal(50, #complete('AB')[1].items)
    -- `AB-1` starts `AB-10` to `AB-19` and `AB-100`: every key the word starts
    -- is among the hundred kept
    local keys = vim.tbl_filter(
      function(label) return label:match('^AB%-1') ~= nil end,
      labels(complete('AB-1'))
    )
    assert.are.equal(12, #keys)
  end)

  it('drops rows missing a column', function()
    replies.list = { code = 0, stdout = 'AB-1\n\nAB-2\tTwo\tx\n' }
    complete('AB')
    assert.are.same({ 'AB-2' }, labels(complete('AB')))
  end)

  it('gives a jira that hangs a few seconds, not forever', function()
    complete('AB')
    assert.is_true(#options > 0)
    for _, opts in ipairs(options) do
      assert.is_true(opts.timeout > 0 and opts.timeout <= 10000)
    end
  end)

  it('stops reading for a while once a read hung', function()
    replies.list = { code = 124, signal = 15 }
    complete('AB')
    local response = complete('ABC')
    assert.are.same({ { items = {}, isIncomplete = false } }, response)
    assert.are.equal(1, #commands)
  end)

  it('reads again after a read that merely failed', function()
    complete('AB')
    complete('ABC')
    assert.are.equal(2, #lists())
  end)

  it('asks nothing when jira-cli is not installed', function()
    installed = false
    local response = complete('AB')
    assert.are.same({ { items = {}, isIncomplete = false } }, response)
    assert.are.same({}, commands)
  end)
end)
