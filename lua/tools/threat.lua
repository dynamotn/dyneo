--- A STRIDE threat model, kept as a decision record
---
--- `:DyThreat new [{scope}]` writes, as a new record of `tools.adr`, the
--- scope to model -- its components, data flows and trust boundaries -- and
--- for each STRIDE category the questions to ask of every boundary a flow
--- crosses, as a checklist. `:DyThreat` reads the model open (or the
--- project's latest) the way `:DyWar` reads a review: how far each category
--- got, and the questions still open in the quickfix list.
local M = {}

local adr = require('tools.adr')
local war = require('tools.war')
local notify = require('util.notify').titled('Threat model')

--- The title every model starts with; its scope follows it
M.TITLE = 'Threat model'

--- The STRIDE categories and the questions each asks of a trust boundary
M.CATEGORIES = {
  {
    'Spoofing',
    {
      'Every caller across the boundary is authenticated',
      'Service-to-service calls carry an identity, not a shared secret',
      'Credentials and tokens expire, and can be revoked',
    },
  },
  {
    'Tampering',
    {
      'Data in transit is integrity protected (TLS, signatures)',
      'Input is validated where it crosses the boundary',
      'Artifacts and images are signed, and checked before they run',
    },
  },
  {
    'Repudiation',
    {
      'Security-relevant actions are logged with who, what and when',
      'Logs are kept where the actor cannot change or delete them',
    },
  },
  {
    'Information disclosure',
    {
      'Sensitive data is classified, and encrypted at rest',
      'Errors and logs leak no secrets or personal data',
      'Access is least privilege, per tenant where there are tenants',
    },
  },
  {
    'Denial of service',
    {
      'Every entry point is rate limited, with quotas per caller',
      'Timeouts, retries and queues are bounded',
      'A dependency that fails degrades the service rather than stops it',
    },
  },
  {
    'Elevation of privilege',
    {
      'Authorization is checked on every request, server side',
      'Workloads run unprivileged, with no more permissions than they use',
      'Admin paths are separate, and need a stronger authentication',
    },
  },
}

--- A threat model, as `war.report` reads it
---@type DyChecklistKind
M.KIND = {
  pattern = '^' .. vim.pesc(M.TITLE) .. ': %S',
  label = 'Threat model',
  noun = 'threat model',
  command = ':DyThreat new',
  -- Only these count: the template's Consequences invite `- [ ]` tasks
  sections = M.CATEGORIES,
}

--- The lines of the model of `scope`, numbered `number`
---@param number integer
---@param date string
---@param scope string
---@return string[]
function M.template(number, date, scope)
  local lines = {
    ('# %d. %s: %s'):format(number, M.TITLE, scope),
    '',
    'Date: ' .. date,
    '',
    '## Status',
    '',
    'Proposed',
    '',
    '## Context',
    '',
    'Components, the data flows between them, and the trust boundaries the',
    'flows cross: a diagram (`:DyArchitecture`, a C4 model) or a list.',
  }
  for _, category in ipairs(M.CATEGORIES) do
    vim.list_extend(lines, { '', '## ' .. category[1], '' })
    for _, question in ipairs(category[2]) do
      table.insert(lines, '- [ ] ' .. question)
    end
  end
  vim.list_extend(lines, {
    '',
    '## Consequences',
    '',
    'The threats accepted, the mitigations planned, and who owns each.',
  })
  return lines
end

--- Write a model of `scope`, asked for when not given, and open it
---@param scope? string
function M.new(scope)
  local function write(text)
    local date = os.date('%Y-%m-%d') --[[@as string]]
    local dir, err = adr.dir(war.root())
    if not dir then return notify(err, vim.log.levels.ERROR) end
    local record = adr.create(dir, ('%s: %s'):format(M.TITLE, text))
    vim.fn.writefile(M.template(record.number, date, text), record.file)
    vim.cmd.edit(vim.fn.fnameescape(record.file))
    notify(('Model %d written: tick what holds'):format(record.number))
  end
  if scope and scope ~= '' then return write(scope) end
  vim.ui.input({ prompt = 'Scope of the model: ' }, function(input)
    if input and vim.trim(input) ~= '' then write(vim.trim(input)) end
  end)
end

--- `:DyThreat [new [{scope}]]`
---@param args { fargs: string[] }
function M.command(args)
  local sub = args.fargs[1]
  if not sub then return war.report(M.KIND) end
  if sub == 'new' then
    return M.new(table.concat(vim.list_slice(args.fargs, 2), ' '))
  end
  notify('Unknown subcommand: ' .. sub, vim.log.levels.ERROR)
end

return M
