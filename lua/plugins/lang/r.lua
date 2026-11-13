local language = require('config.languages').r

-- Every filetype R.nvim knows but `quarto`, whose chunks of any language run
-- through quarto-nvim on the same `<localleader>` keys. Typst is a document
-- with R chunks (`.Rtyp`), which R.nvim supports as it does R Markdown.
local filetypes = { 'r', 'rmd', 'rnoweb', 'rhelp', 'typst' }

--- The first of the working directory and the project of `bufnr` not
--- trusted to run R code, each asked once: R reads the `.Rprofile` of the
--- directory it starts in, and R.nvim runs the `rnvim_config.lua` beside a
--- file
---@param bufnr integer
---@return string? dir
local function untrusted(bufnr)
  local file = vim.api.nvim_buf_get_name(bufnr)
  local dirs = { vim.fn.getcwd() }
  if file ~= '' then
    table.insert(
      dirs,
      vim.fs.root(bufnr, { '.git', 'DESCRIPTION' }) or vim.fs.dirname(file)
    )
  end
  for _, dir in ipairs(dirs) do
    local question = ('Let R run the code of %s?'):format(dir)
    if not require('util.trust').ask('r', dir, question, true) then
      return dir
    end
  end
end

return vim.list_contains(DyNeo.enabled_languages, 'r')
    and {
      {
        -- R console in a split, and everything that talks to it
        'R-nvim/R.nvim',
        -- Its hooks are ftplugins, which lazy.nvim runs again for the buffer
        -- that loaded it; its ftdetect (`.Rtyp`) lazy.nvim reads at startup
        ft = filetypes,
        init = function() vim.g.R_filetypes = filetypes end,
        -- Every R buffer asks R for its `nvimcom` version, and fails when
        -- there is no R to ask.
        cond = function() return vim.fn.executable('R') == 1 end,
        opts = {
          R_args = { '--quiet', '--no-save' },
          pdfviewer = '',
          hook = {
            on_filetype = function()
              vim.keymap.set(
                'n',
                '<Enter>',
                '<Plug>RDSendLine',
                { buffer = true, desc = 'Send line to R' }
              )
              vim.keymap.set(
                'x',
                '<Enter>',
                '<Plug>RSendSelection',
                { buffer = true, desc = 'Send selection to R' }
              )
              require('which-key').add({
                buffer = true,
                mode = { 'n', 'x' },
                { '<localleader>a', group = 'all' },
                { '<localleader>b', group = 'between marks' },
                { '<localleader>c', group = 'chunks' },
                { '<localleader>f', group = 'functions' },
                { '<localleader>g', group = 'goto' },
                { '<localleader>i', group = 'install' },
                { '<localleader>k', group = 'knit' },
                { '<localleader>p', group = 'paragraph' },
                { '<localleader>q', group = 'quarto' },
                { '<localleader>r', group = 'r general' },
                { '<localleader>s', group = 'split or send' },
                { '<localleader>t', group = 'terminal' },
                { '<localleader>v', group = 'view' },
              })
            end,
          },
        },
        config = function(_, opts)
          vim.g.rout_follow_colorscheme = true
          -- Every buffer R.nvim sets up runs project code. Each ftplugin goes
          -- through `real_setup` first, so a buffer of an untrusted project
          -- stops there, before any of it runs.
          local r_config = require('r.config')
          local real_setup = r_config.real_setup
          r_config.real_setup = function()
            local dir = untrusted(0)
            if dir then
              error(('R.nvim is off in %s: it is not trusted'):format(dir), 0)
            end
            vim.b.rnvim_trusted = true
            return real_setup()
          end
          require('r').setup(opts)
          -- Once R runs, entering any R Markdown buffer has it read the
          -- knitr params of the file, `!r` code and all: only those of a
          -- buffer set up above
          local rmd = require('r.rmd')
          local update_params = rmd.update_params
          rmd.update_params = function()
            if vim.b.rnvim_trusted then return update_params() end
          end
          require('r.pdf.generic').open = vim.ui.open
        end,
      },
      {
        -- LSP config
        'neovim/nvim-lspconfig',
        opts = {
          servers = {
            r_language_server = {
              -- The server is R, started in the working directory
              root_dir = function(bufnr, on_dir)
                if untrusted(bufnr) then return end
                on_dir(
                  vim.fs.root(
                    bufnr,
                    { 'DESCRIPTION', 'NAMESPACE', '.Rbuildignore' }
                  )
                )
              end,
            },
          },
        },
      },
      {
        -- Test adapter
        'nvim-neotest/neotest',
        dependencies = {
          'shunsambongi/neotest-testthat',
          ft = language.filetypes,
        },
        opts = {
          adapters = {
            ['neotest-testthat'] = {},
          },
        },
      },
    }
  or {}
