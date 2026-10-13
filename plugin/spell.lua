-- Paths come from `stdpath` and `DyNeo.dictionaries_path` rather than
-- `~/.config/...`, so `:DySpell` writes into the configuration actually in use
-- under a different `XDG_CONFIG_HOME` or `NVIM_APPNAME`.
local spell_dir = vim.fs.joinpath(vim.fn.stdpath('config'), 'spell')
-- `DyNeo` is missing when this tree is only on the runtimepath (`--clean`)
local dictionaries = vim.fn.expand(
  (rawget(_G, 'DyNeo') or {}).dictionaries_path
    or vim.fs.joinpath(vim.fn.stdpath('config'), '..', 'dictionaries')
)

-- Escaped for `:mkspell`: a directory with a space would split its argument
-- list, and escaping the whole `zh` glob would stop it expanding
local spell_files = {
  vi = { vim.fs.joinpath(vim.fn.fnameescape(dictionaries), 'vietnamese.txt') },
  zh = { vim.fs.joinpath(vim.fn.fnameescape(dictionaries), 'chinese', '*.txt') },

  proper = { vim.fs.joinpath(vim.fn.fnameescape(spell_dir), 'proper.txt') },
  technical = {
    vim.fs.joinpath(vim.fn.fnameescape(spell_dir), 'technical.txt'),
  },
}

--- Build the spell file of one language from its dictionaries
---@param lang string Key of `spell_files`
---@param silent? boolean Keep `mkspell` from reporting its progress
local make_spell = function(lang, silent)
  -- `lang` is the argument as typed, a plain string. Reaching for a field on
  -- it turned the complaint about a wrong name into a crash of its own.
  if spell_files[lang] == nil then
    vim.notify(
      "[spell] invalid spell file '" .. lang .. "'",
      vim.log.levels.ERROR
    )
    return
  end
  vim.cmd(
    (silent and 'silent ' or '')
      .. 'mkspell! '
      .. vim.fn.fnameescape(vim.fs.joinpath(spell_dir, lang))
      .. ' '
      .. table.concat(spell_files[lang], ' ')
  )
end

--- The word to add: the selection in Visual mode, else the one under the
--- cursor. `<cword>` stops at an apostrophe or a dot, so a word like
--- `Neovim's` has to be selected.
---@return string
local target_word = function()
  local mode = vim.fn.mode()
  if mode:match('^[vV\22]') then
    local text =
      vim.fn.getregion(vim.fn.getpos('v'), vim.fn.getpos('.'), { type = mode })
    vim.api.nvim_feedkeys(vim.keycode('<Esc>'), 'nx', false)
    return vim.trim(table.concat(text, ' '))
  end
  return vim.fn.expand('<cword>')
end

--- Add a word to one of my own word lists, rebuild its spell file, and hand
--- it to every running Harper too, which otherwise would only see it on the
--- next start, when `util.harper` merges the lists again
---@param lang string A key of `spell_files` whose list lives in `spell/`
local add_word = function(lang)
  local word = target_word()
  if word == '' or word:find('%s') then
    vim.notify(
      "[spell] not a single word: '" .. word .. "'",
      vim.log.levels.WARN
    )
    return
  end

  local list = spell_files[lang][1]
  local words = vim.uv.fs_stat(list) and vim.fn.readfile(list) or {}
  if vim.list_contains(words, word) then
    vim.notify("[spell] '" .. word .. "' is already in " .. lang)
  else
    vim.fn.writefile({ word }, list, 'a')
    make_spell(lang, true)
    vim.notify("[spell] added '" .. word .. "' to " .. lang)
  end

  local uri = vim.uri_from_bufnr(0)
  for _, client in ipairs(vim.lsp.get_clients({ name = 'harper_ls' })) do
    client:exec_cmd({
      title = 'Add to user dictionary',
      command = 'HarperAddToUserDict',
      arguments = { word, uri },
    })
  end
end

vim.keymap.set(
  { 'n', 'x' },
  '<leader>zt',
  function() add_word('technical') end,
  { desc = 'Add word to technical' }
)
vim.keymap.set(
  { 'n', 'x' },
  '<leader>zp',
  function() add_word('proper') end,
  { desc = 'Add word to proper nouns' }
)

vim.api.nvim_create_user_command(
  'DySpell',
  -- `nargs = 1` means the argument is always there, so there is nothing to
  -- fall back to
  function(opts) make_spell(opts.fargs[1]) end,
  {
    nargs = 1,
    desc = 'Make spell file from my dictionary',
    -- Neovim hands back a Lua completion list as it is, so the narrowing to
    -- what has been typed has to happen here
    complete = function(arg_lead)
      local names = vim.tbl_filter(
        function(name) return vim.startswith(name, arg_lead) end,
        vim.tbl_keys(spell_files)
      )
      table.sort(names)
      return names
    end,
  }
)
