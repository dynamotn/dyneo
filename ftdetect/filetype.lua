--- A filetype for files under a project that `markers` identify, upward
--- from the file. A broad path such as `*/templates/*.yaml` names a Helm
--- template only in a chart; anywhere else Neovim's own detection applies.
---@param filetype string
---@param markers string[]
---@return fun(path: string): string?
local function within(filetype, markers)
  return function(path)
    if vim.fs.root(path, markers) then return filetype end
  end
end

-- A bare `roles/` folder is no marker: Kubernetes RBAC keeps one too. The
-- folders of a role are matched by their own patterns below.
local ansible = within('yaml.ansible', {
  'ansible.cfg',
  '.ansible-lint',
  'galaxy.yml',
  'molecule',
})
local helm = within('helm', { 'Chart.yaml' })

--- A filetype for a file whose first lines hold one of `keys`: a name such as
--- `openapi*.json` is shared by `openapitools.json` and the generator's
--- config, and only the document itself starts with `openapi:` or `swagger:`
---@param filetype string
---@param keys string[] Lua patterns, one per line
---@return fun(path: string, bufnr?: integer): string?
local function declaring(filetype, keys)
  return function(_, bufnr)
    if not bufnr then return end
    for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, 20, false)) do
      for _, key in ipairs(keys) do
        if line:find(key) then return filetype end
      end
    end
  end
end

vim.filetype.add({
  extension = {
    envrc = 'sh',
    ino = 'arduino',
    pde = 'arduino',
    gotmpl = 'gotmpl',
    rasi = 'rasi',
    rofi = 'rasi',
    wofi = 'rasi',
    ebuild = 'sh.ebuild',
    eclass = 'sh.eclass',
    -- Neovim's own check for a PHP `.install` file (Drupal) comes first
    install = function(_, bufnr)
      local first = bufnr and vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
      if first and first:lower():find('<%?php') then return 'php' end
      return 'sh.install'
    end,
    promql = 'promql',
    bean = 'beancount',
    -- LikeC4 models; `.dsl`, Structurizr's, Neovim already knows
    c4 = 'likec4',
    likec4 = 'likec4',
    snippets = 'snippets',
    dbml = 'dbml',
    d2 = 'd2',
    ipynb = 'ipynb',
    -- Neovim knows `.tsv` and `.jsonl` already, not these two spellings
    psv = 'psv',
    ndjson = 'jsonl',
    nf = 'nextflow',
    j2 = 'jinja',
    jinja = 'jinja',
    jinja2 = 'jinja',
    djhtml = 'htmldjango',
    -- A code scanner's report, see `:DySarif`
    sarif = 'json',
    -- Markdown with JSX, which Neovim leaves without a filetype
    mdx = 'markdown.mdx',
  },
  filename = {
    ['terragrunt.hcl'] = 'terragrunt',
    ['azure-pipelines.yml'] = 'yaml.az-pl',
    ['docker-compose.yml'] = 'yaml.docker-compose',
    ['docker-compose.yaml'] = 'yaml.docker-compose',
    ['compose.yml'] = 'yaml.docker-compose',
    ['compose.yaml'] = 'yaml.docker-compose',
    ['PKGBUILD'] = 'sh.PKGBUILD',
    ['nextflow.config'] = 'nextflow',
  },
  pattern = {
    -- An `ignore` file kept in a repository's `.git` directory. A `filename`
    -- key is matched only against the full path and the tail, so one with a
    -- slash in it never matches, and this takes a pattern instead. git's
    -- per-user ignore file, `$XDG_CONFIG_HOME/git/ignore`, Neovim detects
    -- on its own.
    ['.*/%.git/ignore'] = 'gitignore',

    -- The `.hcl` files a Terragrunt tree shares (`env.hcl`, `account.hcl`)
    -- under its `root.hcl`. Packer, Nomad and the Terraform lock file keep
    -- Neovim's `hcl`.
    ['.*%.hcl'] = function(path)
      local name = vim.fs.basename(path)
      if name == '.terraform.lock.hcl' or name:find('%.pkr%.hcl$') then
        return
      end
      if vim.fs.root(path, { 'root.hcl', 'terragrunt.hcl' }) then
        return 'terragrunt'
      end
    end,

    ['.*/defaults/.*%.ya?ml'] = ansible,
    ['.*/host_vars/.*%.ya?ml'] = 'yaml.ansible',
    ['.*/group_vars/.*%.ya?ml'] = 'yaml.ansible',
    ['.*/group_vars/.*/.*%.ya?ml'] = 'yaml.ansible',
    ['.*/playbook.*%.ya?ml'] = ansible,
    ['.*/playbooks/.*%.ya?ml'] = 'yaml.ansible',
    ['.*/roles/.*/tasks/.*%.ya?ml'] = 'yaml.ansible',
    ['.*/roles/.*/handlers/.*%.ya?ml'] = 'yaml.ansible',
    ['.*/roles/[^/]+/defaults/.*%.ya?ml'] = 'yaml.ansible',
    ['.*/roles/[^/]+/vars/.*%.ya?ml'] = 'yaml.ansible',
    ['.*/roles/[^/]+/meta/.*%.ya?ml'] = 'yaml.ansible',
    ['.*/tasks/.*%.ya?ml'] = ansible,
    ['.*/molecule/.*%.ya?ml'] = 'yaml.ansible',

    ['openapi.*%.ya?ml'] = declaring(
      'yaml.openapi',
      { '^openapi%s*:', '^swagger%s*:' }
    ),
    ['openapi.*%.json'] = declaring(
      'json.openapi',
      { '"openapi"%s*:', '"swagger"%s*:' }
    ),

    ['.*%.gitlab%-ci%.ya?ml'] = 'yaml.gitlab',
    ['.*%.github/workflows/.*%.ya?ml'] = 'yaml.gh-action',
    ['.*%.forgejo/workflows/.*%.ya?ml'] = 'yaml.gh-action',
    ['.*%.gitea/workflows/.*%.ya?ml'] = 'yaml.gh-action',

    -- Ahead of the `templates/` rule below, which can match the same file
    ['.*%.component%.html'] = { 'htmlangular', { priority = 10 } },
    ['.*%.container%.html'] = { 'htmlangular', { priority = 10 } },

    ['.*%.tmpl'] = 'gotmpl',

    -- where Django (or Flask, with Jinja) keeps its templates; a plain HTML
    -- file elsewhere, or a Go `html/template`, is untouched
    ['.*/templates/.*%.html'] = within('htmldjango', {
      'manage.py',
      'pyproject.toml',
      'setup.py',
      'requirements.txt',
    }),

    ['.*/templates/.*%.tpl'] = helm,
    ['.*/templates/.*%.ya?ml'] = helm,
    ['helmfile.*%.ya?ml'] = 'helm',
    -- The values of a chart, or of the releases a helmfile deploys; any other
    -- `values.yaml` (Kustomize, Argo CD, an app's own) stays plain YAML
    ['values.*%.ya?ml'] = within('yaml.helm-values', {
      'Chart.yaml',
      'helmfile.yaml',
      'helmfile.yml',
      'helmfile.d',
    }),

    ['.*/hypr/.*%.conf'] = 'hyprlang',

    ['Dockerfile-.*'] = 'dockerfile',
  },
})
