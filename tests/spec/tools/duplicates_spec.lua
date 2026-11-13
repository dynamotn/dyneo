local h = require('helpers')

describe('tools.duplicates', function()
  local duplicates, dir, cleanup, path, notes, restores, installed

  before_each(function()
    h.unload('tools.duplicates')
    duplicates = require('tools.duplicates')
    dir, cleanup = h.tmpdir()
    vim.fn.mkdir(dir .. '/bin', 'p')
    vim.fn.mkdir(dir .. '/proj/src', 'p')
    path = vim.env.PATH
    -- Only the fakes of this spec, whatever the machine has
    vim.env.PATH = dir .. '/bin:/usr/bin:/bin'
    notes, installed = {}, nil
    restores = {
      h.stub(vim, 'notify', function(msg) table.insert(notes, msg) end),
      h.stub(package.loaded, 'util.lazy_install', {
        install_once = function(name) installed = name end,
      }),
    }
  end)
  after_each(function()
    vim.env.PATH = path
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.fn.setqflist({})
    vim.cmd('silent! cclose')
    cleanup()
  end)

  --- A `jscpd` that keeps its arguments and writes `report`, if any, as the
  --- SARIF report into the directory after `--output`
  local function jscpd(report)
    local file = dir .. '/report.sarif'
    if report then h.write(file, { vim.json.encode(report) }) end
    h.write(dir .. '/bin/jscpd', {
      '#!/bin/sh',
      'echo "$@" > "' .. dir .. '/args"',
      'pwd > "' .. dir .. '/cwd"',
      'while [ "$1" != "--output" ]; do shift; done',
      'mkdir -p "$2"',
      report and ('cp "' .. file .. '" "$2/jscpd-sarif.json"') or 'true',
    })
    vim.fn.setfperm(dir .. '/bin/jscpd', 'rwxr-xr-x')
  end

  local function wait_qf(count)
    return vim.wait(
      3000,
      function()
        return #vim.fn.getqflist() == count
          and vim.fn.getqflist({ title = 0 }).title == 'Duplicated code'
      end
    )
  end

  it('lists the clones jscpd finds in the project', function()
    local root = dir .. '/proj'
    jscpd({
      version = '2.1.0',
      runs = {
        {
          tool = { driver = { name = 'jscpd' } },
          results = {
            {
              ruleId = 'duplication',
              level = 'warning',
              message = { text = 'Clone of src/b.lua:4-12' },
              locations = {
                {
                  physicalLocation = {
                    artifactLocation = { uri = root .. '/src/a.lua' },
                    region = { startLine = 3, endLine = 11 },
                  },
                },
              },
            },
          },
        },
      },
    })
    duplicates.run(root)
    assert.is_true(wait_qf(1))
    local item = vim.fn.getqflist()[1]
    assert.equals(root .. '/src/a.lua', vim.api.nvim_buf_get_name(item.bufnr))
    assert.equals(3, item.lnum)
    assert.matches('Clone of src/b.lua', item.text)
    local args = vim.fn.readfile(dir .. '/args')[1]
    assert.matches('%-%-reporters sarif', args)
    assert.matches('%-%-absolute', args)
    assert.equals(
      vim.uv.fs_realpath(root),
      vim.uv.fs_realpath(vim.fn.readfile(dir .. '/cwd')[1])
    )
  end)

  it('says so when there is no clone', function()
    jscpd({
      version = '2.1.0',
      runs = { { tool = { driver = { name = 'jscpd' } }, results = {} } },
    })
    duplicates.run(dir .. '/proj')
    assert.is_true(
      vim.wait(
        3000,
        function() return vim.tbl_contains(notes, 'No duplicated code') end
      )
    )
  end)

  it('fails when jscpd writes no report', function()
    jscpd(nil)
    duplicates.run(dir .. '/proj')
    assert.is_true(
      vim.wait(
        3000,
        function() return vim.tbl_contains(notes, 'jscpd wrote no SARIF report') end
      )
    )
    assert.is_false(vim.tbl_contains(notes, 'No duplicated code'))
  end)

  it('has Mason install jscpd when it is missing', function()
    duplicates.run(dir .. '/proj')
    assert.is_true(vim.wait(3000, function() return installed ~= nil end))
    assert.equals('jscpd', installed)
  end)
end)
