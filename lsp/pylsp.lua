-- pylsp runs beside pyright and ruff only for the rope refactorings that
-- `pylsp-rope` brings into its venv (`dynamotn/mason-registry`): extract,
-- inline, move, introduce parameter. pyright answers everything else, and
-- ruff lints and formats, so pylsp's own linters and formatters stay off.
local config = require('util.sidecar').only({ 'codeActionProvider' })

local off = { enabled = false }
config.settings = {
  pylsp = {
    plugins = {
      autopep8 = off,
      flake8 = off,
      mccabe = off,
      pycodestyle = off,
      pydocstyle = off,
      pyflakes = off,
      pylint = off,
      yapf = off,
    },
  },
}

---@type vim.lsp.Config
return config
