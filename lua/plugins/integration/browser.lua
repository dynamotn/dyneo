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
      -- The host script runs whichever `nvim` is on `$PATH` but keeps the
      -- `NVIM_APPNAME` it was installed from, so another channel installing
      -- it would point the default binary at that channel's plugins
      if (vim.env.NVIM_APPNAME or 'nvim') ~= 'nvim' then return end
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
      -- Its `github` opener asks api.github.com, without a timeout and from
      -- the main loop, about any `a/b` under the cursor -- a path, or the
      -- host and path of an internal URL -- before anything opens
      disabled_openers = { 'github' },
      self_defined_openers = vim.list_extend({
        -- A quoted `'owner/repo'` lazy.nvim knows opens where it is cloned
        -- from, answered from memory: a plugin spec's name, not a path
        {
          name = 'lazy',
          open_fn = function(text)
            local name = text:match([[^['"]([%w_%-%.]+/[%w_%-%.]+)['"]$]])
            if not name or not package.loaded['lazy.core.config'] then
              return nil
            end
            for _, plugin in pairs(require('lazy.core.config').plugins) do
              if plugin[1] == name and plugin.url then
                return { (plugin.url:gsub('%.git$', '')) }
              end
            end
          end,
        },
      }, (vim.env.JIRA_URL or '') ~= '' and {
        -- Issue keys open on the Jira of `$JIRA_URL` (up to `/browse/`), and
        -- only there: `UTF-8` and `SHA-256` read as keys too, and are nobody
        -- else's business
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
      } or {}),
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
