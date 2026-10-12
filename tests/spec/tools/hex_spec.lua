local h = require('helpers')

describe('tools.hex', function()
  local hex, notes, restore

  before_each(function()
    h.unload('tools.hex')
    dofile(h.root .. '/plugin/hex.lua')
    hex = require('tools.hex')
    notes = {}
    restore = h.stub(vim, 'notify', function(msg) table.insert(notes, msg) end)
  end)
  after_each(function()
    restore()
    vim.cmd('silent! %bwipeout!')
  end)

  describe('dump', function()
    it(
      'lays the bytes out as xxd does',
      function()
        assert.are.same({
          '00000000: 6162 6364 6566 6768 696a 6b6c 6d6e 6f70  abcdefghijklmnop',
          '00000010: 000a ff                                  ...',
        }, hex.dump('abcdefghijklmnop\0\n\255'))
      end
    )

    it(
      'gives nothing for an empty file',
      function() assert.are.same({}, hex.dump('')) end
    )
  end)

  describe('parse', function()
    it('reads back every byte of a dump', function()
      local bytes = {}
      for i = 0, 255 do
        bytes[#bytes + 1] = string.char(i)
      end
      local all = table.concat(bytes)
      assert.are.equal(all, hex.parse(hex.dump(all)))
    end)

    it(
      'ignores the offsets and the text column',
      function()
        assert.are.equal(
          'ABC',
          hex.parse({ '00000099: 41 42  zz', 'deadbeef: ', '43' })
        )
      end
    )

    it(
      'takes bare hex with no offset, in either case',
      function() assert.are.equal('\1\2\171', hex.parse({ '0102 aB' })) end
    )

    it(
      'takes a text column that starts with a byte shown as a space',
      function()
        assert.are.equal(' a', hex.parse(hex.dump(' a')))
        assert.are.equal('  ', hex.parse(hex.dump('  ')))
      end
    )

    it('refuses a line that is not hex pairs', function()
      local bytes, err = hex.parse({ '00000000: 4142  AB', '00000002: 4g  ?' })
      assert.is_nil(bytes)
      assert.matches('line 2', err)
      assert.is_nil((hex.parse({ '414' })))
    end)

    it('refuses a line whose text column does not match its bytes', function()
      local lines = hex.dump('abcdefghijklmnopqr')
      local function refused(line)
        local bytes, err = hex.parse({ lines[2], line })
        assert.is_nil(bytes)
        assert.matches('line 2', err)
      end
      -- one space before a text column of hex digits
      refused('00000000: 6162 6364  6566 abcdef')
      refused('00000000: 6162 6364 abcd')
      -- two lines joined with `J`
      refused(lines[1] .. ' ' .. lines[2])
      -- two spaces inside the hex columns
      refused('00000000: 6162  6364 6566  abcdef')
      -- an offset with hex and no text column
      refused('00000000: 4344')
    end)
  end)

  describe('open and write', function()
    local dir, cleanup
    before_each(function()
      dir, cleanup = h.tmpdir()
    end)
    after_each(function() cleanup() end)

    local function file(name, bytes)
      local path = dir .. '/' .. name
      local f = assert(io.open(path, 'wb'))
      f:write(bytes)
      f:close()
      return path
    end

    local function read(path)
      local f = assert(io.open(path, 'rb'))
      local bytes = f:read('*a')
      f:close()
      return bytes
    end

    it('edits the bytes of the file and writes them back', function()
      local path = file('a.bin', 'AB\0')
      vim.cmd.edit(path)
      hex.open()
      local bufnr = vim.api.nvim_get_current_buf()
      assert.are.equal('dyhex://' .. path, vim.api.nvim_buf_get_name(bufnr))
      assert.are.equal('xxd', vim.bo.filetype)
      assert.are.equal('acwrite', vim.bo.buftype)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { '00000000: 4344  CD' })
      vim.cmd.write()
      assert.are.equal('CD', read(path))
      assert.is_false(vim.bo[bufnr].modified)
    end)

    it('writes nothing when the dump does not parse', function()
      local path = file('b.bin', 'AB')
      vim.cmd.edit(path)
      hex.open()
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'zz' })
      vim.cmd.write()
      assert.are.equal('AB', read(path))
      assert.matches('nothing written', notes[#notes])
    end)

    it('opens the same dump again rather than a second one', function()
      local path = file('c.bin', 'x')
      vim.cmd.edit(path)
      hex.open()
      local first = vim.api.nvim_get_current_buf()
      local function handlers()
        return #vim.api.nvim_get_autocmds({ group = 'dy_hex', buffer = first })
      end
      local before = handlers()
      vim.cmd.edit(path)
      hex.open()
      vim.cmd('edit!')
      assert.are.equal(first, vim.api.nvim_get_current_buf())
      assert.are.equal(before, handlers())
    end)

    it('does not undo the dump into an empty buffer', function()
      local path = file('u.bin', 'AB')
      vim.cmd.edit(path)
      hex.open()
      local dump = vim.api.nvim_buf_get_lines(0, 0, -1, false)
      vim.cmd('silent! undo')
      assert.are.same(dump, vim.api.nvim_buf_get_lines(0, 0, -1, false))
      vim.cmd.write()
      assert.are.equal('AB', read(path))
    end)

    it('dumps the file again on `:e!`', function()
      local path = file('r.bin', 'AB')
      vim.cmd.edit(path)
      hex.open()
      local dump = vim.api.nvim_buf_get_lines(0, 0, -1, false)
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { '41' })
      vim.cmd('edit!')
      assert.are.same(dump, vim.api.nvim_buf_get_lines(0, 0, -1, false))
      assert.is_false(vim.bo.modified)
      vim.cmd.write()
      assert.are.equal('AB', read(path))
    end)

    it('writes only the whole dump over its own file', function()
      local path = file('w.bin', 'AB')
      vim.cmd.edit(path)
      hex.open()
      local bufnr = vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { '43', '44' })
      pcall(vim.cmd.write, dir .. '/other.bin')
      assert.matches('only over its own file', notes[#notes])
      pcall(vim.cmd, '1write!')
      assert.matches('Only the whole dump', notes[#notes])
      pcall(vim.cmd.saveas, dir .. '/saved.bin')
      assert.matches('only over its own file', notes[#notes])
      assert.are.equal('AB', read(path))
      assert.is_nil(vim.uv.fs_stat(dir .. '/other.bin'))
      assert.is_true(vim.bo[bufnr].modified)
    end)

    it('tells apart files whose names start alike', function()
      local short = file('p.bin', 'A')
      local long = file('p.bin.bak', 'B')
      vim.cmd.edit(long)
      hex.open()
      local first = vim.api.nvim_get_current_buf()
      vim.cmd.edit(short)
      hex.open()
      assert.are_not.equal(first, vim.api.nvim_get_current_buf())
      assert.are.equal('dyhex://' .. short, vim.api.nvim_buf_get_name(0))
    end)

    it('refuses to write over a file changed on disk', function()
      local path = file('s.bin', 'AB')
      vim.cmd.edit(path)
      hex.open()
      file('s.bin', 'changed')
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { '43' })
      vim.cmd.write()
      assert.are.equal('changed', read(path))
      assert.matches('changed on disk', notes[#notes])
      assert.is_true(vim.bo.modified)
    end)

    it('keeps the buffer modified when the file cannot be written', function()
      local path = file('ro.bin', 'AB')
      vim.cmd.edit(path)
      hex.open()
      vim.uv.fs_chmod(path, tonumber('444', 8))
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { '43' })
      vim.cmd.write()
      assert.are.equal('AB', read(path))
      assert.matches('nothing written', notes[#notes])
      assert.is_true(vim.bo.modified)
    end)

    it('says so of a file it cannot read', function()
      local path = file('x.bin', 'AB')
      vim.cmd.edit(path)
      vim.uv.fs_chmod(path, 0)
      hex.open()
      assert.matches('denied', notes[#notes])
      vim.cmd.write()
      assert.matches('not read', notes[#notes])
      vim.uv.fs_chmod(path, tonumber('644', 8))
      assert.are.equal('AB', read(path))
    end)

    it('refuses a buffer with unwritten edits', function()
      vim.cmd.edit(file('d.bin', 'x'))
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'changed' })
      hex.open()
      assert.matches('Write the buffer first', notes[1])
      assert.are_not.equal('xxd', vim.bo.filetype)
    end)

    it('refuses a sensitive file', function()
      vim.cmd.edit(file('.env', 'TOKEN=x'))
      hex.open()
      assert.matches('sensitive', notes[1])
    end)

    it('refuses a file over the limit', function()
      hex.LIMIT = 1
      vim.cmd.edit(file('e.bin', 'xy'))
      hex.open()
      assert.matches('over', notes[1])
    end)
  end)
end)
