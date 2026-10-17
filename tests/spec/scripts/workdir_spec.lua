local h = require('helpers')

describe('scripts/lib/workdir.lua', function()
  local workdir = dofile(h.root .. '/scripts/lib/workdir.lua')
  local appname, made

  before_each(function() appname = vim.env.NVIM_APPNAME end)
  after_each(function()
    vim.env.NVIM_APPNAME = appname
    if made then vim.fn.delete(made, 'rf') end
  end)

  --- The configuration a Neovim started on `config` with this environment
  --- would load
  local function loaded(config)
    local result = vim
      .system({
        vim.v.progpath,
        '--headless',
        '-i',
        'NONE',
        '-u',
        'NORC',
        '--cmd',
        'lua io.stdout:write(vim.fn.stdpath("config")) vim.cmd.qall()',
      }, { env = { XDG_CONFIG_HOME = config }, text = true })
      :wait(10000)
    return vim.uv.fs_realpath(result.stdout)
  end

  it('links the tree where Neovim looks for its configuration', function()
    for _, name in ipairs({ vim.NIL, 'nvim-stable' }) do
      vim.env.NVIM_APPNAME = name ~= vim.NIL and name or nil
      local dir, config = workdir.config(h.root)
      made = dir
      assert.equals(vim.uv.fs_realpath(h.root), loaded(config))
      vim.fn.delete(dir, 'rf')
    end
  end)
end)
