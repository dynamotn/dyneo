---@diagnostic disable-next-line: unused-local
local language = require('config.languages').cmake

return vim.list_contains(DyNeo.enabled_languages, 'cmake')
    and {
      {
        -- Powerful toolbox for CMake
        'Civitasv/cmake-tools.nvim',
        -- stylua: ignore
        keys = {
          { '<localleader>b', '<cmd>CMakeBuild<cr>', desc = 'CMake Build', ft = { 'cmake', 'c', 'cpp' } },
          { '<localleader>r', '<cmd>CMakeRun<cr>', desc = 'CMake Run', ft = { 'cmake', 'c', 'cpp' } },
          { '<localleader>g', '<cmd>CMakeGenerate<cr>', desc = 'CMake Generate', ft = { 'cmake', 'c', 'cpp' } },
          { '<localleader>t', '<cmd>CMakeSelectBuildType<cr>', desc = 'CMake Build Type', ft = { 'cmake', 'c', 'cpp' } },
        },
        -- Loaded for a buffer inside a CMake project, wherever Neovim was
        -- started from
        init = function()
          local group =
            vim.api.nvim_create_augroup('dyneo_cmake', { clear = true })
          local filetypes = { 'cmake', 'c', 'cpp' }
          --- Load once for a buffer of a CMake project. It regenerates the
          --- build when `CMakeLists.txt` is saved and reads the project's
          --- own settings, so a buffer under a held directory waits.
          local loaded = false
          ---@param bufnr integer
          local function load(bufnr)
            if not vim.list_contains(filetypes, vim.bo[bufnr].filetype) then
              return
            end
            if not vim.fs.root(bufnr, 'CMakeLists.txt') then return end
            if require('util.untrusted').held(bufnr) then return end
            pcall(vim.api.nvim_del_augroup_by_id, group)
            if loaded then return end
            loaded = true
            require('lazy').load({ plugins = { 'cmake-tools.nvim' } })
          end
          vim.api.nvim_create_autocmd('FileType', {
            group = group,
            pattern = filetypes,
            callback = function(args) load(args.buf) end,
          })
          require('util.untrusted').on_release('cmake-tools', load)
        end,
        opts = {},
      },
    }
  or {}
