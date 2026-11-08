-- The code lenses of ruby-lsp and of its Rails add-on, which it installs on
-- its own for a Rails app, name commands the editor runs: a test, a test
-- under the debugger, a migration, a route or the views of an action. VS Code
-- ships them; here they are given to the client.

--- Run the shell `cmd` in a terminal below, from the client's root
---@param cmd string
---@param ctx table
local function in_terminal(cmd, ctx)
  local client = vim.lsp.get_client_by_id(ctx.client_id)
  vim.cmd('botright 12split')
  vim.api.nvim_win_set_buf(0, vim.api.nvim_create_buf(false, true))
  vim.fn.jobstart(cmd, {
    term = true,
    cwd = client and client.root_dir or vim.fn.getcwd(),
  })
end

--- Open `uri`, on the line its `#L<n>` names if it does
---@param uri string
local function open(uri)
  local path, line = uri:match('^(.-)#L(%d+)$')
  vim.cmd.edit(vim.fn.fnameescape(vim.uri_to_fname(path or uri)))
  if line then vim.api.nvim_win_set_cursor(0, { tonumber(line), 0 }) end
end

---@type vim.lsp.Config
return {
  commands = {
    -- `[path, name, command, range, ...]`, `command` a whole shell line
    ['rubyLsp.runTest'] = function(cmd, ctx) in_terminal(cmd.arguments[3], ctx) end,
    ['rubyLsp.runTestInTerminal'] = function(cmd, ctx)
      in_terminal(cmd.arguments[3], ctx)
    end,
    ['rubyLsp.debugTest'] = function(cmd, ctx)
      in_terminal('rdbg -c -- ' .. cmd.arguments[3], ctx)
    end,
    -- `[command]`: a migration, which changes the database, so it is shown
    -- and run only once agreed to
    ['rubyLsp.runTask'] = function(cmd, ctx)
      local line = cmd.arguments[1]
      if
        vim.fn.confirm(('Run `%s`?'):format(line), '&Run\n&Cancel', 2) == 1
      then
        in_terminal(line, ctx)
      end
    end,
    -- `[[uri, ...]]`: a route, or the views of an action
    ['rubyLsp.openFile'] = function(cmd)
      local uris = cmd.arguments[1] or {}
      if #uris <= 1 then return uris[1] and open(uris[1]) end
      local paths = vim.tbl_map(vim.uri_to_fname, uris)
      vim.ui.select(paths, { prompt = 'Open' }, function(choice)
        if choice then open(vim.uri_from_fname(choice)) end
      end)
    end,
  },
}
