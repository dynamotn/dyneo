--- The query plan of the SQL statement under the cursor, as a tree
---
--- The connection is dadbod's: `w:db`, `t:db`, `b:db` or `g:db` (what
--- dadbod-ui sets in its query buffers), a URL, a `$VARIABLE` holding one, or
--- the name of a connection in `g:dbs`. PostgreSQL plans come from
--- `EXPLAIN (FORMAT JSON)` through `psql`, MySQL and MariaDB ones from
--- `EXPLAIN FORMAT=JSON` through `mysql`, SQLite ones from `EXPLAIN QUERY
--- PLAN` through `sqlite3 -readonly`.
---
--- `analyze` executes the statement: it is confirmed first, a second time
--- for anything but a plain query, and run inside a transaction rolled back
--- at once. The URL may carry a password: it is never shown or logged, and
--- is cut out of any error the client prints; messages name the scheme and
--- the host only.
local M = {}

local system = require('util.system')
local notify = require('util.notify').titled('Explain')

--- Milliseconds a plan may take, also the server's statement timeout
M.TIMEOUT = 30 * 1000
--- Bytes of a plan kept
M.MAX_OUTPUT = 4 * 1024 * 1024
--- Planned rows from which a full scan is flagged
M.BIG_ROWS = 10000
--- Loops from which a nested loop is flagged
M.BIG_LOOPS = 1000
--- How far actual rows may stray from the estimate before it is flagged
M.MISS = 10
--- Lines of the statement shown in a confirmation
M.PREVIEW_LINES = 12

M.ns = vim.api.nvim_create_namespace('dy_explain')

---@alias DyExplainEngine 'postgres'|'mysql'|'sqlite'

---@type table<string, DyExplainEngine>
M.SCHEMES = {
  postgres = 'postgres',
  postgresql = 'postgres',
  mysql = 'mysql',
  mariadb = 'mysql',
  sqlite = 'sqlite',
  sqlite3 = 'sqlite',
}

---@class DyExplainConn
---@field engine DyExplainEngine
---@field scheme string
---@field url string
---@field user? string
---@field password? string
---@field host? string
---@field port? string
---@field db? string Database name, or the file of SQLite

---@class DyExplainNode
---@field label string
---@field detail? string Costs and actuals, after the label
---@field children DyExplainNode[]
---@field flags string[] Why the node stands out
---@field raw? table What the database said of it

-- Connection ------------------------------------------------------------------

--- The connection URL of `bufnr`, the way dadbod looks for it
---@param bufnr integer
---@return string?
function M.url(bufnr)
  local value = vim.w.db or vim.t.db or vim.b[bufnr].db or vim.g.db
  if type(value) ~= 'string' or value == '' then return nil end
  if value:sub(1, 1) == '$' then value = vim.env[value:sub(2)] or '' end
  if not value:find(':') then
    local dbs = vim.g.dbs
    if type(dbs) == 'table' then
      if dbs[value] then
        value = dbs[value]
      else
        for _, db in ipairs(dbs) do
          if type(db) == 'table' and db.name == value then value = db.url end
        end
      end
    end
  end
  return type(value) == 'string' and value:find(':') and value or nil
end

local function unescape(s)
  return s
    and (
      s:gsub('%%(%x%x)', function(h) return string.char(tonumber(h, 16)) end)
    )
end

--- `url` read into its parts, or nil and why
---@param url string
---@return DyExplainConn?
---@return string? err
function M.parse(url)
  local scheme, rest = url:match('^([%w+.-]+):(.*)$')
  scheme = scheme and scheme:lower()
  local engine = scheme and M.SCHEMES[scheme]
  if not engine then
    return nil,
      ('%s: is not a database :DyExplain reads (PostgreSQL, MySQL, MariaDB, SQLite)'):format(
        scheme or '?'
      )
  end
  ---@type DyExplainConn
  local conn = { engine = engine, scheme = scheme, url = url }
  if engine == 'sqlite' then
    -- `sqlite:file`, `sqlite:///abs/file`
    conn.db = unescape((rest:gsub('^//', ''):gsub('%?.*$', '')))
    return conn
  end
  rest = rest:gsub('^//', ''):gsub('%?.*$', '')
  local auth, hostpart = rest:match('^(.*)@([^@]*)$')
  hostpart = hostpart or rest
  if auth then
    local user, password = auth:match('^([^:]*):(.*)$')
    conn.user = unescape(user or auth)
    conn.password = unescape(password)
  end
  local hostport, db = hostpart:match('^([^/]*)/?(.*)$')
  conn.host, conn.port = hostport:match('^(.-):(%d+)$')
  conn.host = unescape(conn.host or hostport)
  conn.db = db ~= '' and unescape(db) or nil
  if conn.host == '' then conn.host = nil end
  return conn
end

--- What may be said of `conn`: its scheme and host, never more
---@param conn DyExplainConn
---@return string
function M.describe(conn)
  if conn.engine == 'sqlite' then
    return 'sqlite:' .. vim.fn.fnamemodify(conn.db or '', ':t')
  end
  return ('%s://%s'):format(conn.scheme, conn.host or 'localhost')
end

--- `text` with the URL and its password cut out
---@param text string
---@param conn DyExplainConn
---@return string
function M.scrub(text, conn)
  for _, secret in ipairs({ conn.url, conn.password }) do
    if secret and secret ~= '' then
      text = text:gsub(vim.pesc(secret), '***')
    end
  end
  return text
end

-- Statement -------------------------------------------------------------------

--- The statement around line `row` (1-based) of `bufnr`: the treesitter
--- `statement` node when the sql parser is there, else the lines between
--- blank lines and `;`
---@param bufnr integer
---@param row integer
---@return string?
function M.statement(bufnr, row)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, 'sql')
  if ok and parser then
    parser:parse()
    local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1]
    local col = #line:match('^%s*')
    local node = vim.treesitter.get_node({
      bufnr = bufnr,
      pos = { row - 1, col },
      ignore_injections = false,
    })
    while node and node:type() ~= 'statement' do
      node = node:parent()
    end
    if node then return vim.treesitter.get_node_text(node, bufnr) end
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local function blank(i) return not lines[i] or lines[i]:match('^%s*$') end
  local function ends(i) return lines[i] and lines[i]:match(';%s*$') end
  if blank(row) then return nil end
  local first, last = row, row
  while first > 1 and not blank(first - 1) and not ends(first - 1) do
    first = first - 1
  end
  while not ends(last) and not blank(last + 1) do
    last = last + 1
  end
  return table.concat(vim.list_slice(lines, first, last), '\n')
end

--- `stmt` trimmed of blanks and its last `;`, or nil and why when it holds
--- more than one statement
---@param stmt string
---@return string?
---@return string? err
function M.clean(stmt)
  stmt = vim.trim(stmt):gsub('[;%s]+$', '')
  if stmt == '' then return nil, 'No statement to explain' end
  -- shortcut: a `;` inside a string literal counts too, refused rather than
  -- read wrong
  if stmt:find(';') then return nil, 'One statement at a time' end
  return stmt
end

--- Words that make a statement more than a plain query
M.WRITES = {
  'insert',
  'update',
  'delete',
  'merge',
  'truncate',
  'drop',
  'alter',
  'create',
  'grant',
  'revoke',
  'call',
  'do',
  'copy',
  'lock',
  'into',
  'replace',
  'set',
}

--- Whether `stmt` is a plain SELECT (or WITH ... SELECT) that writes nothing
---@param stmt string
---@return boolean
function M.is_plain_query(stmt)
  local text = (' ' .. stmt:lower() .. ' '):gsub('%-%-[^\n]*', ' ')
  local first = text:match('^%s*%(*%s*(%a+)')
  if first ~= 'select' and first ~= 'with' then return false end
  for _, word in ipairs(M.WRITES) do
    if text:find('%f[%w_]' .. word .. '%f[^%w_]') then return false end
  end
  return true
end

-- Commands --------------------------------------------------------------------

--- The command explaining `stmt` on `conn`, and its environment
---@param conn DyExplainConn
---@param stmt string
---@param analyze? boolean
---@return string[] argv
---@return table<string, string>? env
function M.command(conn, stmt, analyze)
  if conn.engine == 'postgres' then
    local argv = {
      'psql',
      '-X',
      '-A',
      '-t',
      '-q',
      '-v',
      'ON_ERROR_STOP=1',
      '-d',
      -- Without its password, which `ps` would show: that goes in the env
      (conn.url:gsub('^([%w+.-]+:/*[^:@/]*):[^?]*@', '%1@')),
    }
    if analyze then
      vim.list_extend(argv, {
        '-c',
        'BEGIN',
        '-c',
        'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ' .. stmt,
        '-c',
        'ROLLBACK',
      })
    else
      vim.list_extend(argv, { '-c', 'EXPLAIN (FORMAT JSON) ' .. stmt })
    end
    -- The server stops the statement too, not only the client
    return argv,
      {
        PGOPTIONS = ('-c statement_timeout=%d'):format(M.TIMEOUT),
        PGPASSWORD = conn.password,
      }
  elseif conn.engine == 'mysql' then
    local argv = { 'mysql', '--batch', '--raw', '--skip-column-names' }
    if conn.host then vim.list_extend(argv, { '-h', conn.host }) end
    if conn.port then vim.list_extend(argv, { '-P', conn.port }) end
    if conn.user then vim.list_extend(argv, { '-u', conn.user }) end
    if conn.db then vim.list_extend(argv, { '-D', conn.db }) end
    local sql = analyze
        and ('START TRANSACTION; EXPLAIN ANALYZE %s; ROLLBACK'):format(stmt)
      or ('EXPLAIN FORMAT=JSON ' .. stmt)
    vim.list_extend(argv, { '-e', sql })
    -- The password stays off the command line, where `ps` would show it
    return argv, conn.password and { MYSQL_PWD = conn.password } or nil
  end
  return {
    'sqlite3',
    '-readonly',
    '-batch',
    '-bail',
    conn.db or '',
    'EXPLAIN QUERY PLAN ' .. stmt,
  },
    nil
end

-- Plans -----------------------------------------------------------------------

local function num(n) return ('%.2f'):format(tonumber(n) or 0) end

--- A PostgreSQL plan node and those under it
---@param p table
---@return DyExplainNode
local function pg_node(p)
  local label = p['Node Type'] or '?'
  if p['Join Type'] and p['Join Type'] ~= 'Inner' then
    label = ('%s %s'):format(p['Join Type'], label)
  end
  if p['Relation Name'] then
    label = label .. ' on ' .. p['Relation Name']
    if p.Alias and p.Alias ~= p['Relation Name'] then
      label = label .. ' ' .. p.Alias
    end
  elseif p['CTE Name'] then
    label = label .. ' on ' .. p['CTE Name']
  elseif p['Function Name'] then
    label = label .. ' on ' .. p['Function Name']
  end
  if p['Index Name'] then label = label .. ' using ' .. p['Index Name'] end
  local detail = ('cost=%s..%s rows=%d'):format(
    num(p['Startup Cost']),
    num(p['Total Cost']),
    p['Plan Rows'] or 0
  )
  local flags = {}
  local actual = p['Actual Rows']
  if p['Actual Loops'] then
    detail = detail
      .. ('  (actual %sms ×%d, %d rows)'):format(
        ('%.1f'):format(p['Actual Total Time'] or 0),
        p['Actual Loops'],
        actual or 0
      )
    if p['Shared Hit Blocks'] or p['Shared Read Blocks'] then
      detail = detail
        .. ('  buffers hit=%d read=%d'):format(
          p['Shared Hit Blocks'] or 0,
          p['Shared Read Blocks'] or 0
        )
    end
  end
  local planned = p['Plan Rows'] or 0
  if
    p['Node Type'] == 'Seq Scan'
    and math.max(planned, actual or 0) >= M.BIG_ROWS
  then
    table.insert(
      flags,
      ('full scan of %d rows'):format(math.max(planned, actual or 0))
    )
  end
  if actual and p['Actual Loops'] ~= 0 then
    local ratio = math.max(actual, 1) / math.max(planned, 1)
    if ratio >= M.MISS or ratio <= 1 / M.MISS then
      table.insert(
        flags,
        ('estimate off ×%d (planned %d, actual %d)'):format(
          math.floor(math.max(ratio, 1 / ratio) + 0.5),
          planned,
          actual
        )
      )
    end
  end
  local children = {}
  for _, child in ipairs(p.Plans or {}) do
    table.insert(children, pg_node(child))
  end
  if p['Node Type'] == 'Nested Loop' and p.Plans and p.Plans[2] then
    -- The inner side runs once per row of the outer one
    local loops = p.Plans[2]['Actual Loops'] or p.Plans[1]['Plan Rows'] or 0
    if loops >= M.BIG_LOOPS then
      table.insert(flags, ('inner side runs %d times'):format(loops))
    end
  end
  local raw = vim.deepcopy(p)
  raw.Plans = nil
  return {
    label = label,
    detail = detail,
    children = children,
    flags = flags,
    raw = raw,
  }
end

--- The tree and the header of PostgreSQL's `EXPLAIN (FORMAT JSON)`
---@param text string
---@return DyExplainNode? root
---@return string header_or_err
function M.postgres(text)
  local ok, doc = pcall(vim.json.decode, vim.trim(text))
  local top = ok and type(doc) == 'table' and doc[1]
  if not top or type(top.Plan) ~= 'table' then
    return nil, 'psql gave no JSON plan'
  end
  local root = pg_node(top.Plan)
  local header = ('PostgreSQL  total cost %s  rows %d'):format(
    num(top.Plan['Total Cost']),
    top.Plan['Plan Rows'] or 0
  )
  if top['Planning Time'] then
    header = header .. ('  planning %.1fms'):format(top['Planning Time'])
  end
  if top['Execution Time'] then
    header = header .. ('  execution %.1fms'):format(top['Execution Time'])
  end
  return root, header
end

--- The parts of a MySQL plan that hold others, in the order shown
M.MYSQL_OPS = {
  'ordering_operation',
  'grouping_operation',
  'duplicates_removal',
  'windowing',
  'buffer_result',
  'union_result',
  'query_specifications',
  'nested_loop',
  'materialized_from_subquery',
  'query_block',
  'attached_subqueries',
  'optimized_away_subqueries',
}

local mysql_nodes

--- The operations held by `v`, one node each
---@param v table
---@return DyExplainNode[]
local function mysql_ops(v)
  local out = {}
  for _, key in ipairs(M.MYSQL_OPS) do
    local child = v[key]
    if type(child) == 'table' then
      local cost = not vim.islist(child)
        and child.cost_info
        and (child.cost_info.query_cost or child.cost_info.sort_cost)
      table.insert(out, {
        label = (key:gsub('_', ' ')),
        detail = cost and ('cost=%s'):format(cost) or nil,
        children = mysql_nodes(child),
        flags = {},
      })
    end
  end
  return out
end

--- The nodes of a MySQL plan value: a table, a list, or operations
---@param v any
---@return DyExplainNode[]
mysql_nodes = function(v)
  local out = {}
  if type(v) ~= 'table' then return out end
  if vim.islist(v) then
    for _, item in ipairs(v) do
      vim.list_extend(out, mysql_nodes(item))
    end
    return out
  end
  if v.table_name then
    local access = v.access_type or '?'
    local label = ('%s on %s'):format(access, v.table_name)
    if v.key then label = label .. ' using ' .. v.key end
    local rows = tonumber(v.rows_examined_per_scan) or 0
    local cost = v.cost_info or {}
    local detail = ('cost=%s rows=%d'):format(
      cost.prefix_cost or cost.read_cost or '?',
      rows
    )
    if v.filtered then
      detail = detail .. (' filtered=%s%%'):format(v.filtered)
    end
    local flags = {}
    if access == 'ALL' and rows >= M.BIG_ROWS then
      table.insert(flags, ('full scan of %d rows'):format(rows))
    end
    local raw = vim.deepcopy(v)
    for _, key in ipairs(M.MYSQL_OPS) do
      raw[key] = nil
    end
    return {
      {
        label = label,
        detail = detail,
        children = mysql_ops(v),
        flags = flags,
        raw = raw,
      },
    }
  end
  out = mysql_ops(v)
  if v.table then vim.list_extend(out, mysql_nodes(v.table)) end
  return out
end

--- The tree and the header of MySQL's `EXPLAIN FORMAT=JSON`
---@param text string
---@return DyExplainNode? root
---@return string header_or_err
function M.mysql(text)
  local ok, doc = pcall(vim.json.decode, vim.trim(text))
  if not ok or type(doc) ~= 'table' or type(doc.query_block) ~= 'table' then
    return nil, 'mysql gave no JSON plan'
  end
  local root = mysql_nodes({ query_block = doc.query_block })[1]
  local cost = doc.query_block.cost_info
    and doc.query_block.cost_info.query_cost
  return root, ('MySQL  total cost %s'):format(cost or '?')
end

--- The tree of MySQL's `EXPLAIN ANALYZE`, which is a tree of text already:
--- one node per line, flagged from the numbers on it
---@param text string
---@return DyExplainNode? root
---@return string header_or_err
function M.mysql_analyze(text)
  local root = { label = 'EXPLAIN ANALYZE', children = {}, flags = {} }
  local stack = { [-1] = root }
  for line in vim.gsplit(vim.trim(text), '\n') do
    local lead, body = line:match('^(%s*)%-> (.*)$')
    if body then
      local depth = math.floor(#lead / 4)
      local parent = stack[depth - 1] or root
      local node = { label = body, children = {}, flags = {} }
      local planned = tonumber(body:match('%(cost=[%d.]+ rows=([%d.]+)%)'))
      local actual, loops =
        body:match('%(actual time=[%d.]+%.%.[%d.]+ rows=([%d.]+) loops=(%d+)%)')
      actual, loops = tonumber(actual), tonumber(loops)
      if body:match('^Table scan') and (planned or 0) >= M.BIG_ROWS then
        table.insert(node.flags, ('full scan of %d rows'):format(planned))
      end
      if loops and loops >= M.BIG_LOOPS then
        table.insert(node.flags, ('runs %d times'):format(loops))
      end
      if planned and actual then
        local ratio = math.max(actual, 1) / math.max(planned, 1)
        if ratio >= M.MISS or ratio <= 1 / M.MISS then
          table.insert(
            node.flags,
            ('estimate off ×%d'):format(
              math.floor(math.max(ratio, 1 / ratio) + 0.5)
            )
          )
        end
      end
      table.insert(parent.children, node)
      stack[depth] = node
    end
  end
  if #root.children == 0 then return nil, 'mysql gave no plan' end
  return #root.children == 1 and root.children[1] or root, 'MySQL (analyzed)'
end

--- The tree of SQLite's `EXPLAIN QUERY PLAN`: the tree the shell draws, or
--- its `id|parent|notused|detail` rows
---@param text string
---@return DyExplainNode? root
---@return string header_or_err
function M.sqlite(text)
  local root = { label = 'QUERY PLAN', children = {}, flags = {} }
  local by_depth, by_id = { [-1] = root }, { [0] = root }
  for line in vim.gsplit(text, '\n') do
    local node, parent
    local lead, mark, detail = line:match('^([| ]*)([|`])%-%-(.*)$')
    local id, pid, rest = line:match('^(%d+)|(%d+)|%d+|(.*)$')
    if mark then
      local depth = math.floor(#lead / 3)
      node =
        { label = detail, children = {}, flags = {}, raw = { detail = detail } }
      parent = by_depth[depth - 1] or root
      by_depth[depth] = node
    elseif id then
      node = {
        label = rest,
        children = {},
        flags = {},
        raw = { id = tonumber(id), parent = tonumber(pid), detail = rest },
      }
      parent = by_id[tonumber(pid)] or root
      by_id[tonumber(id)] = node
    end
    if node then
      if
        node.label:match('^SCAN ') and not node.label:match('COVERING INDEX')
      then
        table.insert(node.flags, 'full scan')
      elseif node.label:match('TEMP B%-TREE') then
        table.insert(node.flags, 'sorts in a temporary tree')
      end
      table.insert(parent.children, node)
    end
  end
  if #root.children == 0 then return nil, 'sqlite3 gave no plan' end
  return root, 'SQLite'
end

-- Rendering -------------------------------------------------------------------

---@class DyExplainMark
---@field row integer 0-based
---@field col integer Where the label starts
---@field flags string[]

--- `root` as lines of a tree under `header`, the marks of the nodes that stand
--- out, and the node of each line (by 1-based line)
---@param root DyExplainNode
---@param header string
---@return string[] lines
---@return DyExplainMark[] marks
---@return table<integer, DyExplainNode> nodes
function M.render(root, header)
  local lines, marks, nodes = { header, '' }, {}, {}
  local function add(node, prefix, branch)
    local head = prefix .. branch
    local text = head .. node.label
    if node.detail then text = text .. '  ' .. node.detail end
    table.insert(lines, text)
    nodes[#lines] = node
    if #node.flags > 0 then
      table.insert(marks, { row = #lines - 1, col = #head, flags = node.flags })
    end
    local inner = prefix
      .. (
        branch == '├─ ' and '│  '
        or branch == '└─ ' and '   '
        or ''
      )
    for i, child in ipairs(node.children) do
      add(child, inner, i == #node.children and '└─ ' or '├─ ')
    end
  end
  add(root, '', '')
  return lines, marks, nodes
end

--- Show `root` in a scratch tab, the nodes that stand out marked
---@param root DyExplainNode
---@param header string
---@return integer bufnr
function M.show(root, header)
  local lines, marks, nodes = M.render(root, header)
  local bufnr = require('util.scratch').open(lines, {
    filetype = 'dyexplain',
    split = 'horizontal',
    -- A plan names tables, columns and the values of the statement
    sensitive = 'a query plan of a database',
  })
  vim.api.nvim_buf_set_extmark(bufnr, M.ns, 0, 0, {
    end_col = #lines[1],
    hl_group = 'Title',
  })
  for _, mark in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(bufnr, M.ns, mark.row, mark.col, {
      end_col = #lines[mark.row + 1],
      hl_group = 'DiagnosticWarn',
      virt_text = {
        { '  ' .. table.concat(mark.flags, ', '), 'DiagnosticVirtualTextWarn' },
      },
    })
  end
  vim.keymap.set('n', '<CR>', function()
    local node = nodes[vim.api.nvim_win_get_cursor(0)[1]]
    if not node or not node.raw then
      return notify('No raw plan for this line', vim.log.levels.WARN)
    end
    require('util.scratch').open(
      vim.split(vim.json.encode(node.raw, { indent = '  ' }), '\n'),
      {
        filetype = 'json',
        split = 'vertical',
        sensitive = 'a query plan of a database',
      }
    )
  end, { buffer = bufnr, desc = 'Raw Plan Node' })
  return bufnr
end

-- Running ---------------------------------------------------------------------

--- The statement, cut for a confirmation
local function preview(stmt)
  local lines = vim.split(stmt, '\n')
  if #lines > M.PREVIEW_LINES then
    lines = vim.list_slice(lines, 1, M.PREVIEW_LINES)
    table.insert(lines, '…')
  end
  return table.concat(lines, '\n')
end

--- Whether running `stmt` for real was agreed to
---@param conn DyExplainConn
---@param stmt string
---@return boolean
function M.confirm_analyze(conn, stmt)
  local rollback = conn.engine == 'postgres'
      and 'It runs inside BEGIN … ROLLBACK, so its writes are rolled back.'
    or 'It runs inside START TRANSACTION … ROLLBACK; DDL and tables without transactions keep what it does.'
  local first = vim.fn.confirm(
    ('EXPLAIN ANALYZE executes the statement on %s:\n\n%s\n\n%s'):format(
      M.describe(conn),
      preview(stmt),
      rollback
    ),
    '&Run\n&Cancel',
    2
  )
  if first ~= 1 then return false end
  if M.is_plain_query(stmt) then return true end
  return vim.fn.confirm(
    'This is not a plain SELECT: it may write, lock or call functions with '
      .. 'effects outside the transaction (sequences, other databases). '
      .. 'Run it anyway?',
    '&Cancel\n&Run it',
    1,
    'Warning'
  ) == 2
end

--- Explain the statement under the cursor, or in lines `range` of the buffer
---@param opts? { analyze?: boolean, range?: integer[] }
function M.run(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local raw
  if opts.range then
    raw = table.concat(
      vim.api.nvim_buf_get_lines(bufnr, opts.range[1] - 1, opts.range[2], false),
      '\n'
    )
  else
    raw = M.statement(bufnr, vim.api.nvim_win_get_cursor(0)[1])
  end
  if not raw then
    return notify('No statement under the cursor', vim.log.levels.WARN)
  end
  local stmt, err = M.clean(raw)
  if not stmt then return notify(err, vim.log.levels.WARN) end

  local url = M.url(bufnr)
  if not url then
    return notify(
      'No database connection: set `b:db` or `g:db` to a URL '
        .. "(`:let g:db = 'postgresql://host/db'`), or open the query from "
        .. 'the database UI (`<leader>Db`)',
      vim.log.levels.WARN
    )
  end
  local conn, perr = M.parse(url)
  if not conn then return notify(perr, vim.log.levels.ERROR) end

  if opts.analyze then
    if conn.engine == 'sqlite' then
      return notify(
        'SQLite has no EXPLAIN ANALYZE; showing the plan needs no run',
        vim.log.levels.WARN
      )
    end
    if not M.confirm_analyze(conn, stmt) then
      return notify('Not run', vim.log.levels.INFO)
    end
  end

  local argv, env = M.command(conn, stmt, opts.analyze)
  local where = M.describe(conn)
  notify(('Explaining on %s…'):format(where))
  system.run(
    argv,
    { env = env, timeout = M.TIMEOUT, max_bytes = M.MAX_OUTPUT },
    function(result)
      if result.missing then
        return notify(
          ('%s is not installed, needed for %s'):format(argv[1], conn.scheme),
          vim.log.levels.ERROR
        )
      end
      if result.code ~= 0 or result.timed_out or result.cut then
        return notify(
          ('%s on %s: %s'):format(
            argv[1],
            where,
            M.scrub(system.failure(result, argv[1]), conn)
          ),
          vim.log.levels.ERROR
        )
      end
      local parse = conn.engine == 'postgres' and M.postgres
        or conn.engine == 'sqlite' and M.sqlite
        or opts.analyze and M.mysql_analyze
        or M.mysql
      local root, header = parse(result.stdout)
      if not root then return notify(header, vim.log.levels.ERROR) end
      M.show(root, ('%s  on %s'):format(header, where))
    end
  )
end

return M
