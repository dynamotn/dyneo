local h = require('helpers')

local registry_dir = vim.fs.joinpath(h.root, 'lua', 'tools', 'mason-registry')

--- Package files of the registry, by name
---@return string[]
local function package_names()
  local names = {}
  for name, kind in vim.fs.dir(registry_dir) do
    if kind == 'file' and name:match('%.lua$') and name ~= 'init.lua' then
      table.insert(names, (name:gsub('%.lua$', '')))
    end
  end
  table.sort(names)
  return names
end

describe('tools.mason-registry', function()
  it('indexes every package file by its name', function()
    -- Wherever the config directory is, the index is of this tree
    local restore = h.stub(vim.fn, 'stdpath', function(what)
      if what == 'config' then return vim.fn.tempname() end
      return vim.call('stdpath', what)
    end)
    h.unload('tools.mason-registry')
    local ok, index = pcall(require, 'tools.mason-registry')
    restore()
    h.unload('tools.mason-registry')
    assert.is_true(ok, index)

    local expected = {}
    for _, name in ipairs(package_names()) do
      expected[name] = 'tools.mason-registry.' .. name
    end
    assert.are.same(expected, index)
    assert.is_nil(index.init)
  end)

  it('finds some packages', function() assert.is_true(#package_names() > 0) end)

  local categories = {
    Compiler = true,
    DAP = true,
    Formatter = true,
    Linter = true,
    LSP = true,
    Runtime = true,
  }
  local targets = {
    darwin_arm64 = true,
    darwin_x64 = true,
    linux_arm64 = true,
    linux_x64 = true,
    linux_x64_gnu = true,
    linux_x64_musl = true,
    win_x64 = true,
    win_arm64 = true,
  }

  for _, name in ipairs(package_names()) do
    describe(name, function()
      local spec
      before_each(function()
        h.unload('tools.mason-registry.' .. name)
        spec = require('tools.mason-registry.' .. name)
      end)

      it(
        'is named after its file',
        function() assert.are.equal(name, spec.name) end
      )

      it('has a description, homepage and licenses', function()
        assert.are.equal('string', type(spec.description))
        assert.is_true(#spec.description > 0)
        assert.is_truthy(spec.homepage:match('^https://'))
        assert.is_true(vim.islist(spec.licenses) and #spec.licenses > 0)
      end)

      it('lists known categories and languages', function()
        assert.is_true(vim.islist(spec.languages))
        assert.is_true(#spec.categories > 0)
        for _, category in ipairs(spec.categories) do
          assert.is_true(categories[category] or false, category)
        end
      end)

      it(
        'has a versioned package URL, or names a dytoy tool',
        function()
          assert.is_truthy(
            spec.source.id:match('^pkg:[%w]+/[^@]+@.+$')
              or spec.source.id:match('^dytoy:[^/@]+$'),
            spec.source.id
          )
        end
      )

      it('names its binaries at the top level', function()
        assert.are.equal('table', type(spec.bin))
        assert.is_true(vim.tbl_count(spec.bin) > 0)
        for bin, target in pairs(spec.bin) do
          assert.are.equal('string', type(bin))
          assert.are.equal('string', type(target))
        end
      end)

      it('has one asset per known target, when it lists several', function()
        local asset = spec.source.asset
        if asset == nil or not vim.islist(asset) then return end
        local seen = {}
        for _, entry in ipairs(asset) do
          assert.is_true(targets[entry.target] or false, entry.target)
          assert.is_nil(seen[entry.target], 'duplicate ' .. entry.target)
          seen[entry.target] = true
          assert.are.equal('string', type(entry.file))
        end
      end)

      it('points at a language server config that exists', function()
        local lspconfig = vim.tbl_get(spec, 'neovim', 'lspconfig')
        if not lspconfig then return end
        -- Under `after/` when it overrides what nvim-lspconfig ships
        assert.is_truthy(
          vim.uv.fs_stat(vim.fs.joinpath(h.root, 'lsp', lspconfig .. '.lua'))
            or vim.uv.fs_stat(
              vim.fs.joinpath(h.root, 'after', 'lsp', lspconfig .. '.lua')
            ),
          'lsp/' .. lspconfig .. '.lua'
        )
      end)
    end)
  end

  it('derives the sonarlint asset from the tagged release', function()
    local spec = require('tools.mason-registry.sonarlint-language-server')
    local version = spec.source.id:match('@(.+)$')
    local release = version:match('^[^+]+')
    assert.are.equal(
      'sonarlint-vscode-' .. release .. '.vsix',
      spec.source.asset.file
    )
    assert.is_nil(spec.source.asset.file:find('+', 1, true))
  end)
end)
