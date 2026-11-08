--- Duplicated code across the project, in the quickfix list
---
--- jscpd finds clones in some 200 languages and writes them as a SARIF
--- report, which `tools.sarif` turns into quickfix items. The report is read
--- against the project root, not the temporary directory it is written to,
--- and removed once read: it may quote the code.
local M = {}

local notify = require('util.notify').titled('Duplicates')

--- Milliseconds jscpd may take on the project
M.TIMEOUT = 120000

--- Look for duplicated code under `root`, the project of the buffer unless
--- given
---@param root? string
function M.run(root)
  root = root or require('util.root')()
  local out = vim.fn.tempname()
  local system = require('util.system')
  system.run({
    'jscpd',
    '--reporters',
    'sarif',
    '--output',
    out,
    '--absolute',
    '--silent',
    root,
  }, { cwd = root, timeout = M.TIMEOUT }, function(result)
    local report_file = vim.fs.joinpath(out, 'jscpd-report.sarif')
    --- Remove the report, then say `msg` when there is one
    ---@param msg? string
    ---@param level? integer
    local function finish(msg, level)
      vim.fn.delete(out, 'rf')
      if msg then notify(msg, level) end
    end
    if result.missing then
      require('util.lazy_install').install_once('jscpd')
      finish(
        'Installing jscpd with Mason; run again once it is done',
        vim.log.levels.WARN
      )
      return
    end
    if result.code ~= 0 or result.timed_out then
      finish(system.failure(result, 'jscpd'), vim.log.levels.ERROR)
      return
    end
    local stat = vim.uv.fs_stat(report_file)
    if not stat then
      finish('No duplicated code')
      return
    end
    local sarif = require('tools.sarif')
    if stat.size > sarif.MAX_REPORT then
      finish('The jscpd report is too large to read', vim.log.levels.ERROR)
      return
    end
    local ok, report =
      pcall(vim.json.decode, table.concat(vim.fn.readfile(report_file), '\n'))
    finish()
    if not ok then
      notify('jscpd wrote no SARIF report', vim.log.levels.ERROR)
      return
    end
    local items = sarif.items(report, root)
    if #items == 0 then
      notify('No duplicated code')
      return
    end
    vim.fn.setqflist({}, ' ', { title = 'Duplicated code', items = items })
    vim.cmd('botright copen')
  end)
end

return M
