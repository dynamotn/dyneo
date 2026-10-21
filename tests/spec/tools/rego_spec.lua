local h = require('helpers')

local POLICY = {
  'package k8s.deny',
  '',
  'import rego.v1',
  '',
  'deny contains msg if {',
  '\tinput.kind == "Pod"',
  '\tmsg := "no pods"',
  '}',
}

describe('tools.rego', function()
  local rego, dir, cleanup, path, notes, restore_notify

  before_each(function()
    h.unload('tools.rego')
    rego = require('tools.rego')
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
  end)
  after_each(function()
    for _, playground in pairs(rego.open_playgrounds) do
      rego.close(playground)
    end
    vim.env.PATH = path
    restore_notify()
    vim.cmd('silent! tabonly!')
    vim.cmd('silent! only!')
    vim.cmd('silent! %bwipeout!')
    cleanup()
  end)

  --- What the fake `opa capabilities --current` prints
  local CAPABILITIES = vim.json.encode({
    builtins = {
      { name = 'count', decl = { type = 'function' } },
      { name = 'http.send', decl = { type = 'function' } },
      { name = 'net.cidr_contains', decl = { type = 'function' } },
      { name = 'net.lookup_ip_addr', decl = { type = 'function' } },
      { name = 'opa.runtime', decl = { type = 'function' } },
    },
    features = { 'rego_v1' },
  })

  --- A fake `opa`: its arguments a line each in `calls`, its input in
  --- `stdin`; `capabilities` answers with `CAPABILITIES` unless `lines`
  --- answer it first
  local function opa(lines, capabilities)
    h.write(
      dir .. '/bin/opa',
      vim.list_extend({
        '#!/bin/sh',
        'printf "%s\\n" "$*" >> "' .. dir .. '/calls"',
        capabilities
          or ([[case "$1" in capabilities) printf '%%s\n' '%s'; exit 0;; esac]]):format(
            CAPABILITIES
          ),
        'case "$*" in *--stdin-input*) cat > "' .. dir .. '/stdin";; esac',
      }, lines)
    )
    vim.fn.setfperm(dir .. '/bin/opa', 'rwxr-xr-x')
  end

  --- The calls of the fake `opa`, but for its capabilities
  local function calls()
    if vim.fn.filereadable(dir .. '/calls') == 0 then return {} end
    return vim.tbl_filter(
      function(call) return not call:find('^capabilities') end,
      vim.fn.readfile(dir .. '/calls')
    )
  end

  local function policy()
    h.write(dir .. '/policy/p.rego', POLICY)
    h.write(dir .. '/policy/lib.rego', { 'package lib' })
    h.write(dir .. '/policy/notes.md', { '# notes' })
    vim.cmd.edit(vim.fn.fnameescape(dir .. '/policy/p.rego'))
    return vim.api.nvim_get_current_buf()
  end

  it('reads the package of a policy', function()
    assert.equals('k8s.deny', rego.package_of(POLICY))
    assert.is_nil(rego.package_of({ '# nothing' }))
  end)

  it('lists the other policies of the folder', function()
    h.write(dir .. '/p/a.rego', {})
    h.write(dir .. '/p/b.rego', {})
    h.write(dir .. '/p/c.txt', {})
    assert.same({ dir .. '/p/b.rego' }, rego.siblings(dir .. '/p/a.rego'))
  end)

  it(
    'evaluates the policy as it is in its buffer, the query given last',
    function()
      opa({ [[echo '{"deny": ["no pods"]}']] })
      h.write(dir .. '/in.yaml', { 'kind: Pod' })
      local bufnr = policy()
      local playground = assert(rego.open(dir .. '/in.yaml'))
      assert.is_true(vim.wait(5000, function() return #calls() > 0 end, 10))
      assert.is_true(
        vim.wait(
          5000,
          function()
            return vim.api.nvim_buf_get_lines(playground.result, 0, 1, false)[1]
              == '{"deny": ["no pods"]}'
          end,
          10
        )
      )
      local call = calls()[1]
      local copy = playground.dir .. '/p.rego'
      assert.equals(
        (
          'eval --capabilities %s --format pretty --data %s --data %s'
          .. ' --input %s -- data.k8s.deny'
        ):format(
          rego.capabilities_file,
          copy,
          dir .. '/policy/lib.rego',
          dir .. '/in.yaml'
        ),
        call
      )
      assert.same(POLICY, vim.fn.readfile(copy))

      -- An edit of the policy is evaluated as it is now, unsaved
      vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { '# more' })
      vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr })
      assert.is_true(vim.wait(5000, function() return #calls() > 1 end, 10))
      assert.equals('# more', vim.fn.readfile(copy)[#POLICY + 1])

      rego.close(playground)
      assert.equals(0, vim.fn.isdirectory(playground.dir))
      assert.is_nil(next(rego.open_playgrounds))
    end
  )

  it('keeps a policy off the network and the environment', function()
    opa({ [[echo '{}']] })
    policy()
    rego.open()
    assert.is_true(vim.wait(5000, function() return #calls() > 0 end, 10))
    local file = assert(rego.capabilities_file)
    assert.is_truthy(calls()[1]:find('--capabilities ' .. file, 1, true))
    local written = vim.json.decode(table.concat(vim.fn.readfile(file), '\n'))
    assert.same(
      { 'count', 'net.cidr_contains' },
      vim.tbl_map(function(builtin) return builtin.name end, written.builtins)
    )
    assert.same({}, written.allow_net)
    assert.same({ 'rego_v1' }, written.features)
  end)

  it('runs nothing when the capabilities cannot be read', function()
    opa(
      { [[echo '{}']] },
      [[case "$1" in capabilities) echo 'unknown command' >&2; exit 1;; esac]]
    )
    local bufnr = policy()
    local playground = assert(rego.open())
    assert.is_true(vim.wait(5000, function()
      local first =
        vim.api.nvim_buf_get_lines(playground.result, 0, 1, false)[1]
      return (first or ''):find('^Not run: the capabilities of opa') ~= nil
    end, 10))
    assert.same({}, calls())

    local done = false
    vim.api.nvim_set_current_buf(bufnr)
    rego.test(function() done = true end)
    assert.is_true(vim.wait(5000, function() return done end, 10))
    assert.is_truthy(notes[#notes]:find('^Not run: the capabilities of opa'))
    assert.same({}, calls())
  end)

  it('reads an input open in a buffer from the buffer', function()
    opa({ [[echo '{}']] })
    h.write(dir .. '/in.yaml', { 'kind: Pod' })
    vim.cmd.edit(vim.fn.fnameescape(dir .. '/in.yaml'))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'kind: Deployment' })
    policy()
    rego.open(dir .. '/in.yaml')
    assert.is_true(
      vim.wait(
        5000,
        function()
          return vim.fn.filereadable(dir .. '/stdin') == 1
            and #vim.fn.readfile(dir .. '/stdin') > 0
        end,
        10
      )
    )
    assert.same({ 'kind: Deployment' }, vim.fn.readfile(dir .. '/stdin'))
    assert.is_truthy(calls()[1]:find('--stdin-input', 1, true))
  end)

  it('names the policy, not its copy, in an error', function()
    opa({
      'for arg; do case "$arg" in */p.rego) copy=$arg;; esac; done',
      [[echo "1 error occurred: $copy:3: rego_parse_error" >&2]],
      'exit 2',
    })
    policy()
    local playground = assert(rego.open())
    local expected = dir .. '/policy/p.rego:3: rego_parse_error'
    assert.is_true(vim.wait(5000, function()
      local first =
        vim.api.nvim_buf_get_lines(playground.result, 0, 1, false)[1]
      return (first or ''):find(expected, 1, true) ~= nil
    end, 10))
  end)

  it('shows why an evaluation failed', function()
    opa({ [[echo 'rego_parse_error: unexpected eof' >&2]], 'exit 2' })
    policy()
    local playground = assert(rego.open())
    assert.is_true(
      vim.wait(
        5000,
        function()
          return (
            vim.api.nvim_buf_get_lines(playground.result, 0, 1, false)[1] or ''
          ):find('rego_parse_error', 1, true) ~= nil
        end,
        10
      )
    )
  end)

  it('says what it cannot evaluate', function()
    opa({})
    vim.cmd.edit(vim.fn.fnameescape(dir .. '/notes.md'))
    assert.is_nil(rego.open())
    policy()
    assert.is_nil(rego.open(dir .. '/missing.yaml'))
    assert.same(
      { 'Not a Rego policy', 'No such input: ' .. dir .. '/missing.yaml' },
      notes
    )
  end)

  it(
    'reads the tests of an answer, an error as a failure',
    function()
      assert.same(
        {
          { name = 'data.p.test_a', file = '/x.rego', row = 3, fail = false },
          { name = 'data.p.test_b', fail = true },
          { name = 'data.p.test_c', fail = true, error = 'boom' },
        },
        rego.tests({
          {
            package = 'data.p',
            name = 'test_a',
            location = { file = '/x.rego', row = 3 },
          },
          { package = 'data.p', name = 'test_b', fail = true },
          { package = 'data.p', name = 'test_c', error = { message = 'boom' } },
        })
      )
    end
  )

  describe('tests', function()
    it('puts the failing tests in the quickfix list', function()
      opa({
        [[echo '[{"package":"data.p","name":"test_bad","fail":true,"location":{"file":"]]
          .. dir
          .. [[/policy/p.rego","row":5}},{"package":"data.p","name":"test_ok"}]']],
        'exit 2',
      })
      policy()
      local done = false
      rego.test(function() done = true end)
      assert.is_true(vim.wait(5000, function() return done end, 10))
      assert.equals('1 of 2 tests failed: see the quickfix list', notes[#notes])
      local items = vim.fn.getqflist()
      assert.equals(1, #items)
      assert.equals(5, items[1].lnum)
      assert.equals('data.p.test_bad: FAIL', items[1].text)
    end)

    it('runs the tests with the capabilities of the session', function()
      opa({ [[echo '[{"package":"data.p","name":"test_ok"}]']] })
      policy()
      local done = false
      rego.test(function() done = true end)
      assert.is_true(vim.wait(5000, function() return done end, 10))
      local file = assert(rego.capabilities_file)
      assert.equals(
        ('test --capabilities %s --format json -- %s'):format(
          file,
          dir .. '/policy'
        ),
        calls()[1]
      )
      assert.equals(
        ('test --capabilities %s --coverage --format json -- %s'):format(
          file,
          dir .. '/policy'
        ),
        calls()[2]
      )
    end)

    it('marks the lines no test reached once every test passes', function()
      opa({
        'case "$*" in',
        [[  *--coverage*) echo '{"coverage": 60, "files": {"]]
          .. dir
          .. [[/policy/p.rego": {"not_covered": [{"start": {"row": 5}, "end": {"row": 6}}]}}}';;]],
        [[  *) echo '[{"package":"data.p","name":"test_ok"}]';;]],
        'esac',
      })
      local bufnr = policy()
      local done = false
      rego.test(function() done = true end)
      assert.is_true(vim.wait(5000, function() return done end, 10))
      assert.equals(
        '1 tests passed, 60.0% covered, 2 lines marked',
        notes[#notes]
      )
      local marks = vim.api.nvim_buf_get_extmarks(bufnr, rego.ns, 0, -1, {})
      assert.same({ 4, 5 }, vim.tbl_map(function(m) return m[2] end, marks))
      rego.clear()
      assert.same({}, vim.api.nvim_buf_get_extmarks(bufnr, rego.ns, 0, -1, {}))
    end)

    it('fails loudly on a policy opa cannot parse', function()
      opa({
        [[echo '1 error occurred: p.rego:3: rego_parse_error' >&2]],
        'exit 2',
      })
      policy()
      local done = false
      rego.test(function() done = true end)
      assert.is_true(vim.wait(5000, function() return done end, 10))
      assert.is_truthy(notes[#notes]:find('^opa test failed: 1 error occurred'))
    end)

    it('asks for the policy to be written first', function()
      opa({})
      local bufnr = policy()
      vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { '# unsaved' })
      rego.test()
      assert.equals(
        'Write the policy first: opa test reads the files on disk',
        notes[#notes]
      )
      assert.same({}, calls())
    end)
  end)
end)
