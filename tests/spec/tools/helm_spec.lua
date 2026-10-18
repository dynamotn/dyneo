local h = require('helpers')

local VALUES = {
  '# values',
  'image:',
  '  repository: nginx',
  '  tag: "1.27"',
  'resources:',
  '  limits:',
  '    cpu: 1',
  'extraEnv:',
  '  - name: A',
  '    value: b',
  'config: |',
  '  key: not a value',
  'unused:',
  '  deep: 1',
  'global:',
  '  region: eu',
  'redis:',
  '  enabled: true',
}

describe('tools.helm', function()
  local helm, dir, cleanup

  before_each(function()
    h.unload('tools.helm')
    helm = require('tools.helm')
    dir, cleanup = h.tmpdir()
    h.write(dir .. '/Chart.yaml', {
      'apiVersion: v2',
      'name: web',
      'dependencies:',
      '  - name: redis',
      '    version: 1.0.0',
    })
    h.write(dir .. '/values.yaml', VALUES)
    h.write(dir .. '/templates/deploy.yaml', {
      'image: {{ .Values.image.repository }}:{{ .Values.image.tag }}',
      'resources: {{- toYaml .Values.resources | nindent 2 }}',
      '{{- range $.Values.extraEnv }}',
      'config: {{ .Values.config | quote }}',
    })
  end)
  after_each(function()
    vim.cmd('silent! cclose')
    vim.cmd('silent! %bwipeout!')
    vim.diagnostic.reset()
    cleanup()
  end)

  it(
    'reads the .Values paths of a line, and the one under the cursor',
    function()
      local line = 'x: {{ .Values.image.tag }} {{ $.Values.a.b. }}'
      assert.same(
        { 'image.tag', 'a.b' },
        vim.tbl_map(function(r) return r.path end, helm.references(line))
      )
      assert.equals('image.tag', helm.path_at(line, 10))
      assert.equals('a.b', helm.path_at(line, 33))
      assert.is_nil(helm.path_at(line, 30))
      assert.is_nil(helm.path_at(line, 2))
    end
  )

  it(
    'maps each key of a values file to its line, lists and scalars left out',
    function()
      local paths, order = helm.paths(VALUES)
      assert.equals(2, paths['image'])
      assert.equals(4, paths['image.tag'])
      assert.equals(7, paths['resources.limits.cpu'])
      assert.equals(8, paths['extraEnv'])
      assert.is_nil(paths['extraEnv.name'])
      assert.is_nil(paths['config.key'])
      assert.equals(14, paths['unused.deep'])
      assert.equals('image', order[1])
      assert.equals('image.tag', helm.path_of_row(VALUES, 4))
    end
  )

  it('counts a key used through itself, a parent or a child', function()
    local refs = { ['resources'] = true, ['image.tag'] = true }
    assert.is_true(helm.used('resources.limits.cpu', refs))
    assert.is_true(helm.used('image', refs))
    assert.is_true(helm.used('image.tag', refs))
    assert.is_false(helm.used('image.repository', refs))
    assert.is_false(helm.used('imagex', refs))
  end)

  it(
    'knows the subcharts and global as not its own',
    function() assert.same({ global = true, redis = true }, helm.subcharts(dir)) end
  )

  it('goes from a template to the line of its value', function()
    vim.cmd.edit(dir .. '/templates/deploy.yaml')
    vim.api.nvim_win_set_cursor(0, { 1, 50 })
    helm.value()
    assert.equals(dir .. '/values.yaml', vim.api.nvim_buf_get_name(0))
    assert.equals(4, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it('lists the template lines using a key', function()
    local items = helm.usages(dir, 'image')
    assert.equals(1, #items)
    assert.equals(1, items[1].lnum)
    assert.equals(1, #helm.usages(dir, 'resources.limits.cpu'))
    assert.same({}, helm.usages(dir, 'unused'))

    vim.cmd.edit(dir .. '/values.yaml')
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    helm.show_usages()
    assert.equals(
      'Helm: image.repository',
      vim.fn.getqflist({ title = 0 }).title
    )
  end)

  it('marks the values no template uses, once per subtree', function()
    vim.cmd.edit(dir .. '/values.yaml')
    local restore = h.stub(vim, 'notify', function() end)
    helm.unused(0)
    restore()
    local messages = vim.tbl_map(
      function(d) return d.lnum + 1 .. ' ' .. d.message end,
      vim.diagnostic.get(0)
    )
    assert.same({ '13 No template uses unused' }, messages)
  end)

  it('maps the usages and the unused values on a values file', function()
    vim.cmd.edit(dir .. '/values.yaml')
    helm.attach(0)
    local descs = vim.tbl_map(
      function(map) return map.desc end,
      vim.api.nvim_buf_get_keymap(0, 'n')
    )
    assert.is_true(vim.tbl_contains(descs, 'Template Usages (Helm)'))
    assert.is_true(vim.tbl_contains(descs, 'Unused Values (Helm)'))
  end)

  it('says when it is not in a chart', function()
    local notes = {}
    local restore = h.stub(
      vim,
      'notify',
      function(msg) table.insert(notes, msg) end
    )
    vim.api.nvim_set_current_buf(h.buffer({ lines = { '{{ .Values.x }}' } }))
    helm.value()
    helm.show_usages()
    helm.unused(0)
    helm.attach(0)
    restore()
    assert.same({
      'Not in a Helm chart',
      'Not in a Helm chart',
      'Not in a Helm chart',
    }, notes)
    assert.same({}, vim.api.nvim_buf_get_keymap(0, 'n'))
  end)

  describe('with notifications kept', function()
    local notes, restore

    before_each(function()
      notes = {}
      restore = h.stub(
        vim,
        'notify',
        function(msg, level) table.insert(notes, { msg, level }) end
      )
    end)
    after_each(function() restore() end)

    it('says when no .Values is under the cursor', function()
      vim.cmd.edit(dir .. '/templates/deploy.yaml')
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      helm.value()
      assert.same(
        { { 'No .Values under the cursor', vim.log.levels.WARN } },
        notes
      )
    end)

    it('says when the chart has no values.yaml', function()
      vim.fn.delete(dir .. '/values.yaml')
      vim.cmd.edit(dir .. '/templates/deploy.yaml')
      vim.api.nvim_win_set_cursor(0, { 1, 50 })
      helm.value()
      assert.same(
        { { 'The chart has no values.yaml', vim.log.levels.WARN } },
        notes
      )
    end)

    it('goes to the deepest key the values file sets', function()
      h.write(dir .. '/templates/extra.yaml', {
        'digest: {{ .Values.image.digest }}',
        'nope: {{ .Values.nope.x }}',
      })
      vim.cmd.edit(dir .. '/templates/extra.yaml')
      vim.api.nvim_win_set_cursor(0, { 1, 15 })
      helm.value()
      assert.equals(dir .. '/values.yaml', vim.api.nvim_buf_get_name(0))
      assert.equals(2, vim.api.nvim_win_get_cursor(0)[1])
      assert.same(
        { { 'values.yaml sets image, not image.digest', vim.log.levels.INFO } },
        notes
      )
    end)

    it('says when the values file does not set the path', function()
      h.write(dir .. '/templates/extra.yaml', { 'nope: {{ .Values.nope.x }}' })
      vim.cmd.edit(dir .. '/templates/extra.yaml')
      vim.api.nvim_win_set_cursor(0, { 1, 12 })
      helm.value()
      assert.equals(
        dir .. '/templates/extra.yaml',
        vim.api.nvim_buf_get_name(0)
      )
      assert.same(
        { { 'values.yaml does not set nope.x', vim.log.levels.WARN } },
        notes
      )
    end)

    it('says when the line holds no key, or no template uses it', function()
      vim.cmd.edit(dir .. '/values.yaml')
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      helm.show_usages()
      vim.api.nvim_win_set_cursor(0, { 13, 0 })
      helm.show_usages()
      assert.same({
        { 'No key on this line', vim.log.levels.WARN },
        { 'No template uses unused', vim.log.levels.INFO },
      }, notes)
    end)
  end)

  it('maps going to the value on a template', function()
    vim.cmd.edit(dir .. '/templates/deploy.yaml')
    vim.bo.filetype = 'helm'
    helm.attach(0)
    local descs = vim.tbl_map(
      function(map) return map.desc end,
      vim.api.nvim_buf_get_keymap(0, 'n')
    )
    assert.same({ 'Go To Value (Helm)' }, descs)
  end)

  it('knows a subchart by its directory, its tarball or its alias', function()
    vim.fn.mkdir(dir .. '/charts/postgres', 'p')
    h.write(dir .. '/charts/mysql-1.2.3.tgz', { '' })
    h.write(dir .. '/Chart.yaml', {
      'apiVersion: v2',
      'name: web',
      'dependencies:',
      '  - name: redis',
      '    alias: cache',
    })
    assert.same({
      global = true,
      redis = true,
      cache = true,
      postgres = true,
      mysql = true,
    }, helm.subcharts(dir))
  end)
end)
