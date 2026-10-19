--- Why a CI job failed, asked of an AI with the job's log and the file that
--- defines it
---
--- The last pipeline of the branch comes from `tools.ci_inline`, the log
--- through the forge's own CLI (`util.forge`). A log is no buffer and may
--- print anything the job had in its environment, so it passes
--- `tools.ai.check` before it goes out, and only its end -- where a failure
--- is told -- is sent.
local M = {}

--- The prompt, under `prompts/` of this configuration or of the project's
--- trusted `.nvim` folder
M.PROMPT = 'ci/failure.md'

--- Bytes of log read from the forge
M.MAX_LOG = 4 * 1024 * 1024

--- Bytes from the end of the log that are sent
M.TAIL = 48 * 1024

--- Bytes of the pipeline file that are sent
M.MAX_FILE = 32 * 1024

--- Lines from the end of an Azure DevOps log that are read: its API answers
--- in JSON, which cannot be cut short and still be read
M.AZURE_LINES = 5000

local notify = require('util.notify').titled('AI CI')

--- The jobs of `pipeline` that failed
---@param pipeline DyCiPipeline
---@return DyCiJob[]
function M.failed(pipeline)
  local ci = require('tools.ci_inline')
  return vim.tbl_filter(
    function(job) return ci.bucket(job.status, job.conclusion) == 'fail' end,
    pipeline.jobs
  )
end

--- The API endpoint of the log of `job`
---@param remote DyForgeRemote
---@param job DyCiJob
---@param pipeline? DyCiPipeline The run of the job, which Azure asks for
---@param start? integer Azure: the first line read
---@return string|DyForgeAzureCall
function M.log_endpoint(remote, job, pipeline, start)
  if remote.kind == 'azure' then
    return {
      area = 'build',
      resource = 'logs',
      route = {
        project = remote.project,
        buildId = pipeline and pipeline.id,
        logId = job.id,
      },
      query = start and start > 1 and { startLine = start } or nil,
    }
  end
  if remote.kind == 'gitlab' then
    return ('projects/%s/jobs/%d/trace'):format(
      require('util.forge').encode(remote.slug),
      job.id
    )
  end
  return ('repos/%s/actions/jobs/%d/logs'):format(remote.slug, job.id)
end

--- Hand `on_done` the log of `job`, or its end; `skipped` says lines before
--- what was read were left out
---@param remote DyForgeRemote
---@param pipeline DyCiPipeline
---@param job DyCiJob
---@param on_done fun(raw: string?, cut: boolean, err: string?, skipped: boolean)
function M.fetch_log(remote, pipeline, job, on_done)
  local forge = require('util.forge')
  if remote.kind ~= 'azure' then
    return forge.api_text(
      remote,
      M.log_endpoint(remote, job),
      M.MAX_LOG,
      function(raw, cut, err) on_done(raw, cut, err, false) end
    )
  end
  -- How long the log is, to read only its end
  forge.api(remote, {
    area = 'build',
    resource = 'logs',
    route = { project = remote.project, buildId = pipeline.id },
  }, function(data, err)
    if not data then return on_done(nil, false, err, false) end
    local count
    local rows = type(data) == 'table' and data.value
    for _, row in ipairs(type(rows) == 'table' and rows or {}) do
      if type(row) == 'table' and row.id == job.id then
        count = row.lineCount
      end
    end
    local start = type(count) == 'number'
        and count > M.AZURE_LINES
        and count - M.AZURE_LINES + 1
      or 1
    forge.api_text(
      remote,
      M.log_endpoint(remote, job, pipeline, start),
      M.MAX_LOG,
      function(raw, cut, e) on_done(raw, cut, e, start > 1) end
    )
  end)
end

--- The end of a job's log, as text: colours, GitLab's section markers and
--- GitHub's timestamps taken out, a line redrawn with `\r` kept as last drawn
---@param log string
---@return string text
---@return boolean cut Whether the start was left out
function M.tail(log)
  local lines = {}
  for line in (log .. '\n'):gmatch('(.-)\r?\n') do
    line = line:gsub('section_%a+:%d+:[^\r]*\r', '')
    line = line:gsub('\27%[[%d;?]*%a', '')
    line = line:match('([^\r]*)$') or line
    line = line:gsub('^%d%d%d%d%-%d%d%-%d%dT[%d:.]+Z ', '')
    table.insert(lines, line)
  end
  while #lines > 0 and vim.trim(lines[#lines]) == '' do
    table.remove(lines)
  end
  local text = table.concat(lines, '\n')
  if #text <= M.TAIL then return text, false end
  local start = text:find('\n', #text - M.TAIL, true) or (#text - M.TAIL)
  return text:sub(start + 1), true
end

--- The prompt for the failed `job`
---@param prompt DyAiPrompt
---@param ctx { job: string, file: string, workflow: string, log: string, run?: string }
---@return string
function M.build(prompt, ctx)
  local values = {
    job = ctx.job,
    file = ctx.file,
    run = ctx.run or '(no link)',
    workflow = ctx.workflow,
    log = ctx.log,
    -- One fence for both, longer than any backticks either holds
    fence = require('tools.ai.prompts').fence(ctx.workflow .. '\n' .. ctx.log),
  }
  return (prompt.body:gsub('{(%a+)}', values))
end

--- Ask about the failed job `job` of `pipeline`
---@param bufnr integer
---@param ctx DyCiContext
---@param pipeline DyCiPipeline
---@param job DyCiJob
---@param prompt DyAiPrompt
local function ask(bufnr, ctx, pipeline, job, prompt)
  local function fail(reason)
    require('util.ai_audit').record('dyai', 'refused', ctx.file, 'ci log')
    notify(reason, vim.log.levels.WARN)
  end
  if not job.id then return fail('The forge gave no id for ' .. job.name) end
  M.fetch_log(ctx.remote, pipeline, job, function(raw, cut, err, skipped)
    if not raw then return fail(err or 'No log for ' .. job.name) end
    local log, left_out = M.tail(raw)
    left_out = left_out or skipped
    if cut then
      notify(
        ('The log passed %d MiB: its end is missing'):format(
          M.MAX_LOG / 1024 / 1024
        ),
        vim.log.levels.WARN
      )
    end
    require('tools.ai.check').text(ctx.dir, {}, log, function(why)
      if why then return fail('The log of ' .. job.name .. ': ' .. why) end
      if not vim.api.nvim_buf_is_valid(bufnr) then return end
      local file =
        table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
      if #file > M.MAX_FILE then file = file:sub(1, M.MAX_FILE) .. '\n(cut)' end
      require('tools.ai').send(
        M.build(prompt, {
          job = job.name,
          file = vim.fn.fnamemodify(ctx.file, ':~:.'),
          run = pipeline.url,
          workflow = file,
          log = (left_out and '(earlier lines left out)\n' or '') .. log,
        }),
        bufnr,
        'ci job ' .. job.name
      )
    end)
  end)
end

--- Explain why a job of the last pipeline of the branch failed, from the
--- pipeline file in the current buffer
---@param bufnr? integer
function M.explain(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf()
    or bufnr
  local sensitive = require('util.sensitive')
  if sensitive.is_sensitive(bufnr) then
    return notify(
      'Kept from AI: ' .. table.concat(sensitive.reasons(bufnr), '; '),
      vim.log.levels.WARN
    )
  end
  local prompt = require('tools.ai.prompts').template(M.PROMPT)
  if not prompt then
    return notify('No prompt ' .. M.PROMPT, vim.log.levels.ERROR)
  end
  local ci = require('tools.ci_inline')
  ci.context(bufnr, function(ctx)
    ci.fetch(ctx.remote, ctx.branch, ctx.file, function(pipeline, err)
      if not pipeline then
        return notify(err or 'No pipeline', vim.log.levels.WARN)
      end
      local failed = M.failed(pipeline)
      if #failed == 0 then
        return notify(
          ('No job failed in the last run on %s'):format(ctx.branch)
        )
      end
      if #failed == 1 then
        return ask(bufnr, ctx, pipeline, failed[1], prompt)
      end
      vim.ui.select(failed, {
        prompt = 'Failed job',
        format_item = function(job) return job.name end,
      }, function(job)
        if job then ask(bufnr, ctx, pipeline, job, prompt) end
      end)
    end)
  end)
end

return M
