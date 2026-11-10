local h = require('helpers')

local URL = 'postgresql://alice:s3cr%40t@db.example:5433/shop'
local PASSWORD = 's3cr@t'

local PG_PLAN = [=[
[
  {
    "Plan": {
      "Node Type": "Nested Loop",
      "Startup Cost": 0.29,
      "Total Cost": 8452.5,
      "Plan Rows": 100,
      "Plans": [
        {
          "Node Type": "Seq Scan",
          "Parent Relationship": "Outer",
          "Relation Name": "users",
          "Alias": "u",
          "Startup Cost": 0.0,
          "Total Cost": 431.0,
          "Plan Rows": 20000
        },
        {
          "Node Type": "Index Scan",
          "Parent Relationship": "Inner",
          "Relation Name": "orders",
          "Alias": "orders",
          "Index Name": "orders_user_id_idx",
          "Startup Cost": 0.29,
          "Total Cost": 0.4,
          "Plan Rows": 1
        }
      ]
    }
  }
]
]=]

local PG_ANALYZE = [=[
[
  {
    "Plan": {
      "Node Type": "Hash Join",
      "Join Type": "Inner",
      "Startup Cost": 10.0,
      "Total Cost": 500.0,
      "Plan Rows": 10,
      "Actual Total Time": 12.34,
      "Actual Rows": 5000,
      "Actual Loops": 1,
      "Shared Hit Blocks": 40,
      "Shared Read Blocks": 2,
      "Plans": [
        {
          "Node Type": "Seq Scan",
          "Relation Name": "users",
          "Alias": "users",
          "Startup Cost": 0.0,
          "Total Cost": 431.0,
          "Plan Rows": 10000,
          "Actual Total Time": 2.1,
          "Actual Rows": 9876,
          "Actual Loops": 1
        }
      ]
    },
    "Planning Time": 0.2,
    "Execution Time": 12.9
  }
]
]=]

local MYSQL_PLAN = [=[
{
  "query_block": {
    "select_id": 1,
    "cost_info": { "query_cost": "2050.25" },
    "nested_loop": [
      {
        "table": {
          "table_name": "users",
          "access_type": "ALL",
          "rows_examined_per_scan": 20000,
          "filtered": "100.00",
          "cost_info": { "read_cost": "10.00", "prefix_cost": "2010.00" }
        }
      },
      {
        "table": {
          "table_name": "orders",
          "access_type": "ref",
          "key": "user_id",
          "rows_examined_per_scan": 2,
          "cost_info": { "prefix_cost": "2050.25" }
        }
      }
    ]
  }
}
]=]

local SQLITE_TREE = table.concat({
  'QUERY PLAN',
  '|--SCAN u',
  '|--SEARCH o USING INDEX ix (user_id=?)',
  '|  `--LIST SUBQUERY 1',
  '`--USE TEMP B-TREE FOR ORDER BY',
}, '\n')

describe('tools.explain', function()
  local explain, dir, cleanup, path, notes, restores

  before_each(function()
    h.unload('tools.explain')
    explain = require('tools.explain')
    dir, cleanup = h.tmpdir()
    vim.fn.mkdir(dir .. '/bin', 'p')
    path = vim.env.PATH
    vim.env.PATH = dir .. '/bin:' .. path
    notes = {}
    restores = {
      h.stub(
        vim,
        'notify',
        function(msg, level) table.insert(notes, { msg = msg, level = level }) end
      ),
    }
    vim.g.db = nil
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.env.PATH = path
    vim.g.db = nil
    vim.cmd('silent! only')
    vim.cmd('silent! tabonly')
    vim.cmd('silent! %bwipeout!')
    cleanup()
  end)

  --- A fake `name` on the private PATH: records its arguments, prints
  --- `stdout` and `stderr`, exits `code`
  local function fake(name, stdout, code, stderr)
    h.write(dir .. '/out-' .. name, vim.split(stdout or '', '\n'))
    h.write(dir .. '/err-' .. name, vim.split(stderr or '', '\n'))
    h.write(dir .. '/bin/' .. name, {
      '#!/bin/sh',
      ('printf "%%s\\n" "$@" > %q'):format(dir .. '/args-' .. name),
      ('cat %q'):format(dir .. '/out-' .. name),
      ('cat %q >&2'):format(dir .. '/err-' .. name),
      ('exit %d'):format(code or 0),
    })
    vim.fn.setfperm(dir .. '/bin/' .. name, 'rwxr-xr-x')
  end
  local function args(name)
    return vim.fn.filereadable(dir .. '/args-' .. name) == 1
        and table.concat(vim.fn.readfile(dir .. '/args-' .. name), '\n')
      or nil
  end
  local function all_notes()
    return table.concat(vim.tbl_map(function(n) return n.msg end, notes), '\n')
  end

  describe('statement', function()
    local lines = {
      'SELECT 1;',
      '',
      'SELECT *',
      'FROM users',
      'WHERE id = 1;',
      'UPDATE users SET a = 1;',
    }

    it('reads the lines between blank lines and semicolons', function()
      local bufnr = h.buffer({ lines = lines })
      assert.equals(
        'SELECT *\nFROM users\nWHERE id = 1;',
        explain.statement(bufnr, 4)
      )
      assert.equals('UPDATE users SET a = 1;', explain.statement(bufnr, 6))
      assert.equals('SELECT 1;', explain.statement(bufnr, 1))
      assert.is_nil(explain.statement(bufnr, 2))
    end)

    it('takes one statement only', function()
      assert.equals('SELECT 1', explain.clean('  SELECT 1 ;\n'))
      local stmt, err = explain.clean('SELECT 1; DELETE FROM t')
      assert.is_nil(stmt)
      assert.matches('One statement', err)
    end)

    it('tells a plain query from one that writes', function()
      assert.is_true(explain.is_plain_query('select * from t'))
      assert.is_true(
        explain.is_plain_query('WITH a AS (SELECT 1) SELECT * FROM a')
      )
      assert.is_false(explain.is_plain_query('DELETE FROM t'))
      assert.is_false(
        explain.is_plain_query(
          'WITH d AS (DELETE FROM t RETURNING *) SELECT * FROM d'
        )
      )
      assert.is_false(explain.is_plain_query('SELECT * INTO copy FROM t'))
    end)
  end)

  describe('connection', function()
    it('reads the URL from b:db, g:db, $VAR and g:dbs', function()
      local bufnr = h.buffer()
      vim.g.db = 'sqlite:/tmp/x.db'
      assert.equals('sqlite:/tmp/x.db', explain.url(bufnr))
      vim.b[bufnr].db = URL
      assert.equals(URL, explain.url(bufnr))
      vim.b[bufnr].db = 'shop'
      vim.g.dbs = { shop = 'mysql://root@h/shop' }
      assert.equals('mysql://root@h/shop', explain.url(bufnr))
      vim.env.DY_EXPLAIN_URL = 'sqlite:env.db'
      vim.b[bufnr].db = '$DY_EXPLAIN_URL'
      assert.equals('sqlite:env.db', explain.url(bufnr))
      vim.env.DY_EXPLAIN_URL = nil
      vim.g.dbs = nil
      vim.b[bufnr].db = nil
    end)

    it('parses a URL and describes it without credentials', function()
      local conn = assert(explain.parse(URL))
      assert.equals('postgres', conn.engine)
      assert.equals('alice', conn.user)
      assert.equals(PASSWORD, conn.password)
      assert.equals('db.example', conn.host)
      assert.equals('5433', conn.port)
      assert.equals('shop', conn.db)
      assert.equals('postgresql://db.example', explain.describe(conn))
      assert.equals('/abs/x.db', assert(explain.parse('sqlite:///abs/x.db')).db)
      assert.equals('rel.db', assert(explain.parse('sqlite:rel.db')).db)
      local none, err = explain.parse('redis://h')
      assert.is_nil(none)
      assert.matches('redis', err)
    end)

    it('keeps the MySQL password off the command line', function()
      local argv, env = explain.command(
        assert(explain.parse('mysql://bob:pw@h:3307/shop')),
        'SELECT 1'
      )
      assert.is_nil(table.concat(argv, ' '):find('pw', 1, true))
      assert.same({ MYSQL_PWD = 'pw' }, env)
      assert.equals('EXPLAIN FORMAT=JSON SELECT 1', argv[#argv])
    end)
  end)

  describe('render', function()
    it('draws a PostgreSQL plan and flags a big scan and a hot loop', function()
      local root, header = explain.postgres(PG_PLAN)
      local lines, marks = explain.render(assert(root), header)
      assert.same({
        'PostgreSQL  total cost 8452.50  rows 100',
        '',
        'Nested Loop  cost=0.29..8452.50 rows=100',
        '├─ Seq Scan on users u  cost=0.00..431.00 rows=20000',
        '└─ Index Scan on orders using orders_user_id_idx  cost=0.29..0.40 rows=1',
      }, lines)
      assert.equals(2, #marks)
      assert.equals(2, marks[1].row)
      assert.matches('inner side runs 20000 times', marks[1].flags[1])
      assert.equals(3, marks[2].row)
      assert.equals(#'├─ ', marks[2].col)
      assert.matches('full scan of 20000 rows', marks[2].flags[1])
    end)

    it('shows the actuals of ANALYZE and an estimate off ×10', function()
      local root, header = explain.postgres(PG_ANALYZE)
      local lines, marks = explain.render(assert(root), header)
      assert.equals(
        'PostgreSQL  total cost 500.00  rows 10  planning 0.2ms  execution 12.9ms',
        lines[1]
      )
      assert.equals(
        'Hash Join  cost=10.00..500.00 rows=10  (actual 12.3ms ×1, 5000 rows)'
          .. '  buffers hit=40 read=2',
        lines[3]
      )
      assert.equals(
        '└─ Seq Scan on users  cost=0.00..431.00 rows=10000  (actual 2.1ms ×1, 9876 rows)',
        lines[4]
      )
      assert.equals(2, marks[1].row)
      assert.matches('estimate off ×500', marks[1].flags[1])
      assert.matches('full scan', marks[2].flags[1])
    end)

    it('draws a MySQL JSON plan', function()
      local root, header = explain.mysql(MYSQL_PLAN)
      local lines, marks = explain.render(assert(root), header)
      assert.same({
        'MySQL  total cost 2050.25',
        '',
        'query block  cost=2050.25',
        '└─ nested loop',
        '   ├─ ALL on users  cost=2010.00 rows=20000 filtered=100.00%',
        '   └─ ref on orders using user_id  cost=2050.25 rows=2',
      }, lines)
      assert.equals(1, #marks)
      assert.equals(4, marks[1].row)
    end)

    it('draws the tree of SQLite and its id|parent rows', function()
      local root, header = explain.sqlite(SQLITE_TREE)
      local lines, marks = explain.render(assert(root), header)
      assert.same({
        'SQLite',
        '',
        'QUERY PLAN',
        '├─ SCAN u',
        '├─ SEARCH o USING INDEX ix (user_id=?)',
        '│  └─ LIST SUBQUERY 1',
        '└─ USE TEMP B-TREE FOR ORDER BY',
      }, lines)
      assert.same({ 3, 6 }, { marks[1].row, marks[2].row })
      local old = explain.render(
        assert(explain.sqlite('2|0|0|SCAN TABLE t\n3|0|0|SEARCH TABLE u')),
        'SQLite'
      )
      assert.same({ '├─ SCAN TABLE t', '└─ SEARCH TABLE u' }, {
        old[4],
        old[5],
      })
    end)
  end)

  describe('run', function()
    local function sql_buffer(lines)
      local bufnr = h.buffer({ lines = lines })
      vim.api.nvim_set_current_buf(bufnr)
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      return bufnr
    end

    it('says how to set a connection when there is none', function()
      sql_buffer({ 'SELECT 1;' })
      explain.run()
      assert.matches('g:db', all_notes())
    end)

    it('explains on PostgreSQL and shows the marked tree', function()
      fake('psql', PG_PLAN)
      local bufnr = sql_buffer({ 'SELECT *', 'FROM users;' })
      vim.b[bufnr].db = URL
      explain.run()
      assert.is_true(
        vim.wait(3000, function() return vim.bo.filetype == 'dyexplain' end)
      )
      assert.matches(
        'EXPLAIN %(FORMAT JSON%) SELECT %*\nFROM users',
        args('psql')
      )
      local marks =
        vim.api.nvim_buf_get_extmarks(0, explain.ns, 0, -1, { details = true })
      assert.equals(3, #marks)
      assert.equals('DiagnosticWarn', marks[3][4].hl_group)
      assert.is_nil(all_notes():find(PASSWORD, 1, true))
      assert.is_nil(all_notes():find('alice', 1, true))
    end)

    it('shows the database error without the URL', function()
      fake('psql', '', 2, 'psql: error: bad ' .. URL .. ' pass ' .. PASSWORD)
      local bufnr = sql_buffer({ 'SELECT 1;' })
      vim.b[bufnr].db = URL
      explain.run()
      assert.is_true(
        vim.wait(
          3000,
          function() return all_notes():find('psql: error', 1, true) ~= nil end
        )
      )
      assert.is_nil(all_notes():find(URL, 1, true))
      assert.is_nil(all_notes():find(PASSWORD, 1, true))
      assert.matches('postgresql://db.example', all_notes())
    end)

    it(
      'analyzes a SELECT inside a rolled-back transaction once confirmed',
      function()
        fake('psql', PG_ANALYZE)
        local asked = {}
        table.insert(
          restores,
          h.stub(vim.fn, 'confirm', function(msg)
            table.insert(asked, msg)
            return 1
          end)
        )
        local bufnr = sql_buffer({ 'SELECT * FROM users;' })
        vim.b[bufnr].db = URL
        explain.run({ analyze = true })
        assert.is_true(
          vim.wait(3000, function() return vim.bo.filetype == 'dyexplain' end)
        )
        assert.equals(1, #asked)
        assert.matches('SELECT %* FROM users', asked[1])
        assert.matches('ROLLBACK', asked[1])
        assert.is_nil(asked[1]:find(PASSWORD, 1, true))
        assert.equals(
          table.concat({
            '-c',
            'BEGIN',
            '-c',
            'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) SELECT * FROM users',
            '-c',
            'ROLLBACK',
          }, '\n'),
          args('psql'):match('%-c\n.*$')
        )
      end
    )

    it('refuses to analyze a write without the second confirm', function()
      fake('psql', PG_ANALYZE)
      local asked = 0
      table.insert(
        restores,
        h.stub(vim.fn, 'confirm', function()
          asked = asked + 1
          -- Run at the first question, Cancel (the default) at the second
          return 1
        end)
      )
      local bufnr = sql_buffer({ 'DELETE FROM users;' })
      vim.b[bufnr].db = URL
      explain.run({ analyze = true })
      vim.wait(200)
      assert.equals(2, asked)
      assert.is_nil(args('psql'))
      assert.matches('Not run', all_notes())
    end)

    it('explains on SQLite read-only', function()
      fake('sqlite3', SQLITE_TREE)
      local bufnr = sql_buffer({ 'SELECT * FROM u;' })
      vim.b[bufnr].db = 'sqlite:' .. dir .. '/t.db'
      explain.run()
      assert.is_true(
        vim.wait(3000, function() return vim.bo.filetype == 'dyexplain' end)
      )
      assert.equals(
        table.concat({
          '-readonly',
          '-batch',
          '-bail',
          dir .. '/t.db',
          'EXPLAIN QUERY PLAN SELECT * FROM u',
        }, '\n'),
        args('sqlite3')
      )
      assert.equals(
        '├─ SCAN u',
        vim.api.nvim_buf_get_lines(0, 3, 4, false)[1]
      )
    end)

    it('says when the client is not installed', function()
      vim.env.PATH = dir .. '/bin'
      local bufnr = sql_buffer({ 'SELECT 1;' })
      vim.b[bufnr].db = 'mysql://h/shop'
      explain.run()
      assert.is_true(
        vim.wait(
          3000,
          function()
            return all_notes():find('mysql is not installed', 1, true) ~= nil
          end
        )
      )
    end)
  end)
end)
