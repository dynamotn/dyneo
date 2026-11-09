local h = require('helpers')

describe('tools.stacktrace', function()
  local stacktrace, dir, cleanup, notes, restores

  before_each(function()
    h.unload('tools.stacktrace')
    stacktrace = require('tools.stacktrace')
    dir, cleanup = h.tmpdir()
    notes = {}
    restores = {
      h.stub(
        vim,
        'notify',
        function(msg, level) table.insert(notes, { msg = msg, level = level }) end
      ),
    }
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.fn.setqflist({})
    vim.cmd('silent! cclose')
    vim.cmd('silent! only')
    cleanup()
  end)

  local function wait_qf()
    return vim.wait(
      3000,
      function() return vim.fn.getqflist({ title = 0 }).title == 'Stack trace' end
    )
  end

  --- The quickfix items, with the name of their buffer
  local function items()
    local list = vim.fn.getqflist()
    for _, item in ipairs(list) do
      item.name = item.bufnr > 0 and vim.api.nvim_buf_get_name(item.bufnr)
        or nil
    end
    return list
  end

  describe('parse', function()
    it(
      'reads Java, Kotlin and Scala frames across a Caused by chain',
      function()
        local frames = stacktrace.parse({
          'Exception in thread "main" java.lang.IllegalStateException: boom',
          '\tat com.acme.Foo.bar(Foo.java:42)',
          '\tat com.acme.Foo$Inner.run(Foo.java:7)',
          '\tat java.base/java.lang.Thread.run(Thread.java:833)',
          'Caused by: java.io.IOException: gone',
          '\tat com.acme.util.IoKt.read(Io.kt:3)',
          '\tat com.acme.Main.main(Main.scala:12)',
          '\t... 3 more',
        })
        assert.equals(5, #frames)
        assert.same({
          fn = 'com.acme.Foo.bar',
          file = 'Foo.java',
          lnum = 42,
          pkg = 'com/acme',
        }, frames[1])
        assert.equals('com/acme', frames[2].pkg)
        assert.equals('java/lang', frames[3].pkg)
        assert.equals('Io.kt', frames[4].file)
        assert.equals('com/acme/util', frames[4].pkg)
        assert.equals(12, frames[5].lnum)
      end
    )

    it('reads Python, Go, Rust and Node frames', function()
      local frames = stacktrace.parse({
        'Traceback (most recent call last):',
        '  File "app/main.py", line 3, in handler',
        'ValueError: nope',
        'goroutine 1 [running]:',
        'main.serve(0x1)',
        '\t/srv/app/main.go:12 +0x1f',
        '   0: app::run',
        '             at ./src/main.rs:5:9',
        '    at handle (/srv/web/x.js:3:7)',
        '    at /srv/web/y.mjs:4:1',
        '    at file:///srv/web/z.mjs:5:2',
      })
      assert.same({
        { fn = 'handler', file = 'app/main.py', lnum = 3 },
        { fn = 'main.serve(0x1)', file = '/srv/app/main.go', lnum = 12 },
        { fn = 'app::run', file = './src/main.rs', lnum = 5, col = 9 },
        { fn = 'handle', file = '/srv/web/x.js', lnum = 3, col = 7 },
        { file = '/srv/web/y.mjs', lnum = 4, col = 1 },
        { file = '/srv/web/z.mjs', lnum = 5, col = 2 },
      }, frames)
    end)

    it(
      'finds nothing in text without a frame',
      function() assert.same({}, stacktrace.parse({ 'hello', 'at noon' })) end
    )
  end)

  it('resolves Java classes in the project, by package path', function()
    local root = dir .. '/proj'
    h.write(root .. '/src/main/java/com/acme/Foo.java', { 'class Foo {}' })
    h.write(root .. '/src/main/java/notcom/acme/Bar.java', { 'class Bar {}' })
    vim.fn.system({ 'git', 'init', '-q', root })
    stacktrace.run({
      'java.lang.IllegalStateException: boom',
      '\tat java.base/java.lang.Thread.run(Thread.java:833)',
      '\tat com.acme.Foo.bar(Foo.java:42)',
      '\tat com.acme.Bar.baz(Bar.java:9)',
    }, root)
    assert.is_true(wait_qf())
    local list = items()
    assert.equals(3, #list)
    -- outside the project: kept, marked, and pointing at no file
    assert.equals('I', list[1].type)
    assert.is_nil(list[1].name)
    assert.matches('Thread%.java:833', list[1].text)
    assert.equals(root .. '/src/main/java/com/acme/Foo.java', list[2].name)
    assert.equals(42, list[2].lnum)
    assert.equals('', list[2].type)
    -- `notcom/acme/Bar.java` is not `com/acme/Bar.java`
    assert.equals('I', list[3].type)
    assert.is_nil(list[3].name)
    -- the cursor is on the first frame of the project
    assert.equals(2, vim.fn.getqflist({ idx = 0 }).idx)
  end)

  it('resolves relative paths against the root and marks libraries', function()
    local root = dir .. '/proj'
    h.write(root .. '/app/main.py', { 'x = 1', 'y = 2', 'z = 3' })
    h.write(root .. '/node_modules/lib/index.js', { '' })
    stacktrace.run({
      '  File "/usr/lib/python3/site-packages/flask/app.py", line 9, in wsgi',
      '  File "app/main.py", line 3, in handler',
      '    at go (' .. root .. '/node_modules/lib/index.js:1:1)',
    }, root)
    assert.is_true(wait_qf())
    local list = items()
    assert.equals(3, #list)
    assert.equals('I', list[1].type)
    assert.equals(root .. '/app/main.py', list[2].name)
    assert.equals(3, list[2].lnum)
    assert.equals('', list[2].type)
    assert.equals('I', list[3].type)
    assert.equals(2, vim.fn.getqflist({ idx = 0 }).idx)
  end)

  it('warns about a trace without a frame, and opens no list', function()
    stacktrace.run({ 'nothing to see here' }, dir)
    assert.equals(1, #notes)
    assert.matches('No stack frame', notes[1].msg)
    assert.equals(vim.log.levels.WARN, notes[1].level)
    assert.equals(0, #vim.fn.getqflist())
  end)

  describe('input', function()
    local trace = { '  File "a.py", line 1, in f' }

    it('takes the range when one is given', function()
      local bufnr = h.buffer({ lines = { 'x', trace[1], 'y' } })
      vim.api.nvim_set_current_buf(bufnr)
      assert.same(trace, stacktrace.input({ range = 2, line1 = 2, line2 = 2 }))
    end)

    it('takes a log buffer whole', function()
      local bufnr = h.buffer({ lines = { 'log', trace[1] }, filetype = 'log' })
      vim.api.nvim_set_current_buf(bufnr)
      assert.same({ 'log', trace[1] }, stacktrace.input({ range = 0 }))
    end)

    it('falls back to the unnamed register', function()
      vim.api.nvim_set_current_buf(h.buffer({ lines = { 'code' } }))
      table.insert(
        restores,
        h.stub(
          vim.fn,
          'getreg',
          function(reg) return reg == '"' and trace[1] .. '\n' or '' end
        )
      )
      assert.same(trace, stacktrace.input({ range = 0 }))
    end)
  end)
end)
