local language = require('config.languages').ansible

--- The Python of Mason's ansible-lint, when ansible itself is not on `$PATH`
---
--- The server runs `ansible-config dump` as it starts and reports a failure
--- for every file it opens when that is missing. Mason installs ansible-lint
--- into a virtualenv that carries ansible-core along with it, but links only
--- `ansible-lint` into `$MASON/bin`. Naming that virtualenv's interpreter
--- makes the server put its `bin/` ahead of `$PATH`, the same as activating
--- it would.
---@return string?
local function mason_ansible_python()
  if vim.fn.executable('ansible-config') == 1 then return nil end
  local python = vim.fn.stdpath('data')
    .. '/mason/packages/ansible-lint/venv/bin/python'
  return vim.uv.fs_stat(python) and python or nil
end

return vim.list_contains(DyNeo.enabled_languages, 'ansible')
    and {
      {
        -- LSP config
        'neovim/nvim-lspconfig',
        opts = {
          servers = {
            ansiblels = {
              settings = {
                ansible = {
                  python = { interpreterPath = mason_ansible_python() },
                  -- nvim-lint runs ansible-lint already; the server running
                  -- it too would show each finding twice
                  validation = { lint = { enabled = false } },
                },
              },
            },
          },
        },
      },
      {
        -- `ansible-doc` for `K`, and `gf` into a role's `files/` and
        -- `templates/`. Running a playbook or a role is the `ansible run`
        -- task of overseer (`<leader>oo`).
        'mfussenegger/nvim-ansible',
        ft = language.filetypes,
      },
    }
  or {}
