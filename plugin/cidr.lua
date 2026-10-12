-- `:DyCidr`: what the IPv4 range under the cursor holds, and
-- `:DyCidr overlaps` for the ranges of the module that collide. The module
-- only loads when asked.
vim.api.nvim_create_user_command(
  'DyCidr',
  function(args) require('tools.cidr').command(args) end,
  {
    nargs = '?',
    complete = function() return { 'overlaps' } end,
    desc = 'What the IPv4 range under the cursor holds',
  }
)

-- The overlaps are those of a Terraform module, so they are asked for from
-- one of its buffers; the read-out stays global, a range shows up anywhere
vim.api.nvim_create_autocmd('FileType', {
  group = vim.api.nvim_create_augroup('dy_cidr', { clear = true }),
  pattern = { 'terraform', 'tf', 'terraform-vars' },
  callback = function(args)
    vim.keymap.set(
      'n',
      '<localleader>n',
      '<cmd>DyCidr overlaps<cr>',
      { buffer = args.buf, desc = 'Overlapping IPv4 Ranges (Terraform)' }
    )
  end,
})
