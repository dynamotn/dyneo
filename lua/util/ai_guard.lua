--- Keep sensitive files out of every AI integration, not only Copilot
---
--- `root_dir` stops Copilot from attaching to a sensitive buffer, but that is
--- decided once, when the buffer is opened, and it says nothing about the
--- other ways a buffer leaves the editor: a chat that is handed a file, a
--- selection that follows the cursor into Claude Code, a prompt sent to a CLI
--- tool. Each integration is guarded here at the one place it reads a buffer
--- or a path, against the list in `util.sensitive`.
---
--- The plugins expose no hook for most of this, so their functions are
--- wrapped. A wrapper that no longer finds what it wraps leaves the plugin as
--- it is and says so, rather than breaking it on an upstream rename.

local audit = require('util.ai_audit')
local policy = require('util.ai_policy')
local sensitive = require('util.sensitive')

local M = {}

local say = require('util.notify').titled('AI guard')

--- Log a handover to `util.ai_audit`, of a path or of a buffer
---@param integration string
---@param action 'sent'|'refused'
---@param target string|integer A path, or a buffer number
---@param detail? string
local function log(integration, action, target, detail)
  if type(target) == 'number' then
    audit.record_buffer(integration, action, target, detail)
  elseif type(target) == 'string' and target ~= '' then
    audit.record(integration, action, vim.fs.normalize(target), detail)
  end
end

--- Say that `what` was turned down, and log it
---@param what string Shown in the notification
---@param integration string Logged as
---@param target string|integer The path or the buffer turned down
local function refuse(what, integration, target)
  say(what .. ' refused: the file is sensitive', vim.log.levels.WARN)
  log(integration, 'refused', target)
end

--- Say that `what` was turned down because its project keeps AI on this
--- machine, and log it
---@param what string Shown in the notification
---@param integration string Logged as
---@param target string|integer The path or the buffer turned down
---@param reason string From `util.ai_policy`
local function refuse_local(what, integration, target, reason)
  say(('%s refused: %s'):format(what, reason), vim.log.levels.WARN)
  log(integration, 'refused', target, 'local only')
end

--- Why `target` must not reach Avante's current provider, if it must not
---@param target integer|string
---@return string?
local function avante_kept_local(target)
  if policy.is_local_provider() then return nil end
  return policy.local_only(target)
end

--- What became of each wrapper, for `:checkhealth dyneo`
---@type table<string, 'guarded'|'missing'>
M.status = {}

--- Wrap `tbl[key]` with `wrapper(original, ...)`, once
---@param tbl table?
---@param key string|integer
---@param name string Shown when the function is missing
---@param wrapper fun(original: function, ...): ...
local function wrap(tbl, key, name, wrapper)
  if type(tbl) ~= 'table' or type(tbl[key]) ~= 'function' then
    M.status[name] = 'missing'
    say(name .. ' not found, left unguarded', vim.log.levels.WARN)
    return
  end
  M.status[name] = 'guarded'
  local original = tbl[key]
  tbl[key] = function(...) return wrapper(original, ...) end
end

--- Milliseconds the buffer has to settle before it is looked at again
---
--- A change event arrives per paste and per insert; the credential patterns
--- are cheap but they read the whole buffer, and a secret pasted now is no
--- more urgent a tenth of a second later. `DiagnosticChanged` is debounced
--- with them because a linter run ends in a burst of them.
local RECHECK_DELAY = 200

--- Detach Copilot from a buffer, and remember this guard is why
---@param bufnr integer
M.detach_copilot = function(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  local clients = vim.lsp.get_clients({ bufnr = bufnr, name = 'copilot' })
  if #clients == 0 then return end
  for _, client in ipairs(clients) do
    vim.lsp.buf_detach_client(bufnr, client.id)
  end
  vim.b[bufnr].dy_ai_guard_detached = true
  refuse('Copilot', 'Copilot', bufnr)
end

--- Methods that carry a buffer's text to the server
local CONTENT_METHODS = {
  ['textDocument/didOpen'] = true,
  ['textDocument/didChange'] = true,
}

--- Drop every notification that would carry a sensitive buffer's text to a
--- Copilot client, and detach it from that buffer
---
--- Detaching flushes the pending change first, through this same `notify`,
--- so that change is dropped too. The check is cached per change of the
--- buffer, which makes it cheap enough to ask on every notification.
---@param client vim.lsp.Client
M.filter_copilot = function(client)
  if rawget(client, 'dy_ai_guard') then return end
  rawset(client, 'dy_ai_guard', true)
  local notify = client.notify
  rawset(client, 'notify', function(self, method, params, bufnr)
    -- Neovim 0.12.0 and 0.12.1 pass no `bufnr`: the URI still names it
    local uri = CONTENT_METHODS[method]
      and type(params) == 'table'
      and type(params.textDocument) == 'table'
      and params.textDocument.uri
    if not bufnr and uri then bufnr = vim.uri_to_bufnr(uri) end
    if
      bufnr
      and CONTENT_METHODS[method]
      and vim.api.nvim_buf_is_valid(bufnr)
      and (sensitive.is_sensitive(bufnr) or policy.local_only(bufnr))
    then
      vim.schedule(function() M.detach_copilot(bufnr) end)
      return true
    end
    return notify(self, method, params, bufnr)
  end)
end

--- Detach Copilot from a buffer that becomes sensitive, and offer it back
---
--- `:saveas`, `:file` and `:set filetype` change what a buffer is without
--- reopening it, so `root_dir` is never asked again -- and neither a name nor
--- a filetype changes when a token is pasted into a file that was perfectly
--- ordinary a second ago, or when `betterleaks` reports one after its run.
--- All four are watched, so what the content check knows reaches Copilot too.
---
--- What was sent before the change is gone already; detaching stops every
--- later edit from following. The way back is watched too: a token deleted
--- again, or a waiver given, leaves an ordinary buffer that Copilot would
--- have attached to all along, so it is offered the buffer once more -- but
--- only when this guard is what took it away.
M.watch_copilot = function()
  local group =
    vim.api.nvim_create_augroup('dy_ai_guard_copilot', { clear = true })

  --- Ask Neovim to decide about Copilot again, the way opening the file does
  ---
  --- There is no public call that re-runs the resolution behind an enabled
  --- LSP configuration -- `root_dir`, the root markers, the whole of it --
  --- but the `FileType` handler of `vim.lsp.enable` does, since that is what
  --- starts a server in the first place. Only that one is fired: the rest
  --- would set the buffer up again, and `ftplugin.vim` runs `b:undo_ftplugin`
  --- before sourcing the ftplugins anew, undoing local options set by hand.
  ---@param bufnr integer
  local function reconsider(bufnr)
    pcall(vim.api.nvim_exec_autocmds, 'FileType', {
      group = 'nvim.lsp.enable',
      buffer = bufnr,
      modeline = false,
    })
  end

  ---@param bufnr integer
  local function reconcile(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    local sensitive_now = sensitive.is_sensitive(bufnr)

    -- Gone again: the token was deleted, the waiver given, the finding
    -- cleared. Copilot is only offered back when this guard is what took it
    -- away, never when the buffer was left without it for another reason.
    if not sensitive_now then
      if vim.b[bufnr].dy_ai_guard_detached then
        vim.b[bufnr].dy_ai_guard_detached = nil
        reconsider(bufnr)
      end
      return
    end

    M.detach_copilot(bufnr)
  end

  -- The content check above runs after the buffer settles; by then Neovim
  -- has sent the change already. Each Copilot client is filtered as well,
  -- so what turns a buffer sensitive is never sent in the first place.
  -- What it is handed -- the whole buffer, the moment it attaches -- is
  -- logged, since nothing else says so.
  vim.api.nvim_create_autocmd('LspAttach', {
    group = group,
    callback = function(args)
      local client = vim.lsp.get_client_by_id(args.data.client_id)
      if client and client.name == 'copilot' then
        M.filter_copilot(client)
        log('Copilot', 'sent', args.buf, 'attached')
      end
    end,
  })

  vim.api.nvim_create_autocmd({ 'BufFilePost', 'FileType' }, {
    group = group,
    callback = function(args)
      -- `reconsider` fires `FileType`, so only the detaching half runs here:
      -- re-attaching from inside the event it fires would be a loop.
      if sensitive.is_sensitive(args.buf) then reconcile(args.buf) end
    end,
  })

  ---@type table<integer, true>
  local pending = {}
  vim.api.nvim_create_autocmd(
    { 'TextChanged', 'InsertLeave', 'DiagnosticChanged' },
    {
      group = group,
      callback = function(args)
        local bufnr = args.buf
        if pending[bufnr] then return end
        pending[bufnr] = true
        vim.defer_fn(function()
          pending[bufnr] = nil
          reconcile(bufnr)
        end, RECHECK_DELAY)
      end,
    }
  )
end

--- Guard every way Avante reads a buffer or a file
---
--- Avante has no switch like a `send_code`, so each place it reads is
--- wrapped: a question or an edit asked from a sensitive buffer carries its
--- selection, a file added to the chat is sent whole, and the model's own
--- tools go through one permission check before touching a path.
M.guard_avante = function()
  local ok_api, api = pcall(require, 'avante.api')
  for _, key in ipairs({ 'ask', 'edit' }) do
    wrap(ok_api and api or nil, key, 'Avante ' .. key, function(original, ...)
      if sensitive.is_sensitive(0) then
        return refuse('Avante ' .. key, 'Avante', 0)
      end
      local reason = avante_kept_local(0)
      if reason then
        return refuse_local('Avante ' .. key, 'Avante', 0, reason)
      end
      log('Avante', 'sent', 0, key)
      return original(...)
    end)
  end

  -- `@` picks, all buffers, and the current file added on open all end here
  local ok_selector, selector = pcall(require, 'avante.file_selector')
  wrap(
    ok_selector and selector or nil,
    'add_selected_file',
    'Avante add_selected_file',
    function(add, self, filepath, ...)
      if
        type(filepath) == 'string'
        and filepath ~= ''
        and sensitive.is_sensitive_path(filepath)
      then
        return refuse('Avante', 'Avante', filepath)
      end
      local reason = type(filepath) == 'string'
        and filepath ~= ''
        and avante_kept_local(filepath)
      if reason then
        return refuse_local('Avante', 'Avante', filepath, reason)
      end
      log('Avante', 'sent', filepath, 'added to chat')
      return add(self, filepath, ...)
    end
  )

  -- Asked by `view`, the edit tools and the rest before they touch a path.
  -- Turned down, the model is told it has no permission and carries on.
  local ok_helpers, helpers = pcall(require, 'avante.llm_tools.helpers')
  wrap(
    ok_helpers and helpers or nil,
    'has_permission_to_access',
    'Avante tool permission',
    function(allowed, abs_path, ...)
      if
        type(abs_path) == 'string'
        and (
          sensitive.is_sensitive_path(abs_path) or avante_kept_local(abs_path)
        )
      then
        log('Avante', 'refused', abs_path, 'tool')
        return false
      end
      local granted = allowed(abs_path, ...)
      if granted then log('Avante', 'sent', abs_path, 'tool') end
      return granted
    end
  )

  -- The one reader behind selected files and the tools, for whatever reaches
  -- it without asking for permission first
  local ok_utils, utils = pcall(require, 'avante.utils')
  wrap(
    ok_utils and utils or nil,
    'read_file_from_buf_or_disk',
    'Avante file reader',
    function(read, filepath, ...)
      if type(filepath) == 'string' then
        if sensitive.is_sensitive_path(filepath) then
          log('Avante', 'refused', filepath, 'read')
          return nil, 'the file is sensitive'
        end
        local reason = avante_kept_local(filepath)
        if reason then
          log('Avante', 'refused', filepath, 'local only')
          return nil, reason
        end
      end
      return read(filepath, ...)
    end
  )
end

--- Refuse to send a prompt to a CLI tool from a sensitive buffer, since
--- `{this}`, `{selection}` and friends expand to its content
M.guard_sidekick = function()
  local ok, cli = pcall(require, 'sidekick.cli')
  wrap(ok and cli or nil, 'send', 'sidekick send', function(send, opts, ...)
    if sensitive.is_sensitive(0) then
      return refuse('sidekick', 'sidekick', 0)
    end
    -- The CLIs it runs answer from a service, never from this machine
    local reason = policy.local_only(0)
    if reason then return refuse_local('sidekick', 'sidekick', 0, reason) end
    local prompt = type(opts) == 'table' and opts.prompt
    log(
      'sidekick',
      'sent',
      0,
      type(prompt) == 'string' and ('prompt ' .. prompt) or 'message'
    )
    return send(opts, ...)
  end)

  -- The statusline icon asks for the Copilot client of the buffer, and a
  -- sensitive buffer has none: the icon vanished, as if Copilot were not
  -- running at all. Reported as `Inactive` instead, while Copilot runs for
  -- other buffers, so a buffer turned down on purpose shows as such.
  local ok_status, status = pcall(require, 'sidekick.status')
  wrap(
    ok_status and status or nil,
    'get',
    'sidekick status',
    function(get, buf, ...)
      local result = get(buf, ...)
      if result then return result end
      -- The statusline asks on every redraw: the cheap checks go first, and
      -- the buffer is only scanned when Copilot runs at all
      local ok_config, config = pcall(require, 'sidekick.config')
      if
        ok_config
        and config.copilot.status.enabled
        and #config.get_clients() > 0
      then
        if sensitive.is_sensitive(buf) then
          return { busy = false, kind = 'Inactive', message = 'sensitive file' }
        elseif policy.local_only(buf) then
          return { busy = false, kind = 'Inactive', message = 'AI kept local' }
        end
      end
    end
  )
end

--- Whether a Claude Code selection comes from a sensitive file or buffer
---@param sel table?
---@return boolean
local function selection_is_sensitive(sel)
  if type(sel) ~= 'table' then return false end
  local path = sel.filePath
  if type(path) ~= 'string' or path == '' then
    return sensitive.is_sensitive(0) or policy.local_only(0) ~= nil
  end
  -- Claude Code answers from a service, so a project kept local is held
  -- back as a sensitive file is
  if sensitive.is_sensitive_path(path) or policy.local_only(path) then
    return true
  end
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(bufnr) == path then
      return sensitive.is_sensitive(bufnr)
    end
  end
  return false
end

--- Keep Claude Code's view of the editor off sensitive buffers
---
--- The selection is pushed to Claude Code on every cursor move, text and all,
--- without anything being asked for. Skipping the update in a sensitive
--- buffer leaves Claude Code with the last selection made elsewhere.
M.guard_claudecode = function()
  local ok, selection = pcall(require, 'claudecode.selection')
  wrap(
    ok and selection or nil,
    'update_selection',
    'claudecode selection',
    function(update, ...)
      if sensitive.is_sensitive(0) or policy.local_only(0) then
        return log('Claude Code', 'refused', 0, 'selection')
      end
      log('Claude Code', 'sent', 0, 'selection')
      return update(...)
    end
  )

  -- Leaving visual mode flushes the selection straight to this sink, past
  -- `update_selection`, and Claude Code's selection tools read it back
  -- through `get_latest_selection`: both are checked against the file the
  -- selection came from.
  wrap(
    ok and selection or nil,
    'send_selection_update',
    'claudecode selection flush',
    function(send, sel, ...)
      if selection_is_sensitive(sel) then return end
      return send(sel, ...)
    end
  )
  wrap(
    ok and selection or nil,
    'get_latest_selection',
    'claudecode latest selection',
    function(get, ...)
      local sel = get(...)
      if selection_is_sensitive(sel) then return nil end
      return sel
    end
  )

  local ok_main, claudecode = pcall(require, 'claudecode')
  wrap(
    ok_main and claudecode or nil,
    'send_at_mention',
    'claudecode send_at_mention',
    function(send, file_path, start_line, end_line, ...)
      if file_path and sensitive.is_sensitive_path(file_path) then
        refuse('Claude Code', 'Claude Code', file_path)
        return false, 'the file is sensitive'
      end
      local reason = file_path and policy.local_only(file_path)
      if reason then
        refuse_local('Claude Code', 'Claude Code', file_path, reason)
        return false, reason
      end
      log(
        'Claude Code',
        'sent',
        file_path,
        start_line
            and ('lines %s-%s'):format(start_line, end_line or start_line)
          or 'mention'
      )
      return send(file_path, start_line, end_line, ...)
    end
  )
end

--- Run `fn` once lazy.nvim has loaded `name`, or now if it already has
---
--- Asked of lazy.nvim itself rather than through `util.plugin`: this runs
--- from `plugin/`, which a `--clean` Neovim with this repository on its
--- runtimepath sources too, and there lazy.nvim is not set up. Without it
--- none of the guarded plugins can load, so there is nothing to guard.
---@param name string
---@param fn fun()
local function on_load(name, fn)
  local ok, config = pcall(require, 'lazy.core.config')
  if not ok or not config.plugins then return end
  local plugin = config.plugins[name]
  if plugin and plugin._.loaded then return fn() end
  vim.api.nvim_create_autocmd('User', {
    pattern = 'LazyLoad',
    callback = function(event)
      if event.data ~= name then return end
      fn()
      return true
    end,
  })
end

--- `:DyAiGuardCheck` and `:DyAiGuardAllow`
---
--- A buffer held back for its name says so by its name; one held back for
--- what is written in it does not, and the first sign of it is a chat that
--- answers nothing. `:DyAiGuardCheck` says what was found and where, and
--- `:DyAiGuardAllow` is the way past a pattern that matched something that is
--- not a credential -- for that buffer, for as long as it is open, and never
--- for a file the name rules already named.
M.commands = function()
  vim.api.nvim_create_user_command('DyAiGuardCheck', function()
    local bufnr = vim.api.nvim_get_current_buf()
    local waived = sensitive.is_allowed(bufnr)
    local reasons = sensitive.reasons(bufnr, { ignore_waiver = true })
    if #reasons == 0 then
      return say('Nothing holding this buffer back', vim.log.levels.INFO)
    end
    local headline = waived
        and 'Waived by :DyAiGuardAllow, and otherwise held back for:'
      or 'Held back from every AI integration:'
    say(
      headline .. '\n- ' .. table.concat(reasons, '\n- '),
      waived and vim.log.levels.INFO or vim.log.levels.WARN
    )
  end, { desc = 'Why this buffer is kept from the AI integrations' })

  vim.api.nvim_create_user_command('DyAiGuardAllow', function(args)
    local bufnr = vim.api.nvim_get_current_buf()
    if args.bang then
      sensitive.allow(bufnr, false)
      return say(
        'The content check is back on for this buffer',
        vim.log.levels.INFO
      )
    end
    if sensitive.is_sensitive_path(vim.api.nvim_buf_get_name(bufnr)) then
      return say(
        'Refused: this file is sensitive by its name, not by what is in it',
        vim.log.levels.ERROR
      )
    end
    local marked = sensitive.marked(bufnr)
    if marked then
      return say(
        'Refused: this buffer is sensitive as ' .. marked,
        vim.log.levels.ERROR
      )
    end
    sensitive.allow(bufnr)
    say(
      'This buffer may now be sent to the AI integrations; :DyAiGuardAllow! '
        .. 'takes it back',
      vim.log.levels.WARN
    )
  end, {
    bang = true,
    desc = 'Waive the content check for this buffer, or take it back with !',
  })
end

--- Install every guard: Copilot's now, the others as their plugin loads
M.setup = function()
  M.commands()
  audit.command()
  M.watch_copilot()
  on_load('avante.nvim', M.guard_avante)
  on_load('sidekick.nvim', M.guard_sidekick)
  on_load('claudecode.nvim', M.guard_claudecode)
end

return M
