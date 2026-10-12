--- Debug adapters named in `config.languages`, and what they share
---
--- An entry of a language's `dap` is the adapter's name in nvim-dap. For most
--- adapters that is all there is to say, because mason-nvim-dap maps the name
--- to the Mason package that installs it. One it does not know is written as
--- a table and carries the package itself, the way a linter or formatter does:
--- `{ 'perl', mason = { package = 'perl-debug-adapter' } }`.

local M = {}

---@param spec string|DyDapSpec
---@return string
M.name = function(spec)
  if type(spec) == 'table' then return spec[1] end
  return spec
end

---@type table<string, string>?
local nvim_dap_to_package

--- mason-nvim-dap's map from adapter name to Mason package
---
--- Read from its file rather than required: a `require` has lazy.nvim load
--- mason-nvim-dap, and nvim-dap with every adapter after it, on the first
--- buffer of any language that can be debugged.
---@return table<string, string>
local function mappings()
  local loaded = package.loaded['mason-nvim-dap.mappings.source']
  if loaded then return loaded.nvim_dap_to_package or {} end
  if nvim_dap_to_package then return nvim_dap_to_package end
  local ok, source = pcall(function()
    -- Outside lazy.nvim -- `scripts/validate-tools.lua` -- nothing loads on
    -- a `require`, and the plugin is found on the runtimepath
    if not package.loaded['lazy.core.config'] then
      return require('mason-nvim-dap.mappings.source')
    end
    local path = require('util.plugin').get_plugin_path(
      'mason-nvim-dap.nvim',
      'lua/mason-nvim-dap/mappings/source.lua'
    )
    return assert(loadfile(path))()
  end)
  if not ok then return {} end
  nvim_dap_to_package = source.nvim_dap_to_package or {}
  return nvim_dap_to_package
end

--- Mason package that installs the adapter of `spec`
---@param spec string|DyDapSpec
---@return string?
M.package = function(spec)
  if type(spec) == 'table' and spec.mason then return spec.mason.package end
  return mappings()[M.name(spec)]
end

--- Whether mason-nvim-dap knows the adapter of `spec` by name
---
--- Only such an adapter can go to its `ensure_installed`, and only such an
--- adapter is set up by it once installed; any other is installed by
--- `plugins.executor.debugging` itself and set up by the language's own plugin
--- file.
---@param spec string|DyDapSpec
---@return boolean
M.is_mapped = function(spec) return type(spec) == 'string' end

--- Register the `codelldb` adapter, unless something already did
---
--- mason-nvim-dap registers it once the package is installed, and rustaceanvim
--- brings its own; a language that debugs through LLDB calls this first so it
--- does not depend on either having run.
M.codelldb_adapter = function()
  local dap = require('dap')
  if dap.adapters['codelldb'] then return end
  dap.adapters['codelldb'] = {
    type = 'server',
    host = 'localhost',
    port = '${port}',
    executable = {
      command = 'codelldb',
      args = { '--port', '${port}' },
    },
  }
end

--- A frontend's config file and the port its dev server listens on by default
---@type {[1]: string, [2]: integer}[]
M.DEV_SERVERS = {
  { '^angular%.json$', 4200 },
  { '^vite%.config%.[cm]?[jt]s$', 5173 },
  { '^vue%.config%.[cm]?js$', 8080 },
  { '^next%.config%.[cm]?[jt]s$', 3000 },
  { '^nuxt%.config%.[cm]?[jt]s$', 3000 },
  { '^astro%.config%.[cm]?[jt]s$', 4321 },
  { '^gatsby%-config%.[cm]?[jt]s$', 8000 },
  { '^webpack%.config%.[cm]?[jt]s$', 8080 },
}

--- Port of a filetype's usual dev server, when no config file is found
---@type table<string, integer>
M.DEV_PORTS = { vue = 5173, svelte = 5173, astro = 4321, htmlangular = 4200 }

--- URL of the dev server serving `bufnr`
---
--- Taken from the nearest frontend config file above the buffer, else from
--- its filetype, else port 3000. Only the framework's default port is used;
--- a port set inside the config file is not read.
---@param bufnr? integer
---@return string
M.dev_server_url = function(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(bufnr)
  local port
  if name ~= '' then
    -- The nearest directory holding a config file decides, as `vim.fs.find`
    -- walks up one directory at a time
    vim.fs.find(function(file)
      for _, server in ipairs(M.DEV_SERVERS) do
        if file:match(server[1]) then
          port = port or server[2]
          return true
        end
      end
      return false
    end, {
      upward = true,
      path = vim.fs.dirname(name),
      stop = vim.uv.os_homedir(),
      limit = 1,
    })
  end
  port = port or M.DEV_PORTS[vim.bo[bufnr].filetype] or 3000
  return ('http://localhost:%d'):format(port)
end

--- Launch and attach configurations for a program debugged through `codelldb`
---@param build_dir string Where the prompt for the executable starts, under the
--- working directory: the build tool's output directory, or `''`.
---@return dap.Configuration[]
M.codelldb_configurations = function(build_dir)
  return {
    {
      type = 'codelldb',
      request = 'launch',
      name = 'Launch file',
      program = function()
        return vim.fn.input(
          'Path to executable: ',
          vim.fn.getcwd() .. '/' .. build_dir,
          'file'
        )
      end,
      cwd = '${workspaceFolder}',
    },
    {
      type = 'codelldb',
      request = 'attach',
      name = 'Attach to process',
      pid = require('dap.utils').pick_process,
      cwd = '${workspaceFolder}',
    },
  }
end

return M
