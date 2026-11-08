local h = require('helpers')

describe('lsp.ruby_lsp', function()
  local config, dir, cleanup, restores, jobs, asked

  before_each(function()
    config = dofile(h.root .. '/lsp/ruby_lsp.lua')
    dir, cleanup = h.tmpdir()
    jobs, asked = {}, {}
    restores = {
      h.stub(vim.fn, 'jobstart', function(cmd, opts)
        table.insert(jobs, { cmd = cmd, opts = opts })
        return 1
      end),
      h.stub(vim.fn, 'confirm', function(msg)
        table.insert(asked, msg)
        return 2
      end),
    }
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.cmd('silent! only')
    vim.cmd('silent! %bwipeout!')
    cleanup()
  end)

  --- Run the client command `name` with `arguments`, as a code lens would
  local function run(name, arguments)
    config.commands[name](
      { command = name, arguments = arguments },
      { client_id = 1, bufnr = 0 }
    )
  end

  it('opens the route a lens points at, on its line', function()
    local routes = dir .. '/config/routes.rb'
    h.write(routes, { 'a', 'b', 'get "/x"' })
    run('rubyLsp.openFile', { { 'file://' .. routes .. '#L3' } })
    assert.equals(routes, vim.api.nvim_buf_get_name(0))
    assert.equals(3, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it('lets one pick among the views of an action', function()
    local picked
    table.insert(
      restores,
      h.stub(vim.ui, 'select', function(items, _, on_choice)
        picked = items
        on_choice(items[2])
      end)
    )
    local one, two = dir .. '/index.html.erb', dir .. '/index.json.jbuilder'
    h.write(one, {})
    h.write(two, {})
    run('rubyLsp.openFile', { { 'file://' .. one, 'file://' .. two } })
    assert.same({ one, two }, picked)
    assert.equals(two, vim.api.nvim_buf_get_name(0))
  end)

  it('runs a test in a terminal, from the project root', function()
    table.insert(
      restores,
      h.stub(
        vim.lsp,
        'get_client_by_id',
        function() return { root_dir = dir } end
      )
    )
    run('rubyLsp.runTestInTerminal', {
      dir .. '/test/a_test.rb',
      'ATest#test_x',
      'bundle exec ruby -Itest test/a_test.rb --name ATest#test_x',
      {},
    })
    assert.equals(
      'bundle exec ruby -Itest test/a_test.rb --name ATest#test_x',
      jobs[1].cmd
    )
    assert.equals(dir, jobs[1].opts.cwd)
    assert.is_true(jobs[1].opts.term)
  end)

  it('debugs a test under rdbg', function()
    run('rubyLsp.debugTest', { 'a_test.rb', 'ATest', 'ruby a_test.rb', {} })
    assert.equals('rdbg -c -- ruby a_test.rb', jobs[1].cmd)
  end)

  it('runs a migration only once it is confirmed', function()
    run('rubyLsp.runTask', { 'bin/rails db:migrate VERSION=1' })
    assert.matches('db:migrate VERSION=1', asked[1])
    assert.same({}, jobs)
    restores[#restores + 1] = h.stub(vim.fn, 'confirm', function() return 1 end)
    run('rubyLsp.runTask', { 'bin/rails db:migrate VERSION=1' })
    assert.equals('bin/rails db:migrate VERSION=1', jobs[1].cmd)
  end)
end)
