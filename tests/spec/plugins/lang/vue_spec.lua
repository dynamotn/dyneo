local h = require('helpers')

describe('plugins.lang.vue', function()
  local restore, specs, mason

  before_each(function()
    h.globals()
    mason = vim.env.MASON
    vim.env.MASON = '/mason'
    specs = dofile(h.root .. '/lua/plugins/lang/vue.lua')
  end)
  after_each(function()
    vim.env.MASON = mason
    if restore then restore() end
    restore = nil
  end)

  it('hands the Vue plugin to vtsls by its Mason path', function()
    local opts = { servers = { vtsls = { filetypes = { 'typescript' } } } }
    specs[2].opts(nil, opts)
    local vtsls = opts.servers.vtsls
    assert.same({ 'typescript', 'vue' }, vtsls.filetypes)
    local plugin = vtsls.settings.vtsls.tsserver.globalPlugins[1]
    assert.are.equal('@vue/typescript-plugin', plugin.name)
    assert.are.equal(
      '/mason/packages/vue-language-server/node_modules/@vue/language-server',
      plugin.location
    )
    assert.same({ 'vue' }, plugin.languages)
    assert.same({}, specs[1].opts.servers.vtsls)
  end)
end)
