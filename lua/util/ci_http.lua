--- HTTP for the CI and pipeline servers a clone names: Jenkins, Airflow,
--- Dagster
---
--- A server comes from the clone's own git config (`dyneo.<tool>Url`), or a
--- `DyNeo` default, never from a file of the repository. `curl` reads the
--- credentials from `~/.netrc`, which hands each only to its own host, so
--- none is read or passed here; a token that must travel in a header goes on
--- `curl`'s standard input, never in its arguments, and only to the hosts
--- its caller allows.
local M = {}

local system = require('util.system')

--- Milliseconds a request may take
M.TIMEOUT = 30 * 1000

--- Bytes of JSON read from a server
M.MAX_BYTES = 4 * 1024 * 1024

--- `curl` with the `~/.netrc` entry of the host it asks, if there is one
---@param args string[] What follows the options
---@return string[]
function M.curl(args)
  return vim.list_extend({
    'curl',
    '--fail-with-body',
    '--silent',
    '--show-error',
    '--netrc-optional',
    '--proto',
    '=https,http',
    '--max-time',
    tostring(math.floor(M.TIMEOUT / 1000)),
  }, args)
end

--- Whether `url` names a server: `http(s)://host[:port][/path]`
---@param url string
---@return boolean
function M.is_server(url)
  return url:match('^https?://[%w%.%-]+[:/]?') ~= nil
    and not url:find('[%s"\'<>]')
end

--- Hand `on_done` the `dyneo.*` values of the clone in `dir`, lower-cased
--- keys without the `dyneo.` prefix
---@param dir string
---@param on_done fun(values: table<string, string>)
function M.git_config(dir, on_done)
  system.run(
    { 'git', 'config', '--get-regexp', [[^dyneo\.]] },
    { cwd = dir, timeout = 5000 },
    function(result)
      local values = {}
      for key, value in (result.stdout or ''):gmatch('dyneo%.(%S+) ([^\n]+)') do
        values[key:lower()] = vim.trim(value)
      end
      on_done(values)
    end
  )
end

--- Hand `on_done` the server `dir`'s clone names under `dyneo.<key>`, else
--- `default`, without a trailing slash; or why there is none
---@param dir string
---@param key string `airflowUrl`, as git config spells it
---@param default? string
---@param on_done fun(url: string?, err: string?)
function M.server(dir, key, default, on_done)
  M.git_config(dir, function(values)
    local url = values[key:lower()] or default
    if not url or url == '' then
      return on_done(nil, ('No server: git config dyneo.%s <url>'):format(key))
    end
    if not M.is_server(url) then
      return on_done(nil, 'Not a server URL: ' .. url)
    end
    on_done((url:gsub('/+$', '')))
  end)
end

--- The host of `url`, lower-cased, with its port
---@param url string
---@return string?
function M.host(url)
  local host = url:match('^https?://([^/?#]+)')
  return host and host:lower() or nil
end

--- The scheme of `url`, lower-cased: `https` or `http`
---@param url string
---@return string?
function M.scheme(url)
  local scheme = url:match('^(%a+)://')
  return scheme and scheme:lower() or nil
end

--- Hand `on_done` the token `command` prints, for `url`; nil, and why,
--- when `url` is not on the host of `home` -- the server the token was set
--- up for --, asks over plain `http` a server set up with `https`, or the
--- command fails. The token is never logged.
---@param command? string[] From a `DyNeo` setting, never from a repository
---@param home? string The server the token belongs to
---@param url string The server about to be asked
---@param on_done fun(token: string?, err: string?)
function M.token(command, home, url, on_done)
  if not command or #command == 0 then return on_done(nil) end
  if not home or M.host(home) ~= M.host(url) then
    return on_done(
      nil,
      ('The token is for %s, not %s'):format(
        home and M.host(home) or 'no server',
        M.host(url) or url
      )
    )
  end
  -- A clone may name the token's own host over plain http: the token would
  -- then cross the network in clear text
  if M.scheme(url) ~= 'https' and M.scheme(home) == 'https' then
    return on_done(
      nil,
      ('The token for %s goes only over https'):format(M.host(home))
    )
  end
  -- It may ask for a passphrase or a login
  system.run(command, { timeout = M.TIMEOUT, detach = true }, function(result)
    local token = vim.trim(result.stdout or '')
    if result.code ~= 0 or token == '' or token:find('[\r\n]') then
      return on_done(
        nil,
        ('%s gave no token'):format(vim.fs.basename(command[1]))
      )
    end
    on_done(token)
  end)
end

---@class DyHttpRequest
---@field url string
---@field method? string `GET` unless given
---@field body? table Sent as JSON
---@field headers? string[] `Name: value` lines, sent on standard input

--- Ask `request.url` and decode its JSON answer
---@param request DyHttpRequest
---@param on_done fun(data: table?, err: string?)
function M.json(request, on_done)
  local args = { '--header', 'Accept: application/json' }
  local stdin = {}
  if request.method then
    vim.list_extend(args, { '--request', request.method })
  end
  if request.headers then
    -- A header from standard input never shows in a process listing
    vim.list_extend(args, { '--header', '@-' })
    vim.list_extend(stdin, request.headers)
  end
  if request.body then
    vim.list_extend(args, {
      '--header',
      'Content-Type: application/json',
      '--data-raw',
      vim.json.encode(request.body),
    })
  end
  vim.list_extend(args, { '--', request.url })
  system.run(M.curl(args), {
    timeout = M.TIMEOUT + 1000,
    max_bytes = M.MAX_BYTES,
    stdin = #stdin > 0 and (table.concat(stdin, '\n') .. '\n') or nil,
  }, function(result)
    if result.code ~= 0 then
      return on_done(nil, system.failure(result, 'curl'))
    end
    if result.cut then
      return on_done(nil, 'The server answered with more than can be read')
    end
    local ok, data = pcall(
      vim.json.decode,
      result.stdout or '',
      { luanil = { object = true, array = true } }
    )
    if not ok or type(data) ~= 'table' then
      return on_done(nil, 'The server answered with something not JSON')
    end
    on_done(data)
  end)
end

--- Hand `on_done` the end of what `url` answers, at most `max_bytes` of it:
--- it streams through `tail`, so a long log never sits whole in memory
---@param url string
---@param max_bytes integer
---@param on_done fun(text: string?, cut: boolean, err: string?, skipped: boolean)
---@param extra? string[] More options for `curl`, before the URL
---@param headers? string[] `Name: value` lines, sent on standard input
function M.tail(url, max_bytes, on_done, extra, headers)
  extra = vim.list_extend({}, extra or {})
  if headers then
    -- On standard input, as `M.json` sends them
    vim.list_extend(extra, { '--header', '@-' })
  end
  local options = vim.list_slice(M.curl(extra), 2)
  local command = vim.list_extend({
    'bash',
    '-c',
    'set -o pipefail; curl "${@:3}" -- "$1" | tail -c "$2"',
    'dy_ci_tail',
    url,
    tostring(max_bytes + 1),
  }, options)
  system.run(command, {
    timeout = M.TIMEOUT + 1000,
    max_bytes = max_bytes + 1024,
    stdin = headers and (table.concat(headers, '\n') .. '\n') or nil,
  }, function(result)
    if result.code ~= 0 then
      return on_done(nil, false, system.failure(result, 'curl'), false)
    end
    local text = result.stdout or ''
    -- One byte more than kept says the start was left out
    local skipped = #text > max_bytes
    if skipped then text = text:sub(#text - max_bytes + 1) end
    on_done(text, false, nil, skipped)
  end)
end

return M
