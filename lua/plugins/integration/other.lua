return {
  {
    -- Terminal
    'akinsho/nvim-toggleterm.lua',
    event = 'VeryLazy',
    opts = {
      open_mapping = '<F3>',
    },
  },
  {
    -- Open files from a terminal inside Neovim in this Neovim, not a nested one
    --
    -- `git commit`, `$EDITOR` from an AI CLI or `kubectl edit` in a toggleterm
    -- or Snacks terminal hand their file over here and wait until it is
    -- written. A plain `nvim` with no file still starts a nested one.
    'willothy/flatten.nvim',
    -- Has to run before anything else to hand the files over and quit
    lazy = false,
    priority = 1001,
    -- A headless run (scripts, `check-startup`, Mason) from a terminal in
    -- Neovim would otherwise send its files here and quit before doing its job
    cond = not vim.list_contains(vim.v.argv, '--headless'),
    opts = function()
      -- The terminal the files came from, taken while it still has the focus
      ---@type { term: any, win: integer }?
      local origin

      --- Whether `path` sits in a temporary directory
      ---@param path string
      ---@return boolean
      local function is_temporary(path)
        path = vim.fs.normalize(vim.fn.fnamemodify(path, ':p'))
        for _, dir in ipairs({
          vim.uv.os_tmpdir() or '',
          -- macOS gives either side of its `/private` symlinks
          '/tmp',
          '/private/tmp',
          '/var/folders',
          '/private/var/folders',
        }) do
          dir = vim.fs.normalize(dir)
          if dir ~= '' and vim.startswith(path, dir .. '/') then return true end
        end
        return false
      end

      return {
        hooks = {
          -- A program handing a temporary file to `$EDITOR` reads it back
          -- once the editor exits, so it has to wait too
          should_block = function(argv)
            if require('flatten').hooks.should_block(argv) then return true end
            for _, arg in ipairs(argv) do
              if not vim.startswith(arg, '-') and is_temporary(arg) then
                return true
              end
            end
            return false
          end,
          pre_open = function()
            local ok, terminal = pcall(require, 'toggleterm.terminal')
            local id = ok and terminal.get_focused_id()
            origin = {
              term = id and terminal.get(id) or nil,
              win = vim.api.nvim_get_current_win(),
            }
          end,
          post_open = function(opts)
            -- Get a floating terminal out of the way of the file; a split
            -- one, like an AI CLI's, can stay next to it
            if origin and origin.term then
              origin.term:close()
            elseif
              origin
              and vim.api.nvim_win_is_valid(origin.win)
              and vim.api.nvim_win_get_config(origin.win).relative ~= ''
            then
              vim.api.nvim_win_hide(origin.win)
            end
            if opts.winnr and vim.api.nvim_win_is_valid(opts.winnr) then
              vim.api.nvim_set_current_win(opts.winnr)
            end
            if not opts.is_blocking then
              origin = nil
              return
            end
            -- `:w` is enough to finish: the buffer goes, its window stays
            vim.api.nvim_create_autocmd('BufWritePost', {
              buffer = opts.bufnr,
              once = true,
              callback = vim.schedule_wrap(
                function() Snacks.bufdelete({ buf = opts.bufnr }) end
              ),
            })
          end,
          -- Bring a toggleterm back once the program it runs carries on
          block_end = vim.schedule_wrap(function()
            if origin and origin.term then origin.term:open() end
            origin = nil
          end),
        },
        nest_if_no_args = true,
        window = {
          -- The terminal is the current window; open next to it, not in it
          open = 'alternate',
        },
      }
    end,
  },
  {
    -- Translate
    'potamides/pantran.nvim',
    cmd = 'Pantran',
    keys = {
      { '<leader>ct', '<cmd>Pantran<cr>', desc = 'Translate' },
      -- The selection reaches `:Pantran` as its range
      { '<leader>ct', ':Pantran<cr>', desc = 'Translate', mode = 'x' },
    },
    opts = {
      default_engine = 'google',
      engines = {
        google = {
          fallback = {
            default_source = 'en',
            default_target = 'vi',
          },
        },
      },
      command = {
        default_mode = 'hover',
      },
    },
  },
  {
    -- Paste image from clipboard
    'HakonHarnes/img-clip.nvim',
    event = 'VeryLazy',
    opts = {
      filetypes = {
        -- Avante pastes through img-clip itself, and sends the file it saved
        AvanteInput = {
          embed_image_as_base64 = false,
          prompt_for_file_name = false,
          use_absolute_path = true,
        },
      },
    },
    keys = {
      {
        '<leader>yi',
        '<cmd>PasteImage<cr>',
        desc = 'Paste image from system clipboard',
      },
    },
  },
  {
    -- Input method switcher
    'drop-stones/im-switch.nvim',
    event = 'VeryLazy',
    -- im-switch turns a platform on by the mere presence of its table (an
    -- `enabled` field is ignored), and on Linux it then runs the command on
    -- every `InsertLeave`. Without fcitx5 -- Termux, a container, an IBus
    -- desktop -- `vim.system` throws each time, so that table is only handed
    -- over when the command is there.
    opts = function()
      local opts = {
        macos = {
          default_im = 'com.apple.keylayout.USExtended',
        },
      }
      if vim.fn.executable('fcitx5-remote') == 1 then
        -- By group, as fcitx5 is set up here (Vietnamese, Japanese, ...):
        -- what is read on leaving Insert mode is what is set on entering it
        -- again, so it has to be a group too, not an input method name
        opts.linux = {
          default_im = 'English',
          get_im_command = { 'fcitx5-remote', '-q' },
          set_im_command = { 'fcitx5-remote', '-g' },
        }
      end
      return opts
    end,
    config = function(_, opts)
      -- im-switch waits on its command at every `InsertLeave`, `InsertEnter`
      -- and `CmdlineLeave`, about 6 ms each on macOS, twice on leaving Insert
      -- mode. Switching needs no answer, so those run in the background, one
      -- after another to keep their order; only reading the current input
      -- method, which needs one, still waits, and only once they are done.
      local im = require('im-switch.im')
      local im_command = require('im-switch.utils.im_command')
      local queue, running = {}, false

      local function next_command()
        local cmd = table.remove(queue, 1)
        running = cmd ~= nil
        if not cmd then return end
        local system = require('util.system')
        system.run(cmd, { timeout = 5000 }, function(result)
          if result.code ~= 0 then
            vim.notify(
              'im-switch: ' .. system.failure(result, cmd[1]),
              vim.log.levels.ERROR
            )
          end
          next_command()
        end)
      end

      -- The macOS CLI panics on `set` with any input method it does not
      -- `list` (one removed from System Settings, a layout it cannot
      -- select), so those are skipped instead of handed to it.
      local selectable, warned = nil, {}

      ---@param cli string
      ---@param value string
      ---@return boolean
      local function can_select(cli, value)
        if vim.fn.has('mac') == 0 then return true end
        if not selectable then
          local result = require('util.system').sync(
            { cli, 'list' },
            { text = true, timeout = 2000 }
          )
          if result.code ~= 0 then return true end
          selectable = {}
          for _, id in
            ipairs(vim.split(result.stdout or '', '\n', { trimempty = true }))
          do
            selectable[vim.trim(id)] = true
          end
        end
        if selectable[value] then return true end
        if not warned[value] then
          warned[value] = true
          vim.notify(
            'im-switch: ' .. value .. ' is not an enabled input method, skipped',
            vim.log.levels.WARN
          )
        end
        return false
      end

      ---@param value? string
      local function switch(value)
        local cmd, err = im_command.get_im_command('set', value)
        if not cmd then
          vim.notify('im-switch: ' .. tostring(err), vim.log.levels.ERROR)
          return false
        end
        if not can_select(cmd[1], cmd[#cmd]) then return false end
        table.insert(queue, cmd)
        if not running then next_command() end
        return true
      end

      -- Upstream waits on `get` with no deadline: a stalled input method
      -- daemon would hold every `InsertLeave`. One that ran out of time, or
      -- a command that is not there, is not asked again this session.
      local get_failed, get_broken = false, false
      im.save_im_state = function()
        if get_broken then return false end
        vim.wait(200, function() return not running end, 5)
        local cmd, err = im_command.get_im_command('get')
        if not cmd then
          vim.notify('im-switch: ' .. tostring(err), vim.log.levels.ERROR)
          return false
        end
        local system = require('util.system')
        local result = system.sync(cmd, { text = true, timeout = 1000 })
        if result.code ~= 0 then
          get_broken = result.code == system.TIMED_OUT
            or result.code == system.MISSING
          if not get_failed then
            get_failed = true
            vim.notify(
              'im-switch: ' .. system.failure(result, cmd[1]),
              vim.log.levels.ERROR
            )
          end
          return false
        end
        vim.b.im_switch_last_state = vim.trim(result.stdout or '')
        return true
      end
      im.set_default_im = function() return switch() end
      im.restore_im = function()
        if not vim.b.im_switch_last_state and not im.save_im_state() then
          return false
        end
        return switch(vim.b.im_switch_last_state)
      end
      require('im-switch').setup(opts)
    end,
  },
}
