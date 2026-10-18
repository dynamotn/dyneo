local h = require('helpers')

--- A stand-in for a lualine component, marking its highlights in the text
local function component()
  return {
    create_hl = function(_, _, name) return name end,
    format_hl = function(_, name) return '<' .. name .. '>' end,
    get_default_hl = function() return '</>' end,
  }
end

describe('util.lualine', function()
  local lualine, dir, cleanup, root, cwd, restores

  before_each(function()
    dir, cleanup = h.tmpdir()
    root, cwd = dir, dir
    restores = {
      h.stub(_G, 'Snacks', {
        util = { color = function(name) return '#' .. name end },
      }),
      h.stub(package.loaded, 'util.root', {
        get = function() return root end,
        cwd = function() return cwd end,
      }),
      h.stub(package.loaded, 'lualine.utils.utils', {
        extract_highlight_colors = function() return nil end,
      }),
    }
    h.unload('util.lualine')
    lualine = require('util.lualine')
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.cmd('silent! %bwipeout!')
    cleanup()
  end)

  describe('status', function()
    it('shows its icon while the status says something', function()
      local state
      local status = lualine.status('X', function() return state end)
      assert.are.equal('X', status[1]())
      assert.is_false(status.cond())
      state = 'pending'
      assert.is_true(status.cond())
      assert.are.same({ fg = '#DiagnosticWarn' }, status.color())
      state = 'ok'
      assert.are.same({ fg = '#Special' }, status.color())
    end)
  end)

  describe('format', function()
    it(
      'escapes % for the status line',
      function() assert.are.equal('50%%', lualine.format(component(), '50%')) end
    )

    it(
      'wraps the text in the highlight it is given',
      function()
        assert.are.equal(
          '<DyNeo_Bold>name</>',
          lualine.format(component(), 'name', 'Bold')
        )
      end
    )
  end)

  describe('pretty_path', function()
    local function path_of(file, opts)
      h.write(dir .. '/' .. file, { '' })
      vim.cmd.edit(dir .. '/' .. file)
      return lualine.pretty_path(opts)(component())
    end

    it(
      'shows the path below the working directory',
      function()
        assert.are.equal('src/<DyNeo_Bold>main.lua</>', path_of('src/main.lua'))
      end
    )

    it(
      'cuts a long path to its last parts',
      function()
        assert.are.equal('a/…/c/<DyNeo_Bold>d.lua</>', path_of('a/b/c/d.lua'))
      end
    )

    it(
      'keeps the whole path with a length of 0',
      function()
        assert.are.equal(
          'a/b/c/<DyNeo_Bold>d.lua</>',
          path_of('a/b/c/d.lua', { length = 0 })
        )
      end
    )

    it(
      'colours the directory when asked to',
      function()
        assert.are.equal(
          '<DyNeo_Comment>src/</><DyNeo_Bold>main.lua</>',
          path_of('src/main.lua', { directory_hl = 'Comment' })
        )
      end
    )

    it('does not take a sibling directory for the root', function()
      root, cwd = dir .. '/proj', dir .. '/proj'
      vim.fn.mkdir(root, 'p')
      local path = path_of('proj-other/a.lua', { length = 0 })
      assert.is_truthy(path:find('proj-other/', 1, true), path)
    end)

    it('marks a modified buffer', function()
      h.write(dir .. '/x.lua', { '' })
      vim.cmd.edit(dir .. '/x.lua')
      vim.bo.modified = true
      assert.are.equal(
        '<DyNeo_MatchParen>x.lua+</>',
        lualine.pretty_path({ modified_sign = '+' })(component())
      )
      vim.bo.modified = false
    end)

    it('resolves a path outside the root once, not on every redraw', function()
      root, cwd = dir .. '/proj', dir .. '/proj'
      vim.fn.mkdir(root, 'p')
      h.write(dir .. '/elsewhere/a.lua', { '' })
      vim.cmd.edit(dir .. '/elsewhere/a.lua')
      local calls = 0
      local realpath = vim.uv.fs_realpath
      table.insert(
        restores,
        h.stub(vim.uv, 'fs_realpath', function(...)
          calls = calls + 1
          return realpath(...)
        end)
      )
      local pretty = lualine.pretty_path()
      local first = pretty(component())
      assert.are.equal(first, pretty(component()))
      assert.are.equal(1, calls)
      -- A new root is a new question
      root, cwd = dir .. '/other', dir .. '/other'
      pretty(component())
      assert.are.equal(2, calls)
    end)

    it('shows a symlink into the project by its name under the root', function()
      root, cwd = dir .. '/proj', dir .. '/proj'
      h.write(root .. '/src/real.lua', { '' })
      vim.fn.mkdir(dir .. '/home', 'p')
      assert(
        vim.uv.fs_symlink(root .. '/src/real.lua', dir .. '/home/link.lua')
      )
      vim.cmd.edit(dir .. '/home/link.lua')
      assert.are.equal(
        'src/<DyNeo_Bold>real.lua</>',
        lualine.pretty_path()(component())
      )
    end)

    it('compares paths case-folded on Windows', function()
      table.insert(
        restores,
        h.stub(
          vim.fn,
          'has',
          function(what) return what == 'win32' and 1 or 0 end
        )
      )
      root, cwd = dir:upper(), dir:upper()
      assert.are.equal('src/<DyNeo_Bold>main.lua</>', path_of('src/main.lua'))
    end)

    it('starts the cache over once it is full', function()
      lualine.PATH_CACHE_SIZE = 1
      assert.are.equal('<DyNeo_Bold>a.lua</>', path_of('a.lua'))
      assert.are.equal('<DyNeo_Bold>b.lua</>', path_of('b.lua'))
      assert.are.equal('<DyNeo_Bold>a.lua</>', path_of('a.lua'))
    end)

    it('marks a read-only buffer', function()
      h.write(dir .. '/ro.lua', { '' })
      vim.cmd.edit(dir .. '/ro.lua')
      vim.bo.readonly = true
      assert.are.equal(
        '<DyNeo_Bold>ro.lua</><DyNeo_MatchParen>RO</>',
        lualine.pretty_path({ readonly_icon = 'RO' })(component())
      )
      vim.bo.readonly = false
    end)

    it('is empty for a buffer with no file', function()
      vim.cmd.enew()
      assert.are.equal('', lualine.pretty_path()(component()))
    end)
  end)

  describe('root_dir', function()
    it(
      'stays hidden while the root is the working directory',
      function() assert.is_false(lualine.root_dir().cond()) end
    )

    it('names a root below the working directory', function()
      root = dir .. '/project'
      local part = lualine.root_dir({ icon = 'R' })
      assert.is_true(part.cond())
      assert.are.equal('R project', part[1]())
    end)

    it('names a root elsewhere, unless told not to', function()
      cwd = dir .. '/work'
      root = dir .. '/project'
      assert.are.equal('R project', lualine.root_dir({ icon = 'R' })[1]())
      assert.is_false(lualine.root_dir({ other = false }).cond())
    end)

    it('can leave a parent root out', function()
      cwd = dir .. '/project/sub'
      root = dir .. '/project'
      assert.is_false(lualine.root_dir({ parent = false }).cond())
    end)
  end)
end)
