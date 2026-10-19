local h = require('helpers')

describe('tools.ai.ci', function()
  local ai_ci, ci, dir, cleanup, restores, notes, delivered, path
  local pipeline, logs, workflow

  before_each(function()
    dir, cleanup = h.tmpdir()
    h.write(
      dir .. '/bin/betterleaks',
      { '#!/bin/sh', 'cat > /dev/null', 'echo "[]"' }
    )
    vim.fn.setfperm(dir .. '/bin/betterleaks', 'rwxr-xr-x')
    path = vim.env.PATH
    vim.env.PATH = dir .. '/bin:' .. path
    notes, delivered, logs = {}, {}, {}
    pipeline = {
      id = 7,
      status = 'failure',
      url = 'https://github.com/o/r/actions/runs/7',
      jobs = {
        { id = 1, name = 'lint', status = 'completed', conclusion = 'success' },
        { id = 2, name = 'test', status = 'completed', conclusion = 'failure' },
      },
    }
    logs[2] = '2026-10-10T01:02:03.4567890Z \27[31mFAIL\27[0m spec.lua\n'
    h.unload(
      'tools.ai.ci',
      'tools.ci_inline',
      'tools.ai.check',
      'tools.ai.prompts'
    )
    ci = require('tools.ci_inline')
    local forge = require('util.forge')
    restores = {
      h.stub(vim, 'notify', function(msg) table.insert(notes, msg) end),
      h.stub(package.loaded, 'util.ai_audit', { record = function() end }),
      h.stub(package.loaded, 'util.project_rtp', {
        current = function() return nil end,
      }),
      h.stub(package.loaded, 'tools.ai', {
        send = function(text, what, detail)
          table.insert(delivered, { text = text, what = what, detail = detail })
          return true
        end,
      }),
      h.stub(
        ci,
        'context',
        function(_, on_context)
          on_context({
            dir = dir,
            file = workflow,
            kind = 'github',
            remote = { kind = 'github', host = 'github.com', slug = 'o/r' },
            branch = 'feat',
          })
        end
      ),
      h.stub(ci, 'fetch', function(_, _, _, on_done) on_done(pipeline) end),
      h.stub(forge, 'api_text', function(_, endpoint, _, on_done)
        local id = tonumber(endpoint:match('jobs/(%d+)/logs$'))
        on_done(logs[id], false)
      end),
    }
    ai_ci = require('tools.ai.ci')
    workflow = dir .. '/.github/workflows/ci.yml'
    vim.api.nvim_set_current_buf(h.buffer({
      name = workflow,
      lines = { 'jobs:', '  test:', '    runs-on: ubuntu-latest' },
    }))
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.env.PATH = path
    vim.cmd('silent! %bwipeout!')
    cleanup()
  end)

  local function wait_for(fn) assert.is_true(vim.wait(5000, fn, 20)) end

  it('sends the failed job, its log and the file', function()
    ai_ci.explain()
    wait_for(function() return #delivered > 0 end)
    local text = delivered[1].text
    assert.is_truthy(text:find('`test` failed', 1, true))
    assert.is_truthy(text:find('\nFAIL spec.lua\n', 1, true))
    assert.is_truthy(text:find('runs-on: ubuntu-latest', 1, true))
    assert.is_truthy(text:find(pipeline.url, 1, true))
    assert.equals('ci job test', delivered[1].detail)
  end)

  it('asks which job when several failed', function()
    pipeline.jobs[1].conclusion = 'failure'
    logs[1] = 'lint failed'
    table.insert(
      restores,
      h.stub(vim.ui, 'select', function(items, opts, on_choice)
        assert.equals('lint', opts.format_item(items[1]))
        on_choice(items[1])
      end)
    )
    ai_ci.explain()
    wait_for(function() return #delivered > 0 end)
    assert.equals('ci job lint', delivered[1].detail)
  end)

  it('fences the log longer than any backticks in it', function()
    logs[2] = 'expected ```lua but got ````'
    ai_ci.explain()
    wait_for(function() return #delivered > 0 end)
    assert.is_truthy(delivered[1].text:find('`````text\n', 1, true))
  end)

  it('says when no job failed', function()
    pipeline.jobs[2].conclusion = 'success'
    ai_ci.explain()
    wait_for(function() return #notes > 0 end)
    assert.is_truthy(notes[1]:find('No job failed', 1, true))
  end)

  it('refuses a log with a secret in it', function()
    logs[2] = 'token=ghp_' .. ('a'):rep(36)
    ai_ci.explain()
    wait_for(function() return #notes > 0 end)
    assert.is_truthy(notes[1]:find('The log of test', 1, true))
    assert.same({}, delivered)
  end)

  it('says when the log passed its limit and the file was cut', function()
    ai_ci.MAX_FILE = 8
    table.insert(
      restores,
      h.stub(
        require('util.forge'),
        'api_text',
        function(_, _, _, on_done) on_done('tail of the log', true) end
      )
    )
    ai_ci.explain()
    wait_for(function() return #delivered > 0 end)
    assert.is_truthy(notes[1]:find('its end is missing', 1, true))
    assert.is_truthy(delivered[1].text:find('jobs:\n  \n(cut)', 1, true))
  end)

  it('keeps a sensitive pipeline file from AI', function()
    table.insert(
      restores,
      h.stub(package.loaded, 'util.sensitive', {
        is_sensitive = function() return true end,
        reasons = function() return { 'holds a key' } end,
      })
    )
    ai_ci.explain()
    assert.same({}, delivered)
    assert.is_truthy(notes[1]:find('Kept from AI: holds a key', 1, true))
  end)

  it('says when the prompt is missing', function()
    local prompts = require('tools.ai.prompts')
    table.insert(
      restores,
      h.stub(prompts, 'template', function() return nil end)
    )
    ai_ci.explain()
    assert.same({}, delivered)
    assert.is_truthy(notes[1]:find('No prompt ' .. ai_ci.PROMPT, 1, true))
  end)

  it('passes on why the pipeline could not be fetched', function()
    table.insert(
      restores,
      h.stub(
        ci,
        'fetch',
        function(_, _, _, on_done) on_done(nil, 'gh: 403') end
      )
    )
    ai_ci.explain()
    wait_for(function() return #notes > 0 end)
    assert.equals('gh: 403', notes[1])
    assert.same({}, delivered)
  end)

  describe('tail', function()
    it('keeps the end of a long log, from a whole line', function()
      ai_ci.TAIL = 10
      local text, cut = ai_ci.tail('first line\nsecond\nthird\n')
      assert.is_true(cut)
      assert.equals('third', text)
    end)

    it(
      'keeps what a line redrawn with \\r showed last',
      function() assert.equals('100%', (ai_ci.tail('10%\r50%\r100%'))) end
    )

    it("drops GitLab's section markers", function()
      local log = 'section_start:1:build\r\27[0KBuild\nok\n'
        .. 'section_end:2:build\r\27[0K'
      assert.equals('Build\nok', (ai_ci.tail(log)))
    end)
  end)

  it('asks GitLab and GitHub for the log of a job', function()
    local job = { id = 3, name = 'x' }
    assert.equals(
      'projects/g%2Fp/jobs/3/trace',
      ai_ci.log_endpoint({ kind = 'gitlab', slug = 'g/p' }, job)
    )
    assert.equals(
      'repos/o/r/actions/jobs/3/logs',
      ai_ci.log_endpoint({ kind = 'github', slug = 'o/r' }, job)
    )
  end)

  it('reads only the end of a long Azure log, and says so', function()
    local forge = require('util.forge')
    local asked = {}
    local undo_api = h.stub(forge, 'api', function(_, call, on_done)
      table.insert(asked, call)
      on_done({
        value = {
          { id = 8, lineCount = 1 },
          { id = 9, lineCount = ai_ci.AZURE_LINES + 100 },
        },
      })
    end)
    local undo_text = h.stub(forge, 'api_text', function(_, call, _, on_done)
      table.insert(asked, call)
      on_done('the end', false)
    end)
    local got
    ai_ci.fetch_log(
      { kind = 'azure', project = 'p' },
      { id = 77, status = 'failed', jobs = {} },
      { id = 9, name = 'x' },
      function(...) got = { ... } end
    )
    undo_text()
    undo_api()
    assert.same({ 'the end', false, nil, true }, got)
    assert.same({ project = 'p', buildId = 77 }, asked[1].route)
    assert.same({ project = 'p', buildId = 77, logId = 9 }, asked[2].route)
    assert.same({ startLine = 101 }, asked[2].query)
  end)

  it('asks Jenkins for its console and Argo for the pod of a step', function()
    local jenkins = require('tools.ci_jenkins')
    local argo = require('tools.ci_argo')
    local asked = {}
    local undo_jenkins = h.stub(
      jenkins,
      'log',
      function(target, pipeline, max, on_done)
        table.insert(asked, { 'jenkins', target.base, pipeline.id, max })
        on_done('console', false, nil, true)
      end
    )
    local undo_argo = h.stub(
      argo,
      'log',
      function(target, pipeline, job, on_done)
        table.insert(asked, { 'argo', target.context, pipeline.id, job.id })
        on_done('pod', false, nil, false)
      end
    )
    local got = {}
    ai_ci.fetch_log_for(
      { kind = 'jenkins', target = { base = 'https://ci.x/job/a' } },
      { id = 5, jobs = {} },
      { id = 'build', name = '#5' },
      function(...) table.insert(got, { ... }) end
    )
    ai_ci.fetch_log_for(
      { kind = 'argo', target = { context = 'kind-dev' } },
      { id = 'ci-new', jobs = {} },
      { id = 'n2', name = 'unit' },
      function(...) table.insert(got, { ... }) end
    )
    undo_argo()
    undo_jenkins()
    assert.same({
      { 'jenkins', 'https://ci.x/job/a', 5, ai_ci.MAX_LOG },
      { 'argo', 'kind-dev', 'ci-new', 'n2' },
    }, asked)
    assert.same(
      { { 'console', false, nil, true }, { 'pod', false, nil, false } },
      got
    )
  end)
end)
