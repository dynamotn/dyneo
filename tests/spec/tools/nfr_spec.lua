local h = require('helpers')

describe('tools.nfr', function()
  local nfr

  before_each(function()
    h.unload('tools.nfr')
    nfr = require('tools.nfr')
  end)

  it('reads components, copies and load', function()
    local spec =
      assert(nfr.parse({ '99.9%', '2x99.5', 'rps=200', 'latency=1.5s' }))
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
      { 'rps=10', 'p99=1s' },
      { 'latency=10ms' },
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
    assert.equals('< 1s', nfr.duration(0.3))
    assert.equals('0s', nfr.duration(0))
  end)

  it('never rounds what is down away', function()
    assert.same({
      'Availability 99.9999999999%',
      'Down < 1s a week',
      'Down < 1s a month',
      'Down < 1s a year',
      'In flight: not worked out without the load, rps=',
    }, nfr.report(assert(nfr.parse({ '3x99.99', 'latency=1s' }))))
    assert.equals(
      'Requests in flight need the load too: add rps=',
      select(2, nfr.parse({ 'latency=10ms' }))
    )
  end)

  it(
    'reports downtime, the error budget and requests in flight',
    function()
      assert.same({
        'Availability 99.9%',
        'Down 10m 5s a week',
        'Down 43m 50s a month',
        'Down 8h 45m a year',
        'Error budget 262980 requests a month',
        'In flight 20.0 requests at once',
      }, nfr.report(
        assert(nfr.parse({ '99.9', 'rps=100', 'latency=200ms' }))
      ))
    end
  )

  it('sizes bandwidth, storage and instances from the load', function()
    assert.same(
      {
        'Peak 600 requests a second',
        'Bandwidth 400 KB/s (3.2 Mbit/s), 1.05 TB a month, 1.2 MB/s at peak',
        'Storage 1.04 TB to keep 30d',
        'Instances 3 at peak, 4 to lose one (N+1)',
      },
      nfr.report(assert(nfr.parse({
        'rps=200',
        'size=2KB',
        'retain=30d',
        'capacity=250',
        'peak=3',
      })))
    )
    assert.equals('999 B', nfr.bytes(999))
    assert.equals('1.5 GB', nfr.bytes(1.5e9))
  end)

  it(
    'takes no instance more than the peak needs',
    function()
      assert.equals(
        'Instances 1 at peak, 2 to lose one (N+1)',
        nfr.report(assert(nfr.parse({ 'rps=100', 'peak=1.1', 'capacity=110' })))[2]
      )
    end
  )

  it('reads a lower-case b as bits, and binary units', function()
    assert.equals(12.5e6, nfr.parse({ 'rps=1', 'size=100Mb' }).size)
    assert.equals(100e6, nfr.parse({ 'rps=1', 'size=100MB' }).size)
    assert.equals(2048, nfr.parse({ 'rps=1', 'size=2KiB' }).size)
    assert.equals(250, nfr.parse({ 'rps=1', 'size=2kb' }).size)
    assert.is_nil(nfr.parse({ 'rps=1', 'size=2mb' }))
  end)

  it('rolls over to the next unit, and never writes an exponent', function()
    assert.equals('1 KB', nfr.bytes(999.7))
    assert.equals('1 MB', nfr.bytes(999999))
    assert.equals('315 ZB', nfr.bytes(3.15e23))
    assert.equals('3150000 ZB', nfr.bytes(3.15e27))
    assert.equals('3.2 Mbit/s', nfr.bits(400e3))
    assert.equals(
      'Peak 1200000 requests a second',
      nfr.report(assert(nfr.parse({ 'rps=400000', 'peak=3', 'size=1B' })))[1]
    )
  end)

  it('says what needs the load, and refuses nothing to size', function()
    for term, err in pairs({
      ['size=2KB'] = 'size needs the load too: add rps=',
      ['retain=30d'] = 'retain needs the load too: add rps=',
      ['capacity=500'] = 'capacity needs the load too: add rps=',
      ['peak=3'] = 'peak needs the load too: add rps=',
    }) do
      assert.same({ nil, err }, { nfr.parse({ '99.9', term }) })
    end
    for _, terms in ipairs({
      { 'rps=1', 'size=0KB' },
      { 'rps=1', 'size=1KB', 'retain=0d' },
      { 'rps=0', 'capacity=500' },
      { 'rps=0', 'size=1KB' },
    }) do
      local spec, err = nfr.parse(terms)
      assert.is_nil(spec)
      assert.is_truthy(err:find('above 0'), err)
    end
  end)

  it('refuses a retention without a size, and bad sizes', function()
    for _, terms in ipairs({
      { 'rps=1', 'latency=1', 'retain=30d' },
      { 'rps=1', 'size=2XB' },
      { 'rps=1', 'size=1KB', 'retain=30m' },
      { 'rps=1', 'capacity=0' },
    }) do
      assert.is_nil(nfr.parse(terms))
    end
  end)

  it('refuses a negative rate', function()
    local spec, err = nfr.parse({ '99.9', 'rps=-5' })
    assert.is_nil(spec)
    assert.equals('Not a rate: rps=-5', err)
  end)

  it('asks for the terms when none are given', function()
    local notes = {}
    local restore = h.stub(
      vim,
      'notify',
      function(msg, level) table.insert(notes, { msg, level }) end
    )
    local answer = ' 99.9  rps=10 '
    local restore_input = h.stub(vim.ui, 'input', function(opts, on_confirm)
      assert.is_truthy(opts.prompt:find('Terms', 1, true))
      on_confirm(answer)
    end)
    nfr.command({ fargs = {} })
    answer = '   '
    nfr.command({ fargs = {} })
    answer = nil
    nfr.command({ fargs = {} })
    restore_input()
    restore()
    assert.equals(1, #notes)
    assert.is_truthy(notes[1][1]:find('Availability 99.9%', 1, true))
  end)

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

describe('tools.nfr slo', function()
  local nfr

  before_each(function()
    h.unload('tools.nfr', 'util.scratch')
    nfr = require('tools.nfr')
  end)
  after_each(function()
    vim.cmd('silent! tabonly!')
    vim.cmd('silent! %bwipeout!')
  end)

  it('reads an objective and its window', function()
    local slo = assert(nfr.parse_slo({ '99.9', 'window=7d' }))
    assert.is_true(math.abs(slo.objective - 0.999) < 1e-12)
    assert.equals(7 * 86400, slo.window)
    assert.equals(30 * 86400, assert(nfr.parse_slo({ '99.5%' })).window)
    for _, terms in ipairs({
      {},
      { '100' },
      { '99.9', '99' },
      { '99.9', 'window=2m' },
      { 'window=30d' },
    }) do
      assert.is_nil(nfr.parse_slo(terms), table.concat(terms, ' '))
    end
  end)

  it("gives the workbook's burn rates for thirty days", function()
    local text =
      table.concat(nfr.slo_report(assert(nfr.parse_slo({ '99.9' }))), '\n')
    assert.is_truthy(text:find('# SLO 99.9% over 30d', 1, true))
    assert.is_truthy(
      text:find('Error budget: 0.1% of the requests, or 43m 12s', 1, true)
    )
    for _, row in ipairs({
      '| page | 1h | 5m | 14.4 | 1.44% | 2% | 2d 2h |',
      '| page | 6h | 30m | 6 | 0.6% | 5% | 5d |',
      '| ticket | 1d | 2h | 3 | 0.3% | 10% | 10d |',
      '| ticket | 3d | 6h | 1 | 0.1% | 10% | 30d |',
      'slo:sli_error:ratio_rate1h > 0.0144\n',
      'and slo:sli_error:ratio_rate5m > 0.0144',
    }) do
      assert.is_truthy(text:find(row, 1, true), row)
    end
  end)

  it('scales the rates to a shorter window, and drops those below 1', function()
    local lines = nfr.slo_report(assert(nfr.parse_slo({ '99', 'window=7d' })))
    local rows = vim.tbl_filter(
      function(line) return line:match('^| page') or line:match('^| ticket') end,
      lines
    )
    assert.same({
      '| page | 1h | 5m | 3.36 | 3.36% | 2% | 2d 2h |',
      '| page | 6h | 30m | 1.4 | 1.4% | 5% | 5d |',
    }, rows)
    assert.is_truthy(
      vim.tbl_contains(
        lines,
        'Left out, as it would burn under 1x over a 7d window: the ticket over 1d, the ticket over 3d.'
      )
    )
    -- A window too short for any: no empty rules
    local short = table.concat(
      nfr.slo_report(assert(nfr.parse_slo({ '99', 'window=12h' }))),
      '\n'
    )
    assert.is_truthy(short:find('No alert holds', 1, true))
    assert.is_falsy(short:find('```yaml', 1, true))
  end)

  it('leaves out an alert whose line no error ratio can pass', function()
    local lines = nfr.slo_report(assert(nfr.parse_slo({ '90' })))
    local text = table.concat(lines, '\n')
    -- 14.4 times a budget of 10% is 144% of the requests failing
    assert.is_falsy(text:find('| page | 1h |', 1, true))
    assert.is_falsy(text:find('ratio_rate1h', 1, true))
    assert.is_truthy(text:find('| page | 6h | 30m | 6 | 60% |', 1, true))
    assert.is_truthy(
      vim.tbl_contains(
        lines,
        'Left out, as its line is past 100% of errors for an objective of 90%: the page over 1h.'
      )
    )
  end)

  it('writes a span of no whole minute in seconds', function()
    nfr.SLO_ALERTS = {
      { severity = 'page', long = 90, short = 30, budget = 0.01 },
    }
    local text =
      table.concat(nfr.slo_report(assert(nfr.parse_slo({ '99.9' }))), '\n')
    assert.is_truthy(text:find('| page | 90s | 30s |', 1, true))
    assert.is_truthy(text:find('ratio_rate90s > ', 1, true))
    assert.is_truthy(text:find('and slo:sli_error:ratio_rate30s > ', 1, true))
  end)

  it(':DyNfr slo opens the report, and says what it cannot read', function()
    local notes = {}
    local restore = h.stub(
      vim,
      'notify',
      function(msg) table.insert(notes, msg) end
    )
    nfr.command({ fargs = { 'slo', '99.95' } })
    nfr.command({ fargs = { 'slo', 'nope' } })
    restore()
    assert.equals(
      '# SLO 99.95% over 30d',
      vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]
    )
    assert.same({ 'Not an objective below 100%: nope' }, notes)
  end)
end)
