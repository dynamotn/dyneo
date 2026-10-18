local h = require('helpers')

local REPORT = {
  version = '2.1.0',
  runs = {
    {
      tool = { driver = { name = 'semgrep' } },
      originalUriBaseIds = { SRC = { uri = 'file:///root/base/' } },
      results = {
        {
          ruleId = 'note-rule',
          level = 'note',
          message = { text = 'just so\n  you know' },
          locations = {
            {
              physicalLocation = {
                artifactLocation = { uri = 'src/a%20b.py' },
                region = { startLine = 3, startColumn = 5, endLine = 4 },
              },
            },
          },
        },
        {
          ruleId = 'sqli',
          level = 'error',
          message = { text = 'SQL injection' },
          locations = {
            {
              physicalLocation = {
                artifactLocation = { uri = 'app.py', uriBaseId = 'SRC' },
                region = { startLine = 10 },
              },
            },
          },
        },
        {
          ruleId = 'remote',
          message = { text = 'no local file' },
          locations = {
            {
              physicalLocation = {
                artifactLocation = { uri = 'https://e.x/a.py' },
              },
            },
          },
        },
      },
    },
  },
}

describe('tools.sarif', function()
  local sarif, notes, restore

  before_each(function()
    h.unload('tools.sarif')
    sarif = require('tools.sarif')
    notes = {}
    restore = h.stub(vim, 'notify', function(msg) table.insert(notes, msg) end)
  end)
  after_each(function()
    restore()
    vim.fn.setqflist({}, 'r')
    vim.cmd('silent! cclose')
  end)

  describe('items', function()
    it('lists results worst first, with their tool and rule', function()
      local items = sarif.items(REPORT, '/root')
      assert.are.same(
        { 'E', 'W', 'N' },
        vim.tbl_map(function(i) return i.type end, items)
      )
      assert.are.equal('/root/base/app.py', items[1].filename)
      assert.are.equal(10, items[1].lnum)
      assert.are.equal('[semgrep sqli] SQL injection', items[1].text)
    end)

    it('reads a relative path against the root, decoded', function()
      local item = sarif.items(REPORT, '/root')[3]
      assert.are.equal('/root/src/a b.py', item.filename)
      assert.are.equal(3, item.lnum)
      assert.are.equal(5, item.col)
      assert.are.equal('[semgrep note-rule] just so you know', item.text)
    end)

    it('keeps a result whose artifact is no local file, unjumpable', function()
      local item = sarif.items(REPORT, '/root')[2]
      assert.is_nil(item.filename)
      assert.is_false(item.valid)
      assert.are.equal('W', item.type)
    end)

    it('keeps no path outside the project jumpable', function()
      local function result(uri, base)
        return {
          message = { text = 'x' },
          locations = {
            {
              physicalLocation = {
                artifactLocation = { uri = uri, uriBaseId = base },
              },
            },
          },
        }
      end
      local items = sarif.items({
        runs = {
          {
            originalUriBaseIds = { UP = { uri = 'file:///etc/' } },
            results = {
              result('../../home/u/.ssh/id_rsa'),
              result('file:///etc/shadow'),
              result('passwd', 'UP'),
              result('/etc/passwd'),
              result('../root-other/a.py'),
              result('file:///root/in.py'),
            },
          },
        },
      }, '/root')
      local valid = vim.tbl_filter(function(i) return i.valid end, items)
      assert.are.equal(1, #valid)
      assert.are.equal('/root/in.py', valid[1].filename)
      for _, i in ipairs(items) do
        if not i.valid then
          assert.is_nil(i.filename)
          assert.matches('outside the project', i.text)
        end
      end
    end)

    it('skips the results that are not SARIF, and counts them', function()
      local items, skipped = sarif.items({
        runs = {
          5,
          {
            results = {
              { message = { text = 5 } },
              { locations = { { physicalLocation = { region = 3 } } } },
              'result',
              { message = { text = 'fine' } },
            },
          },
        },
      }, '/root')
      assert.are.equal(4, skipped)
      assert.are.equal(1, #items)
      assert.matches('fine', items[1].text)
    end)

    it('takes a report with no runs or results', function()
      assert.are.same({}, sarif.items({}, '/root'))
      assert.are.same({}, sarif.items({ runs = { {} } }, '/root'))
    end)
  end)

  describe('load', function()
    local dir, cleanup
    before_each(function()
      dir, cleanup = h.tmpdir()
    end)
    after_each(function() cleanup() end)

    it('fills the quickfix list from a report', function()
      vim.fn.mkdir(dir .. '/.git', 'p')
      h.write(dir .. '/out/r.sarif', { vim.json.encode(REPORT) })
      sarif.load(dir .. '/out/r.sarif')
      local list = vim.fn.getqflist({ title = 1, items = 1 })
      assert.are.equal('SARIF: ' .. dir .. '/out/r.sarif', list.title)
      assert.are.equal(3, #list.items)
      local named = vim.fn.bufname(list.items[3].bufnr)
      assert.are.equal(dir .. '/src/a b.py', named)
    end)

    it('says so of a file that is not SARIF, and keeps the list', function()
      vim.fn.setqflist({}, ' ', { title = 'before' })
      h.write(dir .. '/x.json', { '{"a": 1}' })
      sarif.load(dir .. '/x.json')
      assert.matches('is not a SARIF report', notes[1])
      assert.are.equal('before', vim.fn.getqflist({ title = 1 }).title)
    end)

    it('says so of results that are not SARIF', function()
      h.write(dir .. '/bad.sarif', {
        '{"runs": [{"results": [{"message": {"text": 5}}, {"ruleId": "ok"}]}]}',
      })
      sarif.load(dir .. '/bad.sarif')
      assert.matches('1 results .* not SARIF', notes[1])
      assert.are.equal(1, #vim.fn.getqflist())
    end)

    it('leaves a link out of the project unjumpable', function()
      vim.fn.mkdir(dir .. '/.git', 'p')
      local outside, cleanup_outside = h.tmpdir()
      h.write(outside .. '/secret.txt', { 'x' })
      vim.uv.fs_symlink(outside, dir .. '/link')
      h.write(dir .. '/r.sarif', {
        vim.json.encode({
          runs = {
            {
              results = {
                {
                  message = { text = 'x' },
                  locations = {
                    {
                      physicalLocation = {
                        artifactLocation = { uri = 'link/secret.txt' },
                      },
                    },
                  },
                },
              },
            },
          },
        }),
      })
      sarif.load(dir .. '/r.sarif')
      cleanup_outside()
      local item = vim.fn.getqflist()[1]
      assert.are.equal(0, item.valid)
      assert.are.equal(0, item.bufnr)
      assert.matches('outside the project', item.text)
    end)

    it('refuses a report over the limit', function()
      sarif.MAX_REPORT = 4
      h.write(dir .. '/big.sarif', { vim.json.encode(REPORT) })
      sarif.load(dir .. '/big.sarif')
      assert.matches('not read', notes[1])
    end)

    it('says so of a report that is not there', function()
      sarif.load(dir .. '/none.sarif')
      assert.matches('does not exist', notes[1])
    end)

    it('takes the path given, the buffer, or asks for one', function()
      h.write(dir .. '/a.sarif', { '{"runs": [{"results": []}]}' })
      sarif.command({ args = dir .. '/a.sarif' })
      assert.matches('No findings', notes[1])

      vim.cmd.edit(dir .. '/a.sarif')
      sarif.command({ args = '' })
      assert.matches('No findings', notes[2])

      vim.cmd.enew()
      local answer = dir .. '/a.sarif'
      local restore_input = h.stub(vim.ui, 'input', function(opts, on_confirm)
        assert.equals('file', opts.completion)
        on_confirm(answer)
      end)
      sarif.command({ args = '' })
      answer = ''
      sarif.command({ args = '' })
      restore_input()
      vim.cmd('silent! %bwipeout!')
      assert.equals(3, #notes)
    end)

    it('says when a report has no findings', function()
      h.write(dir .. '/empty.sarif', { '{"runs": [{"results": []}]}' })
      sarif.load(dir .. '/empty.sarif')
      assert.matches('No findings', notes[1])
    end)
  end)
end)
