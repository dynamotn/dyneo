--- Workspace diagnostics for language servers without `workspace/diagnostic`
---
--- A server only reports on the documents it has been handed, so every file of
--- the project the server cares about is sent to it with `textDocument/didOpen`
--- as if it were open in the editor. Unlike artemave/workspace-diagnostics.nvim,
--- which this replaces:
---
--- - the file list and the file contents are read off the main loop, so a big
---   repository does not freeze the editor;
--- - the documents opened here are remembered per client, and closed again
---   right before Neovim opens the same file for real, so the server never sees
---   two `didOpen` for one URI (a protocol error that leaves stale or doubled
---   diagnostics behind);
--- - it can be run again to pick up files that changed, appeared or went away;
--- - the number of files sent to one server is capped.
local M = {}

local notify = require('util.notify').titled('Workspace diagnostics')

---@class tools.workspace_diagnostics.Config
M.config = {
  -- Most documents one server is sent. Every one of them is held in memory
  -- and analysed by the server, so a monorepo would otherwise flood it.
  max_files = 2000,
  -- Bigger files are skipped: they are nearly always generated or vendored,
  -- and a server analysing them only slows down on the files that matter.
  max_size = 1024 * 1024,
  -- Files read at the same time
  concurrency = 16,
  -- Listed files looked at per main loop tick, between which the editor gets
  -- to handle input
  batch = 200,
}

---@class tools.workspace_diagnostics.State
---@field notify fun(self: vim.lsp.Client, method: string, params?: table, bufnr?: integer): boolean The client's own `notify`
---@field opened table<string, string> URI sent in `didOpen` by this module, by the real path of the file
---@field live table<string, true> Real paths of the files Neovim itself has open in the client
---@field generation integer Bumped by every run, so a run that was overtaken stops

---@type table<integer, tools.workspace_diagnostics.State>
local states = {}

--- The path a file is known by whatever name it was reached through
---
--- A buffer is named after the path it was opened with, and `git ls-files`
--- lists paths under `root_dir`: with a symlink anywhere in between (`/tmp` on
--- macOS is one) the same file carries two names, and would be opened twice.
---@param path string
---@return string
local function realpath(path)
  return vim.uv.fs_realpath(path) or vim.fs.normalize(path)
end

--- Close a document this module opened, if it did
---@param state tools.workspace_diagnostics.State
---@param client vim.lsp.Client
---@param real string
local function close(state, client, real)
  local uri = state.opened[real]
  if not uri then return end
  state.opened[real] = nil
  state.notify(
    client,
    'textDocument/didClose',
    { textDocument = { uri = uri } }
  )
end

--- Real paths of the files Neovim itself has open in `client`
---@param client vim.lsp.Client
---@return table<string, true>
local function attached(client)
  local paths = {}
  for bufnr in pairs(client.attached_buffers) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      paths[realpath(vim.api.nvim_buf_get_name(bufnr))] = true
    end
  end
  return paths
end

--- Track the documents opened for `client`, and hand each one back before
--- Neovim opens the same file
---
--- The hook sits on `client.notify` because every `didOpen` Neovim sends goes
--- through it: attaching a buffer (`on_attach`), a filetype change, `:e!`, and
--- a buffer renamed onto one of these files by `:saveas`. `BufReadPre` or
--- `BufAdd` would only cover the first, and `LspAttach` fires after the
--- `didOpen` has already gone out. `didClose` goes out immediately before it,
--- so a server that drops the diagnostics of a closed file publishes them
--- again for the `didOpen` that follows.
---@param client vim.lsp.Client
---@return tools.workspace_diagnostics.State
local function state_of(client)
  local state = states[client.id]
  if state then return state end

  -- A client that has gone away takes its documents with it
  for id in pairs(states) do
    if not vim.lsp.get_client_by_id(id) then states[id] = nil end
  end

  state = {
    notify = client.notify,
    opened = {},
    live = attached(client),
    generation = 0,
  }
  states[client.id] = state
  ---@diagnostic disable-next-line: duplicate-set-field
  client.notify = function(self, method, params, bufnr)
    local uri = vim.tbl_get(params or {}, 'textDocument', 'uri')
    if uri and method == 'textDocument/didOpen' then
      local real = realpath(vim.uri_to_fname(uri))
      close(state, self, real)
      state.live[real] = true
    elseif uri and method == 'textDocument/didClose' then
      state.live[realpath(vim.uri_to_fname(uri))] = nil
    end
    return state.notify(self, method, params, bufnr)
  end
  return state
end

--- Read a file without blocking, giving up on one too big or not text
---@param path string
---@param callback fun(text?: string) Called on the main loop
local function read(path, callback)
  local uv = vim.uv
  local function done(text)
    vim.schedule(function() callback(text) end)
  end
  uv.fs_open(path, 'r', 438, function(open_err, fd)
    if open_err or not fd then return done(nil) end
    uv.fs_fstat(fd, function(stat_err, stat)
      if
        stat_err
        or not stat
        or stat.type ~= 'file'
        or stat.size > M.config.max_size
      then
        uv.fs_close(fd)
        return done(nil)
      end
      uv.fs_read(fd, stat.size, 0, function(read_err, data)
        uv.fs_close(fd)
        -- A NUL byte means a binary file, which no language server wants
        if read_err or not data or data:find('\0', 1, true) then
          return done(nil)
        end
        done(data)
      end)
    end)
  end)
end

--- List the files of the project under `root`, tracked or not ignored
---@param root string
---@param callback fun(paths?: string[], err?: string) Called on the main loop
local function list(root, callback)
  local system = require('util.system')
  system.run({
    'git',
    'ls-files',
    '-z',
    '--cached',
    '--others',
    '--exclude-standard',
    '--deduplicate',
  }, { cwd = root, timeout = 30000 }, function(result)
    if result.code ~= 0 and not result.cut then
      return callback(nil, system.failure(result, 'git ls-files'))
    end
    -- Past the cap, the last name may be cut in half
    local stdout = result.stdout or ''
    if result.cut then stdout = stdout:match('^(.*)%z') or '' end
    local paths = {}
    for name in vim.gsplit(stdout, '\0', { trimempty = true }) do
      paths[#paths + 1] = vim.fs.joinpath(root, name)
    end
    callback(paths)
  end)
end

---@param client vim.lsp.Client
---@param message string
---@param level? integer
local function say(client, message, level)
  notify(('%s: %s'):format(client.name, message), level or vim.log.levels.INFO)
end

--- Send every file of the project that `client` handles to it, so that it
--- reports on them as well
---
--- Running it again re-sends the files, closes those that are gone, and
--- abandons a run still in progress.
---@param client vim.lsp.Client
function M.populate(client)
  local filetypes = vim.tbl_get(client.config, 'filetypes')
  if not filetypes then
    return say(
      client,
      'skipped, it has no `filetypes` to pick the files by',
      vim.log.levels.WARN
    )
  end
  if not client:supports_method('textDocument/didOpen') then return end

  local state = state_of(client)
  state.generation = state.generation + 1
  local generation = state.generation
  local function current()
    return state.generation == generation and not client:is_stopped()
  end

  local folder = vim.tbl_get(client, 'workspace_folders', 1, 'uri')
  local root = client.root_dir
    or (folder and vim.uri_to_fname(folder))
    or vim.fn.getcwd()
  list(root, function(paths, err)
    if not current() then return end
    if not paths then
      return say(client, 'cannot list files: ' .. err, vim.log.levels.WARN)
    end

    local sent = {} ---@type table<string, true>
    local count, index, in_flight = 0, 1, 0
    local capped, finished = false, false

    local function finish()
      if finished then return end
      finished = true
      -- What was opened by an earlier run but not by this one has been
      -- deleted, ignored, or pushed out by the cap
      for real in pairs(state.opened) do
        if not sent[real] then close(state, client, real) end
      end
      say(
        client,
        capped and ('%d files sent, stopped at `max_files`'):format(count)
          or ('%d files sent'):format(count),
        capped and vim.log.levels.WARN or nil
      )
    end

    ---@param path string
    ---@param text? string
    ---@param filetype? string
    local function send(path, text, filetype)
      if not text then return end
      -- A server may well send what it is given on to somewhere else
      local sensitive = require('util.sensitive')
      if sensitive.is_sensitive_path(path) then return end
      for line in text:gmatch('[^\n]+') do
        if sensitive.secret_format(line) then return end
      end
      -- An extension alone does not tell every filetype apart (`.conf`,
      -- `.h`, a script without one), the contents do
      filetype = filetype
        or vim.filetype.match({
          filename = path,
          contents = vim.split(text, '\n', { plain = true }),
        })
      if not filetype or not vim.list_contains(filetypes, filetype) then
        return
      end
      local real = realpath(path)
      -- Open in Neovim, maybe since the run started: it owns that document
      if sent[real] or state.live[real] then return end
      if count >= M.config.max_files then
        capped = true
        return
      end

      local ok, language = true, filetype
      if client.config.get_language_id then
        -- A server's own `get_language_id` may look at the name of the
        -- buffer; the one made here is the one the diagnostics of the file
        -- land in anyway. Left out otherwise, so that a clean file does not
        -- leave a buffer behind.
        local bufnr = vim.fn.bufadd(path)
        ok, language = pcall(client.get_language_id, bufnr, filetype)
      end
      local uri = vim.uri_from_fname(path)
      -- A second run: the document is already open, and opening it again
      -- would be the very protocol error this module avoids
      close(state, client, real)
      state.notify(client, 'textDocument/didOpen', {
        textDocument = {
          uri = uri,
          version = 0,
          languageId = ok and language or filetype,
          text = text,
        },
      })
      state.opened[real] = uri
      sent[real] = true
      count = count + 1
    end

    local pump
    pump = function()
      if not current() then return end
      local looked = 0
      while
        index <= #paths
        and in_flight < M.config.concurrency
        and count + in_flight < M.config.max_files
        and looked < M.config.batch
      do
        local path = paths[index]
        index = index + 1
        looked = looked + 1
        local filetype = vim.filetype.match({ filename = path })
        -- No match on the name alone: the contents may still tell
        if not filetype or vim.list_contains(filetypes, filetype) then
          in_flight = in_flight + 1
          read(path, function(text)
            in_flight = in_flight - 1
            if not current() then return end
            send(path, text, filetype)
            pump()
          end)
        end
      end
      if index <= #paths and count >= M.config.max_files then
        capped = true
        index = #paths + 1
      end
      if in_flight == 0 and index > #paths then return finish() end
      -- Only the batch limit stops the loop with nothing in flight to call
      -- `pump` back
      if looked >= M.config.batch and in_flight < M.config.concurrency then
        vim.schedule(pump)
      end
    end
    pump()
  end)
end

--- Workspace diagnostics of every server attached to the current buffer
---
--- Neovim's own pull request is used where the server answers it, the
--- documents are pushed to the others.
function M.run()
  -- Not a language server's diagnostics: running these over the whole
  -- repository only buries the real errors, or sends every file to a remote
  -- service.
  local skipped = { 'null-ls', 'harper_ls', 'copilot' }
  -- Only the servers of this buffer: one serving another project would be
  -- handed the files of this one.
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = 0 })) do
    if vim.list_contains(skipped, client.name) then
    elseif client:supports_method('workspace/diagnostic') then
      vim.lsp.buf.workspace_diagnostics({ client_id = client.id })
    else
      M.populate(client)
    end
  end
end

return M
