local h = require('helpers')

describe('tools.ai.prompts', function()
  local prompts, dir, cleanup, restores, project

  before_each(function()
    dir, cleanup = h.tmpdir()
    project = nil
    restores = {
      h.stub(package.loaded, 'util.project_rtp', {
        current = function() return project end,
      }),
    }
    h.unload('tools.ai.prompts')
    prompts = require('tools.ai.prompts')
    prompts.BUILTIN = dir .. '/builtin'
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.cmd('silent! %bwipeout!')
    cleanup()
  end)

  it('ships a prompt for every mapping', function()
    h.unload('tools.ai.prompts')
    local shipped = require('tools.ai.prompts')
    for _, name in ipairs({ 'explain', 'review', 'tests', 'docs', 'fix' }) do
      assert.is_not_nil(shipped.get(name), name)
    end
    assert.is_not_nil(shipped.read(shipped.BUILTIN .. '/git/commit.md', false))
  end)

  it('reads the description from front matter', function()
    h.write(dir .. '/builtin/explain.md', {
      '---',
      'description: Say what it does',
      '---',
      '',
      'Explain {selection}',
    })
    local prompt = prompts.get('explain')
    assert.equals('Say what it does', prompt.description)
    assert.equals('Explain {selection}', prompt.body)
    assert.is_false(prompt.project)
  end)

  it('takes the first line for a description without front matter', function()
    h.write(dir .. '/builtin/plain.md', { '# Do a thing', '', 'Body' })
    assert.equals('Do a thing', prompts.get('plain').description)
  end)

  it('reads no project prompt while the folder is not trusted', function()
    h.write(dir .. '/project/prompts/own.md', { 'Own' })
    assert.is_nil(prompts.get('own'))
  end)

  it("lets a trusted project's prompt replace a shipped one", function()
    h.write(dir .. '/builtin/review.md', { 'Shipped' })
    h.write(dir .. '/project/prompts/review.md', { 'Ours' })
    project = dir .. '/project'
    local prompt = prompts.get('review')
    assert.equals('Ours', prompt.body)
    assert.is_true(prompt.project)
    assert.equals(1, #prompts.list())
  end)

  it("builds a command on the trusted project's template first", function()
    h.write(dir .. '/builtin/git/commit.md', { 'Shipped' })
    assert.equals('Shipped', prompts.template('git/commit.md').body)
    project = dir .. '/project'
    assert.equals('Shipped', prompts.template('git/commit.md').body)
    h.write(dir .. '/project/prompts/git/commit.md', { 'Ours' })
    local own = prompts.template('git/commit.md')
    assert.equals('Ours', own.body)
    assert.is_true(own.project)
  end)

  describe('expand', function()
    local bufnr

    before_each(
      function()
        bufnr = h.buffer({
          name = dir .. '/x.lua',
          filetype = 'lua',
          lines = { 'local a = 1', 'local b = 2', 'return a + b' },
        })
      end
    )

    it('fills the code, file and filetype of a selection', function()
      local text, cut = prompts.expand(
        { body = '{file} {filetype}\n{selection}' },
        { bufnr = bufnr, range = { 2, 3 } }
      )
      assert.is_false(cut)
      assert.is_truthy(text:find('x.lua lua', 1, true))
      assert.is_truthy(
        text:find('```lua (lines 2-3)\nlocal b = 2\nreturn a + b\n```', 1, true)
      )
      assert.is_nil(text:find('local a', 1, true))
    end)

    it('lists the diagnostics of the selection only', function()
      local ns = vim.api.nvim_create_namespace('dy_ai_spec')
      vim.diagnostic.set(ns, bufnr, {
        { lnum = 0, col = 0, message = 'outside', severity = 1 },
        { lnum = 2, col = 0, message = 'inside', severity = 2, source = 'x' },
      })
      local text = prompts.expand(
        { body = '{diagnostics}' },
        { bufnr = bufnr, range = { 2, 3 } }
      )
      assert.equals('- line 3, warn (x): inside', text)
    end)

    it('cuts the code at MAX_BYTES and says so', function()
      prompts.MAX_BYTES = 5
      local text, cut = prompts.expand(
        { body = '{selection}' },
        { bufnr = bufnr }
      )
      assert.is_true(cut)
      assert.is_truthy(text:find('local\n```', 1, true))
      assert.is_truthy(text:find('cut at', 1, true))
    end)

    it('fences code that holds fences of its own', function()
      local md = h.buffer({
        filetype = 'markdown',
        lines = { 'Run:', '```sh', 'make', '```' },
      })
      local text = prompts.expand({ body = '{selection}' }, { bufnr = md })
      assert.equals('````markdown\nRun:\n```sh\nmake\n```\n````', text)
    end)

    it('cuts between characters, never inside one', function()
      local utf8 = h.buffer({ lines = { 'aé' } })
      prompts.MAX_BYTES = 2
      local text, cut = prompts.expand(
        { body = '{selection}' },
        { bufnr = utf8 }
      )
      assert.is_true(cut)
      assert.is_truthy(text:find('```\na\n```', 1, true))
    end)

    it('leaves unknown words and percent signs alone', function()
      local text = prompts.expand(
        { body = '{input} {other} 100%' },
        { bufnr = bufnr, input = 'why %1' }
      )
      assert.equals('why %1 {other} 100%', text)
    end)
  end)
end)
