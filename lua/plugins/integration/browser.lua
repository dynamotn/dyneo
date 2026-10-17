local site_settings = vim.tbl_extend('force', {
  [ [[.*]] ] = {
    cmdline = 'firenvim',
    content = 'text',
    priority = 0,
    selector = 'textarea:not([readonly]):not([class="handsontableInput"]), div[role="textbox"], div[role="presentation"]',
    takeover = 'always',
  },
}, DyNeo.firenvim_site_settings)
vim.g.firenvim_config = {
  globalSettings = { alt = 'all' },
  localSettings = site_settings,
}

return {
  {
    -- Edit on browser by neovim
    'glacambre/firenvim',
    build = function()
      require('lazy').load({ plugins = { 'firenvim' }, wait = true })
      vim.fn['firenvim#install'](0)
    end,
    enabled = DyNeo.used_full_plugins or DyNeo.enabled_plugins.firenvim,
    lazy = not vim.g.started_by_firenvim,
    config = function(_, _)
      vim.o.laststatus = 0
      vim.o.showtabline = 0
    end,
  },
  {
    -- Open current word by other tools
    'ofirgall/open.nvim',
    opts = {
      -- Issue keys open on the Jira of `$JIRA_URL` (up to `/browse/`), and
      -- only there: `UTF-8` and `SHA-256` read as keys too, and are nobody
      -- else's business
      self_defined_openers = (vim.env.JIRA_URL or '') ~= '' and {
        {
          name = 'jira',
          open_fn = function(text)
            local urls = {}
            -- An issue key (`OPS-12`), not `utf-8` or `x86-64`
            for url in text:gmatch('%f[%w]%u[%u%d]+%-%d+%f[%W]') do
              table.insert(urls, vim.env.JIRA_URL .. url)
            end
            return urls
          end,
        },
      } or {},
    },
    keys = {
      -- The word under the cursor; open.nvim has nothing for a selection,
      -- which Neovim's own `gx` opens
      {
        'gx',
        function() require('open').open_cword() end,
        desc = 'Open with system app',
      },
    },
    config = function(_, opts)
      local open = require('open')
      open.setup(opts)

      for _, opener in ipairs(opts.self_defined_openers) do
        open.register_opener(opener)
      end
    end,
  },
}
