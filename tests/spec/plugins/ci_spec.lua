local h = require('helpers')

describe('plugins.toolbox.git: ci.nvim', function()
  local dir, cleanup, cwd, restore, forge

  before_each(function()
    dir, cleanup = h.tmpdir()
    for _, args in ipairs({
      { 'init', '--quiet' },
      { 'remote', 'add', 'origin', 'https://gitlab.com/o/r.git' },
      { 'remote', 'add', 'gh', 'https://github.com/o/r.git' },
    }) do
      vim.system(vim.list_extend({ 'git', '-C', dir }, args)):wait(10000)
    end
    cwd = vim.fn.getcwd()
    vim.cmd.cd(dir)
    forge = {
      host = function() return 'fallback' end,
      host_of = function(url) return url:match('//([^/]+)') end,
    }
    restore = h.stub(package.loaded, 'ci.forge', forge)
    for _, spec in ipairs(dofile(h.root .. '/lua/plugins/toolbox/git.lua')) do
      if spec.name == 'ci.nvim' then spec.config() end
    end
  end)
  after_each(function()
    restore()
    vim.cmd.cd(cwd)
    cleanup()
  end)

  it(
    'takes the first remote in order of preference, in one call',
    function() assert.equals('github.com', forge.host()) end
  )
end)
