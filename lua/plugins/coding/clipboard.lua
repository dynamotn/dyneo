return {
  {
    -- Yank history
    'gbprod/yanky.nvim',
    -- The ring only has to be listening by the time a key can be pressed,
    -- which is after the first screen, not before the file is shown.
    event = 'VeryLazy',
    opts = {
      system_clipboard = {
        sync_with_ring = not vim.env.SSH_CONNECTION,
        -- Read off `clipboard` otherwise, which `config.lazy` keeps empty
        -- until after yanky has loaded: that would be `*`, the selection
        clipboard_register = '+',
      },
      highlight = { timer = 150 },
    },
    config = function(_, opts)
      require('yanky').setup(opts)
      -- The ring is `g:YANKY_HISTORY`, which shada's `!` keeps across
      -- sessions and the picker lists: a yank from a buffer holding secrets
      -- (a decrypted file, a `.env`) goes to the registers only, which
      -- `tools.encrypted` keeps out of the shada file once it decrypted one
      local history = require('yanky.history')
      local push = history.push
      history.push = function(item)
        if require('util.sensitive').is_sensitive(0) then return end
        return push(item)
      end
    end,
    keys = {
      {
        '<leader>yh',
        function() Snacks.picker.pick('yanky') end,
        mode = { 'n', 'x' },
        desc = 'Open Yank History',
      },
      { 'y', '<Plug>(YankyYank)', mode = { 'n', 'x' }, desc = 'Yank Text' },
      {
        'p',
        '<Plug>(YankyPutAfter)',
        mode = { 'n', 'x' },
        desc = 'Put Text After Cursor',
      },
      {
        'P',
        '<Plug>(YankyPutBefore)',
        mode = { 'n', 'x' },
        desc = 'Put Text Before Cursor',
      },
      {
        'gp',
        '<Plug>(YankyGPutAfter)',
        mode = { 'n', 'x' },
        desc = 'Put Text After Selection',
      },
      {
        'gP',
        '<Plug>(YankyGPutBefore)',
        mode = { 'n', 'x' },
        desc = 'Put Text Before Selection',
      },
      {
        '[y',
        '<Plug>(YankyCycleForward)',
        desc = 'Cycle Forward Through Yank History',
      },
      {
        ']y',
        '<Plug>(YankyCycleBackward)',
        desc = 'Cycle Backward Through Yank History',
      },
      {
        ']p',
        '<Plug>(YankyPutIndentAfterLinewise)',
        desc = 'Put Indented After Cursor (Linewise)',
      },
      {
        '[p',
        '<Plug>(YankyPutIndentBeforeLinewise)',
        desc = 'Put Indented Before Cursor (Linewise)',
      },
      {
        ']P',
        '<Plug>(YankyPutIndentAfterLinewise)',
        desc = 'Put Indented After Cursor (Linewise)',
      },
      {
        '[P',
        '<Plug>(YankyPutIndentBeforeLinewise)',
        desc = 'Put Indented Before Cursor (Linewise)',
      },
      {
        '>p',
        '<Plug>(YankyPutIndentAfterShiftRight)',
        desc = 'Put and Indent Right',
      },
      {
        '<p',
        '<Plug>(YankyPutIndentAfterShiftLeft)',
        desc = 'Put and Indent Left',
      },
      {
        '>P',
        '<Plug>(YankyPutIndentBeforeShiftRight)',
        desc = 'Put Before and Indent Right',
      },
      {
        '<P',
        '<Plug>(YankyPutIndentBeforeShiftLeft)',
        desc = 'Put Before and Indent Left',
      },
      {
        '=p',
        '<Plug>(YankyPutAfterFilter)',
        desc = 'Put After Applying a Filter',
      },
      {
        '=P',
        '<Plug>(YankyPutBeforeFilter)',
        desc = 'Put Before Applying a Filter',
      },
    },
  },
}
