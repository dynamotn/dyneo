local h = require('null-ls.helpers')
local methods = require('null-ls.methods')

local DIAGNOSTICS_ON_SAVE = methods.internal.DIAGNOSTICS_ON_SAVE

return h.make_builtin({
  name = 'terragrunt_validate',
  meta = {
    url = 'https://terragrunt.gruntwork.io/docs/reference/cli-options/#validate-inputs',
    description = 'Terragrunt validate is a subcommand of terragrunt to validate configuration files in a directory',
  },
  method = DIAGNOSTICS_ON_SAVE,
  filetypes = {},
  generator_opts = {
    command = 'terragrunt',
    args = { 'hcl', 'validate', '--json' },
    cwd = h.cache.by_bufnr(
      function(params) return vim.fs.dirname(params.bufname) end
    ),
    -- Validating evaluates the configuration, and a `run_cmd` in its locals
    -- runs as the user: the project is trusted first, once a session
    runtime_condition = function(params)
      local root = vim.fs.root(params.bufnr, '.git')
        or vim.fs.dirname(params.bufname)
      return require('util.trust').ask(
        'terragrunt',
        root,
        ('Run terragrunt hcl validate in %s?\n'):format(
          vim.fn.fnamemodify(root, ':~')
        ) .. 'It evaluates terragrunt.hcl, whose run_cmd runs as you.',
        true
      )
    end,
    from_stderr = false,
    to_stdin = false,
    multiple_files = true,
    ignore_stderr = true,
    -- Decoded here rather than by none-ls, which skips `on_output` for an
    -- empty `[]`: the diagnostics kept from other directories would then be
    -- dropped the moment this one is clean
    format = 'raw',
    -- `hcl validate` exits non-zero when it finds a problem, with the JSON on
    -- stdout either way. Any other answer has none-ls move that output into
    -- the error output, which `ignore_stderr` then throws away.
    check_exit_code = function() return true end,
    on_output = function(params, done)
      local output = params.output
      -- Something said that is not the JSON report -- a crash, a prompt --
      -- is reported on the buffer rather than read as a clean directory
      local unreadable = false
      if type(output) == 'string' then
        local ok, decoded = pcall(vim.json.decode, output)
        unreadable = not ok and vim.trim(output) ~= ''
        output = ok and decoded or nil
      end
      if type(output) ~= 'table' then output = {} end
      local combined_diagnostics = {}
      if unreadable then
        table.insert(combined_diagnostics, {
          message = 'terragrunt hcl validate gave no JSON report: '
            .. vim.split(vim.trim(params.output), '\n')[1],
          row = 1,
          col = 1,
          source = 'terragrunt validate',
          severity = h.diagnostics.severities.error,
          filename = params.bufname,
        })
      end

      -- keep diagnostics from other directories
      if params.source_id ~= nil then
        local namespace =
          require('null-ls.diagnostics').get_namespace(params.source_id)
        local old_diagnostics =
          vim.diagnostic.get(nil, { namespace = namespace })
        -- `/repo/ab` is not under `/repo/a`
        local prefix = params.cwd:gsub('/$', '') .. '/'
        for _, old in ipairs(old_diagnostics) do
          local filename = old.filename
            or (old.bufnr and vim.api.nvim_buf_get_name(old.bufnr))
          if filename and filename:sub(1, #prefix) ~= prefix then
            -- Handed back as none-ls takes them, 1-based: what it stored is
            -- 0-based, and fed as it is would move a column left each run
            table.insert(combined_diagnostics, {
              message = old.message,
              source = old.source,
              severity = old.severity,
              filename = filename,
              row = old.lnum + 1,
              col = old.col + 1,
              end_row = (old.end_lnum or old.lnum) + 1,
              end_col = (old.end_col or old.col) + 1,
            })
          end
        end
      end

      for _, new_diagnostic in ipairs(output) do
        local message = new_diagnostic.summary
        if new_diagnostic.detail then
          message = message .. ' - ' .. new_diagnostic.detail
        end
        local rewritten_diagnostic = {
          message = message,
          row = 0,
          col = 0,
          source = 'terragrunt validate',
          severity = h.diagnostics.severities[new_diagnostic.severity],
          filename = params.bufname,
        }
        if new_diagnostic.range ~= nil then
          rewritten_diagnostic.col = new_diagnostic.range.start.column
          rewritten_diagnostic.end_col = new_diagnostic.range['end'].column
          rewritten_diagnostic.row = new_diagnostic.range.start.line
          rewritten_diagnostic.end_row = new_diagnostic.range['end'].line
          rewritten_diagnostic.filename = new_diagnostic.range.filename
        end
        table.insert(combined_diagnostics, rewritten_diagnostic)
      end
      if done then done(combined_diagnostics) end
      return combined_diagnostics
    end,
  },
  factory = h.generator_factory,
})
