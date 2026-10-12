local h = require('helpers')

describe('plugins.lang.dart', function()
  local dir, cleanup, path

  before_each(function()
    h.globals()
    dir, cleanup = h.tmpdir()
    vim.fn.mkdir(dir .. '/bin', 'p')
    path = vim.env.PATH
    vim.env.PATH = dir .. '/bin'
  end)
  after_each(function()
    vim.env.PATH = path
    cleanup()
  end)

  local function fake(name)
    h.write(dir .. '/bin/' .. name, { '#!/bin/sh' })
    vim.fn.setfperm(dir .. '/bin/' .. name, 'rwxr-xr-x')
  end

  local function specs()
    local found = {}
    for _, spec in ipairs(dofile(h.root .. '/lua/plugins/lang/dart.lua')) do
      found[spec[1]] = spec
    end
    return found['akinsho/flutter-tools.nvim'],
      found['neovim/nvim-lspconfig'].opts.setup.dartls
  end

  it('leaves dartls to lspconfig with only the Dart SDK', function()
    fake('dart')
    local flutter_tools, skip_dartls = specs()
    assert.is_false(flutter_tools.cond())
    assert.is_false(skip_dartls())
  end)

  it('hands dartls to flutter-tools when flutter is there', function()
    fake('dart')
    fake('flutter')
    local flutter_tools, skip_dartls = specs()
    assert.is_true(flutter_tools.cond())
    assert.is_true(skip_dartls())
  end)
end)
