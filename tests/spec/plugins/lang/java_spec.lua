local h = require('helpers')

describe('plugins.lang.java', function()
  local restores, specs

  --- The spec of `name` among those `plugins.lang.java` returns
  local function spec(name)
    for _, s in ipairs(specs) do
      if s[1] == name then return s end
    end
  end

  before_each(function()
    h.globals()
    restores = {}
    specs = dofile(h.root .. '/lua/plugins/lang/java.lua')
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
  end)

  it('gives two projects of the same name a workspace each', function()
    local opts = spec('mfussenegger/nvim-jdtls').opts()
    local one = opts.project_name('/work/a/api')
    local other = opts.project_name('/work/b/api')
    assert.matches('^api%-', one)
    assert.matches('^api%-', other)
    assert.are_not.equal(one, other)
    assert.are.equal(one, opts.project_name('/work/a/api'))
    assert.is_nil(opts.project_name(nil))
  end)
end)
