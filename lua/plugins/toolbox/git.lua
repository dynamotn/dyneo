-- GitHub is the `gh` remote in my repositories, with `origin` often on GitLab,
-- so plugins asking a forge take the first of these that exists
local remotes = { 'upstream', 'gh', 'github', 'origin' }

return {
  {
    -- Signs for the lines changed since the last commit, and staging hunk
    -- by hunk
    'lewis6991/gitsigns.nvim',
    event = 'LazyFile',
    opts = function()
      Snacks.toggle({
        name = 'Git Signs',
        get = function() return require('gitsigns.config').config.signcolumn end,
        set = function(state) require('gitsigns').toggle_signs(state) end,
      }):map('<leader>uG')

      return {
        signs = {
          add = { text = '▎' },
          change = { text = '▎' },
          delete = { text = '' },
          topdelete = { text = '' },
          changedelete = { text = '▎' },
          untracked = { text = '▎' },
        },
        signs_staged = {
          add = { text = '▎' },
          change = { text = '▎' },
          delete = { text = '' },
          topdelete = { text = '' },
          changedelete = { text = '▎' },
        },
        on_attach = function(buffer)
          local gs = package.loaded.gitsigns

          local function map(mode, l, r, desc)
            vim.keymap.set(
              mode,
              l,
              r,
              { buffer = buffer, desc = desc, silent = true }
            )
          end

          -- stylua: ignore start
          map('n', ']h', function()
            if vim.wo.diff then
              vim.cmd.normal({ ']c', bang = true })
            else
              gs.nav_hunk('next')
            end
          end, 'Next Hunk')
          map('n', '[h', function()
            if vim.wo.diff then
              vim.cmd.normal({ '[c', bang = true })
            else
              gs.nav_hunk('prev')
            end
          end, 'Prev Hunk')
          map('n', ']H', function() gs.nav_hunk('last') end, 'Last Hunk')
          map('n', '[H', function() gs.nav_hunk('first') end, 'First Hunk')
          map({ 'n', 'x' }, '<leader>ghs', ':Gitsigns stage_hunk<CR>', 'Stage Hunk')
          map({ 'n', 'x' }, '<leader>ghr', ':Gitsigns reset_hunk<CR>', 'Reset Hunk')
          map('n', '<leader>ghS', gs.stage_buffer, 'Stage Buffer')
          map('n', '<leader>ghu', gs.undo_stage_hunk, 'Undo Stage Hunk')
          map('n', '<leader>ghR', gs.reset_buffer, 'Reset Buffer')
          map('n', '<leader>ghp', gs.preview_hunk_inline, 'Preview Hunk Inline')
          map('n', '<leader>ghb', function() gs.blame_line({ full = true }) end, 'Blame Line')
          map('n', '<leader>ghB', function() gs.blame() end, 'Blame Buffer')
          map('n', '<leader>ghd', gs.diffthis, 'Diff This')
          map('n', '<leader>ghD', function() gs.diffthis('~') end, 'Diff This ~')
          map('n', '<leader>ghq', function() gs.setqflist('all') end, 'Hunks to Quickfix')
          map('n', '<leader>ghw', gs.toggle_word_diff, 'Toggle Word Diff')
          map('n', '<leader>ght', gs.toggle_current_line_blame, 'Toggle Line Blame')
          map({ 'o', 'x' }, 'ih', ':<C-U>Gitsigns select_hunk<CR>', 'GitSigns Select Hunk')
          -- stylua: ignore end
        end,
      }
    end,
  },
  {
    -- VSCode-style diff to review changes, history and merge conflicts
    'esmuellert/codediff.nvim',
    cmd = 'CodeDiff',
    keys = {
      { '<leader>gv', '<cmd>CodeDiff<cr>', desc = 'Review Changes (CodeDiff)' },
      {
        '<leader>gH',
        '<cmd>CodeDiff history %<cr>',
        desc = 'File History (CodeDiff)',
      },
      {
        '<leader>gH',
        ':CodeDiff history<cr>',
        desc = 'Line History (CodeDiff)',
        mode = 'x',
      },
    },
    opts = {},
  },
  {
    -- CI checks and job logs of GitHub, GitLab and Forgejo
    -- It leaves GitHub on 2026-10-31 and warns when installed from there.
    url = 'https://forge.barrettruth.com/barrettruth/ci.nvim',
    name = 'ci.nvim',
    -- Needs Neovim 0.13, above what the `stable` channel asks for
    cond = vim.fn.has('nvim-0.13') == 1,
    cmd = 'CI',
    keys = {
      { '<leader>pc', '<cmd>CI<cr>', desc = 'CI Checks' },
    },
    config = function()
      -- It picks the forge from `upstream`, else `origin`, and has no option
      -- to say otherwise: with `origin` on GitLab, `:CI` asked a project that
      -- runs no pipelines for the checks GitHub runs. `gh` finds the GitHub
      -- remote by itself once it is the CLI asked.
      local forge = require('ci.forge')
      local host = forge.host
      forge.host = function()
        -- Every remote in one call: `:CI` waits on it
        local r = require('util.system').sync(
          { 'git', 'config', '--get-regexp', [[^remote\..*\.url$]] },
          { text = true, timeout = 2000 }
        )
        local urls = {}
        if r.code == 0 then
          for name, url in (r.stdout or ''):gmatch('remote%.(%S+)%.url%s+(%S+)') do
            urls[name] = url
          end
        end
        for _, name in ipairs(remotes) do
          if urls[name] then return forge.host_of(urls[name]) or host() end
        end
        return host()
      end
    end,
  },
  -- Review GitHub pull requests and issues, when the `gh` CLI is there.
  -- Under `<leader>ph`, beside the other trackers of a project: GitLab at
  -- `<leader>pl`, Jira at `<leader>pj`.
  vim.fn.executable('gh') == 1
      and {
        {
          'pwntester/octo.nvim',
          cmd = 'Octo',
          event = { { event = 'BufReadCmd', pattern = 'octo://*' } },
          opts = function()
            vim.treesitter.language.register('markdown', 'octo')

            -- Keep the Octo windows of a session, empty as they are
            vim.api.nvim_create_autocmd('ExitPre', {
              group = vim.api.nvim_create_augroup(
                'octo_exit_pre',
                { clear = true }
              ),
              callback = function()
                for _, win in ipairs(vim.api.nvim_list_wins()) do
                  local buf = vim.api.nvim_win_get_buf(win)
                  if vim.bo[buf].filetype == 'octo' then
                    vim.bo[buf].buftype = ''
                  end
                end
              end,
            })

            return {
              enable_builtin = true,
              default_to_projects_v2 = true,
              default_merge_method = 'squash',
              picker = 'snacks',
              default_remote = remotes,
            }
          end,
          -- `<leader>gS` stays Snacks' git stash. `@` and `#` complete
          -- through the blink `git` source as they are typed, so they are not
          -- mapped to the omnifunc popup, a second menu.
          -- stylua: ignore
          keys = {
            { '<leader>ph', '', desc = '+github' },
            { '<leader>phi', '<cmd>Octo issue list<CR>', desc = 'List Issues (Octo)' },
            { '<leader>phI', '<cmd>Octo issue search<CR>', desc = 'Search Issues (Octo)' },
            { '<leader>php', '<cmd>Octo pr list<CR>', desc = 'List PRs (Octo)' },
            { '<leader>phP', '<cmd>Octo pr search<CR>', desc = 'Search PRs (Octo)' },
            { '<leader>phr', '<cmd>Octo repo list<CR>', desc = 'List Repos (Octo)' },
            { '<leader>ph/', '<cmd>Octo search<cr>', desc = 'Search (Octo)' },

            { '<localleader>a', '', desc = '+assignee (Octo)', ft = 'octo' },
            { '<localleader>c', '', desc = '+comment/code (Octo)', ft = 'octo' },
            { '<localleader>l', '', desc = '+label (Octo)', ft = 'octo' },
            { '<localleader>i', '', desc = '+issue (Octo)', ft = 'octo' },
            { '<localleader>r', '', desc = '+react (Octo)', ft = 'octo' },
            { '<localleader>p', '', desc = '+pr (Octo)', ft = 'octo' },
            { '<localleader>pr', '', desc = '+rebase (Octo)', ft = 'octo' },
            { '<localleader>ps', '', desc = '+squash (Octo)', ft = 'octo' },
            { '<localleader>v', '', desc = '+review (Octo)', ft = 'octo' },
            { '<localleader>g', '', desc = '+goto_issue (Octo)', ft = 'octo' },
          },
        },
        {
          -- Git parsers, for the issues and PRs Octo shows
          'nvim-treesitter/nvim-treesitter',
          opts = {
            ensure_installed = {
              'git_config',
              'gitcommit',
              'git_rebase',
              'gitignore',
              'gitattributes',
            },
          },
        },
      }
    or {},
  -- Review GitLab merge requests -- diff, comments, approvals, pipeline --
  -- when the `glab` CLI is there, which is also where the token comes from
  -- (`util.gitlab_auth`). Its own `gl…` mappings are turned off for these,
  -- under `<leader>pl`.
  vim.fn.executable('glab') == 1
      and {
        'harrisoncramer/gitlab.nvim',
        dependencies = {
          'MunifTanjim/nui.nvim',
          -- The maintained fork gitlab.nvim recommends: it detects renames
          -- with GitLab's own threshold, so comments land on the right file
          'dlyongemallo/diffview-plus.nvim',
        },
        -- Builds the local Go server the plugin talks to GitLab through
        build = function() require('gitlab.server').build(true) end,
        opts = function()
          local remote = 'origin'
          return {
            auth_provider = function()
              return require('util.gitlab_auth').auth(
                require('gitlab.state').default_auth_provider,
                remote
              )
            end,
            connection_settings = { remote = remote },
            keymaps = { global = { disable_all = true } },
          }
        end,
        -- stylua: ignore
        keys = {
          { '<leader>pl', '', desc = '+gitlab' },
          { '<leader>plc', function() require('gitlab').choose_merge_request() end, desc = 'Choose MR (GitLab)' },
          { '<leader>plS', function() require('gitlab').review() end, desc = 'Review This Branch (GitLab)' },
          { '<leader>plQ', function() require('gitlab').close_review() end, desc = 'Close Review (GitLab)' },
          { '<leader>pls', function() require('gitlab').summary() end, desc = 'MR Summary (GitLab)' },
          { '<leader>pld', function() require('gitlab').toggle_discussions() end, desc = 'Discussions (GitLab)' },
          { '<leader>pln', function() require('gitlab').create_note() end, desc = 'Note (GitLab)' },
          { '<leader>plD', function() require('gitlab').toggle_draft_mode() end, desc = 'Toggle Draft Mode (GitLab)' },
          { '<leader>plP', function() require('gitlab').publish_all_drafts() end, desc = 'Publish Drafts (GitLab)' },
          { '<leader>plA', function() require('gitlab').approve() end, desc = 'Approve (GitLab)' },
          { '<leader>plR', function() require('gitlab').revoke() end, desc = 'Revoke Approval (GitLab)' },
          { '<leader>plM', function() require('gitlab').merge() end, desc = 'Merge (GitLab)' },
          { '<leader>plC', function() require('gitlab').create_mr() end, desc = 'Create MR (GitLab)' },
          { '<leader>plp', function() require('gitlab').pipeline() end, desc = 'Pipeline (GitLab)' },
          { '<leader>plo', function() require('gitlab').open_in_browser() end, desc = 'Open MR in Browser (GitLab)' },
          { '<leader>plu', function() require('gitlab').copy_mr_url() end, desc = 'Copy MR URL (GitLab)' },
        },
      }
    or {},
  {
    -- Completion source. Its own spec rather than a dependency of blink.cmp,
    -- which would load it on the first `InsertEnter` of any buffer.
    'petertriho/cmp-git',
    ft = 'octo',
    -- `setup` is what registers the source, and lazy.nvim only calls it for
    -- a spec with `opts`; `gitrebase` is not among its default filetypes
    opts = {
      filetypes = { 'gitcommit', 'gitrebase', 'octo', 'NeogitCommitMessage' },
    },
    init = function()
      DyNeo.completion_sources =
        vim.tbl_extend('force', DyNeo.completion_sources, {
          git = '「GIT」',
        })
    end,
  },
  {
    'blink.cmp',
    optional = true,
    opts = {
      sources = {
        compat = { 'git' },
        per_filetype = {
          octo = require('util.cmp').sources('octo'),
        },
      },
    },
  },
}
