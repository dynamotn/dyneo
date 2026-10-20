local h = require('helpers')

describe('tools.logview', function()
  local logview, dir, cleanup, notes, restore_notify

  before_each(function()
    h.unload('tools.logview', 'util.scratch')
    logview = require('tools.logview')
    dir, cleanup = h.tmpdir()
    notes = {}
    restore_notify = h.stub(
      vim,
      'notify',
      function(msg) table.insert(notes, msg) end
    )
  end)
  after_each(function()
    restore_notify()
    vim.cmd('silent! tabonly!')
    vim.cmd('silent! %bwipeout!')
    cleanup()
  end)

  describe('level', function()
    it('reads words, syslog priorities and pino numbers', function()
      assert.equals('warn', logview.level('WARNING'))
      assert.equals('error', logview.level('fatal'))
      assert.equals('info', logview.level('notice'))
      assert.is_nil(logview.level('verbose'))
      assert.equals('error', logview.level('3', true))
      assert.equals('warn', logview.level(4, true))
      assert.equals('info', logview.level('6', true))
      assert.equals('debug', logview.level(7, true))
      assert.equals('error', logview.level(60))
      assert.equals('info', logview.level(30))
      assert.equals('trace', logview.level(10))
    end)
  end)

  describe('parse', function()
    it('reads a JSON line, whatever its keys are called', function()
      local record = logview.parse(
        '{"ts":"2026-10-09T10:00:00Z","severity":"ERROR","message":"boom","requestId":"r1"}'
      )
      assert.same({
        time = '2026-10-09T10:00:00Z',
        level = 'error',
        msg = 'boom',
        id = 'r1',
        raw = '{"ts":"2026-10-09T10:00:00Z","severity":"ERROR","message":"boom","requestId":"r1"}',
        json = true,
      }, record)
      -- pino: numbers for levels, no id
      local pino = logview.parse('{"level":40,"time":1,"msg":"slow"}')
      assert.equals('warn', pino.level)
      assert.equals('1', pino.time)
      assert.is_nil(pino.id)
    end)

    it('reads a journal entry by its priority', function()
      local record = logview.parse(vim.json.encode({
        __REALTIME_TIMESTAMP = '1700000000000000',
        PRIORITY = '3',
        MESSAGE = 'unit failed',
        level = 'info',
      }))
      assert.equals('error', record.level)
      assert.equals('unit failed', record.msg)
      assert.equals(os.date('%Y-%m-%dT%H:%M:%S', 1700000000), record.time)
    end)

    it('reads logfmt, quoted values and all', function()
      local record = logview.parse(
        'time=2026-10-09 level=warn msg="disk \\"nearly\\" full" request_id=abc'
      )
      assert.equals('2026-10-09', record.time)
      assert.equals('warn', record.level)
      assert.equals('disk "nearly" full', record.msg)
      assert.equals('abc', record.id)
      assert.is_false(record.json)
      assert.is_nil(logview.logfmt('just one=pair'))
      assert.is_nil(logview.logfmt('a=1 b=2 then words'))
    end)

    it('finds the level of a plain line, if it says one', function()
      assert.equals('error', logview.parse('2026 ERROR could not bind').level)
      assert.equals('warn', logview.parse('Warning: slow disk').level)
      assert.is_nil(logview.parse('an error in lower case is prose').level)
      assert.equals('{ not json', logview.parse('{ not json').msg)
    end)
  end)

  it('formats a record on one line', function()
    assert.equals(
      't ERROR a⏎b [r1]',
      logview.format({
        time = 't',
        level = 'error',
        msg = 'a\nb',
        id = 'r1',
        raw = '',
        json = false,
      })
    )
    assert.equals(
      '-     x',
      logview.format({ msg = 'x', raw = 'x', json = false })
    )
  end)

  it('narrows down by level, request and selection', function()
    local records = {
      { level = 'debug', msg = 'a', raw = 'a', json = false },
      { level = 'warn', msg = 'b', id = 'r1', raw = 'b', json = false },
      { level = 'error', msg = 'c', id = 'r2', raw = 'c', json = false },
      { msg = 'd', raw = 'd', json = false },
    }
    assert.same({ 1, 2, 3, 4 }, logview.visible(records, {}))
    assert.same({ 2, 3 }, logview.visible(records, { level = 'warn' }))
    assert.same({ 2 }, logview.visible(records, { id = 'r1' }))
    assert.same({ 3 }, logview.visible(records, { selected = { [3] = true } }))
  end)

  describe('view', function()
    local file

    before_each(function()
      file = dir .. '/app.log'
      h.write(file, {
        '{"level":"info","msg":"start","request_id":"r1"}',
        '{"level":"error","msg":"failed","request_id":"r2"}',
        'level=debug msg=tick request_id=r1',
        '{"level":"warn","msg":"slow","request_id":"r1"}',
      })
    end)

    local function lines() return vim.api.nvim_buf_get_lines(0, 0, -1, false) end

    it('opens a file as records, held back from AI', function()
      logview.command({ fargs = { file } })
      local bufnr = vim.api.nvim_get_current_buf()
      assert.equals('dylog', vim.bo.filetype)
      assert.is_truthy(require('util.sensitive').marked(bufnr))
      assert.is_false(vim.bo.modifiable)
      assert.is_truthy(lines()[1]:find('4 of 4 records', 1, true))
      assert.equals('ERROR failed [r2]', lines()[3])

      local marks = vim.api.nvim_buf_get_extmarks(
        bufnr,
        vim.api.nvim_create_namespace('dy_logview'),
        0,
        -1,
        { details = true }
      )
      assert.equals(4, #marks)
      assert.equals('DiagnosticError', marks[2][4].hl_group)
    end)

    it('narrows to a level and to the request under the cursor', function()
      logview.command({ fargs = { file } })
      local bufnr = vim.api.nvim_get_current_buf()
      logview.min_level(bufnr, 'warn')
      assert.same(
        { 'ERROR failed [r2]', 'WARN  slow [r1]' },
        vim.list_slice(lines(), 2)
      )
      logview.clear(bufnr)
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      logview.request(bufnr)
      assert.equals(4, #lines())
      assert.is_truthy(lines()[1]:find('request r1', 1, true))
      -- Again, and every request is back
      logview.request(bufnr)
      assert.equals(5, #lines())

      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      logview.request(bufnr)
      assert.equals('No request id on this line', notes[#notes])
    end)

    it('narrows to what a jq expression selects', function()
      if vim.fn.executable('jq') ~= 1 then
        assert(not vim.env.CI, 'no jq on CI')
        return pending('jq is not installed')
      end
      logview.command({ fargs = { file } })
      local bufnr = vim.api.nvim_get_current_buf()
      logview.jq(bufnr, '.request_id == "r1"')
      assert.is_true(vim.wait(5000, function() return #lines() == 3 end, 20))
      assert.same(
        { 'INFO  start [r1]', 'WARN  slow [r1]' },
        vim.list_slice(lines(), 2)
      )

      logview.jq(bufnr, '.[')
      assert.is_true(vim.wait(5000, function() return #notes > 0 end, 20))
      assert.is_truthy(notes[#notes]:find('^jq failed'))
    end)

    it('drops what jq selected of records a reload replaced', function()
      if vim.fn.executable('jq') ~= 1 then
        assert(not vim.env.CI, 'no jq on CI')
        return pending('jq is not installed')
      end
      logview.command({ fargs = { file } })
      local bufnr = vim.api.nvim_get_current_buf()
      local jq_runs = 0
      local run = require('util.system').run
      local restore = h.stub(
        require('util.system'),
        'run',
        function(cmd, opts, cb)
          if cmd[1] == 'jq' then jq_runs = jq_runs + 1 end
          return run(cmd, opts, cb)
        end
      )
      logview.jq(bufnr, '.request_id == "r1"')
      logview.reload(bufnr)
      -- Long enough for jq to answer, and for its answer to be dropped
      vim.wait(1000, function() return false end, 20)
      restore()
      assert.equals(1, jq_runs)
      assert.equals(5, #lines())
    end)

    it('reads only the end of a file past the size cap', function()
      h.write(file, { 'first record', 'second record', 'third record' })
      local restore = h.stub(logview, 'MAX_BYTES', 20)
      local read, err, cut = logview.read_tail(file)
      restore()
      assert.is_nil(err)
      assert.is_true(cut)
      assert.same({ 'third record' }, read)
      assert.same(
        { 'first record', 'second record', 'third record' },
        (logview.read_tail(file))
      )
      assert.is_nil(logview.read_tail(dir .. '/missing.log'))
    end)

    it('reloads from its source, keeping the level asked for', function()
      logview.command({ fargs = { file } })
      local bufnr = vim.api.nvim_get_current_buf()
      logview.min_level(bufnr, 'error')
      h.write(
        file,
        { '{"level":"error","msg":"again"}', '{"level":"info","msg":"x"}' }
      )
      logview.reload(bufnr)
      assert.same({ 'ERROR again' }, vim.list_slice(lines(), 2))
    end)

    it('reads the journal and a pod through their commands', function()
      vim.fn.mkdir(dir .. '/bin', 'p')
      h.write(dir .. '/bin/journalctl', {
        '#!/bin/sh',
        'echo "$@" > "' .. dir .. '/journal.args"',
        [[echo '{"__REALTIME_TIMESTAMP":"1700000000000000","PRIORITY":"4","MESSAGE":"hot"}']],
      })
      h.write(
        dir .. '/bin/kubectl',
        { '#!/bin/sh', 'echo "pod broke" >&2', 'exit 1' }
      )
      vim.fn.setfperm(dir .. '/bin/journalctl', 'rwxr-xr-x')
      vim.fn.setfperm(dir .. '/bin/kubectl', 'rwxr-xr-x')
      local path = vim.env.PATH
      vim.env.PATH = dir .. '/bin:' .. path

      logview.command({ fargs = { 'journal', '-u', 'nginx' } })
      assert.is_true(vim.wait(5000, function() return #lines() == 2 end, 20))
      assert.is_truthy(lines()[2]:find('WARN  hot', 1, true))
      assert.equals(
        '--output=json --no-pager --lines=2000 -u nginx',
        vim.fn.readfile(dir .. '/journal.args')[1]
      )

      logview.command({ fargs = { 'kube', 'web-0' } })
      assert.is_true(vim.wait(5000, function() return #notes > 0 end, 20))
      vim.env.PATH = path
      assert.equals('kubectl failed: pod broke', notes[#notes])
    end)

    it('keeps what a followed source printed before the deadline', function()
      vim.fn.mkdir(dir .. '/bin', 'p')
      h.write(dir .. '/bin/journalctl', {
        '#!/bin/sh',
        [[echo '{"PRIORITY":"6","MESSAGE":"tick"}']],
        'exec sleep 30',
      })
      vim.fn.setfperm(dir .. '/bin/journalctl', 'rwxr-xr-x')
      local path = vim.env.PATH
      vim.env.PATH = dir .. '/bin:' .. path
      -- The deadline runs from the spawn: it has to leave a loaded machine
      -- time to start the shell and print, or there is nothing to keep
      local restore = h.stub(logview, 'TIMEOUT', 2000)
      logview.command({ fargs = { 'journal', '-f' } })
      local function shown()
        return table.concat(lines(), '\n'):find('tick', 1, true) ~= nil
      end
      assert.is_true(vim.wait(10000, shown, 20))
      restore()
      vim.env.PATH = path
      assert.same({}, notes)
    end)

    it('warns when a source did not finish in time', function()
      vim.fn.mkdir(dir .. '/bin', 'p')
      h.write(dir .. '/bin/journalctl', {
        '#!/bin/sh',
        [[echo '{"PRIORITY":"6","MESSAGE":"tick"}']],
        'exec sleep 30',
      })
      vim.fn.setfperm(dir .. '/bin/journalctl', 'rwxr-xr-x')
      local path = vim.env.PATH
      vim.env.PATH = dir .. '/bin:' .. path
      local restore = h.stub(logview, 'TIMEOUT', 2000)
      logview.command({ fargs = { 'journal', '-u', 'nginx' } })
      assert.is_true(vim.wait(10000, function() return #notes > 0 end, 20))
      restore()
      vim.env.PATH = path
      assert.equals(
        'journalctl did not finish within 2 s: showing what it printed',
        notes[1]
      )
      assert.is_true(logview.follows({ 'kubectl', 'logs', 'p', '--follow' }))
      assert.is_false(logview.follows({ 'kubectl', 'logs', 'p' }))
    end)

    it('stops a source that keeps printing, and says so', function()
      vim.fn.mkdir(dir .. '/bin', 'p')
      -- `journalctl -f`: a record a line, for as long as it is let run
      h.write(dir .. '/bin/journalctl', {
        '#!/bin/sh',
        [[exec yes '{"PRIORITY":"6","MESSAGE":"tick"}']],
      })
      vim.fn.setfperm(dir .. '/bin/journalctl', 'rwxr-xr-x')
      local path = vim.env.PATH
      vim.env.PATH = dir .. '/bin:' .. path
      local restore = h.stub(logview, 'MAX_BYTES', 4096)
      logview.command({ fargs = { 'journal', '-f' } })
      assert.is_true(vim.wait(5000, function() return #notes > 0 end, 20))
      restore()
      vim.env.PATH = path
      assert.is_truthy(notes[1]:find('^Read the first'))
      assert.is_true(#lines() > 10)
    end)

    it('keeps the last records only past the line cap', function()
      logview.command({ fargs = { file } })
      local bufnr = vim.api.nvim_get_current_buf()
      local restore = h.stub(logview, 'MAX_LINES', 2)
      logview.reload(bufnr)
      restore()
      assert.same(
        { 'DEBUG tick [r1]', 'WARN  slow [r1]' },
        vim.list_slice(lines(), 2)
      )
    end)

    it('asks for the level, and for the jq expression', function()
      logview.command({ fargs = { file } })
      local bufnr = vim.api.nvim_get_current_buf()
      local offered
      local restore_select = h.stub(vim.ui, 'select', function(items, _, on)
        offered = items
        on(nil)
      end)
      logview.min_level(bufnr)
      assert.same(logview.LEVELS, offered)
      assert.equals(5, #lines())
      restore_select()
      restore_select = h.stub(
        vim.ui,
        'select',
        function(_, _, on) on('error') end
      )
      logview.min_level(bufnr)
      restore_select()
      assert.same({ 'ERROR failed [r2]' }, vim.list_slice(lines(), 2))

      local asked = {}
      local restore_exe = h.stub(
        vim.fn,
        'executable',
        function(name) return name == 'jq' and 0 or 1 end
      )
      local restore_input = h.stub(vim.ui, 'input', function(opts, on)
        table.insert(asked, opts.prompt)
        on(#asked == 1 and '' or '.level == "warn"')
      end)
      logview.jq(bufnr)
      assert.same({}, notes)
      logview.jq(bufnr)
      restore_input()
      restore_exe()
      assert.equals(2, #asked)
      assert.same({ 'jq is not installed' }, notes)
    end)

    it('runs jq on nothing when no record is JSON', function()
      h.write(file, { 'plain line', 'another' })
      logview.command({ fargs = { file } })
      local bufnr = vim.api.nvim_get_current_buf()
      local restore_exe = h.stub(vim.fn, 'executable', function() return 1 end)
      logview.jq(bufnr, '.x')
      restore_exe()
      assert.same({ 'No JSON record to run jq on' }, notes)
    end)

    it('says when the command of a source is not installed', function()
      local restore_exe = h.stub(vim.fn, 'executable', function() return 0 end)
      logview.command({ fargs = { 'journal' } })
      restore_exe()
      assert.same({ 'journalctl is not installed' }, notes)
    end)

    it('says when only the end of a file was read', function()
      local restore = h.stub(logview, 'MAX_BYTES', 20)
      logview.command({ fargs = { file } })
      restore()
      assert.same({ 'Read the last 0 MiB only' }, notes)
    end)

    it('says what it needs', function()
      logview.command({ fargs = {} })
      logview.command({ fargs = { 'kube' } })
      logview.command({ fargs = { dir .. '/missing.log' } })
      assert.equals(3, #notes)
      assert.is_truthy(notes[2]:find('Name the pod', 1, true))
      assert.is_truthy(notes[3]:find('Cannot read', 1, true))
    end)
  end)
end)
