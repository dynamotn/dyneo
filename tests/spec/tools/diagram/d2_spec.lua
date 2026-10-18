local h = require('helpers')

describe('tools.diagram.d2.snacks', function()
  local dir, cleanup, cache_dir, commands, executables, results, notified
  local restores, d2

  --- Run `fn` with `tbl[key]` replaced for the rest of the test
  local function stub(tbl, key, value)
    table.insert(restores, h.stub(tbl, key, value))
  end

  before_each(function()
    restores = {}
    dir, cleanup = h.tmpdir()
    cache_dir = dir .. '/cache/diagram-cache/d2'
    commands, notified = {}, {}
    executables = { d2 = 1, ['rsvg-convert'] = 1 }
    -- Exit code of each command, by its program
    results = {}

    local stdpath = vim.fn.stdpath
    stub(vim.fn, 'stdpath', function(what)
      if what == 'cache' then return dir .. '/cache' end
      return stdpath(what)
    end)
    stub(vim.fn, 'executable', function(name) return executables[name] or 0 end)
    stub(
      vim,
      'system',
      h.system_double(function(cmd)
        table.insert(commands, cmd)
        return results[cmd[1]] or { code = 0, stderr = '' }
      end)
    )
    stub(
      vim,
      'notify',
      function(msg, level, opts)
        table.insert(notified, { msg = msg, level = level, title = opts.title })
      end
    )
    stub(vim.env, 'ZELLIJ', nil)

    h.unload('tools.diagram.d2.snacks')
    d2 = require('tools.diagram.d2.snacks')
  end)

  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.cmd('silent! only')
    cleanup()
  end)

  --- Open a d2 file holding `lines` and press the preview mapping
  ---@param lines string[]
  ---@return string path
  local function preview(lines)
    local path = dir .. '/src/diagram.d2'
    h.write(path, lines)
    vim.cmd.edit(path)
    d2.preview(0)
    -- Converting and opening are scheduled; let them run
    vim.wait(100, function() return false end)
    return path
  end

  ---@param program string
  local function command_of(program)
    for _, cmd in ipairs(commands) do
      if cmd[1] == program then return cmd end
    end
  end

  it('makes its cache directory on the first render, not on load', function()
    assert.are.equal(0, vim.fn.isdirectory(cache_dir))
    preview({ 'a -> b' })
    assert.are.equal(1, vim.fn.isdirectory(cache_dir))
  end)

  it('maps <leader>cp in the d2 buffer its ftplugin runs for', function()
    h.unload('tools.diagram.d2.snacks')
    local bufnr = h.buffer({ filetype = 'd2' })
    vim.api.nvim_set_current_buf(bufnr)
    dofile(h.root .. '/ftplugin/d2.lua')
    local map = vim.fn.maparg('<leader>cp', 'n', false, true)
    assert.are.equal(1, map.buffer)
    assert.are.equal('Preview D2 diagram', map.desc)
    -- The module waits for the key
    assert.is_nil(package.loaded['tools.diagram.d2.snacks'])
  end)

  it('does nothing for an unnamed buffer', function()
    vim.api.nvim_set_current_buf(h.buffer({ filetype = 'd2' }))
    d2.preview(0)
    assert.are.same({}, commands)
    assert.are.same({}, notified)
  end)

  it('reports a missing d2', function()
    executables.d2 = 0
    preview({ 'a -> b' })
    assert.are.same({}, commands)
    assert.are.equal('d2 not found in PATH', notified[1].msg)
    assert.are.equal('DyNeo D2', notified[1].title)
    assert.are.equal(vim.log.levels.ERROR, notified[1].level)
  end)

  it('renders to SVG with the configured themes and layout', function()
    local path = preview({ 'a -> b' })
    local d2 = command_of('d2')
    assert.are.equal(path, d2[2])
    assert.is_truthy(d2[3]:match('/diagram%-cache/d2/%x+%.svg$'))
    assert.are.same(
      { '-t', '4', '--dark-theme', '4', '--layout', 'tala' },
      vim.list_slice(d2, 4)
    )
  end)

  it('leaves the layout to a diagram that picks its own', function()
    preview({ 'vars: { d2-config: { layout-engine: elk } }', 'a -> b' })
    assert.is_false(vim.list_contains(command_of('d2'), '--layout'))
  end)

  it(
    'converts with rsvg-convert and opens the PNG beside the source',
    function()
      preview({ 'a -> b' })
      local d2 = command_of('d2')
      local rsvg = command_of('rsvg-convert')
      assert.are.equal(d2[3], rsvg[4])
      local png = rsvg[3]
      assert.is_truthy(png:match('%.png$'))
      vim.wait(1000, function() return #vim.api.nvim_list_wins() == 2 end)
      assert.are.equal(2, #vim.api.nvim_list_wins())
      assert.are.equal(png, vim.api.nvim_buf_get_name(0))
    end
  )

  it('falls back to resvg, then magick', function()
    executables['rsvg-convert'] = nil
    executables.resvg = 1
    preview({ 'a -> b' })
    assert.is_not_nil(command_of('resvg'))

    commands = {}
    executables.resvg = nil
    executables.magick = 1
    preview({ 'a -> c' })
    assert.are.same(
      { 'magick', '-background', 'none' },
      vim.list_slice(command_of('magick'), 1, 3)
    )
  end)

  it('crops the Quick Look thumbnail to the aspect of the diagram', function()
    executables['rsvg-convert'] = nil
    executables.qlmanage = 1
    executables.sips = 1
    -- d2 is stubbed, so the SVG it would have written is put there by hand
    stub(
      vim,
      'system',
      h.system_double(function(cmd)
        table.insert(commands, cmd)
        if cmd[1] == 'd2' then
          h.write(cmd[3], { '<svg viewBox="0 0 200 100">', '</svg>' })
        end
        return { code = 0, stderr = '' }
      end)
    )
    preview({ 'a -> b' })
    local ql = command_of('qlmanage')
    assert.are.same(
      { 'qlmanage', '-t', '-s', '4096', '-o' },
      vim.list_slice(ql, 1, 5)
    )
    local sips = command_of('sips')
    assert.are.same({ '-c', '2048', '4096' }, vim.list_slice(sips, 5, 7))
  end)

  it('drops the thumbnail and reports when the crop fails', function()
    executables['rsvg-convert'] = nil
    executables.qlmanage = 1
    executables.sips = 1
    local thumbnail
    stub(
      vim,
      'system',
      h.system_double(function(cmd)
        table.insert(commands, cmd)
        if cmd[1] == 'd2' then
          h.write(cmd[3], { '<svg viewBox="0 0 200 100">', '</svg>' })
        elseif cmd[1] == 'qlmanage' then
          -- The thumbnail Quick Look would have written
          thumbnail = cmd[6]
            .. '/'
            .. vim.fn.fnamemodify(cmd[7], ':t')
            .. '.png'
          h.write(thumbnail, { 'png' })
        elseif cmd[1] == 'sips' then
          return { code = 1, stderr = 'sips: no such file' }
        end
        return { code = 0, stderr = '' }
      end)
    )
    preview({ 'a -> b' })
    assert.is_not_nil(command_of('sips'))
    assert.is_nil(vim.uv.fs_stat(thumbnail))
    assert.is_truthy(notified[#notified].msg:find('sips', 1, true))
    assert.are.equal(vim.log.levels.ERROR, notified[#notified].level)
  end)

  it('reports when no converter is installed', function()
    executables['rsvg-convert'] = nil
    preview({ 'a -> b' })
    vim.wait(1000, function() return #notified > 0 end)
    assert.is_truthy(notified[1].msg:find('no SVG converter found', 1, true))
  end)

  it('reports what d2 printed when it fails', function()
    results.d2 = { code = 1, stderr = 'syntax error' }
    preview({ 'a -> ' })
    vim.wait(1000, function() return #notified > 0 end)
    assert.are.equal('failed to render:\nsyntax error', notified[1].msg)
    assert.is_nil(command_of('rsvg-convert'))
  end)

  it('serves a cached render without running d2', function()
    preview({ 'a -> b' })
    local png = command_of('rsvg-convert')[3]
    h.write(png, { 'png' })
    commands = {}
    preview({ 'a -> b' })
    assert.are.same({}, commands)
  end)

  it('renders again when an imported file changes', function()
    h.write(dir .. '/src/lib/shapes.d2', { 'x: 1' })
    preview({ '...@lib/shapes', 'a -> b' })
    local first = command_of('d2')[3]
    h.write(dir .. '/src/lib/shapes.d2', { 'x: 2' })
    commands = {}
    preview({ '...@lib/shapes', 'a -> b' })
    assert.are_not.equal(first, command_of('d2')[3])
  end)

  it('follows imports, up a directory too, and reads nothing else', function()
    h.write(dir .. '/shared/style.d2', { 'classes: { a: {} }' })
    h.write(dir .. '/src/lib/shapes.d2', { 'x: @../../shared/style' })
    h.write(dir .. '/src/unrelated.d2', { 'z: 1' })
    local source = { 'shapes: @lib/shapes', 'a -> b' }
    preview(source)
    local first = command_of('d2')[3]
    -- The render as the converter would have left it
    h.write(command_of('rsvg-convert')[3], { 'png' })

    -- A file nothing imports changes nothing
    h.write(dir .. '/src/unrelated.d2', { 'z: 2' })
    commands = {}
    preview(source)
    assert.is_nil(command_of('d2'))

    -- A file two imports away does
    h.write(dir .. '/shared/style.d2', { 'classes: { b: {} }' })
    commands = {}
    preview(source)
    assert.are_not.equal(first, command_of('d2')[3])
  end)

  it('leaves no SVG behind when the converter fails', function()
    results['rsvg-convert'] = { code = 1, stderr = 'bad svg' }
    stub(
      vim,
      'system',
      h.system_double(function(cmd)
        table.insert(commands, cmd)
        if cmd[1] == 'd2' then h.write(cmd[3], { '<svg/>' }) end
        return results[cmd[1]] or { code = 0, stderr = '' }
      end)
    )
    preview({ 'a -> b' })
    vim.wait(1000, function() return #notified > 0 end)
    assert.are.equal('failed to render:\nbad svg', notified[1].msg)
    assert.are.same({}, vim.fn.glob(cache_dir .. '/*.svg', true, true))
  end)

  it('opens the picture outside zellij', function()
    vim.env.ZELLIJ = '0'
    vim.env.KITTY_LISTEN_ON = nil
    local opened
    stub(vim.ui, 'open', function(path) opened = path end)
    preview({ 'a -> b' })
    vim.wait(1000, function() return opened ~= nil end)
    assert.is_truthy(opened:match('%.png$'))
    assert.are.equal(1, #vim.api.nvim_list_wins())
  end)

  it('shows the picture in a kitty overlay under zellij', function()
    vim.env.ZELLIJ = '0'
    stub(vim.env, 'KITTY_LISTEN_ON', 'unix:/tmp/kitty')
    executables.kitten = 1
    preview({ 'a -> b' })
    vim.wait(1000, function() return command_of('kitten') ~= nil end)
    local kitten = command_of('kitten')
    assert.are.same(
      { 'kitten', '@', '--to', 'unix:/tmp/kitty', 'launch', '--type=overlay' },
      vim.list_slice(kitten, 1, 6)
    )
  end)

  it('opens the picture externally when the kitty overlay fails', function()
    vim.env.ZELLIJ = '0'
    stub(vim.env, 'KITTY_LISTEN_ON', 'unix:/tmp/kitty')
    executables.kitten = 1
    results.kitten = { code = 1, stderr = 'kitten: connection refused' }
    local opened
    stub(vim.ui, 'open', function(path) opened = path end)
    preview({ 'a -> b' })
    vim.wait(1000, function() return opened ~= nil end)
    assert.is_truthy(opened:match('%.png$'))
    local last = notified[#notified]
    assert.are.equal(vim.log.levels.WARN, last.level)
    assert.is_truthy(last.msg:find('kitty overlay failed', 1, true))
    assert.is_truthy(last.msg:find('connection refused', 1, true))
  end)
end)
