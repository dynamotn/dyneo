local h = require('helpers')

local SHA = ('a'):rep(40)

describe('tools.actions', function()
  local actions, dir, cleanup, path, notes, restore_notify

  before_each(function()
    h.unload('tools.actions', 'util.forge')
    actions = require('tools.actions')
    dir, cleanup = h.tmpdir()
    vim.fn.mkdir(dir .. '/bin', 'p')
    path = vim.env.PATH
    vim.env.PATH = dir .. '/bin:' .. path
    notes = {}
    restore_notify = h.stub(
      vim,
      'notify',
      function(msg) table.insert(notes, msg) end
    )
  end)
  after_each(function()
    vim.env.PATH = path
    restore_notify()
    vim.cmd('silent! %bwipeout!')
    cleanup()
  end)

  it('reads the action and ref of a uses line', function()
    assert.same({
      head = '      - uses: ',
      repo = 'actions/checkout',
      path = '',
      ref = 'v4',
    }, actions.parse('      - uses: actions/checkout@v4'))
    assert.same({
      head = '    uses: ',
      repo = 'github/codeql-action',
      path = '/init',
      ref = 'v3',
      comment = 'keep',
    }, actions.parse('    uses: "github/codeql-action/init@v3" # keep'))
    assert.is_nil(actions.parse('      - uses: ./.github/actions/local'))
    assert.is_nil(actions.parse('      - uses: docker://alpine:3'))
    assert.is_nil(actions.parse('      - run: echo uses: x/y@v1'))
  end)

  it('tells a full commit from a tag, and pins to it', function()
    assert.is_true(actions.pinned(SHA))
    assert.is_false(actions.pinned('v4'))
    assert.is_false(actions.pinned('abc123'))
    -- The author's comment stays, after the ref
    assert.equals(
      '  - uses: actions/checkout@' .. SHA .. ' # v4 keep in sync',
      actions.pin_line(
        actions.parse('  - uses: actions/checkout@v4 # keep in sync'),
        SHA
      )
    )
    assert.equals(
      '  - uses: actions/checkout@' .. SHA .. ' # v4',
      actions.pin_line(actions.parse('  - uses: actions/checkout@v4 # v4'), SHA)
    )
    assert.equals(
      '  - uses: actions/checkout@' .. SHA .. ' # v4',
      actions.pin_line(actions.parse('  - uses: actions/checkout@v4'), SHA)
    )
  end)

  local function gh(lines)
    h.write(
      dir .. '/bin/gh',
      vim.list_extend(
        { '#!/bin/sh', 'echo "$@" >> "' .. dir .. '/calls"' },
        lines
      )
    )
    vim.fn.setfperm(dir .. '/bin/gh', 'rwxr-xr-x')
  end

  local WORKFLOW = {
    'jobs:',
    '  build:',
    '    steps:',
    '      - uses: actions/checkout@v4',
    '      - uses: actions/setup-go@v5',
    '      - uses: actions/checkout@v4',
    '      - uses: ./local',
    '      - uses: actions/cache@' .. ('b'):rep(40) .. ' # v4',
  }

  it('pins every action, asking once per ref', function()
    gh({
      'case "$*" in',
      [[  *actions/checkout/commits/v4) echo '{"sha":"]] .. SHA .. [["}';;]],
      '  *) echo "HTTP 404: No commit found" >&2; exit 1;;',
      'esac',
    })
    local bufnr = h.buffer({ lines = WORKFLOW })
    actions.pin(bufnr)
    assert.is_true(vim.wait(5000, function() return #notes > 0 end, 10))
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.equals('      - uses: actions/checkout@' .. SHA .. ' # v4', lines[4])
    assert.equals('      - uses: actions/setup-go@v5', lines[5])
    assert.equals('      - uses: actions/checkout@' .. SHA .. ' # v4', lines[6])
    assert.equals(WORKFLOW[8], lines[8])
    assert.is_truthy(
      notes[1]:find(
        '^2 uses pinned; not found:\nactions/setup%-go@v5: HTTP 404'
      )
    )
    local calls = vim.fn.readfile(dir .. '/calls')
    assert.equals(2, #calls)
    assert.is_truthy(
      vim.tbl_contains(
        calls,
        'api --hostname github.com repos/actions/checkout/commits/v4'
      )
    )
  end)

  it('looks up no more than a few refs at once', function()
    gh({
      'touch "' .. dir .. '/running.$$"',
      'ls "' .. dir .. '" | grep -c "^running" >> "' .. dir .. '/counts"',
      'sleep 0.2',
      'rm "' .. dir .. '/running.$$"',
      [[echo '{"sha":"]] .. SHA .. [["}']],
    })
    local lines = { 'jobs:', '  build:', '    steps:' }
    for index = 1, 8 do
      table.insert(lines, ('      - uses: o/action%d@v1'):format(index))
    end
    actions.pin(h.buffer({ lines = lines }))
    assert.is_true(vim.wait(10000, function() return #notes > 0 end, 10))
    assert.equals('8 uses pinned', notes[1])
    local most = 0
    for _, count in ipairs(vim.fn.readfile(dir .. '/counts')) do
      most = math.max(most, tonumber(count))
    end
    assert.is_true(most <= actions.PARALLEL, ('%d at once'):format(most))
  end)

  it('pins nothing when the workflow changed meanwhile', function()
    gh({ 'sleep 0.3', [[echo '{"sha":"]] .. SHA .. [["}']] })
    local bufnr = h.buffer({ lines = WORKFLOW })
    actions.pin(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { '# edited' })
    assert.is_true(vim.wait(5000, function() return #notes > 0 end, 10))
    assert.equals('The workflow changed meanwhile: nothing pinned', notes[1])
    assert.equals(
      '      - uses: actions/checkout@v4',
      vim.api.nvim_buf_get_lines(bufnr, 4, 5, false)[1]
    )
  end)

  it('pins nothing without gh, from the mapping of a workflow', function()
    vim.env.PATH = dir .. '/bin'
    local bufnr = h.buffer({ lines = { '      - uses: actions/checkout@v4' } })
    vim.api.nvim_set_current_buf(bufnr)
    actions.pin()
    assert.same({ 'gh is not installed' }, notes)

    actions.attach(bufnr)
    local pin
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr, 'n')) do
      if map.desc == 'Pin Actions To Commits (CI)' then pin = map.callback end
    end
    pin()
    assert.same({ 'gh is not installed', 'gh is not installed' }, notes)
    assert.equals(
      '      - uses: actions/checkout@v4',
      vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
    )
  end)

  it('says when there is nothing to pin', function()
    actions.pin(h.buffer({ lines = { 'jobs: {}' } }))
    assert.same({ 'Every action is pinned already' }, notes)
  end)

  it('lints workflows with zizmor, offline, and nothing else', function()
    h.globals()
    local zizmor
    for _, tool in ipairs(require('config.languages').yaml.linters) do
      if type(tool) == 'table' and tool[1] == 'zizmor' then zizmor = tool end
    end
    assert.same({ '--offline' }, zizmor.opts.prepend_args)
    vim.api.nvim_set_current_buf(h.buffer({ filetype = 'yaml.gh-action' }))
    assert.is_true(zizmor.opts.condition())
    vim.api.nvim_set_current_buf(h.buffer({ filetype = 'yaml' }))
    assert.is_false(zizmor.opts.condition())
  end)
end)
