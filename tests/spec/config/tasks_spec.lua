local h = require('helpers')

-- The commands of `config.tasks` that are built from the file, through the
-- overseer provider that reads them
describe('config.tasks', function()
  local dir, cleanup, restores
  local lang = require('overseer.template.dytask.lang')

  before_each(function()
    dir, cleanup = h.tmpdir()
    restores = {
      h.stub(
        DyNeo,
        'enabled_languages',
        vim.tbl_keys(require('config.languages'))
      ),
      h.stub(vim.fn, 'executable', function() return 1 end),
    }
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.cmd('silent! %bwipeout!')
    cleanup()
  end)

  --- Templates offered for `file` under the scratch directory, by name
  ---@param file string
  ---@param filetype string
  ---@return table<string, overseer.TemplateDefinition>
  local function templates(file, filetype)
    local ret = {}
    for _, template in ipairs(lang.templates(dir .. '/' .. file, filetype)) do
      ret[template.name] = template
    end
    return ret
  end

  --- `executable` answering 1 for `names` only
  ---@param names string[]
  local function only(names)
    restores[2]()
    restores[2] = h.stub(
      vim.fn,
      'executable',
      function(name) return vim.list_contains(names, name) and 1 or 0 end
    )
  end

  it('sources a vim script in a clean headless Neovim', function()
    local task = templates('x.vim', 'vim')['vim source'].builder()
    assert.are.same(
      { 'nvim', '--clean', '--headless', '-S', dir .. '/x.vim', '+qa!' },
      task.cmd
    )
  end)

  it('compiles an erlang module and calls its main', function()
    local task =
      templates('hello.erl', 'erlang')['erlang build and run'].builder()
    assert.are.same({
      'erl',
      '-noshell',
      '-pa',
      dir,
      '-s',
      'hello',
      'main',
      '-s',
      'init',
      'stop',
    }, task.cmd)
    assert.are.same(
      { 'erlc', '-o', dir, dir .. '/hello.erl' },
      task.components[2].tasks[1].cmd
    )
  end)

  it('renders a mermaid diagram next to its file', function()
    local task = templates('flow.mmd', 'mermaid')['mermaid render'].builder()
    assert.are.same(
      { 'mmdc', '-i', dir .. '/flow.mmd', '-o', dir .. '/flow.svg' },
      task.cmd
    )
  end)

  it('builds bicep with its CLI, or through az', function()
    local task = templates('main.bicep', 'bicep')['bicep build'].builder()
    assert.are.same({ 'bicep', 'build', dir .. '/main.bicep' }, task.cmd)
    only({ 'az' })
    task = templates('main.bicep', 'bicep')['bicep build'].builder()
    assert.are.same(
      { 'az', 'bicep', 'build', '--file', dir .. '/main.bicep' },
      task.cmd
    )
  end)

  it('builds with the gradle wrapper, else gradle itself', function()
    h.write(dir .. '/settings.gradle', { '' })
    h.write(dir .. '/gradlew', { '' })
    local task = templates('src/Main.java', 'java')['gradle build'].builder()
    assert.are.equal(dir .. '/gradlew', task.cmd[1])
    only({ 'gradle' })
    task = templates('src/Main.java', 'java')['gradle build'].builder()
    assert.are.equal('gradle', task.cmd[1])
    only({})
    assert.is_nil(templates('src/Main.java', 'java')['gradle build'])
  end)
end)
