--- jdtls add-ons of OpenIDEA: usages told apart by read and write, and a
--- Lombok agent that finds `lombok.config` again
---
--- Both are jars checked into the OpenIDEA repository, with no release to
--- pin, so they are fetched from one commit and kept only when their SHA-256
--- is the one written here. The commit waits out `DyNeo.quarantine_window`
--- like any release: until then nothing is fetched and jdtls runs as it did.
--- A fetched jar serves from the next jdtls start.
---
--- `openidea.java.usages` takes `[uri, line, character, declarations]` and
--- answers `{ location, kind, access }`, `access` being `read`, `write`,
--- `readWrite` or `unknown`. `M.attach` puts it behind jdtls's own
--- `textDocument/references`; a server without it answers as before.
local M = {}

local notify = require('util.notify').titled('OpenIDEA')

--- The commit the jars come from, and when it was made (2026-11-02 14:23 UTC)
M.COMMIT = 'd981603f3c9b7b618d745a3514256f5f63d18339'
M.PUBLISHED = 1793629389
--- Milliseconds a download may take
M.TIMEOUT = 300000

---@class DyOpenideaJar
---@field path string In the repository
---@field file string Under `M.dir()`; versioned, as OSGi caches bundles by it
---@field sha256 string

---@type table<string, DyOpenideaJar>
M.JARS = {
  usages = {
    path = 'plugins/java-usages/openidea-java-usages.jar',
    file = 'java-usages-1.2.0.jar',
    -- The reproducible build of 1.2.0, as its README gives it
    sha256 = '9140f1d2ecf27eadfe66b40a17daa18a08a65927ebef79456ba55d486ce5eeba',
  },
  lombok = {
    path = 'plugins/lombok/lombok-1.18.48-openidea.1.jar',
    file = 'lombok-1.18.48-openidea.1.jar',
    sha256 = '10f5cd1a32b946d3ff1c075735b94f35fffdbac11dea2be29d24dbf591dd51a4',
  },
}

local LABELS = { read = 'read', write = 'write', readWrite = 'read/write' }

--- Where the jars are kept
---@return string
function M.dir() return vim.fn.stdpath('data') .. '/openidea' end

---@return integer
function M.published() return M.PUBLISHED end

--- Whether the pinned commit is out of quarantine at `now`
---@param now? integer
---@return boolean
function M.released(now)
  return (now or os.time()) >= M.published() + DyNeo.quarantine_window
end

--- The SHA-256 of the file at `path`, or nil when it cannot be read
---@param path string
---@return string?
local function sha256(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local data = f:read('*a')
  f:close()
  return vim.fn.sha256(data)
end

--- The path of jar `name` when it is there with the pinned hash
---@param name string A key of `M.JARS`
---@return string?
function M.ready(name)
  local jar = M.JARS[name]
  local path = vim.fs.joinpath(M.dir(), jar.file)
  if sha256(path) == jar.sha256 then return path end
end

local fetching = false

--- Download the jars that are missing, once a session, and keep each only
--- when its hash matches
---@param on_done? fun(ok: boolean, fetched: integer) `ok` false when held
---back or a jar failed
---@param now? integer
function M.fetch(on_done, now)
  on_done = on_done or function() end
  if not M.released(now) or fetching then return on_done(false, 0) end
  local missing = {}
  for name in vim.spairs(M.JARS) do
    if not M.ready(name) then table.insert(missing, name) end
  end
  if #missing == 0 then return on_done(true, 0) end
  fetching = true
  vim.fn.mkdir(M.dir(), 'p')
  local left, ok = #missing, true
  for _, name in ipairs(missing) do
    local jar = M.JARS[name]
    local target = vim.fs.joinpath(M.dir(), jar.file)
    local part = target .. '.part'
    local url = ('https://raw.githubusercontent.com/l0ng-ai/openidea/%s/%s'):format(
      M.COMMIT,
      jar.path
    )
    require('util.system').run({
      'curl',
      '-fsSL',
      '--connect-timeout',
      '10',
      '--max-time',
      tostring(M.TIMEOUT / 1000),
      '-o',
      part,
      url,
    }, { timeout = M.TIMEOUT + 5000 }, function(result)
      if result.code ~= 0 then
        ok = false
        notify(
          require('util.system').failure(result, 'curl'),
          vim.log.levels.ERROR
        )
      elseif sha256(part) ~= jar.sha256 then
        ok = false
        notify(
          ('%s does not have the pinned SHA-256, and was thrown away'):format(
            jar.file
          ),
          vim.log.levels.ERROR
        )
      else
        vim.uv.fs_rename(part, target)
      end
      vim.fn.delete(part)
      left = left - 1
      if left == 0 then on_done(ok, #missing) end
    end)
  end
end

--- The access of each usage the last answer gave, by `file:lnum:col` as
--- `vim.lsp.util.locations_to_items` gives them, for the pickers to label
---@type table<string, string>
local access_at = {}

---@param file string
---@param lnum integer
---@param col integer 0-based
---@return string
local function key(file, lnum, col) return ('%s:%d:%d'):format(file, lnum, col) end

--- The locations of a usages answer, each one's access kept for `M.label`
---@param response table[]
---@return lsp.Location[]
function M.locations(response)
  access_at = {}
  local locations = {}
  for _, usage in ipairs(response) do
    table.insert(locations, usage.location)
    local item =
      vim.lsp.util.locations_to_items({ usage.location }, 'utf-16')[1]
    if item and LABELS[usage.access] then
      access_at[key(item.filename, item.lnum, item.col - 1)] =
        LABELS[usage.access]
    end
  end
  return locations
end

--- `[read]`, `[write]` or `[read/write]` for the usage at that place, if the
--- last answer said
---@param file string
---@param lnum integer
---@param col integer 0-based
---@return string?
function M.label(file, lnum, col)
  local access = access_at[key(file, lnum, col)]
  return access and ('[%s]'):format(access)
end

--- Answer `textDocument/references` of jdtls through `openidea.java.usages`,
--- so every list of references -- the picker, Trouble, quickfix -- gets a
--- field together with its getter, setter and builder; plain references
--- when the server lacks the command or it fails
---@param client vim.lsp.Client
function M.attach(client)
  if rawget(client, 'dy_openidea') then return end
  ---@diagnostic disable-next-line: inject-field
  client.dy_openidea = true
  local request = client.request
  ---@diagnostic disable-next-line: duplicate-set-field, inject-field
  client.request = function(self, method, params, handler, bufnr)
    local commands = vim.tbl_get(
      self.server_capabilities or {},
      'executeCommandProvider',
      'commands'
    ) or {}
    if
      method ~= 'textDocument/references'
      or not vim.list_contains(commands, 'openidea.java.usages')
    then
      return request(self, method, params, handler, bufnr)
    end
    return request(self, 'workspace/executeCommand', {
      command = 'openidea.java.usages',
      arguments = {
        params.textDocument.uri,
        params.position.line,
        params.position.character,
        vim.tbl_get(params, 'context', 'includeDeclaration') == true,
      },
    }, function(err, result, ctx, config)
      if err then return request(self, method, params, handler, bufnr) end
      ctx = vim.tbl_extend('force', ctx or {}, { method = method })
      handler(nil, M.locations(result or {}), ctx, config)
    end, bufnr)
  end
end

return M
