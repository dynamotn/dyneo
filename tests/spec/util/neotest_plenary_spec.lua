local h = require('helpers')

describe('util.neotest_plenary', function()
  local dir, cleanup, cwd, restores, created, globbed, adapter

  before_each(function()
    dir, cleanup = h.tmpdir()
    created, globbed = {}, 0
    restores = {
      h.stub(package.loaded, 'nio', {
        fn = {
          globpath = function(...)
            globbed = globbed + 1
            return vim.fn.globpath(...)
          end,
        },
      }),
      h.stub(package.loaded, 'neotest-plenary.adapter', function(config)
        table.insert(created, config)
        return {
          name = 'neotest-plenary',
          build_spec = function() return { command = { config.min_init } } end,
        }
      end),
    }
    -- Another project's init in the working directory, which a glob from
    -- there would find first
    h.write(dir .. '/a/tests/minimal_init.lua')
    h.write(dir .. '/project/lua/x.lua')
    h.write(dir .. '/project/tests/minimal_init.lua')
    h.write(dir .. '/project/tests/spec/x_spec.lua')
    cwd = vim.fn.getcwd()
    vim.cmd.cd(dir)
    h.unload('util.neotest_plenary')
    adapter = require('util.neotest_plenary')
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.cmd.cd(cwd)
    cleanup()
    h.unload('util.neotest_plenary')
  end)

  ---@param path string
  local function args(path)
    return { tree = { data = function() return { path = path } end } }
  end

  it("runs from the test file's project with its own init", function()
    local spec =
      adapter.build_spec(args(dir .. '/project/tests/spec/x_spec.lua'))
    assert.same({ dir .. '/project/tests/minimal_init.lua' }, spec.command)
    assert.equals(dir .. '/project', spec.cwd)
  end)

  it('looks for the init once per project', function()
    local path = dir .. '/project/tests/spec/x_spec.lua'
    adapter.build_spec(args(path))
    local first = globbed
    adapter.build_spec(args(path))
    assert.equals(first, globbed)
  end)

  it('runs without an init when the project has none', function()
    vim.fn.delete(dir .. '/project/tests/minimal_init.lua')
    local spec =
      adapter.build_spec(args(dir .. '/project/tests/spec/x_spec.lua'))
    assert.same({ 'NONE' }, spec.command)
  end)

  it(
    "hands the rest to neotest-plenary's own adapter",
    function() assert.equals('neotest-plenary', adapter.name) end
  )
end)
