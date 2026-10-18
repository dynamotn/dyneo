local h = require('helpers')

describe('plugins.lang.csv', function()
  before_each(function() h.globals() end)

  --- The csvview spec, with these table languages enabled
  ---@param ... string
  ---@return table?
  local function csvview(...)
    DyNeo.enabled_languages = { 'lua', ... }
    return dofile(h.root .. '/lua/plugins/lang/csv.lua')[1]
  end

  it('views every enabled table format, each by its delimiter', function()
    local spec = csvview('csv', 'tsv', 'psv')
    assert.same({ 'csv', 'tsv', 'psv' }, spec.ft)
    assert.same(spec.ft, spec.keys[1].ft)
    assert.same(
      { csv = ',', tsv = '\t', psv = '|' },
      spec.opts.parser.delimiter.ft
    )
  end)

  it('loads for the formats that are on alone', function()
    assert.same({ 'tsv' }, csvview('tsv').ft)
    assert.is_nil(csvview())
  end)
end)
