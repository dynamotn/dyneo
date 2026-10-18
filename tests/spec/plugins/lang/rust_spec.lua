local h = require('helpers')

describe('plugins.lang.rust', function()
  local restores, specs, executables

  --- The spec of `name` among those `plugins.lang.rust` returns
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
    executables = {}
    restores = {
      h.stub(
        vim.fn,
        'executable',
        function(name) return vim.list_contains(executables, name) and 1 or 0 end
      ),
    }
    specs = dofile(h.root .. '/lua/plugins/lang/rust.lua')
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.g.rustaceanvim = nil
    vim.cmd('silent! %bwipeout!')
  end)

  it(
    'leaves rust-analyzer to rustaceanvim',
    function()
      assert.is_true(spec('neovim/nvim-lspconfig').opts.setup.rust_analyzer())
    end
  )

  it(
    'maps the RustLsp commands on the buffer the server attaches to',
    function()
      local ran = {}
      table.insert(
        restores,
        h.stub(vim.cmd, 'RustLsp', function(cmd) table.insert(ran, cmd) end)
      )
      local bufnr = h.buffer({ name = 'main.rs' })
      vim.api.nvim_set_current_buf(bufnr)
      spec('mrcjkb/rustaceanvim').opts.server.on_attach(nil, bufnr)
      for _, lhs in ipairs({
        '<localleader>a',
        '<leader>dR',
        '<localleader>e',
        '<localleader>m',
        '<localleader>r',
        '<localleader>t',
        '<localleader>c',
      }) do
        local map = vim.fn.maparg(lhs, 'n', false, true)
        assert.are.equal(1, map.buffer, lhs)
        map.callback()
      end
      assert.same({
        'codeAction',
        'debuggables',
        'explainError',
        'expandMacro',
        'runnables',
        'testables',
        'openCargo',
      }, ran)
    end
  )

  it(
    'hands rustaceanvim its settings and says when the server is missing',
    function()
      local errors = {}
      table.insert(
        restores,
        h.stub(
          require('util.plugin'),
          'error',
          function(msg, opts)
            table.insert(errors, { msg = msg, title = opts.title })
          end
        )
      )
      vim.g.rustaceanvim = { tools = { x = 1 } }
      local rustaceanvim = spec('mrcjkb/rustaceanvim')
      rustaceanvim.config(nil, rustaceanvim.opts)
      assert.are.equal(1, vim.g.rustaceanvim.tools.x)
      assert.is_true(
        vim.g.rustaceanvim.server.default_settings['rust-analyzer'].checkOnSave
      )
      assert.are.equal(1, #errors)
      assert.matches('rust%-analyzer', errors[1].msg)
      assert.are.equal('DyNeo Rust', errors[1].title)

      executables = { 'rust-analyzer' }
      rustaceanvim.config(nil, nil)
      assert.are.equal(1, #errors)
    end
  )

  it('tests through rustaceanvim only where cargo is', function()
    local opts = {}
    spec('nvim-neotest/neotest').opts(nil, opts)
    assert.is_false(opts.adapters['rustaceanvim.neotest'])
    executables = { 'cargo' }
    spec('nvim-neotest/neotest').opts(nil, opts)
    assert.same({}, opts.adapters['rustaceanvim.neotest'])
  end)
end)
