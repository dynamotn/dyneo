local h = require('helpers')

dofile(h.root .. '/ftdetect/filetype.lua')

---@param path string
---@return string?
local function match(path) return vim.filetype.match({ filename = path }) end

describe('ftdetect', function()
  local cases = {
    -- extension
    { '/p/.envrc', 'sh' },
    { '/p/sketch.ino', 'arduino' },
    { '/p/sketch.pde', 'arduino' },
    { '/p/page.gotmpl', 'gotmpl' },
    { '/p/theme.rasi', 'rasi' },
    { '/p/x.rofi', 'rasi' },
    { '/p/x.wofi', 'rasi' },
    { '/p/foo-1.0.ebuild', 'sh.ebuild' },
    { '/p/eclass/cmake.eclass', 'sh.eclass' },
    { '/p/query.promql', 'promql' },
    { '/p/ledger.bean', 'beancount' },
    { '/p/lua.snippets', 'snippets' },
    { '/p/schema.dbml', 'dbml' },
    { '/p/diagram.d2', 'd2' },
    { '/p/notebook.ipynb', 'ipynb' },
    { '/p/table.psv', 'psv' },
    { '/p/events.ndjson', 'jsonl' },
    { '/p/main.nf', 'nextflow' },
    { '/p/page.j2', 'jinja' },
    { '/p/page.jinja', 'jinja' },
    { '/p/page.jinja2', 'jinja' },
    { '/p/page.djhtml', 'htmldjango' },
    { '/p/post.mdx', 'markdown.mdx' },
    -- file name
    { '/p/terragrunt.hcl', 'terragrunt' },
    { '/p/azure-pipelines.yml', 'yaml.az-pl' },
    { '/p/docker-compose.yml', 'yaml.docker-compose' },
    { '/p/compose.yaml', 'yaml.docker-compose' },
    { '/p/PKGBUILD', 'sh.PKGBUILD' },
    { '/p/nextflow.config', 'nextflow' },
    -- pattern
    { '/p/host_vars/web.yaml', 'yaml.ansible' },
    { '/p/group_vars/all.yml', 'yaml.ansible' },
    { '/p/group_vars/all/vars.yml', 'yaml.ansible' },
    { '/p/playbooks/site.yml', 'yaml.ansible' },
    { '/p/roles/web/tasks/main.yml', 'yaml.ansible' },
    { '/p/roles/web/handlers/main.yml', 'yaml.ansible' },
    { '/p/molecule/default/converge.yml', 'yaml.ansible' },
    { '/p/openapi.yaml', 'yaml.openapi' },
    { '/p/openapi-v2.json', 'json.openapi' },
    { '/p/model/landscape.c4', 'likec4' },
    { '/p/model/views.likec4', 'likec4' },
    { '/p/.gitlab-ci.yml', 'yaml.gitlab' },
    { '/p/.github/workflows/ci.yml', 'yaml.gh-action' },
    { '/p/.forgejo/workflows/ci.yml', 'yaml.gh-action' },
    { '/p/src/app.component.html', 'htmlangular' },
    { '/p/src/app.container.html', 'htmlangular' },
    { '/p/dot_bashrc.tmpl', 'gotmpl' },
    { '/p/helmfile.yaml', 'helm' },
    { '/p/.config/hypr/hyprland.conf', 'hyprlang' },
    { '/p/Dockerfile-dev', 'dockerfile' },
  }

  for _, case in ipairs(cases) do
    it(
      case[1] .. ' is ' .. case[2],
      function() assert.are.equal(case[2], match(case[1])) end
    )
  end

  it(
    '/p/.git/ignore is gitignore',
    function() assert.are.equal('gitignore', match('/p/.git/ignore')) end
  )

  it(
    'leaves a file named ignore outside .git alone',
    function() assert.is_nil(match('/p/docs/ignore')) end
  )

  it(
    'leaves a plain HTML file outside templates alone',
    function() assert.are.equal('html', match('/p/static/index.html')) end
  )

  describe('within a project', function()
    local dir, cleanup
    before_each(function()
      dir, cleanup = h.tmpdir()
    end)
    after_each(function() cleanup() end)

    ---@param files string[] Files to create, relative to the project
    ---@param path string
    local function match_in(files, path)
      for _, file in ipairs(files) do
        vim.fn.mkdir(vim.fs.dirname(dir .. '/' .. file), 'p')
        vim.fn.writefile({}, dir .. '/' .. file)
      end
      return match(dir .. '/' .. path)
    end

    local anchored = {
      { { 'root.hcl' }, 'live/vpc.hcl', 'terragrunt' },
      { {}, 'live/vpc.hcl', 'hcl' },
      { { 'root.hcl' }, '.terraform.lock.hcl', 'hcl' },
      { { 'root.hcl' }, 'build.pkr.hcl', 'hcl' },
      { { 'ansible.cfg' }, 'playbook-site.yml', 'yaml.ansible' },
      { { 'ansible.cfg' }, 'roles/web/defaults/main.yml', 'yaml.ansible' },
      {
        { 'roles/web/tasks/main.yml' },
        'roles/web/defaults/x.yml',
        'yaml.ansible',
      },
      { {}, 'pipeline/tasks/build.yaml', 'yaml' },
      { { 'manage.py' }, 'app/templates/index.html', 'htmldjango' },
      { { 'go.mod' }, 'web/templates/index.html', 'html' },
      { { 'manage.py' }, 'templates/app.component.html', 'htmlangular' },
      { { 'chart/Chart.yaml' }, 'chart/templates/_helpers.tpl', 'helm' },
      { { 'chart/Chart.yaml' }, 'chart/templates/deployment.yaml', 'helm' },
      { {}, 'deploy/templates/pipeline.yaml', 'yaml' },
      { { 'chart/Chart.yaml' }, 'chart/values-prod.yaml', 'yaml.helm-values' },
      { { 'helmfile.yaml' }, 'env/values.yaml', 'yaml.helm-values' },
      { {}, 'overlays/values.yaml', 'yaml' },
    }
    for _, case in ipairs(anchored) do
      local files, path, ft = case[1], case[2], case[3]
      it(
        path .. ' beside ' .. vim.inspect(files) .. ' is ' .. ft,
        function() assert.are.equal(ft, match_in(files, path)) end
      )
    end

    it('reads a shell .install file as sh.install', function()
      local path = dir .. '/foo.install'
      vim.fn.writefile({ 'post_install() {', '}' }, path)
      vim.cmd.edit(path)
      assert.are.equal('sh.install', vim.bo.filetype)
      vim.cmd('bwipeout!')
    end)

    it('keeps a PHP .install file as PHP', function()
      local path = dir .. '/mod.install'
      vim.fn.writefile({ '<?php' }, path)
      vim.cmd.edit(path)
      assert.are.equal('php', vim.bo.filetype)
      vim.cmd('bwipeout!')
    end)
  end)

  it(
    'gives every filetype it adds to a language of the configuration',
    function()
      local known = {}
      for _, spec in pairs(require('config.languages')) do
        for _, ft in ipairs(spec.filetypes) do
          known[ft] = true
        end
      end
      -- Filetypes only detected for plugins of their own, with no tooling
      local unclaimed =
        { rasi = true, snippets = true, dbml = true, ipynb = true }
      for _, case in ipairs(cases) do
        local ft = case[2]
        assert(known[ft] or unclaimed[ft], ft .. ' belongs to no language')
      end
    end
  )
end)
