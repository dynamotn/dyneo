local h = require('helpers')

describe('tools.runbook', function()
  local runbook

  before_each(function()
    h.unload('tools.runbook')
    runbook = require('tools.runbook')
  end)
  after_each(function() vim.cmd('silent! %bwipeout!') end)

  local doc = {
    '# Restart',
    '',
    '```bash',
    'echo one',
    '```',
    '',
    'Text between.',
    '',
    '  ~~~console',
    '  $ kubectl get pods',
    '  NAME READY',
    '  $ echo two',
    '  ~~~',
    '',
    '````md',
    '```bash',
    'not a block of its own',
    '```',
    '````',
  }

  describe('blocks', function()
    it('lists the runnable blocks of a long runbook in one pass', function()
      local lines = {}
      for index = 1, 2000 do
        vim.list_extend(lines, { '```bash', 'echo ' .. index, '```', '' })
      end
      local start = vim.uv.hrtime()
      local blocks = runbook.blocks(lines)
      local took = (vim.uv.hrtime() - start) / 1e6
      assert.are.equal(2000, #blocks)
      assert.are.same({ 'echo 2000' }, blocks[2000].code)
      -- Read again from the top for each block, this is several seconds
      assert.is_true(took < 1000, ('took %d ms'):format(took))
    end)

    it('leaves out a fence never closed', function()
      local blocks = runbook.blocks({ '```bash', 'echo a', '```', '```sh' })
      assert.are.equal(1, #blocks)
      assert.is_nil(runbook.block_at({ '```sh', 'echo b' }, 2))
    end)
  end)

  describe('block_at', function()
    it('finds the block the row is in, fences included', function()
      local block = runbook.block_at(doc, 4)
      assert.same({
        open = 3,
        close = 5,
        lang = 'bash',
        code = { 'echo one' },
        indent = '',
      }, block)
      assert.same(block, runbook.block_at(doc, 3))
      assert.same(block, runbook.block_at(doc, 5))
    end)

    it('finds nothing outside a block', function()
      assert.is_nil(runbook.block_at(doc, 1))
      assert.is_nil(runbook.block_at(doc, 7))
    end)

    it('reads an indented tilde fence', function()
      local block = runbook.block_at(doc, 10)
      assert.equals('console', block.lang)
      assert.equals('  ', block.indent)
      assert.equals(9, block.open)
      assert.equals(13, block.close)
    end)

    it('lets a longer fence hold a shorter one', function()
      local block = runbook.block_at(doc, 17)
      assert.equals('md', block.lang)
      assert.equals(15, block.open)
      assert.equals(19, block.close)
    end)
  end)

  it('lists the blocks it can run', function()
    local blocks = runbook.blocks(doc)
    assert.same(
      { 'bash', 'console' },
      vim.tbl_map(function(b) return b.lang end, blocks)
    )
  end)

  it(
    'runs only the commands of a console block',
    function()
      assert.equals(
        'kubectl get pods\necho two',
        runbook.code_of(runbook.block_at(doc, 10))
      )
    end
  )

  it('runs the code of an indented fence without its indent', function()
    local block = runbook.block_at({
      '- step',
      '  ```python',
      '  if True:',
      '      print(1)',
      '  ```',
    }, 3)
    assert.equals('if True:\n    print(1)', runbook.code_of(block))
  end)

  it('asks before what deletes, destroys or reaches for root', function()
    -- The line it found, to show in the question
    assert.equals(
      'sudo systemctl restart x',
      runbook.danger('sudo systemctl restart x')
    )
    assert.is_truthy(runbook.danger('rm -rf ./build'))
    assert.is_truthy(runbook.danger('kubectl delete pod web-0'))
    assert.is_truthy(runbook.danger('tofu destroy -auto-approve'))
    assert.is_truthy(runbook.danger('git push origin main --force'))
    assert.is_truthy(runbook.danger('psql -c "drop table users"'))
    assert.is_nil(runbook.danger('kubectl get pods'))
    assert.is_nil(runbook.danger('echo pseudo; firmware'))
    -- Flags before the verb, other spellings, other cases
    for _, code in ipairs({
      'kubectl -n prod delete pod web-0',
      'kubectl --context prod delete ns app',
      'rm --recursive --force /srv/data',
      'helm -n app uninstall web',
      'terraform -chdir=infra destroy -auto-approve',
      'terraform apply -destroy',
      'git push origin +main',
      'psql -c "DELETE FROM users"',
      'TRUNCATE users;',
      'find /var/data -delete',
      'kubectl scale deploy/web --replicas=0',
      'echo ok\nsudo reboot',
      -- One command over several lines
      'kubectl -n prod \\\n  delete deploy api',
      'git push origin main \\\n  --force',
    }) do
      assert.is_truthy(runbook.danger(code), code)
    end
    assert.is_nil(runbook.danger('kubectl scale deploy/web --replicas=10'))
    assert.is_nil(runbook.danger('git push origin main'))
  end)

  describe('output', function()
    it('fences the output, longer than any fence inside it', function()
      assert.same(
        { '', '  ```output', '  a', '', '  b', '  ```' },
        runbook.fence({ 'a', '', 'b' }, '  ')
      )
      assert.same(
        { '', '````output', '```', '````' },
        runbook.fence({ '```' }, '')
      )
    end)

    it('shows both streams, and how a run ended', function()
      assert.same(
        { 'out', 'err', '[exit 2]' },
        runbook.render({
          code = 2,
          signal = 0,
          stdout = 'out\n',
          stderr = 'err\n',
        })
      )
      assert.same(
        { '[no output]' },
        runbook.render({ code = 0, signal = 0, stdout = '', stderr = '' })
      )
      assert.same(
        { '[stopped: signal 15]' },
        runbook.render({ code = 143, signal = 15, stdout = '', stderr = '' })
      )
      assert.same(
        { '[stopped after 5 min, the run took too long]' },
        runbook.render({
          code = 124,
          signal = 15,
          timed_out = true,
          stdout = '',
          stderr = '',
        })
      )
    end)

    it('finds the output fence of a block', function()
      local lines =
        { '```sh', 'ls', '```', '', '```output', 'a', '```', 'after' }
      assert.same({ 4, 7 }, { runbook.output_after(lines, 3) })
      assert.is_nil(runbook.output_after({ '```sh', 'ls', '```', 'text' }, 3))
    end)
  end)

  describe('running', function()
    local dir, cleanup

    before_each(function()
      dir, cleanup = h.tmpdir()
    end)
    after_each(function() cleanup() end)

    --- A Markdown buffer in `dir` holding `lines`, made current
    local function buffer(lines)
      local bufnr = h.buffer({ name = dir .. '/runbook.md', lines = lines })
      vim.api.nvim_set_current_buf(bufnr)
      -- Agreed to already, as `allowed` asks the first time
      vim.b[bufnr].dy_runbook_allowed = true
      return bufnr
    end

    --- Run `fn` and wait until `done` says the runs it started are over
    local function settle(done)
      assert.is_true(vim.wait(10000, done, 20), 'the run never finished')
    end

    it(
      'puts the output under the block, and replaces it on the next run',
      function()
        local bufnr =
          buffer({ '```bash', 'pwd', 'echo "$((1 + 1))"', '```', 'after' })
        vim.api.nvim_win_set_cursor(0, { 2, 0 })
        runbook.run()
        settle(function() return vim.api.nvim_buf_line_count(bufnr) > 5 end)
        assert.same({
          '```bash',
          'pwd',
          'echo "$((1 + 1))"',
          '```',
          '',
          '```output',
          dir,
          '2',
          '```',
          'after',
        }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))

        vim.api.nvim_buf_set_lines(bufnr, 2, 3, false, { 'echo three' })
        vim.api.nvim_win_set_cursor(0, { 3, 0 })
        runbook.run()
        settle(
          function()
            return vim.api.nvim_buf_get_lines(bufnr, 7, 8, false)[1] == 'three'
          end
        )
        assert.equals(10, vim.api.nvim_buf_line_count(bufnr))
      end
    )

    it('runs every block in turn, and stops at the first that fails', function()
      local bufnr = buffer({
        '```sh',
        'echo first',
        '```',
        '```sh',
        'exit 3',
        '```',
        '```sh',
        'echo never',
        '```',
      })
      local notes = {}
      local restore = h.stub(
        vim,
        'notify',
        function(msg) table.insert(notes, msg) end
      )
      local restore_confirm = h.stub(vim.fn, 'confirm', function() return 1 end)
      runbook.run_all()
      settle(function() return #notes > 0 end)
      restore_confirm()
      restore()
      local text =
        table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
      assert.is_truthy(text:find('first', 1, true))
      assert.is_truthy(text:find('[exit 3]', 1, true))
      assert.is_falsy(text:find('```output\nnever', 1, true))
      assert.equals('Stopped at block 2, on line 8', notes[1])

      runbook.clear()
      assert.same({
        '```sh',
        'echo first',
        '```',
        '```sh',
        'exit 3',
        '```',
        '```sh',
        'echo never',
        '```',
      }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    end)

    it('runs nothing dangerous unless told to', function()
      local bufnr = buffer({ '```sh', 'sudo true', '```' })
      local restore = h.stub(vim.fn, 'confirm', function() return 2 end)
      local finished
      runbook.run_block(
        bufnr,
        runbook.block_at(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), 2),
        function(ok) finished = ok end
      )
      restore()
      assert.is_false(finished)
      assert.equals(3, vim.api.nvim_buf_line_count(bufnr))
    end)

    it('asks once before running the blocks of a file', function()
      local bufnr = buffer({ '```sh', 'echo hi', '```' })
      vim.b[bufnr].dy_runbook_allowed = nil
      local asked = 0
      local restore = h.stub(vim.fn, 'confirm', function()
        asked = asked + 1
        return 2
      end)
      local finished
      runbook.run_block(
        bufnr,
        runbook.block_at(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), 2),
        function(ok) finished = ok end
      )
      restore()
      assert.equals(1, asked)
      assert.is_false(finished)
      assert.equals(3, vim.api.nvim_buf_line_count(bufnr))
    end)

    it('runs nothing of a buffer that is no file', function()
      local bufnr = h.buffer({ lines = { '```sh', 'echo hi', '```' } })
      vim.bo[bufnr].buftype = 'nofile'
      assert.is_false(runbook.allowed(bufnr))
    end)

    it('stops what a block started, not only its shell', function()
      local bufnr = buffer({ '```sh', 'sleep 30 &', 'sleep 30', '```' })
      local finished
      runbook.run_block(
        bufnr,
        runbook.block_at(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), 2),
        function(ok) finished = ok end
      )
      vim.wait(200)
      runbook.stop()
      settle(function() return finished ~= nil end)
      assert.is_false(finished)
    end)

    it('stops a run that prints without end, and keeps its head', function()
      local max = runbook.MAX_OUTPUT
      runbook.MAX_OUTPUT = 4096
      local bufnr = buffer({ '```sh', 'yes', '```' })
      local finished
      runbook.run_block(
        bufnr,
        runbook.block_at(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), 2),
        function(ok) finished = ok end
      )
      settle(function() return finished ~= nil end)
      runbook.MAX_OUTPUT = max
      assert.is_false(finished)
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local text = table.concat(lines, '\n')
      assert.is_truthy(
        text:find('[output cut at 4 KiB, the run was stopped]', 1, true)
      )
      -- 4096 bytes of `y\n` and the fences around them, no more
      assert.is_true(#lines < 2100)
    end)

    it('does not take a line opening with inline code for a fence', function()
      local lines = { '```js``` is inline', 'text', '```sh', 'ls', '```' }
      assert.equals('sh', runbook.block_at(lines, 4).lang)
    end)

    it('sets its mappings on a buffer', function()
      local bufnr = buffer({})
      runbook.attach(bufnr)
      local lhs = vim.tbl_map(
        function(map) return map.desc end,
        vim.api.nvim_buf_get_keymap(bufnr, 'n')
      )
      assert.is_true(vim.tbl_contains(lhs, 'Run Block (Runbook)'))
      assert.is_true(vim.tbl_contains(lhs, 'Run From Here (Runbook)'))
      assert.is_true(vim.tbl_contains(lhs, 'Record Runs (Runbook)'))
      assert.is_true(vim.tbl_contains(lhs, 'Forget Inputs (Runbook)'))
    end)

    describe('inputs', function()
      it('finds each input once, and fills them in', function()
        local code = 'kubectl -n ${input:ns} get pod ${input:pod}\n'
          .. 'echo ${input:ns} ${HOME} {{ .x }}'
        assert.same({ 'ns', 'pod' }, runbook.inputs(code))
        assert.equals(
          'kubectl -n prod get pod api\necho prod ${HOME} {{ .x }}',
          runbook.expand(code, { ns = 'prod', pod = 'api' })
        )
        assert.equals('${input:x}', runbook.expand('${input:x}', {}))
      end)

      it(
        'asks for each input once per buffer, and runs it filled in',
        function()
          local bufnr = buffer({ '```sh', 'echo "${input:who}"', '```' })
          local asked = {}
          local restore = h.stub(vim.ui, 'input', function(opts, on_confirm)
            table.insert(asked, opts.prompt)
            on_confirm('world')
          end)
          local block =
            runbook.block_at(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), 2)
          local finished
          runbook.run_block(bufnr, block, function(ok) finished = ok end)
          settle(function() return finished ~= nil end)
          assert.is_true(finished)
          assert.same({ 'who: ' }, asked)
          assert.same(
            { '```output', 'world', '```' },
            vim.api.nvim_buf_get_lines(bufnr, 4, 7, false)
          )

          -- Kept for the next run, until forgotten
          finished = nil
          runbook.run_block(bufnr, block, function(ok) finished = ok end)
          settle(function() return finished ~= nil end)
          assert.equals(1, #asked)
          runbook.command({ fargs = { 'inputs' } })
          assert.is_nil(vim.b[bufnr].dy_runbook_inputs)
          restore()
        end
      )

      it('runs nothing when an input is not given', function()
        local bufnr = buffer({ '```sh', 'echo ${input:x}', '```' })
        local restore = h.stub(
          vim.ui,
          'input',
          function(_, on_confirm) on_confirm(nil) end
        )
        local finished
        runbook.run_block(
          bufnr,
          runbook.block_at(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), 2),
          function(ok) finished = ok end
        )
        restore()
        assert.is_false(finished)
        assert.equals(3, vim.api.nvim_buf_line_count(bufnr))
      end)

      it('checks the command as it will run, inputs filled in', function()
        local bufnr = buffer({ '```sh', '${input:cmd} -rf /tmp/x', '```' })
        local restore_input = h.stub(
          vim.ui,
          'input',
          function(_, on_confirm) on_confirm('rm') end
        )
        local question
        local restore_confirm = h.stub(vim.fn, 'confirm', function(msg)
          question = msg
          return 2
        end)
        local finished
        runbook.run_block(
          bufnr,
          runbook.block_at(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), 2),
          function(ok) finished = ok end
        )
        restore_confirm()
        restore_input()
        assert.is_false(finished)
        assert.equals('This block runs `rm -rf /tmp/x`. Run it?', question)
      end)
    end)

    it('runs from the block under the cursor down', function()
      local bufnr = buffer({
        '```sh',
        'echo one',
        '```',
        'text',
        '```sh',
        'echo two',
        '```',
        '```sh',
        'echo three',
        '```',
      })
      vim.api.nvim_win_set_cursor(0, { 4, 0 })
      local notes, question = {}, nil
      local restore = h.stub(
        vim,
        'notify',
        function(msg) table.insert(notes, msg) end
      )
      local restore_confirm = h.stub(vim.fn, 'confirm', function(msg)
        question = msg
        return 1
      end)
      runbook.command({ fargs = { 'from' } })
      settle(function() return #notes > 0 end)
      restore_confirm()
      restore()
      assert.equals(
        'Run the 2 blocks from block 2, one after the other?',
        question
      )
      assert.equals('Ran 2 blocks', notes[1])
      local text =
        table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
      assert.is_falsy(text:find('```output\none', 1, true))
      assert.is_truthy(text:find('```output\ntwo', 1, true))
      assert.is_truthy(text:find('```output\nthree', 1, true))
    end)

    it('records each run to a private file, until stopped', function()
      local bufnr = buffer({ '```sh', 'echo "${input:x}"; exit 4', '```' })
      local log = dir .. '/records/runbook-1.md'
      local restore_path = h.stub(
        runbook,
        'log_path',
        function() return log end
      )
      local restore_input = h.stub(
        vim.ui,
        'input',
        function(_, on_confirm) on_confirm('typed') end
      )
      local restore_notify = h.stub(vim, 'notify', function() end)
      runbook.command({ fargs = { 'record' } })
      assert.equals(log, vim.b[bufnr].dy_runbook_log)

      local finished
      runbook.run_block(
        bufnr,
        runbook.block_at(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), 2),
        function(ok) finished = ok end
      )
      settle(function() return finished ~= nil end)
      runbook.command({ fargs = { 'record' } })
      restore_notify()
      restore_input()
      restore_path()

      assert.is_nil(vim.b[bufnr].dy_runbook_log)
      assert.equals('rw-------', vim.fn.getfperm(log))
      local lines = vim.fn.readfile(log)
      assert.equals(
        '# ' .. vim.fn.fnamemodify(dir .. '/runbook.md', ':~'),
        lines[1]
      )
      local text = table.concat(lines, '\n')
      assert.is_truthy(text:find('line 1 (sh): exit 4', 1, true))
      -- The code as written, the value typed nowhere but in what it printed
      assert.is_truthy(
        text:find('```sh\necho "${input:x}"; exit 4\n```', 1, true)
      )
      assert.is_falsy(text:find('echo "typed"', 1, true))
      assert.is_truthy(text:find('```output\ntyped\n[exit 4]\n```', 1, true))
    end)

    it('runs nothing of a buffer gone while an input was typed', function()
      local bufnr = buffer({ '```sh', 'echo ${input:x}', '```' })
      local block =
        runbook.block_at(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), 2)
      local restore = h.stub(vim.ui, 'input', function(_, on_confirm)
        vim.api.nvim_buf_delete(bufnr, { force = true })
        on_confirm('late')
      end)
      local finished
      runbook.run_block(bufnr, block, function(ok) finished = ok end)
      restore()
      assert.is_false(finished)
    end)
  end)

  it('tells how each run ended in its record', function()
    local function entry(fields)
      return runbook.log_entry(vim.tbl_extend('force', {
        line = 3,
        lang = 'bash',
        code = 'ls',
        output = { 'a' },
        code_status = 0,
        started = 0,
        ms = 1500,
      }, fields))
    end
    assert.equals(
      os.date('## %H:%M:%S', 0) .. ' line 3 (bash): exit 0, 1.5 s',
      entry({})[1]
    )
    assert.is_truthy(entry({ signal = 15 })[1]:find('signal 15', 1, true))
    assert.is_truthy(entry({ cut = true })[1]:find('output cut', 1, true))
    assert.is_truthy(
      entry({ signal = 15, timed_out = true })[1]:find('timed out', 1, true)
    )
    assert.same({ '', '```bash', 'ls', '```' }, vim.list_slice(entry({}), 2, 5))
  end)
end)
