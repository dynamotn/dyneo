local h = require('helpers')

describe('tools.nfr', function()
  local nfr

  before_each(function()
    h.unload('tools.nfr')
    nfr = require('tools.nfr')
  end)

  it('reads components, copies and load', function()
    local spec = assert(nfr.parse({ '99.9', '2x99.5', 'rps=200', 'p99=1.5s' }))
    assert.same(
      { { 99.9, 1 }, { 99.5, 2 } },
      vim.tbl_map(
        function(c)
          return { math.floor(c.availability * 1e4 + 0.5) / 100, c.copies }
        end,
        spec.components
      )
    )
    assert.equals(200, spec.rps)
    assert.equals(1.5, spec.latency)
    assert.equals(0.15, nfr.parse({ 'rps=1', 'latency=150' }).latency)
  end)

  it('refuses what it cannot read', function()
    for _, terms in ipairs({
      { '101' },
      { '0' },
      { 'abc' },
      { 'latency=fast', '99' },
      { 'foo=1' },
      { 'rps=10' },
      {},
    }) do
      local spec, err = nfr.parse(terms)
      assert.is_nil(spec)
      assert.is_string(err)
    end
  end)

  it('multiplies a chain and adds up redundant copies', function()
    local chain = nfr.availability({
      { availability = 0.999, copies = 1 },
      { availability = 0.9995, copies = 1 },
    })
    assert.is_true(math.abs(chain - 0.999 * 0.9995) < 1e-12)
    local pair = nfr.availability({ { availability = 0.99, copies = 2 } })
    assert.is_true(math.abs(pair - 0.9999) < 1e-12)
  end)

  it('says durations the way a person does', function()
    assert.equals('45s', nfr.duration(45))
    assert.equals('43m 12s', nfr.duration(43 * 60 + 12))
    assert.equals('8h 45m', nfr.duration(8 * 3600 + 45 * 60 + 36))
    assert.equals('1d 2h', nfr.duration(86400 + 2 * 3600))
  end)

  it(
    'reports downtime, the error budget and requests in flight',
    function()
      assert.same({
        'Availability 99.9%',
        'Down 10m 5s a week',
        'Down 43m 12s a month',
        'Down 8h 45m a year',
        'Error budget 259200 requests a month',
        'In flight 20.0 requests at once',
      }, nfr.report(
        assert(nfr.parse({ '99.9', 'rps=100', 'latency=200ms' }))
      ))
    end
  )

  it('notifies the report, or why there is none', function()
    local notes = {}
    local restore = h.stub(
      vim,
      'notify',
      function(msg, level) table.insert(notes, { msg, level }) end
    )
    nfr.command({ fargs = { '99.99' } })
    nfr.command({ fargs = { 'nope' } })
    restore()
    assert.is_truthy(notes[1][1]:find('Availability 99.99%', 1, true))
    assert.same({ 'Not an availability: nope', vim.log.levels.ERROR }, notes[2])
  end)
end)
