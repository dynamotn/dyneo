-- A `.safetensors` or `.gguf` model opens as its header: metadata, tensors
-- and parameters, rather than its bytes. The module only loads when asked.
vim.api.nvim_create_autocmd('BufReadCmd', {
  group = vim.api.nvim_create_augroup('dy_model', { clear = true }),
  pattern = { '*.safetensors', '*.gguf' },
  callback = function(event) require('tools.model').read(event.buf) end,
  desc = 'Show a model file as its header',
})
