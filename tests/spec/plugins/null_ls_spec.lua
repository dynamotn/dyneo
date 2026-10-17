local h = require('helpers')

describe('plugins.lsp.null_ls', function()
  local restores, setup_opts, sensitive

  before_each(function()
    h.globals()
    setup_opts, sensitive = nil, false
    local require_ = require
    restores = {
      h.stub(package.loaded, 'null-ls', {
        setup = function(opts) setup_opts = opts end,
      }),
      h.stub(package.loaded, 'null-ls.utils', {
        root_pattern = function()
          return function() end
        end,
      }),
      h.stub(package.loaded, 'util.sensitive', {
        is_sensitive = function() return sensitive end,
      }),
      -- Every source is a table naming itself and what `with` was given
      h.stub(_G, 'require', function(name)
        local source = name:match('^null%-ls%.builtins%.(.+)$')
          or name:match('^tools%.([%w_]+%..+)$')
        if not source then return require_(name) end
        return {
          with = function(opts)
            return vim.tbl_extend('force', opts, { name = source })
          end,
        }
      end),
    }
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
  end)

  --- The sources none-ls is set up with, by `type.name`
  ---@return table<string, table>
  local function sources()
    local spec
    for _, plugin in ipairs(dofile(h.root .. '/lua/plugins/lsp/null_ls.lua')) do
      if plugin[1] == 'nvimtools/none-ls.nvim' then spec = plugin end
    end
    spec.config(nil, {})
    local by_name = {}
    for _, source in ipairs(setup_opts.sources) do
      by_name[source.name] = source
    end
    return by_name
  end

  it('looks words up online only in prose, never in a secret', function()
    local dictionary = sources()['hover.dictionary']
    -- Not every filetype, which none-ls reads an empty list as
    assert.is_true(#dictionary.filetypes > 0)
    assert.is_true(vim.list_contains(dictionary.filetypes, 'markdown'))
    assert.is_false(vim.list_contains(dictionary.filetypes, 'yaml'))
    assert.is_function(dictionary.runtime_condition)
    assert.is_true(dictionary.runtime_condition({ bufnr = 0 }))
    sensitive = true
    assert.is_false(dictionary.runtime_condition({ bufnr = 0 }))
  end)

  it(
    'gives a `*` source of no filetypes of its own every filetype',
    function() assert.same({}, sources()['diagnostics.trail_space'].filetypes) end
  )
end)
