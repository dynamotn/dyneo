local h = require('helpers')

describe('tools.data', function()
  local data, dir, cleanup, path, cwd, notes, restore_notify, restore_confirm
  local asked

  before_each(function()
    h.unload('tools.data')
    data = require('tools.data')
    -- The command and the `BufReadCmd`, as Neovim sources them at startup
    dofile(h.root .. '/plugin/data.lua')
    cwd = vim.fn.getcwd()
    dir, cleanup = h.tmpdir()
    vim.fn.mkdir(dir .. '/bin', 'p')
    path = vim.env.PATH
    -- Only the fakes of this spec, whatever the machine has
    vim.env.PATH = dir .. '/bin:/usr/bin:/bin'
    notes = {}
    restore_notify = h.stub(
      vim,
      'notify',
      function(msg) table.insert(notes, msg) end
    )
    -- Running the SQL of a buffer is agreed to unless a spec says otherwise
    asked = 0
    restore_confirm = h.stub(vim.fn, 'confirm', function()
      asked = asked + 1
      return 1
    end)
  end)
  after_each(function()
    vim.cmd.cd(cwd)
    vim.env.PATH = path
    restore_notify()
    restore_confirm()
    vim.cmd('silent! %bwipeout!')
    cleanup()
  end)

  --- A `duckdb` that keeps its arguments and its script, and prints `lines`;
  --- `read` appears once the whole script is in
  local function duckdb(lines)
    h.write(
      dir .. '/bin/duckdb',
      vim.list_extend({
        '#!/bin/sh',
        'echo "$@" > "' .. dir .. '/args"',
        'cat > "' .. dir .. '/script"',
        ': > "' .. dir .. '/read"',
      }, lines or { 'echo ok' })
    )
    vim.fn.setfperm(dir .. '/bin/duckdb', 'rwxr-xr-x')
  end

  local function lines(bufnr)
    return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  end

  it('knows the reader of each format, compressed or not', function()
    assert.equal('read_parquet', data.reader('/d/x.parquet'))
    assert.equal('read_csv', data.reader('/d/X.CSV'))
    assert.equal('read_csv', data.reader('/d/x.tsv.gz'))
    assert.equal('read_json', data.reader('/d/x.ndjson.zst'))
    assert.is_nil(data.reader('/d/x.xlsx'))
    assert.is_nil(data.reader('/d/Makefile'))
  end)

  it(
    'quotes a path holding a quote',
    function()
      assert.equal("read_csv('/d/it''s.csv')", data.source("/d/it's.csv"))
    end
  )

  it('sums up a file without downloading an extension', function()
    local script = data.summary_script('/d/x.parquet')
    assert.same({
      'SET autoinstall_known_extensions = false;',
      'SET autoload_known_extensions = false;',
      'SET allow_community_extensions = false;',
      -- Nothing outside the file's own directory, nor the environment
      "SET allowed_directories = ['/d/'];",
      'SET enable_external_access = false;',
      'SET lock_configuration = true;',
      -- No colour escapes in the buffer
      '.highlight off',
      -- `box` prints every row whatever `.maxrows` says
      '.mode duckbox',
    }, vim.list_slice(script, 1, 8))
    local text = table.concat(script, '\n')
    -- The count reads a CSV whole: what is quick comes first
    assert.is_true(text:find('DESCRIBE') < text:find('count%(%*%)'))
    assert.is_true(text:find('LIMIT 50') < text:find('count%(%*%)'))
    assert.matches(
      "allowed_directories = %['/d/data/'%]",
      table.concat(data.summary_script('/d/data/*.csv'), '\n')
    )
    assert.matches(
      "count%(%*%) AS rows FROM read_parquet%('/d/x.parquet'%)",
      text
    )
    assert.matches('DESCRIBE SELECT', text)
    assert.matches('LIMIT 50;', text)
    assert.not_matches('SUMMARIZE', text)
    assert.matches(
      'SUMMARIZE SELECT',
      table.concat(data.summary_script('/d/x.parquet', true), '\n')
    )
  end)

  it('says when the output was cut or the run failed', function()
    assert.same(
      { 'a', '[cut at 1024 KiB]' },
      data.output({ stdout = 'a\n', stderr = '', code = 0, cut = true })
    )
    assert.same(
      { 'Error: boom' },
      data.output({ stdout = '', stderr = 'Error: boom\n', code = 1 })
    )
    assert.same(
      { 'duckdb exited 3' },
      data.output({ stdout = '', stderr = '', code = 3 })
    )
    assert.same(
      { 'duckdb gave no answer in time' },
      data.output({ stdout = '', stderr = '', code = 124, timed_out = true })
    )
  end)

  it('shows the summary of a file in a tab kept from AI', function()
    duckdb({ 'echo summary' })
    h.write(dir .. '/x.csv', { 'a,b', '1,2' })
    data.summary(dir .. '/x.csv')
    local bufnr = vim.api.nvim_get_current_buf()
    assert.is_true(
      vim.wait(5000, function() return lines(bufnr)[1] == 'summary' end, 20)
    )
    assert.equal(data.SENSITIVE, require('util.sensitive').marked(bufnr))
    assert.matches('%-bail', vim.fn.readfile(dir .. '/args')[1])
    assert.matches(
      "read_csv%('" .. vim.pesc(dir) .. "/x.csv'%)",
      table.concat(vim.fn.readfile(dir .. '/script'), '\n')
    )
  end)

  it('refuses a file DuckDB does not read, or one that is not there', function()
    duckdb()
    data.summary(dir .. '/x.xlsx')
    data.summary(dir .. '/missing.csv')
    assert.equal(2, #notes)
    assert.is_nil(vim.uv.fs_stat(dir .. '/args'))
  end)

  it('opens a Parquet file as a summary that cannot be written', function()
    duckdb({ 'echo parquet summary' })
    h.write(dir .. '/x.parquet', { 'PAR1' })
    vim.cmd.edit(dir .. '/x.parquet')
    local bufnr = vim.api.nvim_get_current_buf()
    assert.is_true(
      vim.wait(
        5000,
        function() return lines(bufnr)[1] == 'parquet summary' end,
        20
      )
    )
    assert.equal('nofile', vim.bo[bufnr].buftype)
    assert.is_false(vim.bo[bufnr].modifiable)
    assert.is_false(vim.bo[bufnr].modified)
    assert.equal(data.SENSITIVE, require('util.sensitive').marked(bufnr))
    assert.is_false(pcall(vim.cmd.write))
    assert.same({ 'PAR1' }, vim.fn.readfile(dir .. '/x.parquet'))
  end)

  it('runs the selected SQL from the working directory', function()
    duckdb({ 'pwd' })
    vim.cmd.cd(dir)
    local source = h.buffer({
      lines = { 'SELECT 1;', 'SELECT 2;', 'SELECT 3;' },
      filetype = 'sql',
    })
    vim.api.nvim_set_current_buf(source)
    vim.cmd('2,3DyData sql')
    assert.equal(source, vim.api.nvim_get_current_buf())
    local result = data.result_buf
    assert.is_true(
      vim.wait(5000, function() return lines(result)[1] == dir end, 20)
    )
    local script = vim.fn.readfile(dir .. '/script')
    assert.same(
      { 'SELECT 2;', 'SELECT 3;' },
      vim.list_slice(script, #script - 1)
    )
    -- Stopped at the first error, so the error is the last line printed
    assert.matches('%-bail', vim.fn.readfile(dir .. '/args')[1])
    assert.equal(data.SENSITIVE, require('util.sensitive').marked(result))
  end)

  it('keeps only the last of two runs into one window', function()
    duckdb({ 'sleep 0.3', 'tail -n1 "' .. dir .. '/script"' })
    local source = h.buffer({ lines = { 'SELECT 1;' } })
    vim.api.nvim_set_current_buf(source)
    data.sql('SELECT 1;')
    data.sql('SELECT 2;')
    local result = data.result_buf
    assert.is_true(
      vim.wait(5000, function() return data.jobs[result] == nil end, 20)
    )
    vim.wait(400)
    assert.same({ 'SELECT 2;' }, lines(result))
  end)

  it('says how to install duckdb when it is missing', function()
    data.sql('SELECT 1;')
    assert.is_true(vim.wait(5000, function() return #notes > 0 end, 20))
    assert.matches('MasonInstall duckdb', notes[1])
  end)

  it('completes subcommands, then files', function()
    assert.same(
      { 'stats', 'sql' },
      vim.list_slice(data.complete('s', 'DyData s'), 1, 2)
    )
    assert.same({}, data.complete('', 'DyData sql '))
  end)

  it('refuses SQL holding a dot command that reaches past SQL', function()
    duckdb()
    local source = h.buffer({
      lines = {
        '.mode csv',
        'SELECT 1;',
        '  .shell touch pwned',
        '.read x.sql',
      },
    })
    vim.api.nvim_set_current_buf(source)
    vim.cmd('DyData sql')
    assert.equal(1, #notes)
    assert.matches('`%.shell` on line 3', notes[1])
    assert.is_nil(vim.uv.fs_stat(dir .. '/args'))
    assert.equal('.read', (data.forbidden({ '.read x.sql' })))
    assert.is_nil(data.forbidden({ '.mode csv', '.maxrows 5', 'SELECT 1;' }))
  end)

  it('stops a run when its window is closed', function()
    duckdb({ 'sleep 1', 'touch "' .. dir .. '/finished"' })
    h.write(dir .. '/x.csv', { 'a', '1' })
    data.summary(dir .. '/x.csv')
    local bufnr = vim.api.nvim_get_current_buf()
    assert.is_true(
      vim.wait(
        5000,
        function() return vim.uv.fs_stat(dir .. '/args') ~= nil end,
        20
      )
    )
    assert.is_not_nil(data.jobs[bufnr])
    vim.cmd.bwipeout({ bufnr, bang = true })
    assert.is_nil(data.jobs[bufnr])
    vim.wait(1500)
    assert.is_nil(vim.uv.fs_stat(dir .. '/finished'))
  end)

  it('runs a Parquet summary again once its buffer is shown again', function()
    duckdb({ 'sleep 0.5', 'echo parquet summary' })
    h.write(dir .. '/x.parquet', { 'PAR1' })
    vim.cmd.edit(dir .. '/x.parquet')
    local bufnr = vim.api.nvim_get_current_buf()
    assert.is_not_nil(data.jobs[bufnr])
    vim.cmd.enew()
    assert.is_nil(data.jobs[bufnr])
    assert.is_true(
      vim.wait(1000, function() return lines(bufnr)[1] == data.STOPPED end, 20)
    )
    vim.api.nvim_set_current_buf(bufnr)
    assert.is_true(
      vim.wait(
        5000,
        function() return lines(bufnr)[1] == 'parquet summary' end,
        20
      )
    )
  end)

  it('stops a run when its result window is closed', function()
    duckdb({ 'sleep 1', 'touch "' .. dir .. '/finished"' })
    vim.cmd.cd(dir)
    data.sql('SELECT 1;')
    local result = data.result_buf
    assert.is_true(
      vim.wait(
        5000,
        function() return vim.uv.fs_stat(dir .. '/args') ~= nil end,
        20
      )
    )
    vim.api.nvim_win_close(vim.fn.win_findbuf(result)[1], true)
    assert.is_nil(data.jobs[result])
    vim.wait(1500)
    assert.is_nil(vim.uv.fs_stat(dir .. '/finished'))
    assert.same({ data.STOPPED }, lines(result))
  end)

  it('runs the SQL of a buffer only once agreed to', function()
    duckdb()
    vim.cmd.cd(dir)
    restore_confirm()
    restore_confirm = h.stub(vim.fn, 'confirm', function()
      asked = asked + 1
      return 2
    end)
    local source = h.buffer({ lines = { 'SELECT 1;' }, filetype = 'sql' })
    vim.api.nvim_set_current_buf(source)
    vim.cmd('DyData sql')
    vim.wait(300)
    assert.is_nil(vim.uv.fs_stat(dir .. '/args'))
    -- A query typed on the command line is the user's own
    data.sql('SELECT 2;')
    assert.is_true(
      vim.wait(
        5000,
        function() return vim.uv.fs_stat(dir .. '/read') ~= nil end,
        20
      )
    )
    assert.equal(1, asked)
    local script = table.concat(vim.fn.readfile(dir .. '/script'), '\n')
    assert.matches('enable_external_access = false', script)
    assert.matches(
      vim.pesc(("allowed_directories = ['%s/']"):format(dir)),
      script
    )
  end)

  it('refuses a file DuckDB would read as a pattern', function()
    duckdb()
    h.write(dir .. '/report[2024].csv', { 'a', '1' })
    data.summary(dir .. '/report[2024].csv')
    assert.matches('as a pattern', notes[#notes])
    assert.is_nil(vim.uv.fs_stat(dir .. '/args'))
    assert.matches('line break', data.unreadable('/d/a\n.shell id\n.csv'))
  end)

  it('leaves a Parquet file another plugin reads alone', function()
    duckdb()
    local bufnr = h.buffer({ name = 'fugitive:///repo/.git//0/x.parquet' })
    data.read(bufnr)
    assert.equal('', vim.bo[bufnr].buftype)
    assert.is_nil(require('util.sensitive').marked(bufnr))
    assert.is_nil(vim.uv.fs_stat(dir .. '/args'))
  end)

  it('sums up the file of the current buffer, or its stats', function()
    duckdb({ 'echo summary' })
    h.write(dir .. '/x.csv', { 'a,b', '1,2' })
    vim.cmd.edit(dir .. '/x.csv')
    vim.cmd.DyData()
    local bufnr = vim.api.nvim_get_current_buf()
    assert.is_true(
      vim.wait(5000, function() return lines(bufnr)[1] == 'summary' end, 20)
    )
    assert.equal(
      'dydata://' .. dir .. '/x.csv',
      vim.api.nvim_buf_get_name(bufnr)
    )

    vim.cmd.DyData('stats ' .. dir .. '/x.csv')
    local stats = vim.api.nvim_get_current_buf()
    assert.is_true(
      vim.wait(5000, function() return lines(stats)[1] == 'summary' end, 20)
    )
    assert.equal(
      'dydata://stats/' .. dir .. '/x.csv',
      vim.api.nvim_buf_get_name(stats)
    )
    assert.matches(
      'SUMMARIZE',
      table.concat(vim.fn.readfile(dir .. '/script'), '\n')
    )
  end)

  it('says so when the buffer has no file to sum up', function()
    duckdb()
    vim.api.nvim_set_current_buf(h.buffer({}))
    vim.cmd.DyData()
    assert.equal('No file given', notes[1])
    assert.is_nil(vim.uv.fs_stat(dir .. '/args'))
  end)

  it('shows why a Parquet file named like a pattern is not read', function()
    duckdb()
    h.write(dir .. '/part[1].parquet', { 'PAR1' })
    local bufnr = h.buffer({ name = dir .. '/part[1].parquet' })
    data.read(bufnr)
    assert.same(
      { 'Not read: DuckDB would read its name as a pattern' },
      lines(bufnr)
    )
    assert.equal('nofile', vim.bo[bufnr].buftype)
    assert.is_nil(vim.uv.fs_stat(dir .. '/args'))
  end)

  it('shows the result buffer again once its window was closed', function()
    duckdb({ 'echo one' })
    vim.cmd.cd(dir)
    data.sql('SELECT 1;')
    local result = data.result_buf
    assert.is_true(
      vim.wait(5000, function() return lines(result)[1] == 'one' end, 20)
    )
    vim.api.nvim_win_close(vim.fn.win_findbuf(result)[1], true)
    assert.same({}, vim.fn.win_findbuf(result))
    local origin = vim.api.nvim_get_current_win()
    duckdb({ 'echo two' })
    data.sql('SELECT 2;')
    assert.equal(result, data.result_buf)
    assert.equal(1, #vim.fn.win_findbuf(result))
    assert.equal(origin, vim.api.nvim_get_current_win())
    assert.is_true(
      vim.wait(5000, function() return lines(result)[1] == 'two' end, 20)
    )
  end)

  it('runs nothing of an empty selection', function()
    duckdb()
    vim.api.nvim_set_current_buf(h.buffer({ lines = { '', '  ' } }))
    data.sql(nil, 1, 2)
    assert.equal('No SQL to run', notes[1])
    assert.equal(0, asked)
    assert.is_nil(vim.uv.fs_stat(dir .. '/args'))
  end)

  it('stops every run on leaving', function()
    duckdb({ 'sleep 1', 'touch "' .. dir .. '/finished"' })
    vim.cmd.cd(dir)
    data.sql('SELECT 1;')
    local result = data.result_buf
    assert.is_true(
      vim.wait(
        5000,
        function() return vim.uv.fs_stat(dir .. '/args') ~= nil end,
        20
      )
    )
    assert.is_not_nil(data.jobs[result])
    vim.api.nvim_exec_autocmds('VimLeavePre', { group = 'dy_data_jobs' })
    assert.is_nil(data.jobs[result])
    vim.wait(1500)
    assert.is_nil(vim.uv.fs_stat(dir .. '/finished'))
  end)

  it('hands a pattern to DuckDB rather than listing its files', function()
    duckdb({ 'echo matched' })
    h.write(dir .. '/a.csv', { 'x', '1' })
    h.write(dir .. '/b.csv', { 'x', '2' })
    data.summary(dir .. '/*.csv')
    local bufnr = vim.api.nvim_get_current_buf()
    assert.is_true(
      vim.wait(5000, function() return lines(bufnr)[1] == 'matched' end, 20)
    )
    assert.matches(
      "read_csv%('" .. vim.pesc(dir) .. "/%*%.csv'%)",
      table.concat(vim.fn.readfile(dir .. '/script'), '\n')
    )
  end)
end)
