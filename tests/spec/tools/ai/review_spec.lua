local h = require('helpers')

describe('tools.ai.review', function()
  local review, dir, cleanup, restores, notes, delivered, path, repo

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
    git('init', '-q')
    h.write(repo .. '/a.txt', { 'one' })
    h.write(
      dir .. '/bin/betterleaks',
      { '#!/bin/sh', 'cat > /dev/null', 'echo "[]"' }
    )
    vim.fn.setfperm(dir .. '/bin/betterleaks', 'rwxr-xr-x')
    path = vim.env.PATH
    vim.env.PATH = dir .. '/bin:' .. path
    notes, delivered = {}, {}
    restores = {
      h.stub(vim, 'notify', function(msg) table.insert(notes, msg) end),
      h.stub(package.loaded, 'util.ai_audit', { record = function() end }),
      h.stub(package.loaded, 'util.project_rtp', {
        current = function() return nil end,
      }),
      h.stub(package.loaded, 'tools.ai', {
        deliver = function(text, what, detail)
          table.insert(delivered, { text = text, what = what, detail = detail })
          return true
        end,
      }),
    }
    h.unload(
      'tools.ai.review',
      'tools.ai.git',
      'tools.ai.check',
      'tools.ai.prompts'
    )
    review = require('tools.ai.review')
    vim.api.nvim_set_current_buf(h.buffer({ name = repo .. '/a.txt' }))
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.env.PATH = path
    vim.cmd('silent! %bwipeout!')
    cleanup()
  end)

  it('sends the staged diff to the chat', function()
    git('add', 'a.txt')
    review.staged()
    assert.is_true(vim.wait(5000, function() return #delivered > 0 end, 20))
    assert.is_truthy(delivered[1].text:find('+one', 1, true))
    assert.is_truthy(delivered[1].text:find('```diff\n', 1, true))
    assert.is_truthy(delivered[1].text:find('a.txt', 1, true))
    assert.equals(repo, delivered[1].what)
    assert.equals('review of 1 staged files', delivered[1].detail)
  end)

  it('says when the diff was cut', function()
    git('add', 'a.txt')
    require('tools.ai.git').MAX_DIFF = 16
    review.staged()
    assert.is_true(vim.wait(5000, function() return #delivered > 0 end, 20))
    assert.is_truthy(notes[1]:find('The diff was cut at 0 KiB', 1, true))
    assert.is_truthy(delivered[1].text:find('(diff cut at 0 KiB)', 1, true))
  end)

  it('says when the prompt is missing', function()
    local prompts = require('tools.ai.prompts')
    table.insert(
      restores,
      h.stub(prompts, 'template', function() return nil end)
    )
    review.staged()
    assert.is_truthy(notes[1]:find('No prompt ' .. review.PROMPT, 1, true))
    assert.same({}, delivered)
  end)

  it('says when the buffer is in no work tree', function()
    vim.api.nvim_set_current_buf(h.buffer({ name = dir .. '/loose.txt' }))
    review.staged()
    assert.is_true(vim.wait(5000, function() return #notes > 0 end, 20))
    assert.is_truthy(notes[1]:find('Not in a git work tree', 1, true))
    assert.same({}, delivered)
  end)

  it('says when nothing is staged', function()
    review.staged()
    assert.is_true(vim.wait(5000, function() return #notes > 0 end, 20))
    assert.equals('Nothing is staged', notes[1])
    assert.same({}, delivered)
  end)
end)
