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

local notify = require('util.notify').titled('Open')

--- Open `target` with the system's opener: as it reads when it names a
--- scheme, as a `file://` URI when it is a file that exists, else not at
--- all. `vim.ui.open` normalizes any other text as a path, which fills in
--- its `$VARIABLE`s: `gx` on `$TOKEN` would pass the token to `open`.
---@param target string
---@return boolean opened
local function open_target(target)
  local uri = target
  if not target:match('^%a[%w+.-]*:') then
    -- `:p` reads `$` and backticks as they are
    local path = vim.fn.fnamemodify(target, ':p')
    if target == '' or not vim.uv.fs_stat(path) then return false end
    uri = vim.uri_from_fname(path)
  end
  local _, err = vim.ui.open(uri)
  if err then notify(err, vim.log.levels.ERROR) end
  return true
end

--- Open the word under the cursor, or the table cell it is in, through the
--- openers open.nvim has. Its own `open_cword` passes the text through
--- `expand()`, which runs a `` `command` `` and fills in `$VARIABLE`s: `gx`
--- on inline code would run it, and on a URL naming `$TOKEN` would put the
--- token in the browser. The text is handed over as it reads instead, and
--- opened as one argument, never through a shell.
local function open_word()
  local open = require('open')
  -- No word under the cursor is E348
  local ok, cword = pcall(vim.fn.expand, '<cWORD>')
  local word = ok and cword:gsub('[%.,;:!%?%)%]]+$', '') or ''
  local texts = { word }
  local cell = open.extract_table_cell_text()
  if cell and cell ~= '' then table.insert(texts, 1, cell) end
  for _, text in ipairs(texts) do
    for _, opener in ipairs(open.openers) do
      local urls = opener.open_fn(text, {})
      if urls and #urls == 1 then
        if open_target(urls[1]) then return end
      elseif urls and #urls > 1 then
        return vim.ui.select(urls, { prompt = 'Open' }, function(url)
          if url and not open_target(url) then
            notify('Not a URL or a file: ' .. url, vim.log.levels.WARN)
          end
        end)
      end
    end
  end
  if not open_target(word) then
    notify('Nothing to open under the cursor', vim.log.levels.WARN)
  end
end

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
      { 'gx', open_word, desc = 'Open with system app' },
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
