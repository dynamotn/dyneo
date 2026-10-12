local cmp_util = require('util.cmp')

--- Wrap `config` so its arguments are asked for, prefilled with its own
---@param config {type?:string, args?:string[]|fun():string[]?}
local function get_args(config)
  local args = type(config.args) == 'function' and (config.args() or {})
    or config.args
    or {} --[[@as string[] | string ]]
  local args_str = type(args) == 'table' and table.concat(args, ' ') or args --[[@as string]]

  config = vim.deepcopy(config)
  ---@cast args string[]
  config.args = function()
    local new_args = vim.fn.expand(vim.fn.input('Run with args: ', args_str)) --[[@as string]]
    if config.type and config.type == 'java' then
      ---@diagnostic disable-next-line: return-type-mismatch
      return new_args
    end
    return require('dap.utils').splitstr(new_args)
  end
  return config
end

return {
  {
    -- Debug Adapter implementation
    'mfussenegger/nvim-dap',
    dependencies = {
      'igorlfs/nvim-dap-view',
      -- Virtual text for the debugger
      { 'theHamsta/nvim-dap-virtual-text', opts = {} },
    },
    -- stylua: ignore
    keys = {
      { '<leader>dB', function() require('dap').set_breakpoint(vim.fn.input('Breakpoint condition: ')) end, desc = 'Breakpoint Condition' },
      { '<leader>db', function() require('dap').toggle_breakpoint() end, desc = 'Toggle Breakpoint' },
      { '<leader>dc', function() require('dap').continue() end, desc = 'Run/Continue' },
      { '<leader>da', function() require('dap').continue({ before = get_args }) end, desc = 'Run with Args' },
      { '<leader>dC', function() require('dap').run_to_cursor() end, desc = 'Run to Cursor' },
      { '<leader>dg', function() require('dap').goto_() end, desc = 'Go to Line (No Execute)' },
      { '<leader>di', function() require('dap').step_into() end, desc = 'Step Into' },
      { '<leader>dj', function() require('dap').down() end, desc = 'Down' },
      { '<leader>dk', function() require('dap').up() end, desc = 'Up' },
      { '<leader>dl', function() require('dap').run_last() end, desc = 'Run Last' },
      { '<leader>dL', function() require('dap').set_breakpoint(nil, nil, vim.fn.input('Log point message: ')) end, desc = 'Log Point' },
      { '<leader>dX', function() require('dap').clear_breakpoints() end, desc = 'Clear Breakpoints' },
      { '<leader>do', function() require('dap').step_out() end, desc = 'Step Out' },
      { '<leader>dO', function() require('dap').step_over() end, desc = 'Step Over' },
      { '<leader>dP', function() require('dap').pause() end, desc = 'Pause' },
      { '<leader>dr', function() require('dap').repl.toggle() end, desc = 'Toggle REPL' },
      { '<leader>ds', function() require('dap').session() end, desc = 'Session' },
      { '<leader>dt', function() require('dap').terminate() end, desc = 'Terminate' },
      { '<leader>dw', function() require('dap.ui.widgets').hover() end, desc = 'Widgets' },
    },
    config = function()
      local Plugin = require('util.plugin')
      -- Load mason-nvim-dap here, after all adapters have been setup
      if Plugin.has('mason-nvim-dap.nvim') then
        require('mason-nvim-dap').setup(Plugin.opts('mason-nvim-dap.nvim'))
      end

      vim.api.nvim_set_hl(
        0,
        'DapStoppedLine',
        { default = true, link = 'Visual' }
      )

      for name, sign in pairs(require('config.defaults').icons.dap) do
        sign = type(sign) == 'table' and sign or { sign }
        vim.fn.sign_define('Dap' .. name, {
          text = sign[1],
          texthl = sign[2] or 'DiagnosticInfo',
          linehl = sign[3],
          numhl = sign[3],
        })
      end

      -- Read `.vscode/launch.json` with its comments and trailing commas
      require('dap.ext.vscode').json_decode = require('util.jsonc').decode
      require('util.dap').guard_launch_json(require('dap'))
    end,
  },
  {
    -- Debugger UI sharing one window between its views
    'igorlfs/nvim-dap-view',
    keys = {
      {
        '<leader>du',
        function() require('dap-view').toggle() end,
        desc = 'Dap View',
      },
      {
        '<leader>de',
        function()
          local expr
          local mode = vim.fn.mode()
          if mode:find('^[vV\22]') then
            expr = table.concat(
              vim.fn.getregion(
                vim.fn.getpos('v'),
                vim.fn.getpos('.'),
                { type = mode }
              ),
              '\n'
            )
          end
          require('dap-view').hover(expr)
        end,
        desc = 'Eval',
        mode = { 'n', 'x' },
      },
    },
    opts = {
      -- Open with a session and close after it, as nvim-dap-ui did
      auto_toggle = true,
    },
  },
  {
    -- Debug adapters from Mason. Its `setup` is called from nvim-dap's own
    -- `config` above, once every adapter is set up; a second call here would
    -- run every handler twice and list each of their configurations twice.
    'jay-babu/mason-nvim-dap.nvim',
    dependencies = 'mason.nvim',
    cmd = { 'DapInstall', 'DapUninstall' },
    -- Set up by nvim-dap. `:DapInstall` typed first loads only this plugin,
    -- whose commands are otherwise made by that `setup`.
    config = function() require('mason-nvim-dap.api.command') end,
    -- The adapters of a language are installed with its first buffer, from a
    -- handler registered at startup: nvim-dap itself only loads with the
    -- first `<leader>d` key, so one registered from there would miss the
    -- buffer that was already open and leave that first session without its
    -- debugger.
    init = function()
      local dap_util = require('util.dap')
      for name, language in pairs(require('config.languages')) do
        if
          language.dap and vim.list_contains(DyNeo.enabled_languages, name)
        then
          require('util.lazy_install').on_filetype(
            language.filetypes,
            function()
              for _, spec in ipairs(language.dap) do
                local package = dap_util.package(spec)
                if package then
                  require('util.lazy_install').install_once(package)
                end
              end
            end
          )
        end
      end
    end,
    -- Install the adapters of bundle languages up front: mason-nvim-dap takes
    -- the adapters it knows by name, the rest are installed here
    opts = function(_, opts)
      local dap_util = require('util.dap')
      opts.automatic_installation = false
      -- Extra configuration for the handlers, see mason-nvim-dap's README
      opts.handlers = opts.handlers or {}
      opts.ensure_installed = opts.ensure_installed or {}
      for name, language in pairs(require('config.languages')) do
        if language.dap and vim.list_contains(DyNeo.bundle_languages, name) then
          for _, spec in ipairs(language.dap) do
            if dap_util.is_mapped(spec) then
              table.insert(opts.ensure_installed, spec)
            else
              local package = dap_util.package(spec)
              if package then
                require('util.lazy_install').install_once(package)
              end
            end
          end
        end
      end
    end,
  },
  {
    -- Print debugging: insert, comment out and delete tagged print lines
    --
    -- Its own `g?` keys add the lines, `[g`/`]g` move between them. It loads
    -- with the first file rather than with the first key, or the lines left
    -- from a previous session go unhighlighted until then.
    'andrewferrier/debugprint.nvim',
    -- With the first file: the print lines are highlighted from setup on, so
    -- a buffer read before then would show its prints plain
    event = 'LazyFile',
    cmd = 'Debugprint',
    dependencies = { 'nvim-mini/mini.hipatterns' },
    keys = {
      -- `refactoring.nvim` had these for its own debug prints, which
      -- debugprint neither finds nor deletes; one kind of print is less
      -- to clean up
      {
        '<leader>rp',
        'g?v',
        remap = true,
        mode = { 'n', 'x' },
        desc = 'Debug Print Variable',
      },
      { '<leader>rP', 'g?p', remap = true, desc = 'Debug Print Location' },
      { '<leader>rc', '<cmd>Debugprint delete<cr>', desc = 'Debug Cleanup' },
      {
        '<leader>rC',
        '<cmd>Debugprint commenttoggle<cr>',
        desc = 'Debug Print Comment Toggle',
      },
      { '<leader>sP', '<cmd>Debugprint search<cr>', desc = 'Debug Prints' },
    },
    opts = {
      picker = 'snacks.picker',
    },
  },
  {
    -- Lualine extensions for DAP
    'lualine.nvim',
    opts = {
      special_filetypes = {
        ['dap-view'] = 'Debug',
        ['dap-repl'] = 'REPL',
        ['dap-view-term'] = 'Console',
      },
    },
  },
  {
    -- Completion for DAP, only ever used in the REPL. Its own spec rather than
    -- a dependency of blink.cmp, which would load it -- and nvim-dap with all
    -- its adapters -- on the first `InsertEnter` of any buffer.
    'rcarriga/cmp-dap',
    ft = 'dap-repl',
    init = function()
      DyNeo.completion_sources =
        vim.tbl_extend('force', DyNeo.completion_sources, {
          dap = '「DAP」',
        })
    end,
  },
  {
    'blink.cmp',
    opts = {
      sources = {
        compat = { 'dap' },
        per_filetype = {
          ['dap-repl'] = cmp_util.sources('dap'),
        },
      },
    },
  },
}
