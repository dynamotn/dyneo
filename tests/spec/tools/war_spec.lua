local h = require('helpers')

describe('tools.war', function()
  local war, dir, cleanup, notes, restore

  before_each(function()
    h.unload('tools.war', 'tools.adr')
    war = require('tools.war')
    dir, cleanup = h.tmpdir()
    vim.system({ 'git', 'init', '-q' }, { cwd = dir }):wait()
    notes = {}
    restore = h.stub(vim, 'notify', function(msg) table.insert(notes, msg) end)
    vim.cmd.edit(dir .. '/README.md')
  end)
  after_each(function()
    restore()
    vim.cmd('cclose | silent! %bwipeout!')
    cleanup()
  end)

  it('asks every question of every pillar, unticked', function()
    local items = war.items(war.template(1, '2026-10-13'))
    local total = 0
    for _, pillar in ipairs(war.PILLARS) do
      total = total + #pillar[2]
    end
    assert.equals(total, #items)
    assert.is_false(items[1].done)
    assert.equals('Operational excellence', items[1].pillar)
  end)

  it('counts what holds in each pillar', function()
    local items = war.items({
      '## Security',
      '- [x] Keys rotated',
      '- [ ] Data encrypted',
      '## Cost optimization',
      '* [X] Tagged',
      '- [ ] not under a pillar? still counted',
    })
    assert.same({ 'Security 1/2', 'Cost optimization 1/2' }, war.summary(items))
  end)

  it('writes a review as a decision record and opens it', function()
    war.command({ fargs = { 'new' } })
    local file = vim.api.nvim_buf_get_name(0)
    assert.is_truthy(file:find('/docs/adr/0001%-well%-architected%-review%-'))
    local first = vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]
    assert.is_truthy(
      first:find('^# 1%. Well%-Architected review %d+%-%d+%-%d+$')
    )
    assert.equals(
      'Proposed',
      require('tools.adr').parse(vim.fn.readfile(file), file).status
    )
  end)

  it('lists the open questions of the latest review', function()
    war.new()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, {
      '# 1. Well-Architected review 2026-10-13',
      '## Reliability',
      '- [x] Backups restored',
      '- [ ] No single point of failure',
    })
    vim.cmd('silent write')
    vim.cmd.edit(dir .. '/README.md')
    war.command({ fargs = {} })
    local items = vim.fn.getqflist()
    assert.equals(1, #items)
    assert.equals(4, items[1].lnum)
    assert.equals('Reliability: No single point of failure', items[1].text)
    assert.equals('1 of 2 questions open\nReliability 1/2', notes[#notes])
  end)

  it('reads the review, not a loaded buffer named like it', function()
    war.new()
    local file = vim.api.nvim_buf_get_name(0)
    vim.cmd.edit(file .. '.orig')
    vim.cmd.bwipeout(vim.fn.fnameescape(file))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { '## Security', '- [ ] x' })
    war.check()
    assert.equals(#war.items(war.template(1, 'd')), #vim.fn.getqflist())
  end)

  it('says when there is no review yet', function()
    war.check()
    assert.equals('No review yet: `:DyWar new` writes one', notes[1])
  end)
end)
