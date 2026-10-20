local Plugin = require('util.plugin')
local merge = require('lazy.core.util').merge

local M = {}

--- Formatter for `util.format` that formats through the LSP clients of the
--- buffer, by way of conform when it is there
---@param opts? Formatter|{ filter?: (string|vim.lsp.get_clients.Filter) }
---@return Formatter
function M.formatter(opts)
  opts = opts or {}
  local filter = opts.filter or {}
  filter = type(filter) == 'string' and { name = filter } or filter
  ---@cast filter vim.lsp.get_clients.Filter
  ---@type Formatter
  local ret = {
    name = 'LSP',
    primary = true,
    priority = 1,
    format = function(buf) M.format(merge({}, filter, { bufnr = buf })) end,
    sources = function(buf)
      local clients = vim.tbl_filter(
        function(client)
          return client:supports_method('textDocument/formatting')
            or client:supports_method('textDocument/rangeFormatting')
        end,
        vim.lsp.get_clients(merge({}, filter, { bufnr = buf }))
      )
      return vim.tbl_map(function(client) return client.name end, clients)
    end,
  }
  return merge(ret, opts) --[[@as Formatter]]
end

---@param opts? { timeout_ms?: number, format_options?: table }|vim.lsp.get_clients.Filter
function M.format(opts)
  -- Conform and the formatters it runs load the project's own code
  local buf = opts and opts.bufnr or 0
  if require('util.untrusted').held(buf) then return end
  -- What the caller asked for wins over the defaults
  opts = vim.tbl_deep_extend(
    'force',
    {},
    Plugin.opts('nvim-lspconfig').format or {},
    opts or {}
  )
  local ok, conform = pcall(require, 'conform')
  -- conform diffs the result better. `formatters` must be nil, or it skips
  -- `formatters_by_ft`.
  if ok then
    opts.formatters = nil
    conform.format(opts)
  else
    vim.lsp.buf.format(opts)
  end
end

--- `action['source.organizeImports']()` applies that code action kind
M.action = setmetatable({}, {
  __index = function(_, action)
    return function()
      vim.lsp.buf.code_action({
        apply = true,
        context = { only = { action }, diagnostics = {} },
      })
    end
  end,
})

---@class LspCommand: lsp.ExecuteCommandParams
---@field open? boolean
---@field handler? lsp.Handler
---@field filter? string|vim.lsp.get_clients.Filter
---@field title? string

--- Run an LSP command on the first matching client, or show its result in
--- trouble with `open`
---@param opts LspCommand
function M.execute(opts)
  local filter = opts.filter or {}
  filter = type(filter) == 'string' and { name = filter } or filter
  local buf = vim.api.nvim_get_current_buf()
  ---@cast filter vim.lsp.get_clients.Filter
  local client = vim.lsp.get_clients(merge({}, filter, { bufnr = buf }))[1]
  local params = { command = opts.command, arguments = opts.arguments }
  if opts.open then
    require('trouble').open({ mode = 'lsp_command', params = params })
  else
    if not client then
      return vim.notify(
        ('No language server to run `%s`'):format(opts.command),
        vim.log.levels.WARN
      )
    end
    params.title = opts.title
    return client:exec_cmd(params, { bufnr = buf }, opts.handler)
  end
end

--- Code action kinds the matching clients offer
---@param filter? vim.lsp.get_clients.Filter
---@return string[]
function M.code_actions(filter)
  filter = filter or {}
  local ret = {} ---@type string[]
  for _, client in ipairs(vim.lsp.get_clients(filter)) do
    vim.list_extend(
      ret,
      vim.tbl_get(
        client,
        'server_capabilities',
        'codeActionProvider',
        'codeActionKinds'
      ) or {}
    )
    local regs = client.dynamic_capabilities:get('codeActionProvider', filter)
    for _, reg in ipairs(regs or {}) do
      vim.list_extend(
        ret,
        vim.tbl_get(reg, 'registerOptions', 'codeActionKinds') or {}
      )
    end
  end
  return Plugin.dedup(ret)
end

M.keymaps = {}

---@alias LspKeysSpec LazyKeysSpec|{ has?: string|string[], enabled?: (fun(buf: number): boolean) }

--- Set lazy.nvim-style `keys` on the buffers of the clients `filter`
--- matches. `has` limits a key to clients supporting that method.
---@param filter vim.lsp.get_clients.Filter
---@param spec LspKeysSpec[]
function M.keymaps.set(filter, spec)
  local Keys = require('lazy.core.handler.keys')
  for _, keys in pairs(Keys.resolve(spec)) do
    local filters = {} ---@type vim.lsp.get_clients.Filter[]
    if keys.has then
      local methods = type(keys.has) == 'string' and { keys.has } or keys.has --[[@as string[] ]]
      for _, method in ipairs(methods) do
        method = method:find('/') and method or ('textDocument/' .. method)
        filters[#filters + 1] =
          vim.tbl_extend('force', vim.deepcopy(filter), { method = method })
      end
    else
      filters[#filters + 1] = filter
    end
    for _, f in ipairs(filters) do
      local opts = Keys.opts(keys)
      ---@cast opts snacks.keymap.set.Opts
      opts.lsp = f
      opts.enabled = keys.enabled
      Snacks.keymap.set(keys.mode or 'n', keys.lhs, keys.rhs, opts)
    end
  end
end

--- Code lenses of a buffer. Neovim 0.13 keeps them current on its own once
--- `enable`d and deprecates `refresh`; 0.12 only has `refresh`, asked again
--- on the events that may move them.
M.codelens = {}

--- Show the code lenses of `buf` and keep them current
---@param buf integer
function M.codelens.enable(buf)
  local codelens = vim.lsp.codelens
  if codelens.enable then return codelens.enable(true, { bufnr = buf }) end
  codelens.refresh({ bufnr = buf })
  vim.api.nvim_create_autocmd({ 'BufEnter', 'CursorHold', 'InsertLeave' }, {
    group = vim.api.nvim_create_augroup('dyneo_codelens_' .. buf, {}),
    buffer = buf,
    callback = function() codelens.refresh({ bufnr = buf }) end,
  })
end

--- Turn the code lenses of the current buffer on or off; refresh them on
--- 0.12, which cannot hide them
function M.codelens.toggle()
  local codelens = vim.lsp.codelens
  if not codelens.enable then return codelens.refresh({ bufnr = 0 }) end
  local buf = vim.api.nvim_get_current_buf()
  codelens.enable(not codelens.is_enabled({ bufnr = buf }), { bufnr = buf })
end

return M
