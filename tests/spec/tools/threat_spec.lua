local h = require('helpers')

describe('tools.threat', function()
  local threat, war, dir, cleanup, notes, restore

  before_each(function()
    h.unload('tools.threat', 'tools.war', 'tools.adr')
    threat = require('tools.threat')
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

  it('asks every STRIDE question, under its category', function()
    local items =
      war.items(threat.template(1, '2026-10-13', 'Checkout'), threat.CATEGORIES)
    local total = 0
    for _, category in ipairs(threat.CATEGORIES) do
      total = total + #category[2]
    end
    assert.equals(total, #items)
    assert.equals('Spoofing', items[1].pillar)
    assert.equals('Elevation of privilege', items[#items].pillar)
  end)

  it('writes a model of a scope as a decision record', function()
    threat.command({ fargs = { 'new', 'Checkout', 'API' } })
    local file = vim.api.nvim_buf_get_name(0)
    assert.equals(dir .. '/docs/adr/0001-threat-model-checkout-api.md', file)
    assert.equals(
      '# 1. Threat model: Checkout API',
      vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]
    )
  end)

  it('asks for the scope when none is given', function()
    local restore_input = h.stub(
      vim.ui,
      'input',
      function(_, on_confirm) on_confirm('Payments') end
    )
    threat.command({ fargs = { 'new' } })
    restore_input()
    assert.equals(
      '# 1. Threat model: Payments',
      vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]
    )
  end)

  it('lists the open questions of the latest model only', function()
    war.new()
    threat.new('Checkout')
    vim.api.nvim_buf_set_lines(0, 0, -1, false, {
      '# 2. Threat model: Checkout',
      '## Spoofing',
      '- [x] Callers authenticated',
      '- [ ] Tokens expire',
    })
    vim.cmd('silent write')
    vim.cmd.edit(dir .. '/README.md')
    threat.command({ fargs = {} })
    local items = vim.fn.getqflist()
    assert.equals(1, #items)
    assert.equals('Spoofing: Tokens expire', items[1].text)
    assert.equals('1 of 2 questions open\nSpoofing 1/2', notes[#notes])
  end)

  it('takes no other record for the model', function()
    h.write(dir .. '/docs/adr/0001-threat-modeling-with-owasp.md', {
      '# 1. Threat modeling with OWASP tools',
      '## Spoofing',
      '- [x] Read the cheat sheet',
    })
    h.write(dir .. '/SECURITY.md', { '# 1. Threat model: see docs/adr' })
    vim.cmd.edit(dir .. '/SECURITY.md')
    threat.command({ fargs = {} })
    assert.same({ 'No threat model yet: `:DyThreat new` writes one' }, notes)
  end)

  it('passes no model without a checklist', function()
    h.write(dir .. '/docs/adr/0001-threat-model-checkout.md', {
      '# 1. Threat model: Checkout',
      '## Context',
      'Nothing to tick.',
    })
    threat.command({ fargs = {} })
    assert.equals(1, #notes)
    assert.is_truthy(
      notes[1]:find('^No checklist in .*0001%-threat%-model%-checkout%.md$')
    )
  end)

  it('turns down a subcommand it does not know', function()
    threat.command({ fargs = { 'nope' } })
    assert.same({ 'Unknown subcommand: nope' }, notes)
  end)

  it('says when there is no model yet', function()
    threat.command({ fargs = {} })
    assert.equals('No threat model yet: `:DyThreat new` writes one', notes[1])
  end)
end)
