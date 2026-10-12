local h = require('helpers')

describe('tools.hex', function()
  local hex, notes, restore

  before_each(function()
    h.unload('tools.hex')
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
          'AB',
          hex.parse({ '00000099: 41 42  zz  zz', 'deadbeef: ' })
        )
      end
    )

    it(
      'takes bare hex with no offset',
      function() assert.are.equal('\1\2', hex.parse({ '0102' })) end
    )

    it('refuses a line that is not hex pairs', function()
      local bytes, err = hex.parse({ '00000000: 4142', '00000002: 4g' })
      assert.is_nil(bytes)
      assert.matches('line 2', err)
      assert.is_nil((hex.parse({ '00000000: 414' })))
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
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { '00000000: 4344' })
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
      vim.cmd.edit(path)
      hex.open()
      assert.are.equal(first, vim.api.nvim_get_current_buf())
      assert.are.equal(1, #vim.api.nvim_get_autocmds({
        group = 'dy_hex',
        buffer = first,
      }))
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
