local h = require('helpers')

describe('tools.adr', function()
  local adr, dir, cleanup

  before_each(function()
    h.unload('tools.adr')
    adr = require('tools.adr')
    dir, cleanup = h.tmpdir()
  end)
  after_each(function()
    vim.cmd('silent! %bwipeout!')
    cleanup()
  end)

  it('names a file after its title', function()
    assert.equals('use-postgres-for-jobs', adr.slug('Use Postgres for jobs!'))
    assert.equals('decision', adr.slug('???'))
  end)

  it('reads its number, title and status', function()
    local record = adr.parse(
      adr.template(3, 'Use Postgres', '2026-10-09', 'Accepted'),
      '/x/0003-use-postgres.md'
    )
    assert.same({
      number = 3,
      title = 'Use Postgres',
      status = 'Accepted',
      file = '/x/0003-use-postgres.md',
    }, record)
    assert.is_nil(adr.parse({}, '/x/notes.md'))
  end)

  it('replaces the status section, and adds one when missing', function()
    local lines = adr.set_status(
      adr.template(1, 'A', 'd'),
      { 'Superseded', '', 'Superseded by [2. B](0002-b.md)' }
    )
    local text = table.concat(lines, '\n')
    assert.is_truthy(
      text:find(
        '## Status\n\nSuperseded\n\nSuperseded by %[2%. B%]%(0002%-b%.md%)\n\n## Context'
      )
    )
    assert.is_falsy(text:find('Proposed', 1, true))
    assert.same(
      { '# 1. A', '', '## Status', '', 'Accepted' },
      adr.set_status({ '# 1. A' }, 'Accepted')
    )
  end)

  it('finds the directory of the records', function()
    assert.equals(dir .. '/docs/adr', adr.dir(dir))
    vim.fn.mkdir(dir .. '/docs/decisions', 'p')
    assert.equals(dir .. '/docs/decisions', adr.dir(dir))
    h.write(dir .. '/.adr-dir', { 'architecture/decisions' })
    assert.equals(dir .. '/architecture/decisions', adr.dir(dir))
    h.write(dir .. '/.adr-dir', { './adr/../decisions/' })
    assert.equals(dir .. '/decisions', adr.dir(dir))
  end)

  it('refuses a directory outside the project', function()
    local outside = '../' .. vim.fs.basename(dir) .. '-other'
    h.write(dir .. '/.adr-dir', { outside })
    local found, err = adr.dir(dir)
    assert.is_nil(found)
    assert.equals('`.adr-dir` points outside the project: ' .. outside, err)
    local elsewhere, clean = h.tmpdir()
    vim.uv.fs_symlink(elsewhere, dir .. '/link')
    h.write(dir .. '/.adr-dir', { 'link/adr' })
    assert.is_nil(adr.dir(dir))
    clean()
  end)

  it(
    'numbers new records after the last one, and lists them in order',
    function()
      local records = dir .. '/docs/adr'
      local first = adr.create(records, 'Record decisions')
      local second = adr.create(records, 'Use Postgres')
      h.write(records .. '/README.md', { 'not a record' })
      assert.equals(records .. '/0001-record-decisions.md', first.file)
      assert.equals(2, second.number)
      assert.same(
        {
          { 1, 'Record decisions', 'Proposed' },
          { 2, 'Use Postgres', 'Proposed' },
        },
        vim.tbl_map(
          function(r) return { r.number, r.title, r.status } end,
          adr.list(records)
        )
      )
    end
  )

  describe('commands', function()
    local notes, restore

    before_each(function()
      vim.system({ 'git', 'init', '-q' }, { cwd = dir }):wait()
      notes = {}
      restore = h.stub(
        vim,
        'notify',
        function(msg) table.insert(notes, msg) end
      )
      vim.cmd.edit(dir .. '/README.md')
    end)
    after_each(function() restore() end)

    it('writes a new record and opens it', function()
      adr.command({ fargs = { 'new', 'Use', 'Postgres' } })
      assert.equals(
        dir .. '/docs/adr/0001-use-postgres.md',
        vim.api.nvim_buf_get_name(0)
      )
      assert.equals(
        '# 1. Use Postgres',
        vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]
      )
      assert.equals('Recorded 1. Use Postgres', notes[1])
    end)

    it('writes nothing outside the project', function()
      local outside = vim.fs.dirname(dir) .. '/' .. vim.fs.basename(dir) .. '-x'
      h.write(dir .. '/.adr-dir', { '../' .. vim.fs.basename(outside) })
      adr.command({ fargs = { 'new', 'Escape' } })
      adr.command({ fargs = { 'list' } })
      assert.equals(0, vim.fn.isdirectory(outside))
      assert.equals(dir .. '/README.md', vim.api.nvim_buf_get_name(0))
      assert.equals(2, #notes)
      assert.is_truthy(notes[1]:find('outside the project', 1, true))
    end)

    it('asks for the title when it is not given', function()
      local restore_input = h.stub(
        vim.ui,
        'input',
        function(_, on_confirm) on_confirm('  Asked  ') end
      )
      adr.new()
      restore_input()
      assert.equals(
        dir .. '/docs/adr/0001-asked.md',
        vim.api.nvim_buf_get_name(0)
      )
    end)

    it('sets the status of the record open', function()
      adr.new('A')
      adr.command({ fargs = { 'status', 'accepted' } })
      assert.equals(
        'Accepted',
        adr.parse(
          vim.api.nvim_buf_get_lines(0, 0, -1, false),
          vim.api.nvim_buf_get_name(0)
        ).status
      )
      adr.status('bogus')
      assert.equals('Unknown status: bogus', notes[#notes])
    end)

    it('supersedes the record open, linking both ways', function()
      adr.new('Use MySQL')
      local old = vim.api.nvim_buf_get_name(0)
      adr.supersede('Use Postgres')
      local new = vim.api.nvim_buf_get_name(0)
      assert.equals(dir .. '/docs/adr/0002-use-postgres.md', new)
      local new_text = table.concat(vim.fn.readfile(new), '\n')
      local old_text = table.concat(vim.fn.readfile(old), '\n')
      assert.is_truthy(
        new_text:find(
          'Accepted\n\nSupersedes [1. Use MySQL](0001-use-mysql.md)',
          1,
          true
        )
      )
      assert.is_truthy(
        old_text:find(
          'Superseded\n\nSuperseded by [2. Use Postgres](0002-use-postgres.md)',
          1,
          true
        )
      )
    end)

    it('refuses what is no record', function()
      adr.status('accepted')
      adr.supersede('x')
      assert.same({
        'This buffer is no decision record',
        'This buffer is no decision record',
      }, notes)
    end)

    it('picks among the records', function()
      adr.pick()
      assert.equals(
        'No decision recorded yet: `:DyAdr new` starts one',
        notes[1]
      )
      adr.new('A')
      adr.new('B')
      local shown
      local restore_select = h.stub(
        vim.ui,
        'select',
        function(items, opts, on_choice)
          shown = vim.tbl_map(opts.format_item, items)
          on_choice(items[1])
        end
      )
      adr.command({ fargs = { 'list' } })
      restore_select()
      assert.same({ '0001  Proposed    A', '0002  Proposed    B' }, shown)
      assert.equals(dir .. '/docs/adr/0001-a.md', vim.api.nvim_buf_get_name(0))
    end)
  end)
end)
