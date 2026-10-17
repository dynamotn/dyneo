local h = require('helpers')

describe('plugin/spell', function()
  local dir, cleanup, restores, commands, messages, executed
  local restore_cmd, record_cmd
  before_each(function()
    h.globals()
    dir, cleanup = h.tmpdir()
    -- `spell/` ships with the repository, the word lists need not
    vim.fn.mkdir(dir .. '/spell', 'p')
    commands, messages, executed = {}, {}, {}
    DyNeo.dictionaries_path = dir .. '/dictionaries'
    local stdpath = vim.fn.stdpath
    restores = {
      -- Point the word lists at a scratch copy, never at the real `spell/`
      h.stub(vim.fn, 'stdpath', function(what)
        if what == 'config' then return dir end
        return stdpath(what)
      end),
      h.stub(
        vim,
        'notify',
        function(msg, level) table.insert(messages, { msg, level }) end
      ),
      h.stub(vim.lsp, 'get_clients', function(filter)
        assert.are.equal('harper_ls', filter.name)
        return {
          {
            exec_cmd = function(_, cmd) table.insert(executed, cmd) end,
          },
        }
      end),
    }
    vim.g.mapleader = ' '
    dofile(h.root .. '/plugin/spell.lua')
    -- Loaded first, so the module keeps the real `vim.cmd`; only `mkspell`
    -- is recorded from here on
    restore_cmd = vim.cmd
    record_cmd = function(cmd) table.insert(commands, cmd) end
    table.insert(restores, h.stub(vim, 'cmd', record_cmd))
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    cleanup()
  end)

  describe(':DySpell', function()
    it('completes the spell file names that match', function()
      local complete = vim.api.nvim_get_commands({}).DySpell.complete_arg
      assert.is_nil(complete) -- a Lua function, not a builtin completion
      local names = vim.fn.getcompletion('DySpell ', 'cmdline')
      assert.are.same({ 'proper', 'technical', 'vi', 'zh' }, names)
      assert.are.same(
        { 'proper' },
        vim.fn.getcompletion('DySpell p', 'cmdline')
      )
    end)

    it('builds the spell file from its word list', function()
      vim.api.nvim_cmd({ cmd = 'DySpell', args = { 'technical' } }, {})
      assert.are.same({
        'mkspell! '
          .. vim.fn.fnameescape(dir .. '/spell/technical')
          .. ' '
          .. dir
          .. '/spell/technical.txt',
      }, commands)
    end)

    it('builds the Vietnamese one from the dictionaries folder', function()
      vim.api.nvim_cmd({ cmd = 'DySpell', args = { 'vi' } }, {})
      assert.truthy(
        commands[1]:find(dir .. '/dictionaries/vietnamese.txt', 1, true)
      )
    end)

    it('reports an unknown name instead of failing', function()
      vim.api.nvim_cmd({ cmd = 'DySpell', args = { 'klingon' } }, {})
      assert.are.same({}, commands)
      assert.are.same(
        { { "[spell] invalid spell file 'klingon'", vim.log.levels.ERROR } },
        messages
      )
    end)
  end)

  describe('add word mappings', function()
    local function add(key, line)
      local bufnr = h.buffer({ lines = { line } })
      vim.api.nvim_set_current_buf(bufnr)
      vim.fn.maparg(' z' .. key, 'n', false, true).callback()
    end

    it('adds the word under the cursor and rebuilds', function()
      add('t', 'Neovim')
      assert.are.same(
        { 'Neovim' },
        vim.fn.readfile(dir .. '/spell/technical.txt')
      )
      assert.are.equal(1, #commands)
      assert.truthy(commands[1]:match('^silent mkspell!'))
      assert.are.equal("[spell] added 'Neovim' to technical", messages[1][1])
    end)

    it('hands the word to every running Harper', function()
      add('p', 'Dynamo')
      assert.are.equal(1, #executed)
      assert.are.equal('HarperAddToUserDict', executed[1].command)
      assert.are.equal('Dynamo', executed[1].arguments[1])
    end)

    it('does not add a word twice', function()
      h.write(dir .. '/spell/proper.txt', { 'Dynamo' })
      add('p', 'Dynamo')
      assert.are.same({ 'Dynamo' }, vim.fn.readfile(dir .. '/spell/proper.txt'))
      assert.are.same({}, commands)
      assert.are.equal("[spell] 'Dynamo' is already in proper", messages[1][1])
    end)

    it('reads and writes a list whose path needs escaping', function()
      -- `stdpath('config')` with a space, `#` and `%` in it
      local config = dir .. '/my config #1 %'
      vim.fn.mkdir(config .. '/spell', 'p')
      h.write(config .. '/spell/proper.txt', { 'Dynamo' })
      restores[1]()
      local stdpath = vim.fn.stdpath
      restores[1] = h.stub(vim.fn, 'stdpath', function(what)
        if what == 'config' then return config end
        return stdpath(what)
      end)
      vim.cmd = restore_cmd
      dofile(h.root .. '/plugin/spell.lua')
      vim.cmd = record_cmd

      add('p', 'Dynamo')
      assert.are.equal("[spell] 'Dynamo' is already in proper", messages[1][1])
      add('t', 'Neovim')
      assert.are.same(
        { 'Neovim' },
        vim.fn.readfile(config .. '/spell/technical.txt')
      )
      assert.are.equal(1, #commands)
      assert.truthy(
        commands[1]:find(
          vim.fn.fnameescape(config) .. '/spell/technical.txt',
          1,
          true
        )
      )
    end)

    it('refuses an empty word', function()
      add('t', '')
      assert.is_nil(vim.uv.fs_stat(dir .. '/spell/technical.txt'))
      assert.are.equal(vim.log.levels.WARN, messages[1][2])
    end)
  end)
end)
