--- Overseer tasks of each language, keyed by its name in `config.languages`.
--- `lua/overseer/template/dytask/lang.lua` turns them into templates for
--- `<leader>oo`, for the languages in `DyNeo.enabled_languages` only.
---
--- A runner either works on the current file, or -- when it names `root`
--- markers -- on the project holding it, from that project's root. Project
--- tooling overseer already reads on its own (make, just, npm, cargo, mix,
--- rake, composer, deno, tox, ...) and the runners of rustaceanvim,
--- cmake-tools, flutter-tools and xcodebuild are not repeated here.

---@class DyTaskContext
---@field file string Absolute path of the current file
---@field dir string Directory of the file
---@field stem string The file's path without its extension
---@field root? string Project root, for a runner with `root` markers
---@field exe string The executable the runner resolved to

---@class DyTaskRunner
---@field name string Template name, shown by `:OverseerRun`
---@field desc string
---@field exe string|string[]|fun(ctx: DyTaskContext): string? The program
--- that must be on `$PATH`, or candidates in order of preference. The task
--- is not offered when none is executable.
---@field cmd fun(ctx: DyTaskContext): string[]
---@field build? fun(ctx: DyTaskContext): string[] Compile step, run first
--- as a dependency of the task
---@field root? string[]|fun(name: string, path: string): boolean Markers of
--- a project; the task only exists inside one and runs from its root
---@field filetypes? string[] The filetypes it suits, when not every
--- filetype of the language does
---@field when? fun(ctx: DyTaskContext): boolean Further condition on the file
---@field cwd? fun(ctx: DyTaskContext): string

--- `<exe> <args...> <file>`
---@param ... string
---@return fun(ctx: DyTaskContext): string[]
local function on_file(...)
  local args = { ... }
  return function(ctx)
    return vim.list_extend(vim.list_extend({ ctx.exe }, args), { ctx.file })
  end
end

--- `<exe> <args...>`
---@param ... string
---@return fun(ctx: DyTaskContext): string[]
local function exe(...)
  local args = { ... }
  return function(ctx) return vim.list_extend({ ctx.exe }, args) end
end

---@param pattern string Lua pattern the file name must match
---@return fun(ctx: DyTaskContext): boolean
local function named(pattern)
  return function(ctx) return ctx.file:match(pattern) ~= nil end
end

---@param ctx DyTaskContext
---@return string
local function in_dir(ctx) return ctx.dir end

--- The project's Gradle wrapper, or Gradle itself
---@param ctx DyTaskContext
---@return string?
local function gradle(ctx)
  local wrapper = vim.fs.joinpath(ctx.root, 'gradlew')
  if vim.fn.executable(wrapper) == 1 then return wrapper end
  if vim.fn.executable('gradle') == 1 then return 'gradle' end
end

local gradle_root = {
  'settings.gradle',
  'settings.gradle.kts',
  'build.gradle',
  'build.gradle.kts',
}

--- Build and test tasks of the JVM build tools, shared by the languages
--- running on it
---@type DyTaskRunner[]
local jvm = {
  {
    name = 'gradle build',
    desc = 'Build the Gradle project',
    exe = gradle,
    root = gradle_root,
    cmd = exe('build'),
  },
  {
    name = 'gradle test',
    desc = 'Test the Gradle project',
    exe = gradle,
    root = gradle_root,
    cmd = exe('test'),
  },
  {
    name = 'maven package',
    desc = 'Build the Maven project',
    exe = 'mvn',
    root = { 'pom.xml' },
    cmd = exe('package'),
  },
  {
    name = 'maven test',
    desc = 'Test the Maven project',
    exe = 'mvn',
    root = { 'pom.xml' },
    cmd = exe('test'),
  },
}

---@param list DyTaskRunner[]
---@return DyTaskRunner[]
local function with_jvm(list) return vim.list_extend(list, vim.deepcopy(jvm)) end

---@param name string
---@return boolean
local function dotnet_project(name)
  return name:match('%.csproj$') ~= nil or name:match('%.slnx?$') ~= nil
end

---@type table<string, DyTaskRunner[]>
return {
  -- Scripting languages: run the file
  bash = {
    {
      name = 'bash run',
      desc = 'Run bash script',
      exe = 'bash',
      -- `sh.PKGBUILD` and the like match too
      filetypes = { 'sh' },
      cmd = on_file(),
    },
    {
      name = 'bats test',
      desc = 'Run the tests of this file',
      exe = 'bats',
      filetypes = { 'bats' },
      cmd = on_file(),
    },
  },
  fish = {
    {
      name = 'fish run',
      desc = 'Run fish script',
      exe = 'fish',
      cmd = on_file(),
    },
  },
  zsh = {
    { name = 'zsh run', desc = 'Run zsh script', exe = 'zsh', cmd = on_file() },
  },
  nu = {
    {
      name = 'nu run',
      desc = 'Run nushell script',
      exe = 'nu',
      cmd = on_file(),
    },
  },
  perl = {
    {
      name = 'perl run',
      desc = 'Run perl script',
      exe = 'perl',
      cmd = on_file(),
    },
  },
  python = {
    {
      name = 'python run',
      desc = 'Run python script',
      exe = { 'python3', 'python' },
      cmd = on_file(),
    },
    {
      name = 'uv run',
      desc = 'Run python script in the environment of its project',
      exe = 'uv',
      root = { 'pyproject.toml' },
      cmd = on_file('run'),
    },
    {
      name = 'pytest',
      desc = 'Test the python project',
      exe = 'pytest',
      root = { 'pyproject.toml', 'setup.cfg', 'pytest.ini', 'tox.ini' },
      cmd = exe(),
    },
  },
  -- A model of a dbt project, named after its file: dbt compiles, runs,
  -- tests and previews it from the project's root
  sql = vim.tbl_map(function(sub)
    return {
      name = 'dbt ' .. sub[1],
      desc = sub[2],
      exe = 'dbt',
      root = { 'dbt_project.yml' },
      -- A model lives under `models/`: a macro, an analysis or a compiled
      -- copy is no model to select, and a package's own project under
      -- `dbt_packages/` is not the one to run.
      -- shortcut: only dbt's default `model-paths`, read `dbt_project.yml`
      -- once a project here moves them
      when = function(ctx)
        return vim.startswith(ctx.file, ctx.root .. '/models/')
          and not ctx.file:find('/dbt_packages/', 1, true)
      end,
      cmd = function(ctx)
        return { ctx.exe, sub[1], '--select', vim.fs.basename(ctx.stem) }
      end,
    }
  end, {
    { 'compile', 'Show the SQL this dbt model compiles to' },
    { 'run', 'Run this dbt model' },
    { 'test', 'Test this dbt model' },
    { 'show', 'Preview the first rows of this dbt model' },
  }),
  ruby = {
    {
      name = 'ruby run',
      desc = 'Run ruby script',
      exe = 'ruby',
      cmd = on_file(),
    },
  },
  lua = {
    {
      name = 'lua run',
      desc = 'Run lua script with the Neovim runtime (nvim -l)',
      exe = 'nvim',
      cmd = on_file('-l'),
    },
  },
  vim = {
    {
      name = 'vim source',
      desc = 'Source vim script in a clean headless Neovim',
      exe = 'nvim',
      cmd = function(ctx)
        return { ctx.exe, '--clean', '--headless', '-S', ctx.file, '+qa!' }
      end,
    },
  },
  php = {
    { name = 'php run', desc = 'Run php script', exe = 'php', cmd = on_file() },
  },
  javascript = {
    {
      name = 'node run',
      desc = 'Run javascript file',
      exe = { 'node', 'bun' },
      cmd = on_file(),
    },
  },
  typescript = {
    {
      name = 'typescript run',
      desc = 'Run typescript file',
      -- Node strips the types of a `.ts` file on its own since 22.18
      exe = { 'tsx', 'bun', 'node' },
      cmd = on_file(),
    },
  },
  tsx = {
    {
      name = 'typescript run',
      desc = 'Run typescript file',
      exe = { 'tsx', 'bun' },
      cmd = on_file(),
    },
  },
  julia = {
    {
      name = 'julia run',
      desc = 'Run julia script',
      exe = 'julia',
      cmd = on_file(),
    },
    {
      name = 'julia test',
      desc = 'Test the julia package',
      exe = 'julia',
      root = { 'Project.toml' },
      cmd = exe('--project=.', '-e', 'using Pkg; Pkg.test()'),
    },
  },
  r = {
    { name = 'R run', desc = 'Run R script', exe = 'Rscript', cmd = on_file() },
  },
  elixir = {
    {
      name = 'elixir run',
      desc = 'Run elixir script',
      exe = 'elixir',
      cmd = on_file(),
    },
  },
  erlang = {
    {
      name = 'erlang build and run',
      desc = 'Compile the module and call its main/0',
      exe = 'erl',
      -- `rebar.config`, `*.hrl` and `*.app.src` are `erlang` too
      when = named('%.erl$'),
      build = function(ctx) return { 'erlc', '-o', ctx.dir, ctx.file } end,
      cmd = function(ctx)
        return {
          ctx.exe,
          '-noshell',
          '-pa',
          ctx.dir,
          '-s',
          vim.fs.basename(ctx.stem),
          'main',
          '-s',
          'init',
          'stop',
        }
      end,
    },
  },
  clojure = {
    {
      name = 'clojure run',
      desc = 'Run clojure script',
      exe = 'clojure',
      cmd = on_file('-M'),
    },
  },
  haskell = {
    {
      name = 'haskell run',
      desc = 'Run haskell file',
      exe = 'runghc',
      cmd = on_file(),
    },
    {
      name = 'cabal build',
      desc = 'Build the cabal project',
      exe = 'cabal',
      root = function(name) return name:match('%.cabal$') ~= nil end,
      cmd = exe('build'),
    },
    {
      name = 'cabal test',
      desc = 'Test the cabal project',
      exe = 'cabal',
      root = function(name) return name:match('%.cabal$') ~= nil end,
      cmd = exe('test'),
    },
    {
      name = 'stack build',
      desc = 'Build the stack project',
      exe = 'stack',
      root = { 'stack.yaml' },
      cmd = exe('build'),
    },
    {
      name = 'stack test',
      desc = 'Test the stack project',
      exe = 'stack',
      root = { 'stack.yaml' },
      cmd = exe('test'),
    },
  },
  ocaml = {
    {
      name = 'ocaml run',
      desc = 'Run ocaml script',
      exe = 'ocaml',
      cmd = on_file(),
    },
    {
      name = 'dune build',
      desc = 'Build the dune project',
      exe = 'dune',
      root = { 'dune-project' },
      cmd = exe('build'),
    },
    {
      name = 'dune test',
      desc = 'Test the dune project',
      exe = 'dune',
      root = { 'dune-project' },
      cmd = exe('test'),
    },
  },
  gleam = {
    {
      name = 'gleam run',
      desc = 'Run the gleam project',
      exe = 'gleam',
      root = { 'gleam.toml' },
      cmd = exe('run'),
    },
    {
      name = 'gleam test',
      desc = 'Test the gleam project',
      exe = 'gleam',
      root = { 'gleam.toml' },
      cmd = exe('test'),
    },
  },
  dart = {
    {
      name = 'dart run',
      desc = 'Run dart file',
      exe = 'dart',
      cmd = on_file('run'),
    },
    {
      name = 'dart test',
      desc = 'Test the dart package',
      exe = 'dart',
      root = { 'pubspec.yaml' },
      cmd = exe('test'),
    },
  },
  swift = {
    {
      name = 'swift run',
      desc = 'Run swift script',
      exe = 'swift',
      cmd = on_file(),
    },
    {
      name = 'swift build',
      desc = 'Build the swift package',
      exe = 'swift',
      root = { 'Package.swift' },
      cmd = exe('build'),
    },
    {
      name = 'swift test',
      desc = 'Test the swift package',
      exe = 'swift',
      root = { 'Package.swift' },
      cmd = exe('test'),
    },
  },
  scala = {
    {
      name = 'scala run',
      desc = 'Run scala file with scala-cli',
      exe = { 'scala-cli', 'scala' },
      cmd = on_file('run'),
    },
    {
      name = 'sbt compile',
      desc = 'Build the sbt project',
      exe = 'sbt',
      root = { 'build.sbt' },
      cmd = exe('compile'),
    },
    {
      name = 'sbt test',
      desc = 'Test the sbt project',
      exe = 'sbt',
      root = { 'build.sbt' },
      cmd = exe('test'),
    },
  },
  groovy = with_jvm({
    {
      name = 'groovy run',
      desc = 'Run groovy script',
      exe = 'groovy',
      cmd = on_file(),
    },
  }),
  java = with_jvm({
    {
      name = 'java run',
      desc = 'Run java source file',
      exe = 'java',
      cmd = on_file(),
    },
  }),
  kotlin = with_jvm({
    {
      name = 'kotlin script run',
      desc = 'Run kotlin script',
      exe = 'kotlinc',
      when = named('%.kts$'),
      cmd = on_file('-script'),
    },
    {
      name = 'kotlin build and run',
      desc = 'Compile kotlin file to a jar and run it',
      exe = 'java',
      when = named('%.kt$'),
      build = function(ctx)
        return {
          'kotlinc',
          ctx.file,
          '-include-runtime',
          '-d',
          ctx.stem .. '.jar',
        }
      end,
      cmd = function(ctx) return { ctx.exe, '-jar', ctx.stem .. '.jar' } end,
    },
  }),
  c_sharp = {
    {
      name = 'dotnet run file',
      desc = 'Run C# file (.NET 10 file-based app)',
      exe = 'dotnet',
      cmd = on_file('run'),
    },
    {
      name = 'dotnet build',
      desc = 'Build the .NET project',
      exe = 'dotnet',
      root = dotnet_project,
      cmd = exe('build'),
    },
    {
      name = 'dotnet test',
      desc = 'Test the .NET project',
      exe = 'dotnet',
      root = dotnet_project,
      cmd = exe('test'),
    },
  },
  gdscript = {
    {
      name = 'godot run script',
      desc = 'Run the script (extends SceneTree) in headless Godot',
      exe = 'godot',
      cmd = on_file('--headless', '--script'),
    },
  },

  -- Compiled languages: build the file, then run it
  cpp = {
    {
      name = 'c build and run',
      desc = 'Compile C to executable and run',
      exe = { 'cc', 'gcc', 'clang' },
      filetypes = { 'c' },
      -- A `.h` is `c` too, and compiles into a precompiled header
      when = named('%.c$'),
      build = function(ctx) return { ctx.exe, ctx.file, '-o', ctx.stem } end,
      cmd = function(ctx) return { ctx.stem } end,
    },
    {
      name = 'g++ build and run',
      desc = 'Compile C++ to executable and run',
      exe = { 'g++', 'clang++' },
      filetypes = { 'cpp' },
      when = function(ctx) return not ctx.file:match('%.h[hpx+]*$') end,
      build = function(ctx) return { ctx.exe, ctx.file, '-o', ctx.stem } end,
      cmd = function(ctx) return { ctx.stem } end,
    },
  },
  rust = {
    {
      name = 'rustc build and run',
      desc = 'Compile a rust file outside a cargo project and run it',
      exe = 'rustc',
      when = function(ctx) return not vim.fs.root(ctx.file, 'Cargo.toml') end,
      -- rustc defaults to the 2015 edition
      build = function(ctx)
        return { ctx.exe, '--edition', '2024', ctx.file, '-o', ctx.stem }
      end,
      cmd = function(ctx) return { ctx.stem } end,
    },
  },
  go = {
    {
      name = 'go run',
      desc = 'Run go file',
      exe = 'go',
      when = function(ctx)
        return not ctx.file:match('_test%.go$')
          and not vim.fs.root(ctx.file, 'go.mod')
      end,
      cmd = on_file('run'),
    },
    {
      -- Inside a module, the file alone misses what the rest of its package
      -- declares
      name = 'go run package',
      desc = 'Run the package of the file',
      exe = 'go',
      root = { 'go.mod' },
      when = function(ctx) return not ctx.file:match('_test%.go$') end,
      cwd = in_dir,
      cmd = exe('run', '.'),
    },
    {
      name = 'go build',
      desc = 'Build every package of the module',
      exe = 'go',
      root = { 'go.mod' },
      cmd = exe('build', './...'),
    },
    {
      name = 'go test',
      desc = 'Test every package of the module',
      exe = 'go',
      root = { 'go.mod' },
      cmd = exe('test', './...'),
    },
  },
  gomod = {
    {
      name = 'go mod tidy',
      desc = 'Tidy the requirements of the module',
      exe = 'go',
      root = { 'go.mod' },
      cmd = exe('mod', 'tidy'),
    },
  },
  zig = {
    {
      name = 'zig run',
      desc = 'Run zig file',
      exe = 'zig',
      cmd = on_file('run'),
    },
    {
      name = 'zig build',
      desc = 'Build the zig project',
      exe = 'zig',
      root = { 'build.zig' },
      cmd = exe('build'),
    },
    {
      name = 'zig build test',
      desc = 'Test the zig project',
      exe = 'zig',
      root = { 'build.zig' },
      cmd = exe('build', 'test'),
    },
  },
  solidity = {
    {
      name = 'forge build',
      desc = 'Build the foundry project',
      exe = 'forge',
      root = { 'foundry.toml' },
      cmd = exe('build'),
    },
    {
      name = 'forge test',
      desc = 'Test the foundry project',
      exe = 'forge',
      root = { 'foundry.toml' },
      cmd = exe('test'),
    },
  },

  -- Tools
  terraform = {
    {
      name = 'terraform init',
      desc = 'Initialize the module of this file',
      exe = { 'tofu', 'terraform' },
      cwd = in_dir,
      cmd = exe('init'),
    },
    {
      name = 'terraform validate',
      desc = 'Validate the module of this file',
      exe = { 'tofu', 'terraform' },
      cwd = in_dir,
      cmd = exe('validate'),
    },
    {
      name = 'terraform plan',
      desc = 'Plan the changes of the module of this file',
      exe = { 'tofu', 'terraform' },
      cwd = in_dir,
      cmd = exe('plan'),
    },
  },
  terragrunt = {
    {
      name = 'terragrunt plan',
      desc = 'Plan the changes of this unit',
      exe = 'terragrunt',
      cwd = in_dir,
      cmd = exe('plan'),
    },
  },
  dockerfile = {
    {
      name = 'docker build',
      desc = 'Build the image of this Dockerfile, with its directory as context',
      exe = { 'docker', 'podman' },
      cmd = function(ctx) return { ctx.exe, 'build', '-f', ctx.file, ctx.dir } end,
    },
  },
  helm = {
    {
      name = 'helm lint',
      desc = 'Lint the chart',
      exe = 'helm',
      root = { 'Chart.yaml' },
      cmd = exe('lint', '.'),
    },
    {
      name = 'helm template',
      desc = 'Render the chart',
      exe = 'helm',
      root = { 'Chart.yaml' },
      cmd = exe('template', '.'),
    },
  },
  typst = {
    {
      name = 'typst compile',
      desc = 'Compile the document to PDF',
      exe = 'typst',
      cmd = on_file('compile'),
    },
  },
  latex = {
    {
      name = 'latexmk',
      desc = 'Compile the document to PDF',
      exe = 'latexmk',
      cwd = in_dir,
      cmd = on_file('-pdf', '-interaction=nonstopmode'),
    },
  },
  d2 = {
    {
      name = 'd2 render',
      desc = 'Render the diagram to SVG',
      exe = 'd2',
      cmd = function(ctx) return { ctx.exe, ctx.file, ctx.stem .. '.svg' } end,
    },
  },
  mermaid = {
    {
      name = 'mermaid render',
      desc = 'Render the diagram to SVG',
      exe = 'mmdc',
      cmd = function(ctx)
        return { ctx.exe, '-i', ctx.file, '-o', ctx.stem .. '.svg' }
      end,
    },
  },
  hurl = {
    {
      name = 'hurl run',
      desc = 'Run the requests of this file',
      exe = 'hurl',
      cmd = on_file('--test'),
    },
  },
  jsonnet = {
    {
      name = 'jsonnet eval',
      desc = 'Evaluate the file',
      exe = 'jsonnet',
      cmd = on_file(),
    },
  },
  cue = {
    {
      name = 'cue eval',
      desc = 'Evaluate the file',
      exe = 'cue',
      cmd = on_file('eval'),
    },
  },
  nix = {
    {
      name = 'nix eval',
      desc = 'Evaluate the file',
      exe = 'nix',
      when = function(ctx) return vim.fs.basename(ctx.file) ~= 'flake.nix' end,
      cmd = on_file('eval', '--file'),
    },
    {
      name = 'nix flake check',
      desc = 'Check the flake',
      exe = 'nix',
      root = { 'flake.nix' },
      cmd = exe('flake', 'check'),
    },
  },
  beancount = {
    {
      name = 'bean-check',
      desc = 'Check the ledger',
      exe = 'bean-check',
      cmd = on_file(),
    },
  },
  bicep = {
    {
      name = 'bicep build',
      desc = 'Build the file to an ARM template',
      exe = { 'bicep', 'az' },
      when = named('%.bicep$'),
      cmd = function(ctx)
        if ctx.exe == 'az' then
          return { ctx.exe, 'bicep', 'build', '--file', ctx.file }
        end
        return { ctx.exe, 'build', ctx.file }
      end,
    },
  },
  proto = {
    {
      name = 'buf lint',
      desc = 'Lint the buf module',
      exe = 'buf',
      root = { 'buf.yaml' },
      cmd = exe('lint'),
    },
    {
      name = 'buf build',
      desc = 'Build the buf module',
      exe = 'buf',
      root = { 'buf.yaml' },
      cmd = exe('build'),
    },
  },
  rego = {
    {
      name = 'opa check',
      desc = 'Check the policy',
      exe = 'opa',
      cmd = on_file('check'),
    },
    {
      name = 'opa test',
      desc = 'Test the policies of this directory',
      exe = 'opa',
      cwd = in_dir,
      cmd = exe('test', '.'),
    },
  },
  systemd = {
    {
      name = 'systemd-analyze verify',
      desc = 'Verify the unit file',
      exe = 'systemd-analyze',
      -- A drop-in (`foo.service.d/override.conf`) is no unit of its own
      when = function(ctx) return not ctx.file:match('%.conf$') end,
      cmd = on_file('verify'),
    },
  },
}
