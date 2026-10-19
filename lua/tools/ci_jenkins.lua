--- The last build of a Jenkins job, for `tools.ci_inline` and `tools.ai.ci`
---
--- A `Jenkinsfile` says nothing of the server or the job that build it, so
--- the clone's own git config names them -- `dyneo.jenkinsJob`, and
--- `dyneo.jenkinsUrl` or `DyNeo.jenkins.url` for the server -- never a file
--- of the repository. `curl` reads the credentials from `~/.netrc`, which
--- hands each only to its own host; none is read or passed here.
---
--- The stages come from the Pipeline Stage View plugin's `wfapi`; a server
--- without it still tells the build, and says why there are no stages.
local M = {}

local forge = require('util.forge')
local system = require('util.system')

--- Milliseconds a request may take
M.TIMEOUT = 30 * 1000

--- Bytes of JSON read from the server
M.MAX_BYTES = 4 * 1024 * 1024

--- Bytes of a Jenkinsfile sent to be checked
M.MAX_FILE = 512 * 1024

---@class DyJenkinsTarget
---@field url string The server, no trailing slash
---@field job string The job's path, `team/app/{branch}`
---@field base string The job's URL, the branch put in

--- The URL of `job` on `url`: each folder its own `job/` segment, and
--- `{branch}` named the way a multibranch pipeline names the branch's job,
--- its slashes encoded once in the name and once more in the URL
---@param url string
---@param job string
---@param branch? string
---@return string
function M.job_url(url, job, branch)
  local named = branch and branch:gsub('/', '%%2F') or nil
  local parts = {}
  for segment in job:gmatch('[^/]+') do
    if named then
      segment = segment:gsub('{branch}', function() return named end)
    end
    table.insert(parts, 'job/' .. forge.encode(segment))
  end
  return (url:gsub('/+$', '')) .. '/' .. table.concat(parts, '/')
end

--- Hand `on_done` the server and the job `dir`'s clone names for `branch`,
--- or why there is none
---@param dir string
---@param branch string
---@param on_done fun(target: DyJenkinsTarget?, err: string?)
function M.target(dir, branch, on_done)
  system.run(
    { 'git', 'config', '--get-regexp', [[^dyneo\.jenkins]] },
    { cwd = dir, timeout = 5000 },
    function(result)
      local values = {}
      for key, value in (result.stdout or ''):gmatch('dyneo%.(%S+) ([^\n]+)') do
        values[key:lower()] = vim.trim(value)
      end
      local job = values.jenkinsjob
      if not job or job == '' then
        return on_done(
          nil,
          'No Jenkins job: git config dyneo.jenkinsJob <folder/job/{branch}>'
        )
      end
      local url = values.jenkinsurl or DyNeo.jenkins.url
      if not url or url == '' then
        return on_done(
          nil,
          'No Jenkins server: git config dyneo.jenkinsUrl, or DyNeo.jenkins.url'
        )
      end
      if not url:match('^https?://[%w%.%-]+[:/]?') then
        return on_done(nil, 'Not a Jenkins URL: ' .. url)
      end
      on_done({
        url = (url:gsub('/+$', '')),
        job = job,
        base = M.job_url(url, job, branch),
      })
    end
  )
end

--- `curl` asking `url`, with the `~/.netrc` entry of its host if there is one
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

--- GET `url` and decode its JSON
---@param url string
---@param on_done fun(data: table?, err: string?)
local function get_json(url, on_done)
  system.run(
    M.curl({ '--', url }),
    { timeout = M.TIMEOUT + 1000, max_bytes = M.MAX_BYTES },
    function(result)
      if result.code ~= 0 then
        return on_done(nil, system.failure(result, 'curl'))
      end
      if result.cut then
        return on_done(nil, 'Jenkins answered with more than can be read')
      end
      local ok, data = pcall(
        vim.json.decode,
        result.stdout or '',
        { luanil = { object = true, array = true } }
      )
      if not ok or type(data) ~= 'table' then
        return on_done(nil, 'Jenkins answered with something not JSON')
      end
      on_done(data)
    end
  )
end

--- The status a build's `result` and `building` come down to
---@param build table
---@return string
local function build_status(build)
  if build.building then return 'in_progress' end
  return type(build.result) == 'string' and build.result or 'pending'
end

--- The last build of `target`, with its stages as jobs
---@param target DyJenkinsTarget
---@param on_done fun(pipeline: DyCiPipeline?, err: string?)
function M.fetch(target, on_done)
  local tree = 'number,result,building'
  get_json(
    target.base .. '/lastBuild/api/json?tree=' .. tree,
    function(build, err)
      if not build then
        if err and err:find('404', 1, true) then
          return on_done(nil, 'No build of ' .. target.base)
        end
        return on_done(nil, err)
      end
      if type(build.number) ~= 'number' then
        return on_done(nil, 'Jenkins named no build number')
      end
      -- The link is built here: the server's own `url` may name another host
      local url = ('%s/%d/'):format(target.base, build.number)
      local pipeline = {
        id = build.number,
        status = build_status(build),
        url = url,
        jobs = {},
      }
      get_json(url .. 'wfapi/describe', function(run, e)
        local stages = type(run) == 'table' and run.stages
        if type(stages) ~= 'table' then
          -- The build as one job, for an AI to be asked about
          pipeline.note = 'no stages: ' .. (e or 'the server gave none')
          pipeline.jobs = {
            {
              id = 'build',
              name = '#' .. build.number,
              status = pipeline.status,
            },
          }
          return on_done(pipeline)
        end
        for _, stage in ipairs(stages) do
          if type(stage) == 'table' and type(stage.name) == 'string' then
            table.insert(pipeline.jobs, {
              id = stage.id,
              name = stage.name,
              status = stage.status,
            })
          end
        end
        on_done(pipeline)
      end)
    end
  )
end

--- Where each stage of a Jenkinsfile is defined: `stage('Build')` or
--- `stage("Build")`, by its name
---@param lines string[]
---@return table<string, integer>
function M.job_lines(lines)
  local jobs = {}
  for number, line in ipairs(lines) do
    for _, name in line:gmatch('stage%s*%(%s*(["\'])(.-)%1') do
      if name ~= '' and not jobs[name] then jobs[name] = number end
    end
  end
  return jobs
end

--- Hand `on_done` the end of the console of build `pipeline`: Jenkins hands
--- a console only from its start, so it streams through `tail`, which keeps
--- what fits
---@param target DyJenkinsTarget
---@param pipeline DyCiPipeline
---@param max_bytes integer
---@param on_done fun(text: string?, cut: boolean, err: string?, skipped: boolean)
function M.log(target, pipeline, max_bytes, on_done)
  local url = ('%s/%d/consoleText'):format(target.base, pipeline.id)
  local command = vim.list_extend({
    'bash',
    '-c',
    'set -o pipefail; curl "${@:3}" -- "$1" | tail -c "$2"',
    'dy_jenkins_log',
    url,
    tostring(max_bytes + 1),
  }, vim.list_slice(M.curl({}), 2))
  system.run(
    command,
    { timeout = M.TIMEOUT + 1000, max_bytes = max_bytes + 1024 },
    function(result)
      if result.code ~= 0 then
        return on_done(nil, false, system.failure(result, 'curl'), false)
      end
      local text = result.stdout or ''
      -- One byte more than kept says the start was left out
      local skipped = #text > max_bytes
      if skipped then text = text:sub(#text - max_bytes + 1) end
      on_done(text, false, nil, skipped)
    end
  )
end

--- The problems Jenkins' `pipeline-model-converter/validate` named, as
--- diagnostics on the line it gives; nil when it found none
---@param output string
---@return vim.Diagnostic[]?
function M.lint_diagnostics(output)
  if output:find('successfully validated', 1, true) then return nil end
  local diagnostics = {}
  for message, line, col in
    output:gmatch('WorkflowScript: %d+: (.-) @ line (%d+), column (%d+)%.')
  do
    table.insert(diagnostics, {
      lnum = tonumber(line) - 1,
      col = math.max(tonumber(col) - 1, 0),
      message = vim.trim(message),
      severity = vim.diagnostic.severity.ERROR,
      source = 'jenkins validate',
    })
  end
  if #diagnostics == 0 then
    table.insert(diagnostics, {
      lnum = 0,
      col = 0,
      message = vim.trim(output):sub(1, 500),
      severity = vim.diagnostic.severity.ERROR,
      source = 'jenkins validate',
    })
  end
  return diagnostics
end

--- Have the server check `text`, a declarative Jenkinsfile
---@param url string The server
---@param text string
---@param on_done fun(diagnostics: vim.Diagnostic[]?, err: string?)
function M.lint(url, text, on_done)
  if #text > M.MAX_FILE then
    return on_done(nil, 'The Jenkinsfile is too large to send')
  end
  system.run(
    M.curl({
      '--request',
      'POST',
      -- The file goes on standard input, never as a word of the command
      '--form',
      'jenkinsfile=<-',
      '--',
      url .. '/pipeline-model-converter/validate',
    }),
    { timeout = M.TIMEOUT + 1000, stdin = text, max_bytes = M.MAX_BYTES },
    function(result)
      if result.code ~= 0 then
        return on_done(nil, system.failure(result, 'curl'))
      end
      on_done(M.lint_diagnostics(result.stdout or ''))
    end
  )
end

return M
