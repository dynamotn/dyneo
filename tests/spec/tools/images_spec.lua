local h = require('helpers')

local DIGEST = 'sha256:' .. ('c'):rep(64)

local DOCKERFILE = {
  'ARG BASE=alpine:3',
  'FROM --platform=$BUILDPLATFORM golang:1.23 AS build',
  'FROM build AS test',
  'FROM ${BASE}',
  'FROM scratch',
  'FROM gcr.io/distroless/static:nonroot',
  'from nginx:1.27@' .. DIGEST,
}

local MANIFEST = {
  'spec:',
  '  containers:',
  '    - name: app',
  '      image: "ghcr.io/o/app:1.2.3" # pinned soon',
  '    - image: golang:1.23',
}

describe('tools.images', function()
  local images, dir, cleanup, path, notes, restore_notify

  before_each(function()
    h.unload('tools.images')
    images = require('tools.images')
    dir, cleanup = h.tmpdir()
    vim.fn.mkdir(dir .. '/bin', 'p')
    path = vim.env.PATH
    -- Only the fakes of this spec, whatever the machine has
    vim.env.PATH = dir .. '/bin:/usr/bin:/bin'
    notes = {}
    restore_notify = h.stub(
      vim,
      'notify',
      function(msg) table.insert(notes, msg) end
    )
  end)
  after_each(function()
    vim.env.PATH = path
    restore_notify()
    vim.cmd('silent! %bwipeout!')
    cleanup()
  end)

  local function tool(name, lines)
    h.write(
      dir .. '/bin/' .. name,
      vim.list_extend(
        { '#!/bin/sh', 'echo "$@" >> "' .. dir .. '/calls"' },
        lines
      )
    )
    vim.fn.setfperm(dir .. '/bin/' .. name, 'rwxr-xr-x')
  end

  it(
    'finds the images of a Dockerfile, stages, scratch and variables left out',
    function()
      assert.same({
        { line = 2, image = 'golang:1.23' },
        { line = 6, image = 'gcr.io/distroless/static:nonroot' },
        { line = 7, image = 'nginx:1.27@' .. DIGEST },
      }, images.images(DOCKERFILE))
    end
  )

  it(
    'finds the images of a manifest',
    function()
      assert.same({
        { line = 4, image = 'ghcr.io/o/app:1.2.3' },
        { line = 5, image = 'golang:1.23' },
      }, images.images(MANIFEST))
    end
  )

  it(
    'leaves out a name a scanner would read as a flag',
    function()
      assert.same(
        { { line = 3, image = 'nginx:1.27' } },
        images.images({
          'FROM --platform=x --chown=1 -o=/tmp/x',
          'image: --config=/tmp/evil.yaml',
          'FROM --a=1 --b=2 --c=3 nginx:1.27',
        })
      )
    end
  )

  it('counts what trivy and grype report, worst first', function()
    local trivy = images.findings({
      Results = {
        {
          Vulnerabilities = {
            { VulnerabilityID = 'CVE-2', Severity = 'HIGH' },
            { VulnerabilityID = 'CVE-1', Severity = 'CRITICAL' },
            { VulnerabilityID = 'CVE-3', Severity = 'LOW' },
          },
        },
        { Vulnerabilities = vim.NIL },
      },
    })
    assert.same({ CRITICAL = 1, HIGH = 1, LOW = 1 }, trivy.counts)
    assert.same({ 'CVE-1', 'CVE-2', 'CVE-3' }, trivy.ids)

    local grype = images.findings({
      matches = { { vulnerability = { id = 'GHSA-x', severity = 'Medium' } } },
    })
    assert.same({ MEDIUM = 1 }, grype.counts)

    local diagnostic = images.diagnostic({ line = 3, image = 'x:1' }, trivy)
    assert.equals(2, diagnostic.lnum)
    assert.equals(vim.diagnostic.severity.ERROR, diagnostic.severity)
    assert.equals(
      'x:1: CRITICAL 1, HIGH 1, LOW 1 (CVE-1, CVE-2, CVE-3)',
      diagnostic.message
    )
    assert.equals(
      vim.diagnostic.severity.WARN,
      images.diagnostic({ line = 1, image = 'y' }, grype).severity
    )
    assert.is_nil(
      images.diagnostic({ line = 1, image = 'z' }, { counts = {}, ids = {} })
    )
  end)

  it('scans each image once, and warns on its lines', function()
    tool('trivy', {
      'case "$*" in',
      [[  *golang:1.23) echo '{"Results":[{"Vulnerabilities":[{"VulnerabilityID":"CVE-9","Severity":"HIGH"}]}]}';;]],
      [[  *nonroot) echo '{"Results":[]}';;]],
      '  *) echo "unauthorized" >&2; exit 1;;',
      'esac',
    })
    local bufnr = h.buffer({
      lines = vim.list_extend(vim.deepcopy(DOCKERFILE), { 'FROM golang:1.23' }),
    })
    images.scan(bufnr)
    assert.is_true(vim.wait(5000, function() return #notes > 1 end, 10))
    assert.is_truthy(
      notes[2]:find(
        '^2 images scanned, 1 with known vulnerabilities; failed: nginx'
      )
    )
    local diagnostics = vim.diagnostic.get(bufnr)
    assert.equals(2, #diagnostics)
    assert.same(
      { 1, 7 },
      vim.tbl_map(function(d) return d.lnum end, diagnostics)
    )
    local scans = vim.tbl_filter(
      function(c) return c:find('golang', 1, true) end,
      vim.fn.readfile(dir .. '/calls')
    )
    assert.equals(1, #scans)
    assert.is_truthy(scans[1]:find('--scanners vuln', 1, true))
  end)

  it(
    'leaves a Helm template out',
    function()
      assert.same(
        {},
        images.images({
          '  image: "{{ .Values.image.repository }}:{{ .Values.tag }}"',
        })
      )
    end
  )

  it('puts the findings where the images are when the scans end', function()
    tool('trivy', {
      'sleep 0.3',
      [[echo '{"Results":[{"Vulnerabilities":[{"VulnerabilityID":"CVE-9","Severity":"HIGH"}]}]}']],
    })
    local bufnr = h.buffer({ lines = { 'FROM golang:1.23' } })
    images.scan(bufnr)
    -- Lines put above it while the scan runs
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { '# a', '# b' })
    assert.is_true(vim.wait(5000, function() return #notes > 1 end, 10))
    local diagnostics = vim.diagnostic.get(bufnr)
    assert.equals(1, #diagnostics)
    assert.equals(2, diagnostics[1].lnum)
  end)

  it('says when it has no scanner, or nothing to scan', function()
    images.scan(h.buffer({ lines = { 'FROM scratch' } }))
    images.scan(h.buffer({ lines = { 'FROM alpine:3' } }))
    assert.same({
      'No image named in this buffer',
      'Neither trivy nor grype is installed',
    }, notes)
  end)

  it('pins each tag to its digest, the digest ones left alone', function()
    tool('crane', {
      'case "$2" in',
      '  golang:1.23) echo "' .. DIGEST .. '";;',
      '  *) echo "MANIFEST_UNKNOWN" >&2; exit 1;;',
      'esac',
    })
    local bufnr = h.buffer({ lines = vim.deepcopy(MANIFEST) })
    images.pin(bufnr)
    assert.is_true(vim.wait(5000, function() return #notes > 0 end, 10))
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.equals('    - image: golang:1.23@' .. DIGEST, lines[5])
    assert.equals(MANIFEST[4], lines[4])
    assert.equals(
      '1 images pinned; not resolved: ghcr.io/o/app:1.2.3',
      notes[1]
    )

    notes = {}
    images.pin(h.buffer({ lines = { 'FROM nginx:1.27@' .. DIGEST } }))
    assert.same({ 'Every image is pinned already' }, notes)
  end)

  it('orders findings of one severity by id', function()
    local findings = images.findings({
      matches = {
        { vulnerability = { id = 'GHSA-b', severity = 'High' } },
        { vulnerability = { id = 'GHSA-a', severity = 'High' } },
        { vulnerability = { id = 'GHSA-b', severity = 'High' } },
      },
    })
    assert.same({ HIGH = 3 }, findings.counts)
    assert.same({ 'GHSA-a', 'GHSA-b' }, findings.ids)
  end)

  it('scans the current buffer with grype when trivy is missing', function()
    tool('grype', {
      [[echo '{"matches":[{"vulnerability":{"id":"GHSA-1","severity":"Critical"}}]}']],
    })
    vim.api.nvim_set_current_buf(h.buffer({ lines = { 'FROM golang:1.23' } }))
    images.scan()
    assert.is_true(vim.wait(5000, function() return #notes > 1 end, 10))
    assert.is_truthy(
      notes[2]:find('^1 images scanned, 1 with known vulnerabilities$')
    )
    assert.same(
      { '--quiet -o json golang:1.23' },
      vim.fn.readfile(dir .. '/calls')
    )
    assert.equals(1, #vim.diagnostic.get(0))
  end)

  it('pins the current buffer with skopeo when crane is missing', function()
    tool('skopeo', { 'echo "' .. DIGEST .. '"' })
    vim.api.nvim_set_current_buf(h.buffer({ lines = { 'FROM golang:1.23' } }))
    images.pin()
    assert.is_true(vim.wait(5000, function() return #notes > 0 end, 10))
    assert.same({ '1 images pinned' }, notes)
    assert.same(
      { 'inspect --format {{.Digest}} docker://golang:1.23' },
      vim.fn.readfile(dir .. '/calls')
    )
    assert.equals(
      'FROM golang:1.23@' .. DIGEST,
      vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]
    )
  end)

  it('says when it has nothing to look digests up with', function()
    -- The runner may have its own skopeo under /usr/bin
    local executable = vim.fn.executable
    local restore = h.stub(vim.fn, 'executable', function(name)
      if name == 'crane' or name == 'skopeo' then return 0 end
      return executable(name)
    end)
    images.pin(h.buffer({ lines = { 'FROM golang:1.23' } }))
    restore()
    assert.same({ 'Neither crane nor skopeo is installed' }, notes)
  end)

  it('pins nothing in a buffer edited while it looked digests up', function()
    tool('crane', { 'sleep 0.3', 'echo "' .. DIGEST .. '"' })
    local bufnr = h.buffer({ lines = { 'FROM golang:1.23' } })
    images.pin(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { '# edited' })
    assert.is_true(vim.wait(5000, function() return #notes > 0 end, 10))
    assert.same({ 'The file changed meanwhile: nothing pinned' }, notes)
    assert.same(
      { '# edited', 'FROM golang:1.23' },
      vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    )
  end)

  it('looks up no more than a few digests at once', function()
    -- Each lookup leaves a mark while it runs; the most marks seen together
    -- is how many ran at once
    tool('crane', {
      'touch "' .. dir .. '/running.$$"',
      'ls "' .. dir .. '" | grep -c "^running" >> "' .. dir .. '/counts"',
      'sleep 0.2',
      'rm "' .. dir .. '/running.$$"',
      'echo "' .. DIGEST .. '"',
    })
    local lines = {}
    for index = 1, 8 do
      lines[index] = ('FROM registry.example/app%d:1'):format(index)
    end
    local bufnr = h.buffer({ lines = lines })
    images.pin(bufnr)
    assert.is_true(vim.wait(10000, function() return #notes > 0 end, 10))
    assert.equals('8 images pinned', notes[1])
    local most = 0
    for _, count in ipairs(vim.fn.readfile(dir .. '/counts')) do
      most = math.max(most, tonumber(count))
    end
    assert.is_true(most <= images.PARALLEL, ('%d at once'):format(most))
  end)

  it('splits a digest off an image', function()
    assert.same(
      { 'nginx:1.27', DIGEST },
      { images.split_digest('nginx:1.27@' .. DIGEST) }
    )
    assert.same({ 'nginx:1.27' }, { images.split_digest('nginx:1.27') })
  end)
end)
