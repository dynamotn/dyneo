local h = require('helpers')

describe('util.rename', function()
  local rename, dir, cleanup, renamed, notes, answer, restore

  before_each(function()
    dir, cleanup = h.tmpdir()
    renamed, notes, answer = {}, {}, 1
    restore = {
      h.stub(_G, 'Snacks', {
        rename = {
          rename_file = function(opts) table.insert(renamed, opts) end,
        },
      }),
      h.stub(vim, 'notify', function(msg) table.insert(notes, msg) end),
      h.stub(vim.fn, 'confirm', function() return answer end),
    }
    h.unload('util.rename')
    rename = require('util.rename')
    h.write(dir .. '/a.lua', { 'old' })
    vim.cmd.edit(dir .. '/a.lua')
  end)

  after_each(function()
    for i = #restore, 1, -1 do
      restore[i]()
    end
    vim.cmd('silent! %bwipeout!')
    cleanup()
  end)

  it('hands a free target to Snacks', function()
    rename.rename_file({ to = dir .. '/b.lua' })
    assert.same({ { from = dir .. '/a.lua', to = dir .. '/b.lua' } }, renamed)
  end)

  it('refuses to overwrite a file unless forced', function()
    h.write(dir .. '/b.lua', { 'keep' })
    rename.rename_file({ to = dir .. '/b.lua' })
    assert.same({}, renamed)
    assert.matches('exists', notes[1])
    rename.rename_file({ to = dir .. '/b.lua', force = true })
    assert.equals(1, #renamed)
  end)

  it('saves a modified buffer before renaming it', function()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'new' })
    rename.rename_file({ to = dir .. '/b.lua' })
    assert.same({ 'new' }, vim.fn.readfile(dir .. '/a.lua'))
    assert.is_false(vim.bo.modified)
    assert.equals(1, #renamed)
  end)

  it('calls the rename off when the save is declined', function()
    answer = 2
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'new' })
    rename.rename_file({ to = dir .. '/b.lua' })
    assert.same({}, renamed)
    assert.same({ 'old' }, vim.fn.readfile(dir .. '/a.lua'))
  end)

  it('asks for the target when none is given', function()
    local prompts = {}
    local answer_with
    table.insert(
      restore,
      h.stub(vim.ui, 'input', function(opts, on_confirm)
        table.insert(prompts, opts)
        on_confirm(answer_with)
      end)
    )
    answer_with = nil
    rename.rename_file()
    assert.same({}, renamed)
    answer_with = ''
    rename.rename_file()
    assert.same({}, renamed)
    answer_with = dir .. '/b.lua'
    rename.rename_file()
    assert.same({ { from = dir .. '/a.lua', to = dir .. '/b.lua' } }, renamed)
    assert.equals(3, #prompts)
    assert.equals('file', prompts[1].completion)
    assert.equals(vim.fn.fnamemodify(dir .. '/a.lua', ':.'), prompts[1].default)
  end)

  it('says so for a buffer with no file', function()
    vim.cmd.enew()
    rename.rename_file({ to = dir .. '/b.lua' })
    assert.same({}, renamed)
    assert.matches('no file', notes[1])
  end)

  it('takes the target and the bang from :DyRename', function()
    rename.setup()
    h.write(dir .. '/b.lua', { 'keep' })
    vim.cmd('DyRename ' .. vim.fn.fnameescape(dir .. '/b.lua'))
    assert.same({}, renamed)
    vim.cmd('DyRename! ' .. vim.fn.fnameescape(dir .. '/b.lua'))
    assert.equals(1, #renamed)
    vim.api.nvim_del_user_command('DyRename')
  end)
end)
