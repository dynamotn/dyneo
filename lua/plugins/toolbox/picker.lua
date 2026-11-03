local pick = require('util.pick')

return {
  {
    -- Picker for files, grep, git, LSP and most lists of Neovim
    'folke/snacks.nvim',
    opts = {
      picker = {
        win = {
          input = {
            keys = {
              ['<a-c>'] = { 'toggle_cwd', mode = { 'n', 'i' } },
              ['<a-t>'] = { 'trouble_open', mode = { 'n', 'i' } },
              ['<a-s>'] = { 'flash', mode = { 'n', 'i' } },
              ['s'] = { 'flash' },
            },
          },
        },
        actions = {
          -- Switch between the root of the buffer and the cwd
          ---@param p snacks.Picker
          toggle_cwd = function(p)
            local root = require('util.root').get({
              buf = p.input.filter.current_buf,
              normalize = true,
            })
            local cwd = vim.fs.normalize(vim.uv.cwd() or '.')
            local current = p:cwd()
            p:set_cwd(current == root and cwd or root)
            p:find()
          end,
          -- Send the results to Trouble
          trouble_open = function(...)
            return require('trouble.sources.snacks').actions.trouble_open.action(
              ...
            )
          end,
          -- Jump to a result by a flash label
          flash = function(picker)
            require('flash').jump({
              pattern = '^',
              label = { after = { 0, 0 } },
              search = {
                mode = 'search',
                exclude = {
                  function(win)
                    return vim.bo[vim.api.nvim_win_get_buf(win)].filetype
                      ~= 'snacks_picker_list'
                  end,
                },
              },
              action = function(match)
                local idx = picker.list:row2idx(match.pos[1])
                picker.list:_move(idx, true, true)
              end,
            })
          end,
        },
      },
      explorer = {},
    },
    -- stylua: ignore
    keys = {
      { '<leader>,', function() Snacks.picker.buffers() end, desc = 'Buffers' },
      { '<leader>/', pick('grep'), desc = 'Grep (Root Dir)' },
      { '<leader>:', function() Snacks.picker.command_history() end, desc = 'Command History' },
      { '<leader><space>', pick('files'), desc = 'Find Files (Root Dir)' },
      -- find
      { '<leader>fb', function() Snacks.picker.buffers() end, desc = 'Buffers' },
      { '<leader>fB', function() Snacks.picker.buffers({ hidden = true, nofile = true }) end, desc = 'Buffers (all)' },
      { '<leader>fc', pick.config_files(), desc = 'Find Config File' },
      { '<leader>ff', pick('files'), desc = 'Find Files (Root Dir)' },
      { '<leader>fF', pick('files', { root = false }), desc = 'Find Files (cwd)' },
      { '<leader>fg', function() Snacks.picker.git_files() end, desc = 'Find Files (git-files)' },
      { '<leader>fr', pick('oldfiles'), desc = 'Recent' },
      { '<leader>fR', function() Snacks.picker.recent({ filter = { cwd = true } }) end, desc = 'Recent (cwd)' },
      { '<leader>fp', function() Snacks.picker.projects() end, desc = 'Projects' },
      { '<leader>fd', function() Snacks.picker.files({ cwd = vim.fn.expand('%:p:h') }) end, desc = 'Find Files (Buffer Dir)' },
      { '<leader>fl', function() Snacks.picker.files({ cwd = vim.fs.joinpath(vim.fn.stdpath('data'), 'lazy') }) end, desc = 'Find Plugin Source File' },
      { '<leader>fz', function() Snacks.picker.zoxide() end, desc = 'Zoxide' },
      -- explorer
      { '<leader>fe', function() Snacks.explorer({ cwd = require('util.root').get() }) end, desc = 'Explorer Snacks (root dir)' },
      { '<leader>fE', function() Snacks.explorer() end, desc = 'Explorer Snacks (cwd)' },
      { '<leader>e', '<leader>fe', desc = 'Explorer Snacks (root dir)', remap = true },
      { '<leader>E', '<leader>fE', desc = 'Explorer Snacks (cwd)', remap = true },
      -- git
      { '<leader>gd', function() Snacks.picker.git_diff() end, desc = 'Git Diff (hunks)' },
      { '<leader>gD', function() Snacks.picker.git_diff({ base = 'origin', group = true }) end, desc = 'Git Diff (origin)' },
      { '<leader>gs', function() Snacks.picker.git_status() end, desc = 'Git Status' },
      { '<leader>gS', function() Snacks.picker.git_stash() end, desc = 'Git Stash' },
      { '<leader>gr', function() Snacks.picker.git_branches() end, desc = 'Git Branches' },
      { '<leader>gp', function() Snacks.picker.git_grep() end, desc = 'Git Grep' },
      -- grep
      { '<leader>sb', function() Snacks.picker.lines() end, desc = 'Buffer Lines' },
      { '<leader>sB', function() Snacks.picker.grep_buffers() end, desc = 'Grep Open Buffers' },
      { '<leader>sg', pick('live_grep'), desc = 'Grep (Root Dir)' },
      { '<leader>sG', pick('live_grep', { root = false }), desc = 'Grep (cwd)' },
      { '<leader>sp', function() Snacks.picker.lazy() end, desc = 'Search for Plugin Spec' },
      { '<leader>sw', pick('grep_word'), desc = 'Visual selection or word (Root Dir)', mode = { 'n', 'x' } },
      { '<leader>sW', pick('grep_word', { root = false }), desc = 'Visual selection or word (cwd)', mode = { 'n', 'x' } },
      -- search
      { '<leader>s"', function() Snacks.picker.registers() end, desc = 'Registers' },
      { '<leader>s/', function() Snacks.picker.search_history() end, desc = 'Search History' },
      { '<leader>sa', function() Snacks.picker.autocmds() end, desc = 'Autocmds' },
      { '<leader>sc', function() Snacks.picker.command_history() end, desc = 'Command History' },
      { '<leader>sC', function() Snacks.picker.commands() end, desc = 'Commands' },
      { '<leader>sd', function() Snacks.picker.diagnostics() end, desc = 'Diagnostics' },
      { '<leader>sD', function() Snacks.picker.diagnostics_buffer() end, desc = 'Buffer Diagnostics' },
      { '<leader>sh', function() Snacks.picker.help() end, desc = 'Help Pages' },
      { '<leader>sH', function() Snacks.picker.highlights() end, desc = 'Highlights' },
      { '<leader>si', function() Snacks.picker.icons() end, desc = 'Icons' },
      { '<leader>sj', function() Snacks.picker.jumps() end, desc = 'Jumps' },
      { '<leader>sk', function() Snacks.picker.keymaps() end, desc = 'Keymaps' },
      { '<leader>sl', function() Snacks.picker.loclist() end, desc = 'Location List' },
      { '<leader>sM', function() Snacks.picker.man() end, desc = 'Man Pages' },
      { '<leader>sm', function() Snacks.picker.marks() end, desc = 'Marks' },
      { '<leader>sR', function() Snacks.picker.resume() end, desc = 'Resume' },
      { '<leader>sq', function() Snacks.picker.qflist() end, desc = 'Quickfix List' },
      { '<leader>su', function() Snacks.picker.undo() end, desc = 'Undotree' },
      { '<leader>s.', function() Snacks.picker.pickers() end, desc = 'All Pickers' },
      { '<leader>sL', function() Snacks.picker.lsp_config() end, desc = 'LSP Configs' },
      { '<leader>sx', function() Snacks.picker.treesitter() end, desc = 'Treesitter Symbols' },
      -- dictionary
      { '<leader>zz', function() Snacks.picker.spelling() end, desc = 'Spelling Suggestions' },
      -- ui
      { '<leader>uC', function() Snacks.picker.colorschemes() end, desc = 'Colorschemes' },
    },
  },
  {
    -- LSP lists through the picker, for every server
    'neovim/nvim-lspconfig',
    opts = {
      servers = {
        ['*'] = {
          -- stylua: ignore
          keys = {
            { 'gd', function() Snacks.picker.lsp_definitions() end, desc = 'Goto Definition', has = 'definition' },
            { 'gr', function() Snacks.picker.lsp_references({ transform = require('util.lsp').label_access }) end, nowait = true, desc = 'References' },
            { 'gI', function() Snacks.picker.lsp_implementations() end, desc = 'Goto Implementation' },
            { 'gy', function() Snacks.picker.lsp_type_definitions() end, desc = 'Goto T[y]pe Definition' },
            { '<leader>ss', function() Snacks.picker.lsp_symbols({ filter = require('config.defaults').kind_filter }) end, desc = 'LSP Symbols', has = 'documentSymbol' },
            { '<leader>sS', function() Snacks.picker.lsp_workspace_symbols({ filter = require('config.defaults').kind_filter }) end, desc = 'LSP Workspace Symbols', has = 'workspace/symbol' },
            { '<leader>cki', function() Snacks.picker.lsp_incoming_calls() end, desc = 'C[a]lls Incoming', has = 'callHierarchy/incomingCalls' },
            { '<leader>cko', function() Snacks.picker.lsp_outgoing_calls() end, desc = 'C[a]lls Outgoing', has = 'callHierarchy/outgoingCalls' },
          },
        },
      },
    },
  },
}
