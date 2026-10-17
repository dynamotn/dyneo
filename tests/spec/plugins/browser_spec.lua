local h = require('helpers')

describe('plugins.integration.browser: open.nvim', function()
  local restore

  --- The open.nvim spec, read with `$JIRA_URL` set to `url`
  ---@param url? string
  ---@return table
  local function spec(url)
    restore = h.stub(vim.env, 'JIRA_URL', url)
    for _, plugin in
      ipairs(dofile(h.root .. '/lua/plugins/integration/browser.lua'))
    do
      if plugin[1] == 'ofirgall/open.nvim' then return plugin end
    end
    error('no open.nvim spec')
  end

  before_each(function() h.globals() end)
  after_each(function() restore() end)

  it(
    'opens no Jira without `$JIRA_URL`',
    function() assert.same({}, spec(nil).opts.self_defined_openers) end
  )

  it('opens issue keys on the Jira of `$JIRA_URL`', function()
    local opener =
      spec('https://jira.example.com/browse/').opts.self_defined_openers[1]
    assert.same(
      { 'https://jira.example.com/browse/OPS-12' },
      opener.open_fn('see OPS-12 here')
    )
  end)

  it('maps `gx` in normal mode only', function()
    for _, key in ipairs(spec(nil).keys) do
      if key[1] == 'gx' then
        assert.is_true(
          key.mode == nil or key.mode == 'n',
          vim.inspect(key.mode)
        )
      end
    end
  end)
end)
