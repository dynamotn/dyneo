local h = require('helpers')

describe('plugins.lang.sql', function()
  local specs, globals

  --- The spec of `name` among those `plugins.lang.sql` returns
  ---@param name string
  ---@return table
  local function spec(name)
    for _, s in ipairs(specs) do
      if s[1] == name then return s end
    end
    error('no spec ' .. name)
  end

  before_each(function()
    h.globals()
    globals = {}
    for _, name in ipairs({
      'db_ui_auto_execute_table_helpers',
      'db_ui_save_location',
      'db_ui_show_database_icon',
      'db_ui_tmp_query_location',
      'db_ui_use_nerd_fonts',
      'db_ui_use_nvim_notify',
      'db_ui_execute_on_save',
    }) do
      globals[name] = vim.g[name]
    end
    specs = dofile(h.root .. '/lua/plugins/lang/sql.lua')
  end)
  after_each(function()
    for name, value in pairs(globals) do
      vim.g[name] = value
    end
    pcall(vim.api.nvim_del_user_command, 'DBUI')
  end)

  it('keeps the DBUI files under the data directory', function()
    spec('kristijanhusak/vim-dadbod-ui').init()
    local data = vim.fn.stdpath('data')
    assert.are.equal(data .. '/dadbod_ui', vim.g.db_ui_save_location)
    assert.are.equal(data .. '/dadbod_ui/tmp', vim.g.db_ui_tmp_query_location)
    assert.is_false(vim.g.db_ui_execute_on_save)
    assert.are.equal(1, vim.g.db_ui_auto_execute_table_helpers)
  end)

  it('labels the database completion sources', function()
    spec('kristijanhusak/vim-dadbod-completion').init()
    spec('ray-x/cmp-sql').init()
    assert.are.equal('「DB」', DyNeo.completion_sources.Dadbod)
    assert.are.equal('「SQL」', DyNeo.completion_sources.sql)
    local sources = spec('blink.cmp').opts.sources
    assert.same({ 'dadbod', 'sql' }, sources.compat)
    assert.same(sources.per_filetype.sql, sources.per_filetype.mysql)
    assert.is_true(vim.list_contains(sources.per_filetype.plsql, 'dadbod'))
  end)

  it('docks DBUI to the right and the query results below', function()
    local opts = { right = { { ft = 'other' } } }
    spec('edgy.nvim').opts(nil, opts)
    assert.are.equal(2, #opts.right)
    assert.are.equal('dbui', opts.right[2].ft)
    assert.is_true(opts.right[2].pinned)
    assert.same({ { title = 'DB Query Result', ft = 'dbout' } }, opts.bottom)

    local opened = false
    vim.api.nvim_create_user_command('DBUI', function() opened = true end, {})
    opts.right[2].open()
    assert.is_true(opened)
  end)
end)
