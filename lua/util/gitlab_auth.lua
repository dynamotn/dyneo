--- The GitLab a repository is on, and the token to reach it with
---
--- gitlab.nvim looks for its token in a `.gitlab.nvim` file at the root of
--- the project or in `GITLAB_TOKEN`, and talks to gitlab.com unless told
--- otherwise. Both miss the usual case here: `glab` is already logged in,
--- and `origin` may be a self-hosted instance. So the plugin's own lookup is
--- asked first, and what it leaves out is filled in from `glab` and from the
--- remote -- the token is handed to the plugin's local server and never
--- kept or shown here.
local M = {}

local notify = require('util.notify').titled('GitLab')

--- The host of a git remote URL, for `https://`, `ssh://` and scp-like URLs
---@param url string
---@return string?
function M.host_of(url)
  local rest = url:match('^%a[%w+.-]*://(.*)$')
  if rest then
    -- The authority ends at the first `/`, `?` or `#`, and its user info at
    -- its last `@`: `https://evil.example?@gitlab.com` is evil.example's
    local authority = rest:match('^([^/?#]*)')
    return (authority:gsub('^.*@', ''):match('^([^:]+)'))
  end
  return url:match('^[%w_.-]+@([^:]+):')
end

--- The URL of `remote` in `dir`, or nil
---@param dir string
---@param remote string
---@return string?
function M.remote_url(dir, remote)
  local result = require('util.system').sync(
    { 'git', '-C', dir, 'remote', 'get-url', remote },
    { text = true }
  )
  local url = result.code == 0 and vim.trim(result.stdout or '') or ''
  return url ~= '' and url or nil
end

--- The token `glab` holds for `host`, or nil
---@param host string
---@return string?
function M.glab_token(host)
  if vim.fn.executable('glab') ~= 1 then return nil end
  -- glab answers with `GITLAB_ACCESS_TOKEN` or `OAUTH_TOKEN` for any host
  -- asked about, and the host may come from the repository
  local env = require('util.forge').cli_env({ kind = 'gitlab', host = host })
  local result = require('util.system').sync(
    { 'glab', 'config', 'get', 'token', '--host', host },
    { text = true, env = env, clear_env = env ~= nil }
  )
  local token = result.code == 0 and vim.trim(result.stdout or '') or ''
  return token ~= '' and token or nil
end

--- The token and the URL gitlab.nvim connects with
---
--- `fallback` is the plugin's own lookup, which reads `.gitlab.nvim` and the
--- environment; whatever it leaves empty comes from `glab` and from the
--- remote of the repository the editor is in.
---
--- A token only ever goes to the host it belongs to. `.gitlab.nvim` sits in
--- the repository, so a branch checked out for review may well bring one
--- naming somebody else's server: `glab` is asked for the token of the URL
--- given, never of `origin`. And a token from the environment keeps the
--- plugin's own default host (or `GITLAB_URL`) rather than being sent to
--- whatever `origin` or `.gitlab.nvim` points at.
---@param fallback fun(): string?, string?, string?
---@param remote string The remote gitlab.nvim targets
---@return string? token
---@return string? url
---@return string? err
function M.auth(fallback, remote)
  local token, url = fallback()
  if token == '' then token = nil end
  if url == '' then url = nil end
  if token then
    -- The plugin pairs `.gitlab.nvim`'s URL with `GITLAB_TOKEN` when the file
    -- names no token of its own: the user's token would go to whatever server
    -- the repository names. It keeps to `GITLAB_URL`, or the plugin's default.
    local env_token = vim.env.GITLAB_TOKEN
    local env_url = vim.env.GITLAB_URL ~= '' and vim.env.GITLAB_URL or nil
    if token == env_token and url and url ~= env_url then
      notify(
        ('Ignoring the `.gitlab.nvim` URL %s for the token in GITLAB_TOKEN'):format(
          url
        ),
        vim.log.levels.WARN
      )
      url = env_url
    end
    return token, url
  end

  local host
  if url then
    host = M.host_of(url)
  else
    local dir = vim.fs.root(0, '.git') or vim.uv.cwd() --[[@as string]]
    local remote_url = M.remote_url(dir, remote)
    host = remote_url and M.host_of(remote_url)
    if host then url = 'https://' .. host end
  end
  if host then token = M.glab_token(host) end

  if not token or token == '' then
    -- gitlab.nvim gives up silently on an error, so it is said here
    local err = ('No GitLab token for %s: run `glab auth login`, or set GITLAB_TOKEN'):format(
      host or remote
    )
    notify(err, vim.log.levels.ERROR)
    return nil, nil, err
  end
  return token, url
end

return M
