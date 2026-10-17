-- `agy` has no ACP mode of its own. Google publishes an ACP server for it in
-- the ACP registry, as a binary archive, which is installed here.
local agy_acp = {
  version = '1.2.1',
  dir = vim.fn.stdpath('data') .. '/agy-acp',
}
agy_acp.cmd = agy_acp.dir .. '/agy_acp_server.par'

--- Download Google's ACP server for Antigravity into `agy_acp.dir`. It is
--- optional, so a failure is a warning: an error would stop the build steps
--- after it.
local function install_agy_acp()
  local warn = function(msg)
    require('util.notify').titled('AI')(
      'agy ACP server: ' .. msg,
      vim.log.levels.WARN
    )
  end
  local uname = vim.uv.os_uname()
  local system = ({ Darwin = 'macos', Linux = 'linux' })[uname.sysname]
  local arch = ({ arm64 = 'arm64', aarch64 = 'arm64', x86_64 = 'x86_64' })[uname.machine]
  if not system or not arch then
    return warn('no build for ' .. uname.sysname .. ' ' .. uname.machine)
  end
  local url = string.format(
    'https://dl.google.com/agy-extensions/releases/%s/agy-acp-server-%s-%s-%s.zip',
    system,
    agy_acp.version,
    system == 'macos' and 'darwin' or 'linux',
    arch
  )
  local zip = agy_acp.dir .. '.zip'
  vim.fn.mkdir(agy_acp.dir, 'p')
  for _, cmd in ipairs({
    { 'curl', '-fsSL', '-o', zip, url },
    { 'unzip', '-o', '-q', zip, '-d', agy_acp.dir },
  }) do
    -- A build step waits on it, but a stalled download must not hang lazy.nvim
    local result =
      require('util.system').sync(cmd, { text = true, timeout = 5 * 60 * 1000 })
    if result.code ~= 0 then
      return warn(table.concat(cmd, ' ') .. ': ' .. (result.stderr or ''))
    end
  end
  vim.fn.delete(zip)
end

return {
  {
    -- Copilot with native LSP, its inline suggestions shown as ghost text
    -- rather than as completion items
    'neovim/nvim-lspconfig',
    opts = {
      servers = {
        copilot = {
          -- nvim-lspconfig ships Copilot with `telemetryLevel = 'all'`.
          settings = {
            telemetry = {
              telemetryLevel = 'off',
            },
          },
          -- Copilot attaches to every filetype, and attaching alone sends the
          -- buffer's text to GitHub. A `root_dir` function that never calls
          -- `on_dir` is how a buffer is declined before the client starts,
          -- and with no client attached neither inline completion nor
          -- sidekick's next edit suggestions have anything to send to.
          -- `on_dir()` without a root leaves `root_markers` to find it.
          root_dir = function(bufnr, on_dir)
            if
              not require('util.sensitive').is_sensitive(bufnr)
              and not require('util.ai_policy').local_only(bufnr)
            then
              on_dir()
            end
          end,
          -- stylua: ignore
          keys = {
            {
              '<M-]>',
              function() vim.lsp.inline_completion.select({ count = 1 }) end,
              desc = 'Next Copilot Suggestion',
              mode = { 'i', 'n' },
            },
            {
              '<M-[>',
              function() vim.lsp.inline_completion.select({ count = -1 }) end,
              desc = 'Prev Copilot Suggestion',
              mode = { 'i', 'n' },
            },
          },
        },
      },
      setup = {
        -- Copilot's status is shown by sidekick, so it needs no handler of
        -- its own here
        copilot = function()
          vim.schedule(function() vim.lsp.inline_completion.enable() end)
          -- Accept inline suggestions or next edits
          require('util.cmp').actions.ai_accept = function()
            return vim.lsp.inline_completion.get()
          end
        end,
      },
    },
  },
  {
    -- AI CLI, and next edit suggestions from the Copilot server
    'folke/sidekick.nvim',
    opts = function(_, opts)
      -- Jump to or apply the next edit
      require('util.cmp').actions.ai_nes = function()
        local Nes = require('sidekick.nes')
        if Nes.have() and (Nes.jump() or Nes.apply()) then return true end
      end
      Snacks.toggle({
        name = 'Sidekick NES',
        get = function() return require('sidekick.nes').enabled end,
        set = function(state) require('sidekick.nes').enable(state) end,
      }):map('<leader>uN')

      -- Antigravity CLI integration
      return vim.tbl_deep_extend('force', opts, {
        cli = {
          -- The multiplexer actually in use, though integration stays off
          mux = { backend = vim.env.TMUX and 'tmux' or 'zellij' },
          tools = {
            antigravity = {
              cmd = { 'agy' },
              is_proc = '\\<agy\\>',
              url = 'https://antigravity.google/docs/cli-overview',
              resume = { '--continue' },
              continue = { '--continue' },
              format = function(text)
                require('sidekick.text').transform(
                  text,
                  function(str)
                    return str:find('[^%w/_%.%-]') and ('"' .. str .. '"')
                      or str
                  end,
                  'SidekickLocFile'
                )
              end,
            },
          },
        },
      })
    end,
    -- stylua: ignore
    keys = {
      -- NES is also useful in normal mode
      {
        '<tab>',
        function() return require('util.cmp').map({ 'ai_nes' }, '<tab>')() end,
        mode = { 'n' },
        expr = true,
      },
      { '<leader>a', '', desc = '+ai', mode = { 'n', 'v' } },
      {
        '<c-.>',
        function() require('sidekick.cli').focus() end,
        desc = 'Sidekick Focus',
        mode = { 'n', 't', 'i', 'x' },
      },
      {
        '<leader>aa',
        function() require('sidekick.cli').toggle() end,
        desc = 'Sidekick Toggle CLI',
      },
      {
        '<leader>as',
        function() require('sidekick.cli').select() end,
        desc = 'Select CLI',
      },
      {
        '<leader>ad',
        function() require('sidekick.cli').close() end,
        desc = 'Detach a CLI Session',
      },
      {
        '<leader>at',
        function() require('sidekick.cli').send({ msg = '{this}' }) end,
        mode = { 'x', 'n' },
        desc = 'Send This',
      },
      {
        '<leader>af',
        function() require('sidekick.cli').send({ msg = '{file}' }) end,
        desc = 'Send File',
      },
      {
        '<leader>aV',
        function() require('sidekick.cli').send({ msg = '{selection}' }) end,
        mode = { 'x' },
        desc = 'Send Visual Selection',
      },
      {
        '<leader>ap',
        function() require('sidekick.cli').prompt() end,
        mode = { 'n', 'x' },
        desc = 'Sidekick Select Prompt',
      },
      {
        '<leader>aD',
        function() require('sidekick.cli').send({ msg = '{diagnostics}' }) end,
        desc = 'Send Diagnostics',
      },
    },
  },
  {
    -- Send picker items to the AI CLI
    'folke/snacks.nvim',
    opts = {
      picker = {
        actions = {
          sidekick_send = function(...)
            return require('sidekick.cli.picker.snacks').send(...)
          end,
        },
        win = {
          input = {
            keys = {
              ['<a-a>'] = {
                'sidekick_send',
                mode = { 'n', 'i' },
              },
            },
          },
        },
      },
    },
  },
  {
    -- Copilot status and running AI CLI sessions
    'nvim-lualine/lualine.nvim',
    opts = function(_, opts)
      opts.sections = opts.sections or {}
      local lualine_x = opts.sections.lualine_x or {}
      opts.sections.lualine_x = lualine_x
      -- Second in `lualine_x`, or first while it is still empty
      local pos = math.min(2, #lualine_x + 1)
      local icons = {
        Error = { ' ', 'DiagnosticError' },
        Inactive = { ' ', 'MsgArea' },
        Warning = { ' ', 'DiagnosticWarn' },
        Normal = { ' ', 'Special' },
      }
      table.insert(lualine_x, pos, {
        function()
          local status = require('sidekick.status').get()
          return status and vim.tbl_get(icons, status.kind, 1)
        end,
        cond = function() return require('sidekick.status').get() ~= nil end,
        color = function()
          local status = require('sidekick.status').get()
          local hl = status
            and (
              status.busy and 'DiagnosticWarn'
              or vim.tbl_get(icons, status.kind, 2)
            )
          return { fg = Snacks.util.color(hl) }
        end,
      })

      -- Avante's provider and model, once it has loaded; busy while it
      -- answers
      table.insert(lualine_x, pos, {
        function() return '󰚩 ' .. require('tools.ai').status() end,
        cond = function() return require('tools.ai').status() ~= nil end,
        color = function()
          local _, busy = require('tools.ai').status()
          return {
            fg = Snacks.util.color(busy and 'DiagnosticWarn' or 'Special'),
          }
        end,
        on_click = function() vim.cmd.AvanteSwitchProvider() end,
      })

      table.insert(lualine_x, pos, {
        function()
          local status = require('sidekick.status').cli()
          return ' ' .. (#status > 1 and #status or '')
        end,
        cond = function() return #require('sidekick.status').cli() > 0 end,
        color = function() return { fg = Snacks.util.color('Special') } end,
      })
    end,
  },
  {
    -- Claude Code
    'coder/claudecode.nvim',
    opts = {},
    -- `:DyAi` runs these before any key has loaded the plugin
    cmd = {
      'ClaudeCode',
      'ClaudeCodeFocus',
      'ClaudeCodeAdd',
      'ClaudeCodeSend',
      'ClaudeCodeSelectModel',
    },
    keys = {
      { '<leader>a', '', desc = '+ai', mode = { 'n', 'v' } },
      { '<leader>ac', '', desc = '+claude', mode = { 'n', 'v' } },
      { '<leader>acc', '<cmd>ClaudeCode<cr>', desc = 'Toggle Claude' },
      { '<leader>acf', '<cmd>ClaudeCodeFocus<cr>', desc = 'Focus Claude' },
      { '<leader>acr', '<cmd>ClaudeCode --resume<cr>', desc = 'Resume Claude' },
      {
        '<leader>acC',
        '<cmd>ClaudeCode --continue<cr>',
        desc = 'Continue Claude',
      },
      {
        '<leader>acb',
        '<cmd>ClaudeCodeAdd %<cr>',
        desc = 'Add current buffer',
      },
      {
        '<leader>acs',
        '<cmd>ClaudeCodeSend<cr>',
        mode = 'v',
        desc = 'Send to Claude',
      },
      {
        '<leader>acs',
        '<cmd>ClaudeCodeTreeAdd<cr>',
        desc = 'Add file',
        ft = { 'snacks_picker_list' },
      },
      -- Diff management
      { '<leader>aca', '<cmd>ClaudeCodeDiffAccept<cr>', desc = 'Accept diff' },
      { '<leader>acd', '<cmd>ClaudeCodeDiffDeny<cr>', desc = 'Deny diff' },
      {
        '<leader>acm',
        '<cmd>ClaudeCodeSelectModel<cr>',
        desc = 'Select model',
      },
    },
  },
  {
    -- LLMs & Agents
    'yetone/avante.nvim',
    build = {
      -- Avante itself first: the ACP adapters after it are optional, and a
      -- machine without npm or unzip still gets a working Avante.
      'make',
      -- The ACP adapters Avante talks to Claude Code and Codex through, at
      -- versions out for longer than `DyNeo.quarantine_window`. A failed
      -- shell step is logged and the next one still runs.
      vim.fn.executable('mise') == 1
          and 'mise use -g npm:@zed-industries/claude-agent-acp@0.23.1 npm:@zed-industries/codex-acp@0.16.0'
        or 'npm install -g @zed-industries/claude-agent-acp@0.23.1 @zed-industries/codex-acp@0.16.0',
      install_agy_acp,
    },
    cmd = {
      'AvanteAsk',
      'AvanteChat',
      'AvanteChatNew',
      'AvanteClear',
      'AvanteEdit',
      'AvanteFocus',
      'AvanteHistory',
      'AvanteModels',
      'AvanteRefresh',
      'AvanteStop',
      'AvanteSwitchProvider',
      'AvanteToggle',
      'AvanteACPModels',
      'AvanteACPModes',
      'Avante',
    },
    dependencies = {
      'nvim-lua/plenary.nvim',
      'MunifTanjim/nui.nvim',
      {
        'ColinKennedy/mega.cmdparse',
        dependencies = { 'ColinKennedy/mega.logging' },
      },
      'ravitemer/mcphub.nvim', -- MCP Hub
    },
    config = function(_, opts)
      -- The sidebar only collapses fully with a global statusline
      vim.o.laststatus = 3
      -- A `config` of its own replaces lazy.nvim's call to `setup`, which
      -- left every option above unread and Avante half started.
      require('avante').setup(opts)
    end,
    opts = {
      provider = vim.env.VIM_AVANTE_PROVIDER or 'claude-code',
      providers = {
        copilot = {
          model = vim.env.VIM_AVANTE_MODEL or 'claude-sonnet-4.6',
        },
        -- Avante leaves Ollama off; it is on whenever a server answers
        ollama = {
          endpoint = vim.env.VIM_AVANTE_OLLAMA_ENDPOINT
            or 'http://127.0.0.1:11434',
          model = vim.env.VIM_AVANTE_OLLAMA_MODEL or 'qwen-7b-instruct',
          is_env_set = function()
            return require('avante.providers.ollama').check_endpoint_alive()
          end,
        },
      },
      acp_providers = {
        ['claude-code'] = {
          command = 'claude-agent-acp',
          args = {},
          env = {
            NODE_NO_WARNINGS = '1',
            -- Unset, Claude Code uses its own login
            ANTHROPIC_API_KEY = vim.env.ANTHROPIC_API_KEY,
            ANTHROPIC_BASE_URL = vim.env.ANTHROPIC_BASE_URL,
            ANTHROPIC_MODEL = vim.env.VIM_AVANTE_CLAUDE_MODEL
              or 'claude-opus-5-5',
            ACP_PATH_TO_CLAUDE_CODE_EXECUTABLE = vim.fn.exepath('claude'),
            -- Avante's default sets `bypassPermissions` here, so that one is
            -- overridden; `claude-agent-acp` 0.23 reads neither variable,
            -- though. Its mode is Claude Code's `permissions.defaultMode`
            -- (`~/.claude/settings.json`, then the project's
            -- `.claude/settings.json` and `.local.json`), `default` unset.
            -- There Claude Code asks Avante, and Avante the user, only for
            -- what its own rules ask about -- a shell, an edit; its read-only
            -- tools read the disk unasked, with no `fs/read_text_file`, so
            -- `util.ai_guard` never sees what they read.
            ACP_PERMISSION_MODE = 'default',
          },
        },
        -- `codex` is one of Avante's own entries, run through `codex-acp`; it
        -- signs in with Codex's login, or `OPENAI_API_KEY`.
        -- Google's server signs in as chosen in
        -- `~/.gemini/antigravity-acp/settings.json`.
        agy = {
          command = agy_acp.cmd,
          args = vim.uv.os_uname().sysname == 'Linux' and { '--uid=' } or {},
        },
      },
      behaviour = {
        -- The defaults bind the whole `<leader>a` group, over the keys of
        -- sidekick and Claude Code. The ones kept are under `keys` below.
        auto_set_keymaps = false,
        -- Avante runs every tool without asking by default. Its own tools
        -- refuse a path outside the project, so reading and editing with
        -- them goes through on its own; a shell or a deletion is asked for.
        -- An ACP agent's requests are matched by their kind, which names no
        -- path: only `think` goes through, and whatever an agent asks about
        -- -- an `edit`, an `execute` -- is asked for. What it reads on its
        -- own tools, as Claude Code does, never comes here; what it reads
        -- or writes through the editor is checked by `util.ai_guard`.
        auto_approve_tool_permissions = {
          'think',
          'attempt_completion',
          'get_diagnostics',
          'git_diff',
          'glob',
          'grep',
          'ls',
          'read_definitions',
          'read_file_toplevel_symbols',
          'read_todos',
          'view',
          'write_todos',
          'create_dir',
          'edit_file',
          'insert',
          'str_replace',
          'undo_edit',
          'write_to_file',
        },
      },
      mappings = {
        -- `<C-s>` is the Zellij prefix, so it never reaches Neovim
        submit = {
          insert = '<M-CR>',
        },
      },
      selection = {
        hint_display = 'none',
      },
      -- Laid out and titled like the panels edgy docks: a plain title rather
      -- than pills, rounded floats like completion and noice, and one family
      -- of spinners
      windows = {
        position = 'right',
        width = 35,
        sidebar_header = {
          align = 'left',
          rounded = false,
          include_model = true,
        },
        spinner = {
          thinking = {
            '⠋',
            '⠙',
            '⠹',
            '⠸',
            '⠼',
            '⠴',
            '⠦',
            '⠧',
            '⠇',
            '⠏',
          },
        },
        input = {
          prefix = '❯ ',
        },
        edit = {
          border = 'rounded',
        },
        ask = {
          border = 'rounded',
        },
      },
      input = {
        provider = 'snacks',
      },
      selector = {
        provider = 'snacks',
      },
      -- A function, so the running MCP servers are read on every message.
      -- Only Avante's own providers read this and `custom_tools`: Claude
      -- Code brings its own prompt, tools and MCP servers.
      system_prompt = function()
        local ok, mcphub = pcall(require, 'mcphub')
        local hub = ok and mcphub.get_hub_instance() or nil
        return hub and hub:get_active_servers_prompt() or ''
      end,
      custom_tools = function()
        local ok, mcphub = pcall(require, 'mcphub.extensions.avante')
        return ok and { mcphub.mcp_tool() } or {}
      end,
    },
    keys = {
      { '<leader>av', '', desc = '+avante', mode = { 'n', 'v' } },
      {
        '<leader>avc',
        function() require('avante').toggle() end,
        desc = 'Avante Toggle Chat',
      },
      {
        '<leader>ava',
        function() require('avante.api').ask() end,
        mode = { 'v' },
        desc = 'Ask Avante about Selection',
      },
      {
        '<leader>avC',
        '<cmd>AvanteChatNew<cr>',
        desc = 'Avante New Chat',
      },
      {
        '<leader>avI',
        '<cmd>AvanteEdit<cr>',
        mode = { 'n', 'v' },
        desc = 'Avante Inline Edit',
      },
      {
        '<leader>avh',
        '<cmd>AvanteHistory<cr>',
        desc = 'Avante History',
      },
      {
        '<leader>avm',
        function() require('tools.ai').avante_model() end,
        desc = 'Avante Select Model',
      },
      {
        '<leader>avP',
        '<cmd>AvanteSwitchProvider<cr>',
        desc = 'Avante Switch Provider',
      },
    },
  },
  {
    -- Completion of `@` mentions and `/` commands in Avante's prompt. Its own
    -- spec rather than a dependency of blink.cmp, which would load it on the
    -- first `InsertEnter` of any buffer.
    'Kaiser-Yang/blink-cmp-avante',
    ft = 'AvanteInput',
    init = function()
      DyNeo.completion_sources =
        vim.tbl_extend('force', DyNeo.completion_sources or {}, {
          Avante = '「AI」',
        })
    end,
  },
  {
    'blink.cmp',
    opts = {
      sources = {
        providers = {
          avante = {
            module = 'blink-cmp-avante',
            name = 'Avante',
          },
        },
        per_filetype = {
          -- Path sources triggered by "/" would hide Avante's commands
          AvanteInput = { 'avante', 'buffer', 'emoji', 'dictionary' },
        },
      },
    },
  },
  {
    -- MCP Hub integration for AI tools
    'ravitemer/mcphub.nvim',
    enabled = vim.fn.executable('npm') == 1,
    cmd = 'MCPHub',
    -- A version out for longer than `DyNeo.quarantine_window`
    build = vim.fn.executable('mise') == 1 and 'mise use -g npm:mcp-hub@4.2.1'
      or 'npm install -g mcp-hub@4.2.1',
    opts = {
      -- Every MCP tool call is confirmed, but for those a server lists in
      -- its own `autoApprove` (servers.json): a tool can write files, run
      -- commands or send the buffer anywhere
      auto_approve = false,
      auto_toggle_mcp_servers = false,
      extensions = {
        avante = {
          make_slash_commands = true,
        },
      },
      ui = {
        window = {
          -- `winborder` is unset, and the other floats are rounded
          border = 'rounded',
        },
      },
    },
    keys = {
      {
        '<leader>M',
        '<cmd>MCPHub<CR>',
        desc = 'MCPHub',
      },
    },
  },
}
