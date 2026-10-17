local h = require('helpers')

-- The lazy.nvim clone runs before anything is on screen: it has a deadline,
-- and a clone that misses it leaves nothing behind that passes for an install
describe('config.lazy bootstrap', function()
  local dir, cleanup, restores, echoed, cmds

  before_each(function()
    dir, cleanup = h.tmpdir()
    echoed, cmds = {}, {}
    restores = {
      h.stub(vim.fn, 'stdpath', function() return dir end),
      h.stub(
        vim,
        'system',
        h.system_double(function(cmd, opts)
          table.insert(cmds, { cmd = cmd, opts = opts })
          vim.fn.mkdir(cmd[#cmd], 'p')
          return { code = 124, signal = 15 }
        end)
      ),
      h.stub(vim.fn, 'getchar', function() return 0 end),
      h.stub(vim.api, 'nvim_echo', function(chunks)
        for _, chunk in ipairs(chunks) do
          table.insert(echoed, chunk[1])
        end
      end),
      h.stub(os, 'exit', function(code) error('exit ' .. code, 0) end),
    }
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    cleanup()
  end)

  it('gives up on a clone past its deadline and says why', function()
    local ok, err = pcall(dofile, h.root .. '/lua/config/lazy.lua')
    assert.is_false(ok)
    assert.are.equal('exit 1', err)
    assert.are.equal('git', cmds[1].cmd[1])
    assert.is_number(cmds[1].opts.timeout)
    assert.truthy(table.concat(echoed):find('took longer than', 1, true))
    assert.is_nil(vim.uv.fs_stat(dir .. '/lazy/lazy.nvim'))
  end)
end)
