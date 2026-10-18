local h = require('helpers')

describe('util.mini', function()
  local mini

  before_each(function()
    h.unload('util.mini')
    mini = require('util.mini')
  end)
  after_each(function() vim.cmd('silent! %bwipeout!') end)

  describe('ai_buffer', function()
    before_each(
      function()
        vim.api.nvim_set_current_buf(
          h.buffer({ lines = { '', 'first', 'last line', '' } })
        )
      end
    )

    it(
      'takes the whole buffer around',
      function()
        assert.are.same({
          from = { line = 1, col = 1 },
          to = { line = 4, col = 1 },
        }, mini.ai_buffer('a'))
      end
    )

    it(
      'leaves the blank lines at either end out inside',
      function()
        assert.are.same({
          from = { line = 2, col = 1 },
          to = { line = 3, col = 9 },
        }, mini.ai_buffer('i'))
      end
    )

    it('selects nothing inside a buffer of blank lines', function()
      vim.api.nvim_set_current_buf(h.buffer({ lines = { '', '' } }))
      assert.are.same({ from = { line = 1, col = 1 } }, mini.ai_buffer('i'))
    end)
  end)

  describe('ai_whichkey', function()
    local added, restore
    before_each(function()
      added = nil
      restore = h.stub(package.loaded, 'which-key', {
        add = function(spec) added = spec end,
      })
    end)
    after_each(function() restore() end)

    --- The spec entry for `lhs`
    local function entry(lhs)
      for _, item in ipairs(added) do
        if item[1] == lhs then return item end
      end
    end

    it('names every text object under each prefix', function()
      mini.ai_whichkey({})
      assert.are.same({ 'o', 'x' }, added.mode)
      assert.are.equal('around', entry('a').group)
      assert.are.equal('next', entry('an').group)
      assert.are.equal('function', entry('af').desc)
      assert.are.equal('class', entry('ilc').desc)
    end)

    it('follows the prefixes mini.ai is set up with', function()
      mini.ai_whichkey({ mappings = { around_next = 'aN' } })
      assert.is_nil(entry('an'))
      assert.are.equal('function', entry('aNf').desc)
    end)
  end)

  describe('tailwind_highlighter', function()
    local highlighter
    before_each(
      function()
        highlighter =
          mini.tailwind_highlighter({ ft = { 'html' }, style = 'full' })
      end
    )

    it('only looks at the filetypes it is given', function()
      vim.bo.filetype = 'lua'
      assert.is_nil(highlighter.pattern())
      vim.bo.filetype = 'html'
      assert.is_string(highlighter.pattern())
    end)

    it('paints the colour part only in the compact style', function()
      vim.bo.filetype = 'html'
      local compact =
        mini.tailwind_highlighter({ ft = { 'html' }, style = 'compact' })
      local pattern = compact.pattern()
      assert.is_string(pattern)
      local from, to, start, stop = ('bg-red-500'):find(pattern)
      assert.equals(1, from)
      assert.equals(10, to)
      assert.equals(4, start)
      assert.equals(11, stop)
      local _, _, full_start = ('bg-red-500'):find(highlighter.pattern())
      assert.equals(1, full_start)
      assert.is_nil(
        mini.tailwind_highlighter({ ft = { 'html' }, style = 'off' }).pattern()
      )
    end)

    it('asks the buffer it is given, not the current one', function()
      local html = vim.api.nvim_create_buf(false, true)
      vim.bo[html].filetype = 'html'
      vim.bo.filetype = 'lua'
      assert.is_string(highlighter.pattern(html))
      vim.bo.filetype = 'html'
      local lua = vim.api.nvim_create_buf(false, true)
      vim.bo[lua].filetype = 'lua'
      assert.is_nil(highlighter.pattern(lua))
      vim.api.nvim_buf_delete(html, { force = true })
      vim.api.nvim_buf_delete(lua, { force = true })
    end)

    it('paints a colour class in its own colour', function()
      local group = highlighter.group(nil, nil, { full_match = 'bg-red-500' })
      assert.are.equal('MiniHipatternsTailwindred500', group)
      local hl = vim.api.nvim_get_hl(0, { name = group })
      assert.are.equal(tonumber(mini.tailwind_colors.red[500], 16), hl.bg)
      assert.are.equal(tonumber(mini.tailwind_colors.red[950], 16), hl.fg)
    end)

    it(
      'leaves an unknown colour alone',
      function()
        assert.is_nil(
          highlighter.group(nil, nil, { full_match = 'bg-nope-500' })
        )
      end
    )

    it('forgets its groups when the colorscheme changes', function()
      highlighter.group(nil, nil, { full_match = 'text-blue-200' })
      assert.is_not_nil(next(mini.tailwind_hl))
      vim.api.nvim_exec_autocmds('ColorScheme', {})
      assert.is_nil(next(mini.tailwind_hl))
    end)
  end)
end)
