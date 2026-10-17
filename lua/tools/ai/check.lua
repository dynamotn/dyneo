--- The checks text that is no buffer passes before it goes to an AI
---
--- A diff, a CI log: nothing `util.sensitive` has looked at, since it never
--- sat in a buffer. It is let through once no path it names is sensitive and
--- neither `config.sensitive`'s patterns nor `betterleaks` find a secret in
--- it. A check that cannot run refuses, as a finding would.
local M = {}

--- Milliseconds `betterleaks` may take
M.TIMEOUT = 30 * 1000

--- What keeps `text` from going out, if anything: one of `paths` that is
--- sensitive, or a line with the shape of a credential
---@param root string What `paths` are relative to
---@param paths string[]
---@param text string
---@return string? reason
function M.refusal(root, paths, text)
  local sensitive = require('util.sensitive')
  for _, path in ipairs(paths) do
    if sensitive.is_sensitive_path(vim.fs.joinpath(root, path)) then
      return ('%s is kept from AI'):format(path)
    end
  end
  -- Every line, removed ones too: a secret a commit takes out is still in
  -- the text that would be sent
  for line in text:gmatch('[^\n]+') do
    local rule = sensitive.secret_format(line)
    if rule then return ('the text holds a %s'):format(rule) end
  end
end

--- A directory of this session holding the `betterleaks` configuration used
--- here, its built-in rules and nothing more, and an empty folder for its
--- ignore file
---@type string?
local own

--- That directory, made again when something removed it
---@return string
local function own_config()
  if own and vim.uv.fs_stat(own .. '/config.toml') then return own end
  own = vim.fn.tempname()
  vim.fn.mkdir(own .. '/ignore', 'p', tonumber('700', 8))
  vim.fn.writefile({ '[extend]', 'useDefault = true' }, own .. '/config.toml')
  return own
end

--- Run `betterleaks` over `text`, with live validation off so nothing of it
--- reaches a provider, and hand `on_done` why it must not go out, or nil
---
--- It runs on its own rules alone: the repository's `.betterleaks.toml`,
--- `.gitleaks.toml` or `.betterleaksignore` could allow anything, and a
--- `betterleaks:allow` comment is text of the diff like any other.
---@param text string
---@param on_done fun(reason?: string)
function M.scan(text, on_done)
  local system = require('util.system')
  local dir = own_config()
  system.run({
    'betterleaks',
    'stdin',
    '--config=' .. dir .. '/config.toml',
    '--gitleaks-ignore-path=' .. dir .. '/ignore',
    '--ignore-gitleaks-allow',
    '--report-format=json',
    '--report-path=-',
    '--exit-code=0',
    '--no-banner',
    '--log-level=error',
    '--validation=false',
    '--redact',
  }, { cwd = dir, stdin = text, timeout = M.TIMEOUT }, function(result)
    if result.code ~= 0 or result.cut then
      return on_done(
        'betterleaks could not check it: '
          .. system.failure(result, 'betterleaks')
      )
    end
    local ok, findings = pcall(vim.json.decode, result.stdout)
    if not ok or type(findings) ~= 'table' then
      return on_done('betterleaks gave a report that does not read')
    end
    if #findings == 0 then return on_done(nil) end
    local rules = {}
    for _, finding in ipairs(findings) do
      rules[finding.RuleID or 'finding'] = true
    end
    local names = vim.tbl_keys(rules)
    table.sort(names)
    on_done(('betterleaks found %s in it'):format(table.concat(names, ', ')))
  end)
end

--- Both checks, the cheap one first
---@param root string
---@param paths string[]
---@param text string
---@param on_done fun(reason?: string)
function M.text(root, paths, text, on_done)
  local reason = M.refusal(root, paths, text)
  if reason then return on_done(reason) end
  M.scan(text, on_done)
end

return M
