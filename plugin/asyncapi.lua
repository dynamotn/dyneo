-- `:DyAsyncApiDiff [{rev}]`: what this AsyncAPI document, as it is now,
-- breaks of itself at {rev}. The module only loads when asked, or for a YAML
-- or JSON buffer whose first lines name an `asyncapi` version.
vim.api.nvim_create_user_command(
  'DyAsyncApiDiff',
  function(args) require('tools.asyncapi').diff(0, args.fargs[1]) end,
  {
    nargs = '?',
    desc = 'The breaking changes of this AsyncAPI document since a revision',
  }
)

-- A copy of `tools.asyncapi.is_document`, so a YAML or JSON buffer that is
-- no AsyncAPI document never loads the module; its spec keeps the two equal
local HEAD_LINES = 20

vim.api.nvim_create_autocmd('FileType', {
  group = vim.api.nvim_create_augroup('dy_asyncapi_attach', { clear = true }),
  pattern = { 'yaml', 'json' },
  callback = function(args)
    for _, line in
      ipairs(vim.api.nvim_buf_get_lines(args.buf, 0, HEAD_LINES, false))
    do
      if line:match('^asyncapi%s*:') or line:match('^%s*"asyncapi"%s*:') then
        return require('tools.asyncapi').attach(args.buf)
      end
    end
  end,
})
