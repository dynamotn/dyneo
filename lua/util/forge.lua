--- The forge a repository lives on, and its API through the forge's own CLI
---
--- GitHub is asked through `gh api`, GitLab through `glab api` and Azure
--- DevOps through `az devops invoke`: each CLI holds its own token for the
--- host, so none is ever read or passed here.
local M = {}

--- The host each CLI's environment token is meant for when no other is set
M.DEFAULT_HOSTS =
  { github = 'github.com', gitlab = 'gitlab.com', azure = 'dev.azure.com' }

--- The CLI that answers for each forge kind
M.CLIS = { github = 'gh', gitlab = 'glab', azure = 'az' }

--- The version of the Azure DevOps REST API asked for; `az devops invoke`
--- defaults to an old one
M.AZURE_API_VERSION = '7.1'

--- The environment `az` runs in: it never offers to install its `azure-devops`
--- extension, a prompt no one would see
M.AZURE_ENV = { AZURE_EXTENSION_USE_DYNAMIC_INSTALL = 'no' }

--- Variables naming the host a user works against, by forge kind
M.HOST_VARS = {
  github = { 'GH_HOST' },
  gitlab = { 'GITLAB_HOST', 'GL_HOST' },
}

--- Tokens a CLI takes from the environment and sends to whatever host it is
--- pointed at, by forge kind. `GH_TOKEN` is not among them: `gh` only ever
--- sends it to github.com and its own cloud.
M.TOKEN_VARS = {
  github = { 'GH_ENTERPRISE_TOKEN', 'GITHUB_ENTERPRISE_TOKEN' },
  gitlab = { 'GITLAB_TOKEN', 'GITLAB_ACCESS_TOKEN', 'OAUTH_TOKEN' },
}

--- The remotes looked at, in order: the same as Octo and the CI checks use
M.REMOTES = { 'upstream', 'gh', 'github', 'origin' }

--- Milliseconds an API call may take
M.TIMEOUT = 30 * 1000

---@alias DyForgeKind 'github'|'gitlab'|'azure'

---@class DyForgeRemote
---@field name string The git remote
---@field host string
---@field slug string `owner/repo`, `group/sub/project`, or `org/project/repo`
---@field kind DyForgeKind
---@field org? string Azure DevOps only: the organization
---@field project? string Azure DevOps only: the project, decoded
---@field repo? string Azure DevOps only: the repository, decoded

--- A call of the Azure DevOps REST API, as `az devops invoke` takes it
---@class DyForgeAzureCall
---@field area string `build`, `git`, ...
---@field resource string `builds`, `timeline`, `pullRequests`, ...
---@field route table<string, string|integer>
---@field query? table<string, string|integer>
---@field method? 'GET'|'POST'|'PATCH'|'PUT'|'DELETE' `GET` unless given
---@field body? table Sent as JSON, from a file `az` reads
---@field api_version? string `M.AZURE_API_VERSION` unless given: an area with no released version asks a preview

--- The host and the path of a clone URL: `https://host/a/b(.git)`,
--- `ssh://git@host:22/a/b`, `git@host:a/b`
---@param url string
---@return string? host
---@return string? slug
function M.parse_url(url)
  local host, path
  local rest = url:match('^%a[%w+.-]*://(.*)$')
  if rest then
    host, path = rest:gsub('^[^@/]*@', ''):match('^([^/]+)/(.-)/?$')
    if host then host = host:gsub(':%d+$', '') end
  else
    host, path = url:match('^[%w_.-]+@([^:]+):(.-)/?$')
  end
  if not host or not path or path == '' then return nil end
  return host:lower(), (path:gsub('%.git$', ''))
end

--- The kind of forge `host` is, if one is known
---@param host string
---@return DyForgeKind?
function M.kind_of(host)
  -- Before GitLab's loose match: an organization may be called `gitlab`
  if
    host == 'dev.azure.com'
    or host == 'ssh.dev.azure.com'
    or host:match('^[%w-]+%.visualstudio%.com$')
  then
    return 'azure'
  end
  if host == 'github.com' or host:match('^github%.') then return 'github' end
  if host == 'gitlab.com' or host:match('gitlab') then return 'gitlab' end
  return nil
end

--- Undo the percent-encoding of a path segment
---@param text string
---@return string
local function decode(text)
  return (
    text:gsub(
      '%%(%x%x)',
      function(hex) return string.char(tonumber(hex, 16)) end
    )
  )
end

--- The organization, project and repository of an Azure DevOps clone URL,
--- from its host and path as `M.parse_url` reads them:
--- `dev.azure.com/org/project/_git/repo`,
--- `ssh.dev.azure.com:v3/org/project/repo`,
--- `org.visualstudio.com/[DefaultCollection/]project/_git/repo`
---@param host string
---@param path string
---@return { org: string, project: string, repo: string }?
function M.azure_parts(host, path)
  local org, project, repo
  if host == 'dev.azure.com' then
    org, project, repo = path:match('^([^/]+)/([^/]+)/_git/([^/]+)$')
  elseif host == 'ssh.dev.azure.com' or host == 'vs-ssh.visualstudio.com' then
    org, project, repo = path:match('^v3/([^/]+)/([^/]+)/([^/]+)$')
  else
    org = host:match('^([%w-]+)%.visualstudio%.com$')
    project, repo =
      path:gsub('^DefaultCollection/', ''):match('^([^/]+)/_git/([^/]+)$')
  end
  -- The organization names the API's URL, built here: nothing but a name
  if not (org and project and repo) or not org:match('^%w[%w-]*$') then
    return nil
  end
  project, repo = decode(project), decode(repo)
  if project:match('%c') or repo:match('%c') then return nil end
  return { org = org, project = project, repo = repo }
end

--- Run git in `dir` and wait, the first line of its output or nil
---@param dir string
---@param args string[]
---@param on_done fun(output: string?) Its output trimmed, nil on failure
local function git(dir, args, on_done)
  require('util.system').run(
    vim.list_extend({ 'git' }, args),
    { cwd = dir, timeout = 5000 },
    function(result)
      local output = vim.trim(result.stdout or '')
      on_done(result.code == 0 and output ~= '' and output or nil)
    end
  )
end

--- The first remote of `urls` on a forge this knows, in `M.REMOTES` order
---@param urls table<string, string> Clone URL by remote name
---@return DyForgeRemote?
function M.pick_remote(urls)
  for _, name in ipairs(M.REMOTES) do
    -- Not `urls[name] and M.parse_url(…)`: `and` keeps only the host
    local host, slug
    if urls[name] then
      host, slug = M.parse_url(urls[name])
    end
    local kind = host and M.kind_of(host)
    if kind == 'azure' then
      local parts = M.azure_parts(host, slug)
      if parts then
        return {
          name = name,
          host = M.DEFAULT_HOSTS.azure,
          slug = ('%s/%s/%s'):format(parts.org, parts.project, parts.repo),
          kind = kind,
          org = parts.org,
          project = parts.project,
          repo = parts.repo,
        }
      end
    elseif kind then
      return { name = name, host = host, slug = slug, kind = kind }
    end
  end
  return nil
end

--- Hand `on_done` the first remote of `dir` on a forge this knows
---@param dir string
---@param on_done fun(remote: DyForgeRemote?)
function M.remote(dir, on_done)
  -- Every remote in one call, rather than one call per name tried
  git(dir, { 'config', '--get-regexp', [[^remote\..*\.url$]] }, function(output)
    local urls = {}
    for name, url in (output or ''):gmatch('remote%.(%S+)%.url%s+(%S+)') do
      urls[name] = url
    end
    on_done(M.pick_remote(urls))
  end)
end

--- Hand `on_done` the branch checked out in `dir`, nil when detached
---@param dir string
---@param on_done fun(branch: string?)
function M.branch(dir, on_done)
  git(dir, { 'symbolic-ref', '--short', 'HEAD' }, on_done)
end

--- Percent-encode `text` for a path segment of a URL
---@param text string
---@return string
function M.encode(text)
  return (
    text:gsub(
      '[^%w%.%-_~]',
      function(char) return ('%%%02X'):format(char:byte()) end
    )
  )
end

--- The environment to run `remote`'s CLI in: nil for the user's own, or one
--- without the tokens of `M.TOKEN_VARS`
---
--- The host comes from a repository's remote, which anyone can set: the
--- tokens in the environment belong to the host the user named, or to the
--- default host when none is named, and are not handed to any other. The
--- CLI's own login for the host is still used.
---@param remote DyForgeRemote
---@return table<string, string>? env
function M.cli_env(remote)
  local host = remote.host:lower()
  local named_any = false
  for _, var in ipairs(M.HOST_VARS[remote.kind] or {}) do
    local value = vim.env[var]
    if value and value ~= '' then
      named_any = true
      local named = M.parse_url(value .. '/x') or value
      if named:lower() == host then return nil end
    end
  end
  -- A host named in the environment owns its tokens, so the default host is
  -- one more host they must not reach
  if not named_any and host == M.DEFAULT_HOSTS[remote.kind] then return nil end
  local env = vim.fn.environ()
  local dropped = false
  for _, var in ipairs(M.TOKEN_VARS[remote.kind] or {}) do
    if env[var] then
      env[var] = nil
      dropped = true
    end
  end
  return dropped and env or nil
end

--- `util.system.run` options for `remote`'s CLI
---@param remote DyForgeRemote
---@param opts DyRunOpts
---@return DyRunOpts
local function cli_opts(remote, opts)
  local env = M.cli_env(remote)
  if env then
    opts.env, opts.clear_env = env, true
  end
  if remote.kind == 'azure' then
    opts.env = vim.tbl_extend('force', opts.env or {}, M.AZURE_ENV)
    -- `az` may ask for a login: never on the terminal the editor holds
    opts.detach = true
  end
  return opts
end

--- The `key=value` words of `map`, sorted so a call reads the same each time
---@param map? table<string, string|integer>
---@return string[]
local function params(map)
  local words = {}
  for key, value in pairs(map or {}) do
    table.insert(words, key .. '=' .. tostring(value))
  end
  table.sort(words)
  return words
end

--- The command that calls `endpoint` of the API of `remote`, the name it
--- goes by in messages, and what removes the file holding an Azure call's
--- body once the command is done
---@param remote DyForgeRemote
---@param endpoint string|DyForgeAzureCall A path for `gh` and `glab`, a call for `az`
---@return string[] command
---@return string name
---@return fun()? cleanup
function M.command(remote, endpoint)
  if remote.kind ~= 'azure' then
    local cli = M.CLIS[remote.kind]
    return {
      cli,
      'api',
      '--hostname',
      remote.host,
      endpoint --[[@as string]],
    },
      cli .. ' api'
  end
  local call = endpoint --[[@as DyForgeAzureCall]]
  local command = {
    'az',
    'devops',
    'invoke',
    -- Built from the organization's name alone, whatever host the remote
    -- names: the CLI's credentials only ever go to Azure DevOps itself
    '--organization',
    'https://dev.azure.com/' .. remote.org,
    '--detect',
    'false',
    '--area',
    call.area,
    '--resource',
    call.resource,
    '--api-version',
    call.api_version or M.AZURE_API_VERSION,
    '--http-method',
    call.method or 'GET',
    '--output',
    'json',
    '--only-show-errors',
  }
  local route, query = params(call.route), params(call.query)
  if #route > 0 then
    table.insert(command, '--route-parameters')
    vim.list_extend(command, route)
  end
  if #query > 0 then
    table.insert(command, '--query-parameters')
    vim.list_extend(command, query)
  end
  local cleanup
  if call.body ~= nil then
    -- `az devops invoke` takes a body from a file alone; one in Neovim's own
    -- temporary directory, which only the user can read
    local file = vim.fn.tempname()
    vim.fn.writefile({ vim.json.encode(call.body) }, file)
    vim.list_extend(command, { '--in-file', file })
    cleanup = function() vim.fn.delete(file) end
  end
  return command, 'az devops invoke', cleanup
end

---@class DyForgeCallOpts
---@field max_bytes? integer
---@field method? 'POST'|'PATCH'|'PUT'|'DELETE' A write, rather than a read
---@field body? table What a write sends, as JSON

--- Run `endpoint` of the API of `remote` and decode its JSON answer
---@param remote DyForgeRemote
---@param endpoint string|DyForgeAzureCall
---@param opts DyForgeCallOpts
---@param on_done fun(data: any?, err: string?)
local function json_call(remote, endpoint, opts, on_done)
  local cli = M.CLIS[remote.kind]
  if not cli then return on_done(nil, 'No CLI answers for ' .. remote.kind) end
  if vim.fn.executable(cli) ~= 1 then
    return on_done(nil, cli .. ' is not installed')
  end
  local run_opts = { timeout = M.TIMEOUT, max_bytes = opts.max_bytes }
  if opts.method and remote.kind == 'azure' then
    endpoint = vim.tbl_extend('force', endpoint --[[@as table]], {
      method = opts.method,
      body = opts.body,
    })
  end
  local command, name, cleanup = M.command(remote, endpoint)
  if opts.method and remote.kind ~= 'azure' then
    -- Before the endpoint, which stays the last word
    local flags = { '--method', opts.method }
    if opts.body ~= nil then
      vim.list_extend(flags, { '--input', '-' })
      run_opts.stdin = vim.json.encode(opts.body)
    end
    for _, flag in ipairs(flags) do
      table.insert(command, #command, flag)
    end
  end
  local system = require('util.system')
  system.run(command, cli_opts(remote, run_opts), function(result)
    -- The body file goes first, whatever the answer
    if cleanup then cleanup() end
    if result.code ~= 0 and not result.cut then
      return on_done(nil, system.failure(result, name))
    end
    -- Half a JSON document is no answer
    if result.cut then
      return on_done(nil, name .. ' answered with more than can be read')
    end
    -- A write may answer `204 No Content`, or `null`: done, with nothing to
    -- say, never a nil that reads as a failure without a reason
    if opts.method and vim.trim(result.stdout or '') == '' then
      return on_done({})
    end
    local decoded, data = pcall(
      vim.json.decode,
      result.stdout or '',
      { luanil = { object = true, array = true } }
    )
    if not decoded then
      return on_done(nil, name .. ' answered with something not JSON')
    end
    if data == nil and opts.method then data = {} end
    on_done(data)
  end)
end

--- Call `endpoint` of the API of `remote`, through its CLI, and hand
--- `on_done` the decoded answer or why there is none
---@param remote DyForgeRemote
---@param endpoint string|DyForgeAzureCall Relative, as `gh` or `glab` takes it (`repos/o/r/pulls`), or a call of Azure DevOps
---@param on_done fun(data: any?, err: string?)
function M.api(remote, endpoint, on_done)
  json_call(remote, endpoint, {}, on_done)
end

--- Send a write -- a comment, a vote -- to `endpoint` of the API of
--- `remote`, through its CLI, and hand `on_done` the decoded answer or why
--- there is none
---
--- `gh` and `glab` read `body` from their input; `az` from a file, removed
--- once the call is done.
---@param remote DyForgeRemote
---@param method 'POST'|'PATCH'|'PUT'|'DELETE'
---@param endpoint string|DyForgeAzureCall A path for `gh` and `glab`; for `az` a call, its `method` and `body` taken from here
---@param body? table Sent as JSON
---@param on_done fun(data: any?, err: string?) `{}` for an empty answer
function M.write(remote, method, endpoint, body, on_done)
  json_call(remote, endpoint, { method = method, body = body }, on_done)
end

--- Call `endpoint` of the API of `remote`, through its CLI, for text rather
--- than JSON -- a job's log -- and hand `on_done` at most `max_bytes` of it
---@param remote DyForgeRemote
---@param endpoint string|DyForgeAzureCall
---@param max_bytes integer
---@param on_done fun(text: string?, cut: boolean, err: string?)
function M.api_text(remote, endpoint, max_bytes, on_done)
  if remote.kind == 'azure' then
    -- `az devops invoke` answers in JSON alone: a log comes as its lines,
    -- and one cut short cannot be read at all
    return json_call(
      remote,
      endpoint,
      { max_bytes = max_bytes },
      function(data, err)
        if data == nil then return on_done(nil, false, err) end
        if type(data) == 'string' then return on_done(data, false) end
        local lines = type(data) == 'table' and data.value
        if type(lines) ~= 'table' then
          return on_done(nil, false, 'az devops invoke answered with no log')
        end
        on_done(table.concat(vim.tbl_map(tostring, lines), '\n'), false)
      end
    )
  end
  local cli = M.CLIS[remote.kind]
  if vim.fn.executable(cli) ~= 1 then
    return on_done(nil, false, cli .. ' is not installed')
  end
  local command, name = M.command(remote, endpoint)
  local system = require('util.system')
  system.run(
    command,
    cli_opts(remote, { timeout = M.TIMEOUT, max_bytes = max_bytes }),
    function(result)
      if result.code ~= 0 and not result.cut then
        return on_done(nil, false, system.failure(result, name))
      end
      on_done(result.stdout or '', result.cut)
    end
  )
end

return M
