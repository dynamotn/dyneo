local h = require('helpers')

describe('config.keymaps', function()
  local restore, restore_keys, claimed
  before_each(function()
    vim.g.mapleader = ' '
    -- The defaults go through Snacks, which is not loaded here: any field or
    -- call on this stand-in hands the stand-in back, so `toggle(...):map()`
    -- chains do nothing. Its `keymap.set` does map a global key, whenever
    -- the right-hand side is one Neovim takes rather than the stand-in.
    local snacks
    snacks = setmetatable({
      keymap = {
        set = function(mode, lhs, rhs, opts)
          opts = vim.deepcopy(opts or {})
          if opts.ft or opts.lsp then return end
          opts.enabled = nil
          if type(rhs) == 'string' or type(rhs) == 'function' then
            vim.keymap.set(mode, lhs, rhs, opts)
          end
        end,
      },
    }, {
      __index = function() return snacks end,
      __call = function() return snacks end,
    })
    restore = h.stub(_G, 'Snacks', snacks)
    -- Keys a plugin spec claims with `keys`, as lazy.nvim's handler sees them
    claimed = {}
    restore_keys = h.stub(require('lazy.core.handler').handlers, 'keys', {
      have = function(_, lhs, mode) return claimed[mode .. lhs] == true end,
    })
  end)
  after_each(function()
    restore_keys()
    restore()
  end)

  -- Specs below run on the mappings as `config.keymaps` leaves them
  before_each(function() dofile(h.root .. '/lua/config/keymaps.lua') end)

  local function map(mode, lhs) return vim.fn.maparg(lhs, mode, false, true) end

  describe('<leader>bR', function()
    local file, cleanup
    before_each(function()
      local dir
      dir, cleanup = h.tmpdir()
      file = dir .. '/f.txt'
      h.write(file, { 'saved' })
      vim.cmd.edit(file)
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'typed' })
    end)
    after_each(function()
      vim.cmd('bwipeout!')
      cleanup()
    end)

    it('keeps the changes unless told to discard them', function()
      local restore_confirm = h.stub(vim.fn, 'confirm', function() return 2 end)
      map('n', ' bR').callback()
      restore_confirm()
      assert.same({ 'typed' }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    end)

    it('reloads the file once told to', function()
      local restore_confirm = h.stub(vim.fn, 'confirm', function() return 1 end)
      map('n', ' bR').callback()
      restore_confirm()
      assert.same({ 'saved' }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    end)
  end)

  describe('<leader>by', function()
    local ran, messages, restores
    before_each(function()
      ran, messages = {}, {}
      vim.api.nvim_set_current_buf(h.buffer({ lines = { 'plain text' } }))
      restores = {
        h.stub(vim, 'cmd', function(cmd) table.insert(ran, cmd) end),
        h.stub(vim, 'notify', function(msg) table.insert(messages, msg) end),
      }
    end)
    after_each(function()
      for _, restore_one in ipairs(restores) do
        restore_one()
      end
    end)

    it('copies an ordinary buffer to the clipboard', function()
      map('n', ' by').callback()
      assert.are.same({ '%yank +' }, ran)
    end)

    it('keeps a sensitive buffer out of the clipboard', function()
      require('util.sensitive').mark(0, 'decrypted for the spec')
      map('n', ' by').callback()
      assert.are.same({}, ran)
      assert.are.equal(1, #messages)
    end)

    it('keeps a decrypted buffer out of the clipboard', function()
      vim.b.dy_encrypted = 'sops'
      map('n', ' by').callback()
      assert.are.same({}, ran)
    end)
  end)

  it('sets the filetype picked for the buffer', function()
    vim.api.nvim_set_current_buf(h.buffer())
    local chosen
    local restore = h.stub(vim.ui, 'select', function(items, opts, on_choice)
      assert.is_true(vim.list_contains(items, 'lua'))
      assert.are.equal('Filetype', opts.prompt)
      on_choice(chosen)
    end)
    map('n', ' bf').callback()
    assert.are.equal('', vim.bo.filetype)
    chosen = 'lua'
    map('n', ' bf').callback()
    restore()
    assert.are.equal('lua', vim.bo.filetype)
  end)

  it('clears the search and stops the snippet on escape', function()
    local stopped = 0
    local restore = h.stub(
      require('util.cmp').actions,
      'snippet_stop',
      function() stopped = stopped + 1 end
    )
    vim.o.hlsearch = true
    vim.v.hlsearch = 1
    assert.are.equal('<esc>', map('n', '<Esc>').callback())
    restore()
    assert.are.equal(0, vim.v.hlsearch)
    assert.are.equal(1, stopped)
  end)

  it('changes the word under the cursor with <C-c>, where it can', function()
    vim.api.nvim_set_current_buf(h.buffer({ lines = { 'word' } }))
    assert.are.equal('ciw', map('n', '<C-c>').callback())
    vim.bo.modifiable = false
    assert.are.equal('<C-c>', map('n', '<C-c>').callback())
    vim.bo.modifiable = true
  end)

  it('jumps to the next diagnostic and shows it', function()
    local bufnr = h.buffer({ lines = { 'one', 'two', 'three' } })
    vim.api.nvim_set_current_buf(bufnr)
    local ns = vim.api.nvim_create_namespace('dy_test_diagnostic_goto')
    vim.diagnostic.set(ns, bufnr, {
      {
        lnum = 2,
        col = 0,
        message = 'broken',
        severity = vim.diagnostic.severity.ERROR,
      },
    })
    local floats = {}
    local restore = h.stub(
      vim.diagnostic,
      'open_float',
      function(opts) table.insert(floats, opts) end
    )
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    map('n', ']e').callback()
    vim.wait(500, function() return #floats > 0 end)
    -- Nothing to jump to, nothing shown
    map('n', ']w').callback()
    vim.wait(100, function() return false end)
    restore()
    vim.diagnostic.reset(ns, bufnr)
    assert.are.equal(3, vim.fn.line('.'))
    assert.are.equal(1, #floats)
    assert.are.equal(bufnr, floats[1].bufnr)
    assert.are.equal('cursor', floats[1].scope)
  end)

  it('keeps the diagnostics of a sensitive buffer off the clipboard', function()
    local bufnr = h.buffer({ lines = { 'TOKEN=abc' } })
    vim.api.nvim_set_current_buf(bufnr)
    require('util.sensitive').mark(bufnr, 'decrypted for the spec')
    local ns = vim.api.nvim_create_namespace('keymaps_spec_xc')
    vim.diagnostic.set(ns, bufnr, {
      { lnum = 0, col = 0, message = 'unknown word "abc"' },
    })
    vim.fn.setreg('+', 'before')
    local restore = h.stub(vim, 'notify', function() end)
    map('n', ' xc').callback()
    restore()
    vim.diagnostic.reset(ns, bufnr)
    assert.are.equal('before', vim.fn.getreg('+'))
  end)

  it('says when the cursor line has no diagnostics to copy', function()
    vim.api.nvim_set_current_buf(h.buffer({ lines = { 'clean' } }))
    local messages = {}
    local restore = h.stub(
      vim,
      'notify',
      function(msg, level) table.insert(messages, { msg, level }) end
    )
    map('n', ' xc').callback()
    restore()
    assert.are.same(
      { { 'No diagnostics on this line', vim.log.levels.WARN } },
      messages
    )
  end)

  it('copies the URL of the file on the forge', function()
    local copied = {}
    local restores = {
      h.stub(vim.fn, 'setreg', function(reg, value) copied[reg] = value end),
    }
    rawset(Snacks, 'gitbrowse', function(opts)
      assert.is_false(opts.notify)
      opts.open('https://forge.example/o/r/blob/main/a.lua')
    end)
    map('n', ' gY').callback()
    rawset(Snacks, 'gitbrowse', nil)
    for _, restore in ipairs(restores) do
      restore()
    end
    assert.are.equal('https://forge.example/o/r/blob/main/a.lua', copied['+'])
  end)

  it('reads the file of the buffer as a log', function()
    local ran, messages = {}, {}
    local restores = {
      h.stub(vim, 'cmd', function(cmd) table.insert(ran, cmd) end),
      h.stub(vim, 'notify', function(msg) table.insert(messages, msg) end),
    }
    vim.api.nvim_set_current_buf(h.buffer())
    map('n', ' il').callback()
    vim.api.nvim_set_current_buf(h.buffer({ name = '/var/log/app.log' }))
    local file = vim.api.nvim_buf_get_name(0)
    map('n', ' il').callback()
    for _, restore in ipairs(restores) do
      restore()
    end
    assert.are.same({ 'The buffer has no file' }, messages)
    assert.are.same({ { cmd = 'DyLog', args = { file } } }, ran)
  end)

  it('maps the path copiers', function()
    for _, suffix in ipairs({
      'y',
      'Y',
      'l',
      'L',
      'c',
      'C',
      'd',
      'D',
      'P',
      'n',
      'N',
    }) do
      local m = map('n', ' fy' .. suffix)
      assert.is_not_nil(m.callback, suffix)
    end
  end)

  it('maps the tab jumps', function()
    for number = 1, 9 do
      assert.are.equal(
        '<cmd>tabn' .. number .. '<cr>',
        map('n', ' <Tab>' .. number).rhs
      )
    end
  end)

  it('maps the tools of this configuration', function()
    for lhs, rhs in pairs({
      [' prr'] = '<cmd>DyAdr list<cr>',
      [' pjy'] = '<cmd>DyJira copy<cr>',
      [' ia'] = '<cmd>DyArchitecture<cr>',
      [' ii'] = '<cmd>DyInspect<cr>',
      [' ic'] = '<cmd>DyKube context<cr>',
      [' kq'] = '<cmd>DyQuarantine<cr>',
      [' ks'] = '<cmd>DySbom<cr>',
      [' kl'] = '<cmd>DySbom lock<cr>',
      [' ki'] = '<cmd>DyImageScan<cr>',
      [' ka'] = '<cmd>DyAiGuardCheck<cr>',
      [' kL'] = '<cmd>DyAiGuardLog<cr>',
    }) do
      assert.are.equal(rhs, map('n', lhs).rhs, lhs)
    end
    assert.is_not_nil(map('n', ' il').callback)
    assert.is_not_nil(map('n', ' zm').callback)
  end)

  it('drops the LSP keys `gr` hides', function()
    for _, lhs in ipairs({ 'grn', 'gra', 'grr', 'gri', 'grt', 'grx' }) do
      assert.are.same({}, map('n', lhs), lhs)
    end
  end)

  describe('smart delete', function()
    local function expand(mode, key, lines)
      local bufnr = h.buffer({ lines = lines })
      vim.api.nvim_set_current_buf(bufnr)
      return map(mode, key).callback()
    end

    for _, case in ipairs({
      { 'n', 'dd' },
      { 'n', 'cc' },
      { 'n', 'x' },
      { 'n', 'X' },
      { 'n', 'C' },
      { 'x', 'd' },
      { 'x', 'x' },
      { 'x', 'c' },
      { 'x', 'C' },
      { 'x', 'X' },
    }) do
      local mode, key = case[1], case[2]
      it(
        mode .. ' ' .. key .. ' goes to the black hole on a blank line',
        function() assert.are.equal('"_' .. key, expand(mode, key, { '   ' })) end
      )
      it(
        mode .. ' ' .. key .. ' yanks on a line with text',
        function() assert.are.equal(key, expand(mode, key, { 'text' })) end
      )
    end

    it('leaves the `d` and `c` operators alone', function()
      -- `d}` on a blank line takes the paragraph after it
      assert.same({}, map('n', 'd'))
      assert.same({}, map('n', 'c'))
    end)

    it('is not mapped in Select mode, where the keys type text', function()
      assert.same({}, map('s', 'd'))
      assert.same({}, map('s', 'x'))
    end)

    -- Typed for real: `v:count1` and `v:register` cannot be stubbed
    local function type_keys(keys, lines)
      vim.api.nvim_set_current_buf(h.buffer({ lines = lines }))
      vim.fn.setreg('"', 'kept')
      vim.api.nvim_feedkeys(keys, 'mx', false)
    end

    it('yanks when the count reaches a line with text', function()
      type_keys('2dd', { '', 'text' })
      assert.are.equal('\ntext\n', vim.fn.getreg('"'))
    end)

    it('keeps the yank when every counted line is blank', function()
      type_keys('2dd', { '', '  ', 'text' })
      assert.are.equal('kept', vim.fn.getreg('"'))
    end)

    it('reads a selection made upwards the same', function()
      type_keys('GVkd', { 'text', '', '  ' })
      assert.are.equal('kept', vim.fn.getreg('"'))
      type_keys('GVkd', { '', 'text', 'more' })
      assert.are.equal('text\nmore\n', vim.fn.getreg('"'))
    end)

    it('honours a register given explicitly', function()
      vim.fn.setreg('a', '')
      type_keys('"add', { '' })
      assert.are.equal('\n', vim.fn.getreg('a'))
    end)
  end)

  describe('command abbreviations', function()
    local function expand(lhs, cmdtype, cmdline)
      local restores = {
        h.stub(vim.fn, 'getcmdtype', function() return cmdtype end),
        h.stub(vim.fn, 'getcmdline', function() return cmdline end),
      }
      local abbr = vim.fn.maparg(lhs, 'c', true, true)
      local result = abbr.callback()
      for _, restore in ipairs(restores) do
        restore()
      end
      return result
    end

    it('expands a whole command', function()
      assert.are.equal('w', expand('W', ':', 'W'))
      assert.are.equal('wq', expand('WQ', ':', 'WQ'))
      assert.are.equal('DySudoWrite', expand('ww', ':', 'ww'))
    end)

    it('leaves the word inside a longer command', function()
      assert.are.equal('W', expand('W', ':', 'e foo/W'))
      assert.are.equal('ww', expand('ww', ':', 'e foo/ww'))
    end)

    it(
      'leaves a search alone',
      function() assert.are.equal('ww', expand('ww', '/', 'ww')) end
    )
  end)

  describe('lazygit', function()
    local executable, opened
    before_each(function()
      executable, opened = vim.fn.executable, {}
      rawset(
        Snacks,
        'lazygit',
        function(opts) table.insert(opened, { opts = opts }) end
      )
    end)
    after_each(function()
      vim.fn.executable = executable
      -- Gone already when the outer `after_each` ran first
      if _G.Snacks then rawset(Snacks, 'lazygit', nil) end
      pcall(vim.keymap.del, 'n', ' gg')
      pcall(vim.keymap.del, 'n', ' gG')
    end)

    it('opens lazygit at the root, or where Neovim runs', function()
      vim.fn.executable = function(name)
        if name == 'lazygit' then return 1 end
        return executable(name)
      end
      local restore_root = h.stub(
        require('util.root'),
        'git',
        function() return '/repo' end
      )
      dofile(h.root .. '/lua/config/keymaps.lua')
      map('n', ' gg').callback()
      map('n', ' gG').callback()
      restore_root()
      assert.same({ { opts = { cwd = '/repo' } }, {} }, opened)
    end)

    it('maps nothing for it without the binary', function()
      vim.fn.executable = function(name)
        if name == 'lazygit' then return 0 end
        return executable(name)
      end
      pcall(vim.keymap.del, 'n', ' gg')
      dofile(h.root .. '/lua/config/keymaps.lua')
      assert.same({}, map('n', ' gg'))
    end)
  end)

  it('leaves a key claimed by a plugin spec to it', function()
    for _, key in ipairs({ { 'n', '<C-c>' }, { 'x', '<C-r>' } }) do
      vim.keymap.del(key[1], key[2])
      claimed[key[1] .. key[2]] = true
    end
    dofile(h.root .. '/lua/config/keymaps.lua')
    assert.same({}, map('n', '<C-c>'))
    assert.same({}, map('x', '<C-r>'))
    assert.are.equal('<Esc>/\\%V', map('x', '/').rhs)
  end)

  it('searches the selection literally, without yanking it', function()
    vim.api.nvim_set_current_buf(h.buffer({ lines = { 'a.b/c<d\\', 'x' } }))
    vim.fn.setreg('"', 'kept')
    local keys = vim.keycode('0v$h<C-f><CR>')
    vim.api.nvim_feedkeys(keys, 'mx', false)
    assert.are.equal('\\Va.b\\/c<d\\\\', vim.fn.getreg('/'))
    assert.are.equal('kept', vim.fn.getreg('"'))
  end)

  it('jumps between merge conflict markers, either way', function()
    vim.api.nvim_set_current_buf(h.buffer({
      lines = {
        'text',
        '<<<<<<< HEAD',
        'ours',
        '=======',
        '======== not a marker',
        'theirs',
        '>>>>>>> branch',
      },
    }))
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    map('n', ']x').callback()
    assert.are.equal(2, vim.fn.line('.'))
    map('n', ']x').callback()
    assert.are.equal(4, vim.fn.line('.'))
    map('n', ']x').callback()
    assert.are.equal(7, vim.fn.line('.'))
    map('n', '[x').callback()
    assert.are.equal(4, vim.fn.line('.'))
  end)

  it('copies the diagnostics of the cursor line', function()
    local bufnr = h.buffer({ lines = { 'one', 'two' } })
    vim.api.nvim_set_current_buf(bufnr)
    local ns = vim.api.nvim_create_namespace('dy_test_copy_diagnostics')
    vim.diagnostic.set(ns, bufnr, {
      { lnum = 1, col = 0, message = 'first', source = 'lint' },
      { lnum = 1, col = 1, message = 'second' },
      { lnum = 0, col = 0, message = 'other line' },
    })
    local copied = {}
    local restore_setreg = h.stub(
      vim.fn,
      'setreg',
      function(reg, value) copied[reg] = value end
    )
    local restore_notify = h.stub(vim, 'notify', function() end)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    map('n', ' xc').callback()
    restore_notify()
    restore_setreg()
    vim.diagnostic.reset(ns, bufnr)
    assert.are.equal('lint: first\nsecond', copied['+'])
  end)

  it('maps a command acting on one kind of buffer only there', function()
    for _, lhs in ipairs({ ' pAm', ' pAo' }) do
      assert.same({}, map('n', lhs), lhs)
    end
  end)

  it('keeps the command line of the search mappings in sight', function()
    for _, lhs in ipairs({ '/', '<C-f>', '<C-r>' }) do
      assert.are.equal(0, map('x', lhs).silent, lhs)
    end
    assert.are.equal(1, map('n', '<C-c>').silent)
  end)
end)
