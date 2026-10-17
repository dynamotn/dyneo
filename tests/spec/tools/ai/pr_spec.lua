local h = require('helpers')

describe('tools.ai.pr', function()
  local pr, dir, cleanup, restores, notes, asked, path, repo

  local function git(...)
    local result = vim
      .system(vim.list_extend({ 'git', '-C', repo }, { ... }), { text = true })
      :wait()
    assert.equals(0, result.code, result.stderr)
  end

  before_each(function()
    dir, cleanup = h.tmpdir()
    repo = dir .. '/repo'
    vim.fn.mkdir(repo, 'p')
    git('init', '-q', '-b', 'main')
    git('config', 'user.email', 'spec@example.com')
    git('config', 'user.name', 'Spec')
    h.write(repo .. '/a.txt', { 'one' })
    git('add', 'a.txt')
    git('commit', '-q', '-m', 'feat(a): add one')
    git('switch', '-q', '-c', 'feat/two')
    h.write(repo .. '/a.txt', { 'one', 'two' })
    git('commit', '-q', '-am', 'feat(a): add two')
    h.write(
      dir .. '/bin/betterleaks',
      { '#!/bin/sh', 'cat > /dev/null', 'echo "[]"' }
    )
    vim.fn.setfperm(dir .. '/bin/betterleaks', 'rwxr-xr-x')
    path = vim.env.PATH
    vim.env.PATH = dir .. '/bin:' .. path
    notes, asked = {}, {}
    restores = {
      h.stub(vim, 'notify', function(msg) table.insert(notes, msg) end),
      h.stub(package.loaded, 'util.ai_audit', { record = function() end }),
      h.stub(package.loaded, 'util.project_rtp', {
        current = function() return nil end,
      }),
      h.stub(package.loaded, 'tools.ai', {
        headless = function(text, root, label, on_done)
          table.insert(asked, { text = text, root = root, label = label })
          on_done('```\n# feat(a): add two\n\nAdds two.\n```\n')
        end,
      }),
    }
    h.unload(
      'tools.ai.pr',
      'tools.ai.git',
      'tools.ai.check',
      'tools.ai.prompts'
    )
    pr = require('tools.ai.pr')
    vim.api.nvim_set_current_buf(h.buffer({ name = repo .. '/a.txt' }))
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.env.PATH = path
    vim.cmd('silent! tabonly!')
    vim.cmd('silent! only!')
    vim.cmd('silent! %bwipeout!')
    cleanup()
  end)

  it('writes up the branch against main, in a buffer to edit', function()
    pr.describe()
    assert.is_true(vim.wait(5000, function() return #asked > 0 end, 20))
    local text = asked[1].text
    assert.is_truthy(text:find('`feat/two`, going into `main`', 1, true))
    assert.is_truthy(text:find('- feat(a): add two', 1, true))
    assert.is_nil(text:find('add one', 1, true))
    assert.is_truthy(text:find('+two', 1, true))
    assert.is_nil(text:find('Conventional', 1, true))
    assert.equals('pull request into main', asked[1].label)
    local bufnr = vim.api.nvim_get_current_buf()
    assert.equals('markdown', vim.bo[bufnr].filetype)
    assert.is_true(vim.bo[bufnr].modifiable)
    assert.equals('hide', vim.bo[bufnr].bufhidden)
    assert.same(
      { '# feat(a): add two', '', 'Adds two.' },
      vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    )
  end)

  it('compares with the branch it is given', function()
    pr.describe('feat/two')
    assert.is_true(vim.wait(5000, function() return #notes > 0 end, 20))
    assert.equals('Nothing changed since feat/two', notes[1])
    assert.same({}, asked)
  end)
end)
