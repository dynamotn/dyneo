local h = require('helpers')

describe('tools.envdiff', function()
  local envdiff, dir, cleanup, path, notes, restore_notify

  before_each(function()
    h.unload('tools.envdiff')
    envdiff = require('tools.envdiff')
    dir, cleanup = h.tmpdir()
    vim.fn.mkdir(dir .. '/bin', 'p')
    path = vim.env.PATH
    vim.env.PATH = dir .. '/bin:/usr/bin:/bin'
    notes = {}
    restore_notify = h.stub(
      vim,
      'notify',
      function(msg) table.insert(notes, msg) end
    )
    h.write(dir .. '/chart/values-dev.yaml', { 'replicas: 1' })
    h.write(dir .. '/chart/values-prod.yaml', { 'replicas: 3' })
    h.write(dir .. '/chart/Chart.yaml', { 'name: app' })
    h.write(dir .. '/chart/notes.txt', {})
  end)
  after_each(function()
    vim.env.PATH = path
    restore_notify()
    vim.cmd('silent! tabonly!')
    vim.cmd('silent! only!')
    vim.cmd('silent! %bwipeout!')
    cleanup()
  end)

  local function dyff(lines)
    h.write(
      dir .. '/bin/dyff',
      vim.list_extend({
        '#!/bin/sh',
        'echo "$*" >> "' .. dir .. '/calls"',
      }, lines)
    )
    vim.fn.setfperm(dir .. '/bin/dyff', 'rwxr-xr-x')
  end

  it(
    'offers the files of its kind beside it, the closest names first',
    function()
      assert.same({
        dir .. '/chart/values-prod.yaml',
        dir .. '/chart/Chart.yaml',
      }, envdiff.candidates(dir .. '/chart/values-dev.yaml'))
    end
  )

  it('tells the documents dyff reads', function()
    assert.is_true(envdiff.structured('/a/values.YAML'))
    assert.is_true(envdiff.structured('/a/x.json'))
    assert.is_false(envdiff.structured('/a/prod.tfvars'))
    assert.is_false(envdiff.structured('/a/.env'))
  end)

  it('shows what dyff finds, held back from AI', function()
    dyff({
      "echo 'replicas'",
      "echo '  ± value change'",
      "echo '    - 1'",
      "echo '    + 3'",
    })
    vim.cmd.edit(vim.fn.fnameescape(dir .. '/chart/values-dev.yaml'))
    local done = false
    envdiff.compare(
      dir .. '/chart/values-prod.yaml',
      function() done = true end
    )
    assert.is_true(vim.wait(5000, function() return done end, 10))
    assert.same({
      'between --omit-header --color=off '
        .. dir
        .. '/chart/values-dev.yaml '
        .. dir
        .. '/chart/values-prod.yaml',
    }, vim.fn.readfile(dir .. '/calls'))
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    assert.is_truthy(lines[1]:find('values-dev.yaml → ', 1, true))
    assert.is_truthy(vim.tbl_contains(lines, '    + 3'))
    assert.is_truthy(require('util.sensitive').marked(0))
  end)

  it(
    'says when nothing differs, and that unsaved edits are left out',
    function()
      dyff({})
      vim.cmd.edit(vim.fn.fnameescape(dir .. '/chart/values-dev.yaml'))
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'replicas: 9' })
      local done = false
      envdiff.compare(
        dir .. '/chart/values-prod.yaml',
        function() done = true end
      )
      assert.is_true(vim.wait(5000, function() return done end, 10))
      assert.equals(
        'No differences on disk; unsaved changes are not compared',
        notes[#notes]
      )
    end
  )

  it('opens a diff split for what dyff cannot read', function()
    dyff({})
    h.write(dir .. '/dev.tfvars', { 'size = 1' })
    h.write(dir .. '/prod.tfvars', { 'size = 2' })
    vim.cmd.edit(vim.fn.fnameescape(dir .. '/dev.tfvars'))
    envdiff.compare(dir .. '/prod.tfvars')
    assert.equals(2, #vim.api.nvim_tabpage_list_wins(0))
    assert.is_true(vim.wo.diff)
    assert.equals(0, vim.fn.filereadable(dir .. '/calls'))
  end)

  it('falls back to a diff split without dyff', function()
    vim.cmd.edit(vim.fn.fnameescape(dir .. '/chart/values-dev.yaml'))
    envdiff.compare(dir .. '/chart/values-prod.yaml')
    assert.is_true(vim.wo.diff)
    assert.equals('dyff is not installed: a line diff instead', notes[#notes])
  end)

  it('fails loudly when dyff does', function()
    dyff({ 'echo "failed to load input files" >&2', 'exit 1' })
    vim.cmd.edit(vim.fn.fnameescape(dir .. '/chart/values-dev.yaml'))
    local done = false
    envdiff.compare(
      dir .. '/chart/values-prod.yaml',
      function() done = true end
    )
    assert.is_true(vim.wait(5000, function() return done end, 10))
    assert.equals('failed to load input files', notes[#notes])
  end)
end)
