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

  it('holds flutter-tools off a held buffer until released', function()
    local attached, set_up = {}, nil
    local restores = {
      h.stub(package.loaded, 'flutter-tools', {
        setup = function(opts) set_up = opts end,
      }),
      h.stub(package.loaded, 'flutter-tools.lsp', {
        attach = function()
          table.insert(attached, vim.api.nvim_get_current_buf())
        end,
      }),
    }
    h.unload('util.untrusted')
    local untrusted = require('util.untrusted')
    local flutter_tools = specs()
    flutter_tools.config(nil, flutter_tools.opts)
    assert.are.equal(flutter_tools.opts, set_up)
    local held =
      h.buffer({ name = dir .. '/held/main.dart', filetype = 'dart' })
    local free =
      h.buffer({ name = dir .. '/free/main.dart', filetype = 'dart' })
    untrusted.hold(dir .. '/held')
    -- What its ftplugin calls, in the buffer it runs for
    local lsp = require('flutter-tools.lsp')
    vim.api.nvim_set_current_buf(held)
    lsp.attach()
    vim.api.nvim_set_current_buf(free)
    lsp.attach()
    assert.same({ free }, attached)
    -- Configured again (`:Lazy reload`): wrapped once, not twice
    flutter_tools.config(nil, flutter_tools.opts)
    untrusted.release(dir .. '/held')
    assert.same({ free, held }, attached)
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.cmd('silent! %bwipeout!')
  end)

  it('hands dartls to flutter-tools when flutter is there', function()
    fake('dart')
    fake('flutter')
    local flutter_tools, skip_dartls = specs()
    assert.is_true(flutter_tools.cond())
    assert.is_true(skip_dartls())
  end)
end)
