local h = require('helpers')

describe('tools.c4', function()
  local c4, dir, cleanup, path, notes, restore, previewed, restore_preview

  before_each(function()
    h.unload('tools.c4', 'util.trust')
    c4 = require('tools.c4')
    dir, cleanup = h.tmpdir()
    path = vim.env.PATH
    notes, previewed = {}, nil
    restore = h.stub(
      vim,
      'notify',
      function(msg, level) table.insert(notes, { msg, level }) end
    )
    local d2 = require('tools.diagram.d2.snacks')
    restore_preview = h.stub(
      d2,
      'preview',
      function(bufnr) previewed = vim.api.nvim_buf_get_name(bufnr) end
    )
    h.write(dir .. '/likec4.config.json', { '{}' })
    h.write(dir .. '/model/landscape.c4', { 'model {}' })
    vim.cmd.edit(dir .. '/model/landscape.c4')
  end)
  after_each(function()
    restore()
    restore_preview()
    vim.env.PATH = path
    vim.fn.delete(c4.out_dir(dir), 'rf')
    vim.cmd('silent! %bwipeout!')
    cleanup()
  end)

  ---@param body string[]
  local function fake(body)
    h.write(dir .. '/bin/likec4', vim.list_extend({ '#!/bin/sh' }, body))
    vim.fn.setfperm(dir .. '/bin/likec4', 'rwxr-xr-x')
    vim.env.PATH = dir .. '/bin:' .. path
  end

  it('lists the views written, by name', function()
    local out = dir .. '/out'
    h.write(out .. '/model/index.d2', {})
    h.write(out .. '/model/deploy.d2', {})
    h.write(out .. '/notes.txt', {})
    local files, names = c4.views(out)
    assert.same({ 'deploy', 'index' }, names)
    assert.equals(out .. '/model/index.d2', files.index)
  end)

  it('draws the only view of the workspace, out of it', function()
    -- `likec4 gen d2 <root> -o <out>`: one file a view under <out>
    fake({ 'mkdir -p "$5/model" && echo "a -> b" > "$5/model/index.d2"' })
    c4.show()
    vim.wait(5000, function() return previewed ~= nil end)
    assert.equals(c4.out_dir(dir) .. '/model/index.d2', previewed)
    assert.is_nil(vim.uv.fs_stat(dir .. '/model/index.d2'))
  end)

  it('draws the view asked for, or says which there are', function()
    fake({
      'mkdir -p "$5" && touch "$5/index.d2" "$5/deploy.d2"',
    })
    c4.show('nope')
    vim.wait(5000, function() return #notes > 0 end)
    assert.same(
      { 'No view nope: deploy, index', vim.log.levels.WARN },
      notes[1]
    )
    c4.show('deploy')
    vim.wait(5000, function() return previewed ~= nil end)
    assert.equals(c4.out_dir(dir) .. '/deploy.d2', previewed)
  end)

  it('takes the nearest config of any name for the root, else .git', function()
    h.write(dir .. '/svc/.likec4rc', { '{}' })
    vim.cmd.edit(dir .. '/svc/model/a.c4')
    assert.equals(dir .. '/svc', vim.fs.root(0, c4.ROOT_MARKERS))
    vim.fn.mkdir(dir .. '/app/.git', 'p')
    vim.cmd.edit(dir .. '/app/b.c4')
    assert.equals(dir, vim.fs.root(0, c4.ROOT_MARKERS))
  end)

  it('runs a code config only once the workspace is trusted', function()
    fake({ 'mkdir -p "$5" && touch "$5/index.d2"' })
    h.write(dir .. '/likec4.config.ts', { 'export default {}' })
    local answer = 2
    local restore_confirm = h.stub(
      vim.fn,
      'confirm',
      function() return answer end
    )
    c4.show()
    assert.same({
      'Not drawn: the workspace is not trusted to run its config',
      vim.log.levels.WARN,
    }, notes[1])
    answer = 1
    c4.show()
    vim.wait(5000, function() return previewed ~= nil end)
    restore_confirm()
    assert.equals(c4.out_dir(dir) .. '/index.d2', previewed)
  end)

  it('walks a large root a chunk at a time, off the main loop', function()
    c4.SCAN_CHUNK = 2
    for i = 1, 5 do
      h.write(dir .. '/model/' .. i .. '.c4', { 'model {}' })
    end
    h.write(dir .. '/zz/likec4.config.ts', { 'export default {}' })
    local found
    c4.code_config(dir, function(config) found = config end)
    assert.is_nil(found)
    assert.is_true(vim.wait(1000, function() return found ~= nil end))
    assert.equals('zz/likec4.config.ts', found)
  end)

  it('asks about a code config that appeared after a draw', function()
    fake({ 'mkdir -p "$5" && touch "$5/index.d2"' })
    c4.show()
    vim.wait(5000, function() return previewed ~= nil end)
    previewed = nil
    h.write(dir .. '/likec4.config.ts', { 'export default {}' })
    local restore_confirm = h.stub(vim.fn, 'confirm', function() return 2 end)
    c4.show()
    restore_confirm()
    assert.same({
      'Not drawn: the workspace is not trusted to run its config',
      vim.log.levels.WARN,
    }, notes[#notes])
    assert.is_nil(previewed)
  end)

  it('draws no model with errors, though likec4 exits 0', function()
    fake({
      'mkdir -p "$5" && touch "$5/index.d2"',
      [[printf '12:00:00.000 INF likec4 workspace\n' >&2]],
      [[printf '\033[31m12:00:00.001 ERR likec4 Invalid /w/m.c4\n' >&2]],
      [[printf '    Line 3: Target not resolved\033[0m\n' >&2]],
      [[printf '12:00:00.002 INF c4:codegen generated index.d2\n' >&2]],
    })
    c4.show()
    vim.wait(5000, function() return #notes > 0 end)
    assert.is_nil(previewed)
    assert.same({
      'The model has errors, not drawn:\nlikec4 Invalid /w/m.c4\n'
        .. 'Line 3: Target not resolved',
      vim.log.levels.ERROR,
    }, notes[1])
  end)

  it('says the first error, without colours or usage', function()
    fake({
      'echo "$NO_COLOR $FORCE_COLOR" > "$5.env"',
      [[printf '12:00:00.000 INF likec4 workspace: /nope\n' >&2]],
      [[printf '\033[31m12:00:00.001 ERR likec4 no sources found\033[0m\n' >&2]],
      [[printf 'likec4 gen d2 [path]\n\ngenerate D2 files\n' >&2]],
      [[printf 'error: no views found\n' >&2]],
      'exit 1',
    })
    c4.show()
    vim.wait(5000, function() return #notes > 0 end)
    assert.same({
      'likec4 gen d2 failed: likec4 no sources found',
      vim.log.levels.ERROR,
    }, notes[1])
    assert.same({ '1 0' }, vim.fn.readfile(c4.out_dir(dir) .. '.env'))
    vim.fn.delete(c4.out_dir(dir) .. '.env')
  end)

  it('fails loudly, and refuses a buffer not written', function()
    fake({ 'echo "Invalid model" >&2', 'exit 1' })
    c4.show()
    vim.wait(5000, function() return #notes > 0 end)
    assert.same(
      { 'likec4 gen d2 failed: Invalid model', vim.log.levels.ERROR },
      notes[1]
    )
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'model { x = actor }' })
    c4.show()
    assert.same({
      'Write the buffer first: likec4 reads the files on disk',
      vim.log.levels.WARN,
    }, notes[2])
  end)
end)
