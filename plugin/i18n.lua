-- `:DyI18n [report|hints|on|off]`: i18n keys checked against the locale files
-- of the project, and their translation shown beside them. The module only
-- loads when asked, or when a buffer of a filetype that uses keys opens.
vim.api.nvim_create_user_command(
  'DyI18n',
  function(args) require('tools.i18n').command(args.fargs) end,
  {
    nargs = '?',
    complete = function() return { 'report', 'hints', 'on', 'off' } end,
    desc = 'Report i18n keys missing in a locale or never used',
  }
)

local group = vim.api.nvim_create_augroup('dy_i18n', { clear = true })
vim.api.nvim_create_autocmd('FileType', {
  group = group,
  pattern = {
    'javascript',
    'javascriptreact',
    'typescript',
    'typescriptreact',
    'vue',
    'svelte',
    'ruby',
    'eruby',
    'php',
  },
  callback = function(args) require('tools.i18n').attach(args.buf) end,
})
-- A written locale file is read again; nothing to forget before the module
-- has read any
vim.api.nvim_create_autocmd('BufWritePost', {
  group = group,
  pattern = { '*.json', '*.yml', '*.yaml' },
  callback = function(args)
    if package.loaded['tools.i18n'] then
      require('tools.i18n').written(args.file)
    end
  end,
})
