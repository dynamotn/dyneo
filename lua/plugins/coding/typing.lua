return {
  {
    -- Automatically insert/delete brackets, parentheses, quotes...
    'windwp/nvim-autopairs',
    event = 'InsertEnter',
    opts = {
      check_ts = true, -- Check grammar by TreeSitter
      enable_abbr = true, -- Enable abbreviation
      fast_wrap = {}, -- Use default FastWrap
    },
    config = function(_, plugin_opts)
      local autopairs = require('nvim-autopairs')
      autopairs.setup(plugin_opts)

      local rule = require('nvim-autopairs.rule')
      local cond = require('nvim-autopairs.conds')
      local ts_cond = require('nvim-autopairs.ts-conds')

      -- Auto pair rules per filetype
      local languages = require('config.languages')
      for _, name in ipairs(require('util.languages').names()) do
        local language = languages[name]
        if language.autopairs then
          autopairs.add_rules(
            language.autopairs(language.filetypes, rule, cond, ts_cond)
          )
        end
      end
    end,
  },
  {
    -- Accept auto brackets from autopairs for completion
    'saghen/blink.cmp',
    opts = { completion = { accept = { auto_brackets = { enabled = true } } } },
  },
  {
    -- Align text on a delimiter
    --
    -- `ga` is already the text-case operator, so the pair moves to `gl`,
    -- which nothing else claims.
    'nvim-mini/mini.align',
    keys = {
      { 'gl', mode = { 'n', 'x' }, desc = 'Align' },
      { 'gL', mode = { 'n', 'x' }, desc = 'Align with preview' },
    },
    opts = {
      mappings = {
        start = 'gl',
        start_with_preview = 'gL',
      },
    },
  },
  {
    -- Convert text case
    'johmsalas/text-case.nvim',
    -- Only its commands and `ga` mappings are needed, and nothing can reach
    -- them before the first screen is drawn: loading on `BufWinEnter` put the
    -- plugin, and which-key with it, in front of every file being opened.
    event = 'VeryLazy',
    keys = {
      'ga',
    },
    config = function()
      require('textcase').setup({
        prefix = 'ga',
      })
    end,
  },
  {
    -- Multiple cursors driven by ordinary Vim motions and operators
    --
    -- `<leader>v` holds the ways to add cursors, `<C-n>` the quickest of
    -- them. Once there is more than one, the arrows pick the main cursor and
    -- `<Esc>` clears them: those keys are only taken while cursors exist.
    'jake-stewart/multicursor.nvim',
    keys = function()
      local function mc(name, ...)
        local args = { ... }
        return function() require('multicursor-nvim')[name](unpack(args)) end
      end
      return {
        {
          '<C-n>',
          mc('matchAddCursor', 1),
          mode = { 'n', 'x' },
          desc = 'Add cursor at next match',
        },
        {
          '<leader>vn',
          mc('matchAddCursor', 1),
          mode = { 'n', 'x' },
          desc = 'Add cursor at next match',
        },
        {
          '<leader>vN',
          mc('matchAddCursor', -1),
          mode = { 'n', 'x' },
          desc = 'Add cursor at previous match',
        },
        {
          '<leader>vs',
          mc('matchSkipCursor', 1),
          mode = { 'n', 'x' },
          desc = 'Skip next match',
        },
        {
          '<leader>vS',
          mc('matchSkipCursor', -1),
          mode = { 'n', 'x' },
          desc = 'Skip previous match',
        },
        {
          '<leader>va',
          mc('matchAllAddCursors'),
          mode = { 'n', 'x' },
          desc = 'Add cursors at all matches',
        },
        {
          '<leader>vj',
          mc('lineAddCursor', 1),
          mode = { 'n', 'x' },
          desc = 'Add cursor below',
        },
        {
          '<leader>vk',
          mc('lineAddCursor', -1),
          mode = { 'n', 'x' },
          desc = 'Add cursor above',
        },
        {
          '<leader>vJ',
          mc('lineSkipCursor', 1),
          mode = { 'n', 'x' },
          desc = 'Skip line below',
        },
        {
          '<leader>vK',
          mc('lineSkipCursor', -1),
          mode = { 'n', 'x' },
          desc = 'Skip line above',
        },
        {
          '<leader>v/',
          mc('searchAllAddCursors'),
          desc = 'Add cursors at all search results',
        },
        -- Operators: `<leader>vlip` puts a cursor on each line of the
        -- paragraph, `<leader>voiwap` one on each match of the word in it,
        -- `<leader>vdip` one on each error in it
        {
          '<leader>vl',
          mc('addCursorOperator'),
          mode = { 'n', 'x' },
          desc = 'Add cursor per line (operator)',
        },
        {
          '<leader>vo',
          mc('operator'),
          mode = { 'n', 'x' },
          desc = 'Add cursor per match (operator)',
        },
        {
          '<leader>vd',
          mc(
            'diagnosticMatchCursors',
            { severity = vim.diagnostic.severity.ERROR }
          ),
          mode = { 'n', 'x' },
          desc = 'Add cursor per error (operator)',
        },
        {
          '<leader>vt',
          mc('toggleCursor'),
          mode = { 'n', 'x' },
          desc = 'Toggle cursor',
        },
        {
          '<leader>vD',
          mc('duplicateCursors'),
          mode = { 'n', 'x' },
          desc = 'Duplicate cursors',
        },
        { '<leader>vr', mc('restoreCursors'), desc = 'Restore cursors' },
        { '<leader>vA', mc('alignCursors'), desc = 'Align cursors' },
        {
          '<leader>vx',
          mc('splitCursors'),
          mode = 'x',
          desc = 'Split selection by regex',
        },
        {
          '<leader>vm',
          mc('matchCursors'),
          mode = 'x',
          desc = 'Match cursors in selection by regex',
        },
        {
          '<leader>v]',
          mc('transposeCursors', 1),
          mode = 'x',
          desc = 'Rotate selections forward',
        },
        {
          '<leader>v[',
          mc('transposeCursors', -1),
          mode = 'x',
          desc = 'Rotate selections backward',
        },
        -- Insert or append on every line of any visual selection, not only
        -- a block one
        { 'I', mc('insertVisual'), mode = 'x', desc = 'Insert on each line' },
        { 'A', mc('appendVisual'), mode = 'x', desc = 'Append on each line' },
        { '<C-LeftMouse>', mc('handleMouse'), desc = 'Add/remove cursor' },
        { '<C-LeftDrag>', mc('handleMouseDrag'), desc = 'Add cursors' },
        { '<C-LeftRelease>', mc('handleMouseRelease'), desc = 'Add cursors' },
      }
    end,
    config = function()
      local mc = require('multicursor-nvim')
      mc.setup()

      -- Only while there are cursors
      mc.addKeymapLayer(function(set)
        set({ 'n', 'x' }, '<Left>', mc.prevCursor, { desc = 'Previous cursor' })
        set({ 'n', 'x' }, '<Right>', mc.nextCursor, { desc = 'Next cursor' })
        set(
          { 'n', 'x' },
          '<leader>vq',
          mc.deleteCursor,
          { desc = 'Delete main cursor' }
        )
        -- One sequence over all cursors, rather than `dial` on each one
        set(
          { 'n', 'x' },
          'g<C-a>',
          mc.sequenceIncrement,
          { desc = 'Increment as a sequence' }
        )
        set(
          { 'n', 'x' },
          'g<C-x>',
          mc.sequenceDecrement,
          { desc = 'Decrement as a sequence' }
        )
        set('n', '<Esc>', function()
          if not mc.cursorsEnabled() then
            mc.enableCursors()
          else
            mc.clearCursors()
          end
        end, { desc = 'Clear cursors' })
      end)
    end,
  },
  {
    'folke/which-key.nvim',
    opts = {
      spec = {
        { '<leader>v', group = 'multicursor', mode = { 'n', 'x' } },
      },
    },
  },
}
