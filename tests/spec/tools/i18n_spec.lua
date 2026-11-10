local h = require('helpers')

describe('tools.i18n', function()
  local i18n, root, cleanup, notes, restores

  before_each(function()
    h.unload('tools.i18n')
    i18n = require('tools.i18n')
    root, cleanup = h.tmpdir()
    notes = {}
    restores = {
      h.stub(vim, 'notify', function(msg, level, opts)
        if (opts or {}).title == 'DyNeo I18n' then
          table.insert(notes, { msg = msg, level = level })
        end
      end),
    }
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.fn.setqflist({})
    vim.cmd('silent! cclose')
    cleanup()
  end)

  --- Put `path` in $PATH until the test ends; `h.stub` cannot restore
  --- `vim.env`, which only proxies the environment
  local function set_path(path)
    local saved = vim.env.PATH
    vim.env.PATH = path
    table.insert(restores, function() vim.env.PATH = saved end)
  end

  local function write(rel, text)
    h.write(vim.fs.joinpath(root, rel), vim.split(text, '\n'))
  end

  --- The index of `root`, waited for
  local function index()
    local got
    i18n.index(root, function(idx) got = idx end)
    assert.is_true(vim.wait(5000, function() return got ~= nil end))
    return got
  end

  describe('discovery', function()
    local cases = {
      { 'locales/en/common.json', 'locales/fr/common.json' },
      { 'locales/en.json', 'locales/fr.json' },
      { 'public/locales/en/translation.json', 'public/locales/fr/x.json' },
      { 'src/i18n/en.json', 'src/i18n/fr.json' },
      { 'messages/en.json', 'messages/fr.json' },
    }
    for _, files in ipairs(cases) do
      it('reads ' .. files[1], function()
        write(files[1], '{ "home": { "title": "Home" } }')
        write(files[2], '{ "home": { "title": "Accueil" } }')
        local idx = index()
        assert.same({ 'en', 'fr' }, idx.langs)
        assert.equals('en', idx.default)
        assert.equals('Home', idx.values.en['home.title'].value)
        assert.equals('Accueil', idx.values.fr['home.title'].value)
        assert.same({ 'home', 'title' }, idx.values.en['home.title'].path)
      end)
    end

    it('leaves out a file whose name is not a locale', function()
      write('locales/en.json', '{ "a": "A" }')
      write('locales/index.json', '{ "b": "B" }')
      assert.same({ 'en' }, index().langs)
    end)

    it('reads Rails and Symfony YAML through yq', function()
      local bin = vim.fs.joinpath(root, 'bin')
      -- The fake yq prints the JSON kept next to each YAML file
      h.write(vim.fs.joinpath(bin, 'yq'), {
        '#!/bin/sh',
        'for last; do :; done',
        'cat "$last.json"',
      })
      vim.fn.setfperm(vim.fs.joinpath(bin, 'yq'), 'rwxr-xr-x')
      set_path(bin .. ':' .. vim.env.PATH)
      write('config/locales/en.yml', 'en:\n  hello: Hello')
      write('config/locales/en.yml.json', '{"en":{"hello":"Hello"}}')
      write('config/locales/admin/de.yml', 'de:\n  hello: Hallo')
      write('config/locales/admin/de.yml.json', '{"de":{"hello":"Hallo"}}')
      write('translations/messages.fr.yaml', 'hello: Salut')
      write('translations/messages.fr.yaml.json', '{"hello":"Salut"}')
      local idx = index()
      assert.same({ 'de', 'en', 'fr' }, idx.langs)
      assert.equals('Hallo', idx.values.de.hello.value)
      assert.same({ 'en', 'hello' }, idx.values.en.hello.path)
      assert.equals('Salut', idx.values.fr.hello.value)
    end)

    it('says YAML was skipped without yq', function()
      set_path('/nonexistent')
      write('config/locales/en.yml', 'en:\n  hello: Hello')
      local idx = index()
      assert.same({}, idx.langs)
      assert.matches('yq is not installed', idx.problems[1])
    end)

    it('skips a file past the size cap and says so', function()
      i18n.MAX_FILE_BYTES = 10
      write('locales/en.json', '{ "a": "a long enough value" }')
      local idx = index()
      assert.same({}, idx.langs)
      assert.matches('bigger than', idx.problems[1])
    end)

    it('follows the override and its default', function()
      write(
        '.nvim/i18n.json',
        '{ "paths": ["lang/{lang}.json"], "default": "fr" }'
      )
      write('lang/en.json', '{ "a": "A" }')
      write('lang/fr.json', '{ "a": "Ah" }')
      write('locales/de.json', '{ "a": "Ach" }')
      local idx = index()
      assert.same({ 'en', 'fr' }, idx.langs)
      assert.equals('fr', idx.default)
    end)

    it('reports a malformed override and reads nothing', function()
      write('.nvim/i18n.json', '{ "paths": ')
      write('locales/en.json', '{ "a": "A" }')
      local idx = index()
      assert.matches('i18n.json: not a JSON object', idx.error)
      assert.same({}, idx.langs)
    end)

    it('refuses an override path leaving the project', function()
      write('.nvim/i18n.json', '{ "paths": ["../other/{lang}.json"] }')
      assert.matches('not a path inside the project', index().error)
    end)

    it('finds the root above the buffer, not past the repository', function()
      write('locales/en.json', '{ "a": "A" }')
      write('src/app/page.ts', 't("a")')
      local bufnr = vim.fn.bufadd(vim.fs.joinpath(root, 'src/app/page.ts'))
      vim.fn.bufload(bufnr)
      assert.equals(root, i18n.root(bufnr))
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
  end)

  describe('extract', function()
    local function keys(line)
      return vim.tbl_map(
        function(u) return u.key or ('dyn:' .. u.prefix .. '*' .. u.suffix) end,
        i18n.extract(line)
      )
    end

    it('finds every call form', function()
      assert.same({ 'a.b' }, keys("t('a.b')"))
      assert.same({ 'a.b' }, keys('t("a.b")'))
      assert.same({ 'a.b' }, keys('i18n.t("a.b", { n: 1 })'))
      assert.same({ 'a.b' }, keys('{{ $t("a.b") }}'))
      assert.same({ 'ns.key' }, keys("const x = t('ns.key')"))
      assert.same({ 'key' }, keys('I18n.t(:key)'))
      assert.same({ 'key' }, keys("trans('key')"))
      assert.same({ 'Welcome back' }, keys("__('Welcome back')"))
      assert.same({ 'a', 'b' }, keys("$_('a') + t('b')"))
    end)

    it(
      'leaves out calls that only end in t',
      function()
        assert.same({}, keys("it('works'); import('x'); cat('y'); set('z')"))
      end
    )

    it('marks dynamic keys with what is known of them', function()
      assert.same({ 'dyn:a.*.b' }, keys('t(`a.${x}.b`)'))
      assert.same({ 'dyn:a.*' }, keys("t('a.' + x)"))
      assert.same({ 'dyn:a.*' }, keys("__('a.' . $x)"))
      assert.same({ 'dyn:*' }, keys('t(name)'))
      assert.same({ 'dyn:*.title' }, keys("t('.title')"))
      assert.same({ 'plain' }, keys('t(`plain`)'))
    end)

    it('gives the byte of the closing quote', function()
      local usage = i18n.extract("x = t('ab')")[1]
      assert.equals(7, usage.s)
      assert.equals(10, usage.e)
    end)
  end)

  describe('compare', function()
    it('finds missing, gaps, unused and maybe unused', function()
      write(
        'locales/en.json',
        vim.json.encode({
          home = { title = 'Home', old = 'Old' },
          item_one = 'one item',
          item_other = 'items',
          errors = { network = 'Down' },
        })
      )
      write(
        'locales/pl.json',
        vim.json.encode({
          home = { title = 'Dom' },
          item_one = 'x',
          item_few = 'y',
          item_other = 'z',
          errors = { network = 'Nie' },
        })
      )
      local idx = index()
      local usages = {
        { key = 'home.title', file = '/p/a.ts', lnum = 1 },
        { key = 'home.missing', file = '/p/a.ts', lnum = 2 },
        { key = 'item', file = '/p/a.ts', lnum = 3 },
        { prefix = 'errors.', suffix = '', file = '/p/b.ts', lnum = 9 },
      }
      local by = {}
      for _, item in ipairs(i18n.compare(idx, usages)) do
        table.insert(by, item.kind .. ' ' .. item.text)
      end
      assert.same({
        'missing `home.missing` is used but missing in en',
        'missing `home.missing` is used but missing in pl',
        'gap `home.old` is missing in pl',
        'maybe `errors.network` is maybe unused (dynamic key at /p/b.ts:9)',
        'unused `home.old` is never used',
      }, by)
    end)

    it('points an entry at its line in the locale file', function()
      write('locales/en.json', '{\n  "a": {\n    "b": "B"\n  },\n  "c": "C"\n}')
      local items = i18n.compare(index(), {})
      assert.equals(3, items[1].lnum)
      assert.equals(5, items[2].lnum)
    end)

    it('makes nothing surely unused when the scan was cut', function()
      write('locales/en.json', '{ "a": "A" }')
      local items = i18n.compare(index(), {}, true)
      assert.equals('maybe', items[1].kind)
    end)
  end)

  it('scans the code with git grep', function()
    write('src/a.ts', "t('a')\nconst x = 1")
    write('src/b.rb', 'I18n.t(:b)')
    write('README.md', "t('c')")
    local got
    i18n.scan(
      root,
      function(usages, failure) got = usages or error(failure) end
    )
    assert.is_true(vim.wait(10000, function() return got ~= nil end))
    local keys = vim.tbl_map(function(u) return u.key end, got)
    table.sort(keys)
    assert.same({ 'a', 'b' }, keys)
  end)

  it('places hints on the visible lines only', function()
    write(
      'locales/en.json',
      '{ "a": "Apple", "b": "A rather long translation text" }'
    )
    i18n.MAX_HINT = 10
    local idx = index()
    local bufnr = h.buffer({ lines = { "t('a')", 'x', "t('b')", "t('zz')" } })
    i18n.place(bufnr, idx, { { 3, 4 } })
    local ns = vim.api.nvim_create_namespace('dy_i18n')
    local marks =
      vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
    assert.equals(2, #marks)
    assert.equals(2, marks[1][2])
    assert.equals(5, marks[1][3])
    assert.equals(' A rather …', marks[1][4].virt_text[1][1])
    assert.equals(' missing in en', marks[2][4].virt_text[1][1])
  end)

  it('reads the locales again once one is written', function()
    write('locales/en.json', '{ "a": "A" }')
    assert.equals('A', index().values.en.a.value)
    write('locales/en.json', '{ "a": "B" }')
    assert.equals('A', index().values.en.a.value)
    i18n.written(vim.fs.joinpath(root, 'src/app.json'))
    assert.equals('A', index().values.en.a.value)
    i18n.written(vim.fs.joinpath(root, 'locales/en.json'))
    assert.equals('B', index().values.en.a.value)
    -- A new locale of a known layout counts too
    write('locales/fr.json', '{ "a": "F" }')
    i18n.written(vim.fs.joinpath(root, 'locales/fr.json'))
    assert.same({ 'en', 'fr' }, index().langs)
  end)

  it('rejects an unknown subcommand', function()
    i18n.command({ 'nope' })
    assert.equals(vim.log.levels.ERROR, notes[1].level)
  end)
end)
