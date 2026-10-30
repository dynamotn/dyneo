local h = require('helpers')

describe('util.cmp', function()
  local cmp

  before_each(function()
    h.unload('util.cmp')
    cmp = require('util.cmp')
  end)

  local common = {
    'lsp',
    'path',
    'project_path',
    'fuzzy_path',
    'snippets',
    'buffer',
    'calc',
    'emoji',
    'dynamic',
    'dictionary',
    -- They say themselves whether their server or socket is there
    'tmux',
    'zellij',
    'kitty',
  }

  describe('actions', function()
    after_each(function()
      vim.snippet.stop()
      vim.cmd('silent! %bwipeout!')
    end)

    it('jumps to the next tabstop of an active snippet', function()
      vim.api.nvim_set_current_buf(h.buffer({ lines = { '' } }))
      vim.snippet.expand('${1:first} ${2:second}')
      assert.is_false(vim.snippet.active({ direction = -1 }))
      assert.is_true(cmp.actions.snippet_forward())
      vim.wait(
        100,
        function() return vim.snippet.active({ direction = -1 }) end
      )
      -- On the second tabstop now, with the first behind it
      assert.is_true(vim.snippet.active({ direction = -1 }))
      cmp.actions.snippet_stop()
      assert.is_false(vim.snippet.active())
    end)

    it('does nothing without a snippet', function()
      assert.is_nil(cmp.actions.snippet_forward())
      cmp.actions.snippet_stop()
    end)
  end)

  describe('sources', function()
    it(
      'gives the common sources for *',
      function() assert.same(common, cmp.sources('*')) end
    )

    it(
      'gives the comment sources',
      function()
        assert.same(
          { 'buffer', 'dictionary', 'emoji', 'nerdfont', 'dynamic' },
          cmp.sources('comment')
        )
      end
    )

    it(
      'gives the dap sources',
      function() assert.same({ 'dap', 'buffer' }, cmp.sources('dap')) end
    )

    for _, ft in ipairs({ 'gitcommit', 'gitrebase', 'octo' }) do
      it('gives git sources for ' .. ft, function()
        local sources = cmp.sources(ft)
        assert.equals('git', sources[1])
        assert.is_false(vim.list_contains(sources, 'path'))
      end)
    end

    for ft, unique in pairs({
      markdown = { 'nerdfont' },
      typst = { 'nerdfont' },
      blade = { 'blade-nav', 'laravel' },
      clojure = { 'conjure' },
      fish = { 'fish' },
      julia = { 'latex_symbols' },
      sql = { 'dadbod', 'sql' },
      lua = { 'lazydev' },
    }) do
      it(
        'puts the own sources of ' .. ft .. ' first',
        function()
          assert.same(
            vim.list_extend(vim.deepcopy(unique), common),
            cmp.sources(ft)
          )
        end
      )
    end

    it(
      'gives nothing for a filetype it does not know',
      function() assert.is_nil(cmp.sources('rust')) end
    )
  end)

  it('leaves the pane sources to say whether their server is there', function()
    local sources = cmp.sources('*')
    for _, source in ipairs({ 'tmux', 'zellij', 'kitty' }) do
      assert.is_true(vim.list_contains(sources, source), source)
    end
  end)

  describe('setup_default_sources', function()
    local restore
    after_each(function() restore() end)

    it('gives comment sources inside a comment node', function()
      restore = h.stub(vim.treesitter, 'get_node', function()
        return {
          type = function() return 'line_comment' end,
          parent = function() end,
        }
      end)
      assert.same(cmp.sources('comment'), cmp.setup_default_sources())
    end)

    it('gives comment sources at the end of a Lua comment', function()
      -- The tree of `x = 1 -- hello` as Lua's parser gives it: the cursor
      -- past the `o` just typed is past the comment, in the chunk
      local comment = {
        type = function() return 'comment' end,
        parent = function() end,
      }
      local content = {
        type = function() return 'comment_content' end,
        parent = function() return comment end,
      }
      local chunk = {
        type = function() return 'chunk' end,
        parent = function() end,
      }
      restore = h.stub(vim.treesitter, 'get_node', function(opts)
        local col = opts and opts.pos and opts.pos[2] or 14
        return col >= 14 and chunk or content
      end)
      local restore_cursor = h.stub(
        vim.api,
        'nvim_win_get_cursor',
        function() return { 1, 14 } end
      )
      local sources = cmp.setup_default_sources()
      restore_cursor()
      assert.same(cmp.sources('comment'), sources)
    end)

    it('gives common sources elsewhere', function()
      restore = h.stub(vim.treesitter, 'get_node', function()
        return {
          type = function() return 'identifier' end,
          parent = function() end,
        }
      end)
      assert.same(common, cmp.setup_default_sources())
    end)

    it('gives common sources when there is no parser', function()
      restore = h.stub(
        vim.treesitter,
        'get_node',
        function() error('no parser') end
      )
      assert.same(common, cmp.setup_default_sources())
    end)
  end)
end)

describe('util.cmp on the command line', function()
  local cmp, restore, cmdtype, path_completion, asked

  before_each(function()
    cmdtype, path_completion, asked = ':', false, nil
    restore = {
      h.stub(vim.fn, 'getcmdtype', function() return cmdtype end),
      h.stub(vim.fn, 'getcmdline', function() return 'e lua/' end),
    }
    -- blink's own cmdline helpers, which decide when its `cmdline` source
    -- completes a path
    package.loaded['blink.cmp.sources.cmdline.utils'] = {
      get_completion_type = function(mode)
        asked = mode
        return path_completion and 'file' or 'command'
      end,
      is_path_completion = function(completion_type, line)
        return completion_type == 'file' and line == 'e lua/'
      end,
    }
    h.unload('util.cmp')
    cmp = require('util.cmp')
  end)

  after_each(function()
    for i = #restore, 1, -1 do
      restore[i]()
    end
    h.unload('blink.cmp.sources.cmdline.utils')
  end)

  describe('cmdline_sources', function()
    it(
      'keeps `path` while `cmdline` completes no path',
      function()
        assert.same(
          { 'cmdline', 'fuzzy_path', 'path', 'buffer' },
          cmp.cmdline_sources()
        )
      end
    )

    it('drops `path` where `cmdline` lists the directory itself', function()
      path_completion = true
      assert.same({ 'cmdline', 'fuzzy_path', 'buffer' }, cmp.cmdline_sources())
      assert.equals('cmdline', asked)
    end)

    it('completes a search from the buffers alone', function()
      cmdtype = '/'
      assert.same({ 'buffer' }, cmp.cmdline_sources())
      cmdtype = '?'
      assert.same({ 'buffer' }, cmp.cmdline_sources())
    end)

    it('completes nothing on other command lines', function()
      cmdtype = '='
      assert.same({}, cmp.cmdline_sources())
    end)

    it('keeps `path` when blink cannot say', function()
      path_completion = true
      package.loaded['blink.cmp.sources.cmdline.utils'] = nil
      local searchers = package.loaders or package.searchers
      table.insert(searchers, 1, function(name)
        if name == 'blink.cmp.sources.cmdline.utils' then
          return function() error('not here') end
        end
      end)
      local ok, result = pcall(cmp.cmdline_sources)
      table.remove(searchers, 1)
      assert.is_true(ok)
      assert.same({ 'cmdline', 'fuzzy_path', 'path', 'buffer' }, result)
    end)
  end)
end)
