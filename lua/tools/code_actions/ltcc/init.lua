local h = require('null-ls.helpers')
local methods = require('null-ls.methods')

return h.make_builtin({
  name = 'ltcc',
  meta = {
    description = 'My custom sources to use languagetool-code-comments',
    url = 'https://github.com/dynamotn/languagetool-code-comments',
  },
  method = methods.internal.CODE_ACTION,
  filetypes = {},
  generator_opts = {
    command = 'ltcc',
    args = { 'check', '-l', 'en-US', '-f', '$FILENAME' },
    format = 'json',
    -- `ltcc` reads a file and has no stdin mode: the buffer goes to a
    -- temporary copy, so the result matches what is on screen, not the
    -- saved file the offsets would be wrong for
    to_temp_file = true,
    ignore_stderr = true,
    timeout = 60000,
    check_exit_code = function(c) return c <= 1 end,
    on_output = function(params)
      local actions = {}

      for _, m in ipairs(params.output) do
        -- `"replacements": null` decodes to `vim.NIL`, and a match may leave
        -- the key out
        if
          type(m.replacements) == 'table'
          and params.row == m.moreContext.line_number
        then
          local row = m.moreContext.line_number - 1
          local col_beg = m.moreContext.line_offset
          local col_end = m.moreContext.line_offset + m.length

          for _, r in ipairs(m.replacements) do
            if string.find(r.value, 'not shown') == nil then
              table.insert(actions, {
                title = 'Replace with “' .. r.value .. '”',
                action = function()
                  vim.api.nvim_buf_set_text(
                    params.bufnr,
                    row,
                    col_beg,
                    row,
                    col_end,
                    { r.value }
                  )
                end,
              })
            end
          end
        end
      end

      return actions
    end,
    use_cache = false,
  },
  factory = h.generator_factory,
})
