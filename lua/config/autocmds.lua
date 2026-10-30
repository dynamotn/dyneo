local function augroup(name)
  return vim.api.nvim_create_augroup('dyneo_' .. name, { clear = true })
end

-- Check if we need to reload the file when it changed
vim.api.nvim_create_autocmd({ 'FocusGained', 'TermClose', 'TermLeave' }, {
  group = augroup('checktime'),
  callback = function()
    if vim.o.buftype ~= 'nofile' then vim.cmd('checktime') end
  end,
})

-- Highlight on yank
vim.api.nvim_create_autocmd('TextYankPost', {
  group = augroup('highlight_yank'),
  callback = function()
    if vim.fn.has('nvim-0.13') == 1 then
      vim.hl.hl_op()
    else
      vim.hl.on_yank()
    end
  end,
})

-- resize splits if window got resized
vim.api.nvim_create_autocmd({ 'VimResized' }, {
  group = augroup('resize_splits'),
  callback = function()
    local current_tab = vim.fn.tabpagenr()
    -- Visiting each tab would run every `BufEnter` handler once per resize
    vim.cmd('noautocmd tabdo wincmd =')
    vim.cmd('noautocmd tabnext ' .. current_tab)
  end,
})

-- go to last loc when opening a buffer
vim.api.nvim_create_autocmd('BufReadPost', {
  group = augroup('last_loc'),
  callback = function(event)
    local exclude = { 'gitcommit' }
    local buf = event.buf
    if
      vim.tbl_contains(exclude, vim.bo[buf].filetype)
      or vim.b[buf].dyneo_last_loc
    then
      return
    end
    vim.b[buf].dyneo_last_loc = true
    local mark = vim.api.nvim_buf_get_mark(buf, '"')
    local lcount = vim.api.nvim_buf_line_count(buf)
    if mark[1] > 0 and mark[1] <= lcount then
      pcall(vim.api.nvim_win_set_cursor, 0, mark)
    end
  end,
})

-- close some filetypes with <q>
vim.api.nvim_create_autocmd('FileType', {
  group = augroup('close_with_q'),
  pattern = {
    'PlenaryTestPopup',
    'checkhealth',
    'dap-float',
    'dbout',
    'gitsigns-blame',
    'grug-far',
    'help',
    'lspinfo',
    'neotest-output',
    'neotest-output-panel',
    'neotest-summary',
    'notify',
    'qf',
    'startuptime',
  },
  callback = function(event)
    -- A help file open for editing (`doc/*.txt` with its modeline) is an
    -- ordinary buffer: `q` there records a macro
    if event.match == 'help' and vim.bo[event.buf].buftype ~= 'help' then
      return
    end
    vim.bo[event.buf].buflisted = false
    vim.schedule(function()
      -- Wiped in the meantime: a help or quickfix buffer closed at once
      if not vim.api.nvim_buf_is_valid(event.buf) then return end
      vim.keymap.set('n', 'q', function()
        -- The last window cannot be closed (E444): the buffer still goes
        pcall(vim.cmd.close)
        -- Never at the cost of unsaved changes
        if not vim.bo[event.buf].modified then
          pcall(vim.api.nvim_buf_delete, event.buf, { force = true })
        end
      end, {
        buffer = event.buf,
        silent = true,
        desc = 'Quit buffer',
      })
    end)
  end,
})

-- Auto create dir when saving a file, in case some intermediate directory does not exist
vim.api.nvim_create_autocmd({ 'BufWritePre' }, {
  group = augroup('auto_create_dir'),
  callback = function(event)
    if event.match:match('^%w%w+:[\\/][\\/]') then return end
    local file = vim.uv.fs_realpath(event.match) or event.match
    vim.fn.mkdir(vim.fn.fnamemodify(file, ':p:h'), 'p')
  end,
})

-- A terminal without a filetype of its own gets one, once. Terminal plugins
-- set theirs (`snacks_terminal`, `toggleterm`), and layouts key on it.
local set_ft_terminal = function()
  vim.api.nvim_create_autocmd('TermOpen', {
    group = augroup('terminal'),
    callback = function(event)
      if vim.bo[event.buf].filetype == '' then
        vim.bo[event.buf].filetype = 'terminal'
      end
    end,
  })
end

local enable_cursorline = function()
  vim.api.nvim_create_autocmd({ 'InsertLeave', 'WinEnter' }, {
    group = augroup('cursor_active_window'),
    callback = function()
      local ok, cl = pcall(vim.api.nvim_win_get_var, 0, 'auto-cursorline')
      if ok and cl then
        vim.wo.cursorline = true
        vim.api.nvim_win_del_var(0, 'auto-cursorline')
      end
    end,
  })
  vim.api.nvim_create_autocmd({ 'InsertEnter', 'WinLeave' }, {
    group = augroup('cursor_inactive_window'),
    callback = function()
      local cl = vim.wo.cursorline
      if cl then
        vim.api.nvim_win_set_var(0, 'auto-cursorline', cl)
        vim.wo.cursorline = false
      end
    end,
  })
end

local auto_relative_number = function()
  local group = augroup('auto_relative_number')
  local function set_relnum_back(win)
    vim.api.nvim_create_autocmd('CmdlineLeave', {
      group = group,
      once = true,
      callback = function() vim.wo[win].relativenumber = true end,
    })
  end
  -- Absolute numbers while a command is typed, so a range like `:12,20d` can
  -- be read straight off the gutter. Entering the command line does not
  -- repaint the window, hence the `redraw`.
  -- Only a command typed at `:`: not a search, an `input()`, or the `:` of a
  -- mapping, which would flicker the gutter for nothing
  vim.api.nvim_create_autocmd('CmdlineEnter', {
    group = group,
    pattern = ':',
    callback = function()
      if vim.fn.state('m') ~= '' then return end
      local win = vim.api.nvim_get_current_win()
      if vim.wo[win].relativenumber then
        vim.wo[win].relativenumber = false
        vim.cmd('redraw')
        set_relnum_back(win)
      end
    end,
  })
end

enable_cursorline()
set_ft_terminal()
auto_relative_number()
-- Watch the clock and swap the colorscheme when the day turns
require('util.day_night').setup()
