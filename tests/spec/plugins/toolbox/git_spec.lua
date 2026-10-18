local h = require('helpers')

describe('plugins.toolbox.git', function()
  local restores, executables

  --- The specs the file returns, keyed by plugin name, with the forge CLIs
  --- named in `executables` on `$PATH`
  ---@param ... string
  ---@return table<string, table>
  local function load(...)
    executables = { ... }
    local found = {}
    for _, spec in ipairs(dofile(h.root .. '/lua/plugins/toolbox/git.lua')) do
      if type(spec[1]) == 'string' then
        found[spec[1]] = spec
      elseif spec.name then
        found[spec.name] = spec
      else
        -- The specs only there with their CLI
        for _, nested in ipairs(spec) do
          found[nested[1]] = nested
        end
      end
    end
    return found
  end

  before_each(function()
    h.globals()
    restores = {
      h.stub(
        vim.fn,
        'executable',
        function(name) return vim.list_contains(executables, name) and 1 or 0 end
      ),
    }
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    pcall(vim.api.nvim_del_augroup_by_name, 'octo_exit_pre')
    vim.cmd('silent! %bwipeout!')
  end)

  it('reviews the forges whose CLI is there', function()
    local specs = load()
    assert.is_nil(specs['pwntester/octo.nvim'])
    assert.is_nil(specs['harrisoncramer/gitlab.nvim'])
    specs = load('gh', 'glab')
    assert.are.equal('Octo', specs['pwntester/octo.nvim'].cmd)
    assert.is_true(
      vim.list_contains(
        specs['nvim-treesitter/nvim-treesitter'].opts.ensure_installed,
        'gitcommit'
      )
    )
    assert.are.equal(
      '<leader>pl',
      specs['harrisoncramer/gitlab.nvim'].keys[1][1]
    )
  end)

  it('completes issues and commits through the git source', function()
    local specs = load()
    specs['petertriho/cmp-git'].init()
    assert.are.equal('「GIT」', DyNeo.completion_sources.git)
    assert.is_true(
      vim.list_contains(specs['petertriho/cmp-git'].opts.filetypes, 'gitrebase')
    )
    assert.same(
      require('util.cmp').sources('octo'),
      specs['blink.cmp'].opts.sources.per_filetype.octo
    )
  end)

  describe('gitsigns', function()
    local toggle, mapped, calls, gitsigns, opts

    before_each(function()
      calls = {}
      gitsigns = setmetatable({}, {
        __index = function(_, name)
          return function(...) table.insert(calls, { name, ... }) end
        end,
      })
      table.insert(
        restores,
        h.stub(_G, 'Snacks', {
          toggle = function(spec)
            toggle = spec
            return {
              map = function(_, lhs) mapped = lhs end,
            }
          end,
        })
      )
      table.insert(restores, h.stub(package.loaded, 'gitsigns', gitsigns))
      table.insert(
        restores,
        h.stub(package.loaded, 'gitsigns.config', {
          config = { signcolumn = 'signs on' },
        })
      )
      opts = load()['lewis6991/gitsigns.nvim'].opts()
    end)

    it('toggles the signs from the ui group', function()
      assert.are.equal('<leader>uG', mapped)
      assert.are.equal('signs on', toggle.get())
      toggle.set(false)
      assert.same({ { 'toggle_signs', false } }, calls)
    end)

    it('maps the hunk keys to the buffer it attaches to', function()
      local bufnr = h.buffer({})
      vim.api.nvim_set_current_buf(bufnr)
      opts.on_attach(bufnr)
      local other = h.buffer({})
      vim.api.nvim_set_current_buf(other)
      assert.same({}, vim.fn.maparg(']h', 'n', false, true))
      vim.api.nvim_set_current_buf(bufnr)

      --- Run the `mode` mapping of `lhs`
      local function press(lhs, mode)
        local map = vim.fn.maparg(lhs, mode or 'n', false, true)
        assert.are.equal(1, map.buffer, lhs)
        if map.callback then
          map.callback()
        else
          return map.rhs
        end
      end

      vim.wo.diff = false
      press(']h')
      press('[h')
      press(']H')
      press('[H')
      assert.same({
        { 'nav_hunk', 'next' },
        { 'nav_hunk', 'prev' },
        { 'nav_hunk', 'last' },
        { 'nav_hunk', 'first' },
      }, calls)

      calls = {}
      press('<leader>ghb')
      press('<leader>ghB')
      press('<leader>ghD')
      press('<leader>ghq')
      press('<leader>ghS')
      assert.same({
        { 'blame_line', { full = true } },
        { 'blame' },
        { 'diffthis', '~' },
        { 'setqflist', 'all' },
        { 'stage_buffer' },
      }, calls)
      assert.are.equal(':Gitsigns stage_hunk<CR>', press('<leader>ghs', 'x'))
      assert.are.equal(':<C-U>Gitsigns select_hunk<CR>', press('ih', 'o'))
    end)

    it('moves between changes with diff mode when diffing', function()
      local normal = {}
      table.insert(
        restores,
        h.stub(vim.cmd, 'normal', function(arg) table.insert(normal, arg) end)
      )
      local bufnr = h.buffer({})
      vim.api.nvim_set_current_buf(bufnr)
      opts.on_attach(bufnr)
      vim.wo.diff = true
      vim.fn.maparg(']h', 'n', false, true).callback()
      vim.fn.maparg('[h', 'n', false, true).callback()
      vim.wo.diff = false
      assert.same({ { ']c', bang = true }, { '[c', bang = true } }, normal)
      assert.same({}, calls)
    end)
  end)

  describe('ci.nvim', function()
    local forge, sync_result, sync_cmd, hosts

    before_each(function()
      hosts = {}
      forge = {
        host = function() return 'fallback.example' end,
        host_of = function(url) return hosts[url] end,
      }
      table.insert(restores, h.stub(package.loaded, 'ci.forge', forge))
      table.insert(
        restores,
        h.stub(require('util.system'), 'sync', function(cmd, opts)
          sync_cmd = { cmd = cmd, opts = opts }
          return sync_result
        end)
      )
      load()['ci.nvim'].config()
    end)

    it('asks the GitHub remote before origin', function()
      hosts['git@github.com:me/x.git'] = 'github.com'
      hosts['git@gitlab.com:me/x.git'] = 'gitlab.com'
      sync_result = {
        code = 0,
        stdout = 'remote.origin.url git@gitlab.com:me/x.git\n'
          .. 'remote.gh.url git@github.com:me/x.git\n',
      }
      assert.are.equal('github.com', forge.host())
      assert.are.equal('git', sync_cmd.cmd[1])
      assert.are.equal(2000, sync_cmd.opts.timeout)

      sync_result.stdout = 'remote.origin.url git@gitlab.com:me/x.git\n'
      assert.are.equal('gitlab.com', forge.host())
    end)

    it("falls back to the plugin's own choice", function()
      sync_result = { code = 0, stdout = 'remote.fork.url x\n' }
      assert.are.equal('fallback.example', forge.host())
      -- A remote with a URL the plugin cannot place
      sync_result = { code = 0, stdout = 'remote.origin.url x\n' }
      assert.are.equal('fallback.example', forge.host())
      -- git did not answer
      sync_result = { code = 1 }
      assert.are.equal('fallback.example', forge.host())
    end)
  end)

  describe('octo', function()
    it('keeps its windows for the session on exit', function()
      local spec = load('gh')['pwntester/octo.nvim']
      local opts = spec.opts()
      assert.same({ 'upstream', 'gh', 'github', 'origin' }, opts.default_remote)
      assert.are.equal('snacks', opts.picker)
      assert.are.equal('markdown', vim.treesitter.language.get_lang('octo'))

      local octo = h.buffer({ filetype = 'octo' })
      vim.bo[octo].buftype = 'nofile'
      local other = h.buffer({ filetype = 'lua' })
      vim.bo[other].buftype = 'nofile'
      vim.api.nvim_set_current_buf(octo)
      vim.cmd.split()
      vim.api.nvim_set_current_buf(other)
      local autocmds = vim.api.nvim_get_autocmds({ group = 'octo_exit_pre' })
      assert.are.equal(1, #autocmds)
      autocmds[1].callback()
      assert.are.equal('', vim.bo[octo].buftype)
      assert.are.equal('nofile', vim.bo[other].buftype)
      vim.cmd.only()
    end)
  end)

  describe('gitlab.nvim', function()
    local spec, called

    before_each(function()
      called = {}
      table.insert(
        restores,
        h.stub(
          package.loaded,
          'gitlab',
          setmetatable({}, {
            __index = function(_, name)
              return function(...) table.insert(called, name) end
            end,
          })
        )
      )
      spec = load('glab')['harrisoncramer/gitlab.nvim']
    end)

    it('takes its token from glab for the origin remote', function()
      local asked
      table.insert(
        restores,
        h.stub(package.loaded, 'gitlab.state', {
          default_auth_provider = function() return 'plugin', 'default' end,
        })
      )
      table.insert(
        restores,
        h.stub(require('util.gitlab_auth'), 'auth', function(fallback, remote)
          asked = { fallback = { fallback() }, remote = remote }
          return 'token', 'https://gitlab.example'
        end)
      )
      local opts = spec.opts()
      assert.are.equal('origin', opts.connection_settings.remote)
      assert.is_true(opts.keymaps.global.disable_all)
      assert.same(
        { 'token', 'https://gitlab.example' },
        { opts.auth_provider() }
      )
      assert.same(
        { fallback = { 'plugin', 'default' }, remote = 'origin' },
        asked
      )
    end)

    it('builds its server and maps every review action', function()
      local built
      table.insert(
        restores,
        h.stub(package.loaded, 'gitlab.server', {
          build = function(force) built = force end,
        })
      )
      spec.build()
      assert.is_true(built)
      for _, key in ipairs(spec.keys) do
        if type(key[2]) == 'function' then key[2]() end
      end
      assert.are.equal(#spec.keys - 1, #called)
      assert.is_true(vim.list_contains(called, 'choose_merge_request'))
      assert.is_true(vim.list_contains(called, 'merge'))
      assert.is_true(vim.list_contains(called, 'copy_mr_url'))
    end)
  end)
end)
