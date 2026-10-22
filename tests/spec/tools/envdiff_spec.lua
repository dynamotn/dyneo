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
        'printf \'%s\\n\' "$*" >> "' .. dir .. '/calls"',
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

  it('orders the names that share as much with its own by name', function()
    h.write(dir .. '/flat/dev.yaml', {})
    h.write(dir .. '/flat/b.yaml', {})
    h.write(dir .. '/flat/a.yaml', {})
    assert.same(
      { dir .. '/flat/a.yaml', dir .. '/flat/b.yaml' },
      envdiff.candidates(dir .. '/flat/dev.yaml')
    )
  end)

  it('warns when the buffer is no file on disk', function()
    local done = false
    envdiff.compare(
      dir .. '/chart/values-prod.yaml',
      function() done = true end
    )
    assert.is_true(done)
    assert.equals('The buffer is no file on disk', notes[#notes])
  end)

  it('fails when the other file does not exist', function()
    vim.cmd.edit(vim.fn.fnameescape(dir .. '/chart/values-dev.yaml'))
    envdiff.compare(dir .. '/chart/values-qa.yaml')
    assert.equals(
      'No such file: ' .. dir .. '/chart/values-qa.yaml',
      notes[#notes]
    )
    assert.equals(1, #vim.api.nvim_tabpage_list_wins(0))
  end)

  it(
    'heads what differs with a note on unsaved edits, and says it was cut',
    function()
      dyff({ "printf 'replicas\\n  ± value change\\n%04000d\\n' 0" })
      envdiff.MAX_OUTPUT = 1024
      vim.cmd.edit(vim.fn.fnameescape(dir .. '/chart/values-dev.yaml'))
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'replicas: 9' })
      local done = false
      envdiff.compare(
        dir .. '/chart/values-prod.yaml',
        function() done = true end
      )
      assert.is_true(vim.wait(5000, function() return done end, 10))
      local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
      assert.equals('As on disk: unsaved changes are not compared.', lines[3])
      assert.equals('replicas', lines[5])
      assert.equals('… cut at 1 KiB', lines[#lines])
    end
  )

  it('compares with the file the command is given', function()
    vim.cmd.edit(vim.fn.fnameescape(dir .. '/chart/values-dev.yaml'))
    envdiff.command({ fargs = { dir .. '/chart/values-prod.yaml' } })
    assert.is_true(vim.wo.diff)
    assert.equals(
      dir .. '/chart/values-prod.yaml',
      vim.api.nvim_buf_get_name(0)
    )
  end)

  it('warns when the command runs in a buffer with no file', function()
    local restore = h.stub(vim.ui, 'select', function() error('asked') end)
    envdiff.command({ fargs = {} })
    restore()
    assert.equals('The buffer is no file on disk', notes[#notes])
  end)

  it('asks for a file to give when none of its kind is beside it', function()
    h.write(dir .. '/alone/only.yaml', {})
    vim.cmd.edit(vim.fn.fnameescape(dir .. '/alone/only.yaml'))
    local restore = h.stub(vim.ui, 'select', function() error('asked') end)
    envdiff.command({ fargs = {} })
    restore()
    assert.equals(
      'No other file of this kind beside it: give one',
      notes[#notes]
    )
  end)

  it(
    'offers the files beside it by name, and compares the one picked',
    function()
      vim.cmd.edit(vim.fn.fnameescape(dir .. '/chart/values-dev.yaml'))
      local offered, shown
      local restore = h.stub(vim.ui, 'select', function(items, opts, on_choice)
        offered = items
        shown = vim.tbl_map(opts.format_item, items)
        on_choice(items[1])
      end)
      envdiff.command({ fargs = {} })
      restore()
      assert.same({ 'values-prod.yaml', 'Chart.yaml' }, shown)
      assert.equals(2, #offered)
      assert.is_true(vim.wo.diff)
      assert.equals(
        dir .. '/chart/values-prod.yaml',
        vim.api.nvim_buf_get_name(0)
      )
    end
  )

  it('does nothing when no file is picked', function()
    vim.cmd.edit(vim.fn.fnameescape(dir .. '/chart/values-dev.yaml'))
    local restore = h.stub(
      vim.ui,
      'select',
      function(_, _, on_choice) on_choice(nil) end
    )
    envdiff.command({ fargs = {} })
    restore()
    assert.equals(1, #vim.api.nvim_tabpage_list_wins(0))
    assert.same({}, notes)
  end)
end)
