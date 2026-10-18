local h = require('helpers')

describe('lsp.sonarlint', function()
  local dir, cleanup, restores, asked, config

  before_each(function()
    dir, cleanup = h.tmpdir()
    asked = 0
    restores = {
      h.stub(vim.fn, 'stdpath', function() return dir end),
      h.stub(vim.fn, 'inputsecret', function()
        asked = asked + 1
        return 'secret-value'
      end),
      h.stub(vim, 'notify', function() end),
    }
    config = dofile(h.root .. '/lsp/sonarlint.lua')
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    cleanup()
  end)

  local get_token = function(org)
    return config.handlers['sonarlint/getTokenForServer'](nil, { org })
  end

  it('keeps a token under the name of its organization', function()
    assert.are.equal('secret-value', get_token('my-org.eu'))
    assert.are.equal(1, asked)
    assert.are.equal(
      1,
      vim.fn.filereadable(dir .. '/sonarlint/tokens/my-org.eu')
    )
    -- Read back, not asked again
    assert.are.equal('secret-value', get_token('my-org.eu'))
    assert.are.equal(1, asked)
  end)

  it('refuses a name reaching outside the token folder', function()
    h.write(dir .. '/outside', { 'not-a-token' })
    for _, name in ipairs({ '../../outside', '..', 'a/b', '' }) do
      assert.is_nil(get_token(name), name)
    end
    assert.are.equal(0, asked)
    assert.same({}, vim.fn.readdir(dir .. '/sonarlint/tokens'))
  end)

  it('falls back to a token named neovim without an organization', function()
    h.write(dir .. '/sonarlint/tokens/neovim', { 'default-token' })
    assert.are.equal('default-token', get_token(nil))
    assert.are.equal(0, asked)
  end)

  it('says so when nothing was typed', function()
    local said = {}
    table.insert(
      restores,
      h.stub(vim.fn, 'inputsecret', function()
        asked = asked + 1
        return ''
      end)
    )
    table.insert(
      restores,
      h.stub(vim, 'notify', function(message) table.insert(said, message) end)
    )
    assert.is_nil(get_token('acme'))
    assert.are.equal(1, asked)
    assert.same({ 'Token not found.', 'Token not found.' }, said)
    assert.are.equal(0, vim.fn.filereadable(dir .. '/sonarlint/tokens/acme'))
  end)

  it('says so when the token file cannot be written', function()
    local said = {}
    table.insert(
      restores,
      h.stub(vim, 'notify', function(message) table.insert(said, message) end)
    )
    -- A directory in the way of the file
    vim.fn.mkdir(dir .. '/sonarlint/tokens/acme', 'p')
    assert.is_nil(get_token('acme'))
    assert.are.equal(1, asked)
    assert.truthy(said[1]:find('Token not saved: cannot write', 1, true))
  end)

  it('passes the analyzers once Mason installed the extension', function()
    local extension = dir
      .. '/mason/packages/sonarlint-language-server/extension'
    vim.fn.mkdir(extension, 'p')
    table.insert(
      restores,
      h.stub(
        package.loaded,
        'util.plugin',
        { has = function() return true end }
      )
    )
    local cmd = dofile(h.root .. '/lsp/sonarlint.lua').cmd
    assert.are.equal('-analyzers', cmd[3])
    assert.is_true(#cmd > 4)
    for _, jar in ipairs(vim.list_slice(cmd, 4)) do
      assert.truthy(jar:find(extension .. '/analyzers/', 1, true), jar)
      assert.truthy(jar:match('%.jar$'), jar)
    end
  end)

  it('answers the simple questions of the server', function()
    assert.is_true(
      config.handlers['sonarlint/canShowMissingRequirementsNotification']()
    )
    assert.is_true(config.handlers['sonarlint/isOpenInEditor']())
  end)

  it('opens the description of a rule in the browser', function()
    local opened
    table.insert(
      restores,
      h.stub(vim.ui, 'open', function(url) opened = url end)
    )
    config.handlers['sonarlint/showRuleDescription'](nil, { key = 'go:S1' })
    assert.are.equal(
      'https://next.sonarqube.com/sonarqube/coding_rules?q=go:S1&open=go:S1',
      opened
    )
  end)

  describe('listAllRules', function()
    after_each(function() vim.cmd('silent! only') end)

    it('reports a failed request', function()
      local said
      table.insert(
        restores,
        h.stub(
          vim,
          'notify',
          function(message, level) said = { message, level } end
        )
      )
      local windows = #vim.api.nvim_list_wins()
      config.handlers['sonarlint/listAllRules']({ message = 'no server' })
      assert.same(
        { 'Cannot request the list of rules: no server', vim.log.levels.ERROR },
        said
      )
      config.handlers['sonarlint/listAllRules']({ code = 1 })
      assert.truthy(said[1]:find('code = 1', 1, true))
      assert.are.equal(windows, #vim.api.nvim_list_wins())
    end)

    it('lists the rules per language in a split', function()
      local windows = #vim.api.nvim_list_wins()
      config.handlers['sonarlint/listAllRules'](nil, {
        go = {
          { key = 'go:S1', name = 'First', activeByDefault = true },
          { key = 'go:S2', name = 'Second' },
        },
      })
      assert.are.equal(windows + 1, #vim.api.nvim_list_wins())
      local buf = vim.api.nvim_get_current_buf()
      assert.are.equal('markdown', vim.bo[buf].filetype)
      assert.is_false(vim.bo[buf].modifiable)
      assert.same({
        '',
        '# go',
        '',
        ' - go:S1: First (active by default)',
        ' - go:S2: Second',
        '',
      }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      assert.is_not_nil(vim.fn.maparg('q', 'n', false, true).buffer)
    end)
  end)

  describe('buffer commands', function()
    local bufnr, notified
    before_each(function()
      bufnr = h.buffer()
      notified = {}
      config.on_attach({
        notify = function(_, method, params)
          table.insert(notified, { method, params })
        end,
      }, bufnr)
      vim.api.nvim_set_current_buf(bufnr)
    end)

    it('turns a rule off through the server configuration', function()
      vim.cmd('DySonarlintDeactivateRule go:S1')
      assert.same({
        {
          'workspace/didChangeConfiguration',
          {
            settings = {
              sonarlint = { rules = { ['go:S1'] = { level = 'off' } } },
            },
          },
        },
      }, notified)
    end)

    it('stores a token typed for an organization', function()
      vim.cmd('DySonarlintToken acme')
      assert.are.equal(1, asked)
      assert.same(
        { 'secret-value' },
        vim.fn.readfile(dir .. '/sonarlint/tokens/acme')
      )
    end)

    it('refuses a token name reaching outside the folder', function()
      local said
      table.insert(
        restores,
        h.stub(vim, 'notify', function(message) said = message end)
      )
      vim.cmd('DySonarlintToken ../x')
      assert.are.equal(0, asked)
      assert.truthy(said:find('not a token name', 1, true))
    end)
  end)
end)
