--- What counts as sensitive: files whose content must never reach an AI
--- service. The checks that read these lists live in `util.sensitive`.
--- At least 20 characters of `class`: a real token is longer, while
--- `hf_hub_download` or `$npm_package_version` is ordinary code that a bare
--- prefix would hold back from every AI integration
---@param class string
---@return string
local function token(class) return class:rep(20) end

---@class DySensitiveConfig
return {
  --- Lua patterns matched against the lower-cased file name alone: macOS
  --- names `ID_RSA` and `id_rsa` the same file. Written in lower case.
  ---@type string[]
  name_patterns = {
    '%.env$', -- dotenv: `.env`, `prod.env`, and `.env.local`, `.env.test`, ...
    '^%.env%.',
    '^%.envrc$', -- direnv
    '%.age$', -- age-encrypted secrets
    '%.gpg$',
    '%.pem$', -- keys and certificates
    '%.key$',
    '%.p12$',
    '%.pfx$',
    '^id_[%w_-]+$', -- ssh keys (`id_rsa`, `id_ed25519`, ...)
    '^%.netrc$',
    '^_netrc$',
    '^%.pgpass$',
    '^%.git%-credentials$',
    '^%.npmrc$', -- package registry tokens
    '^%.pypirc$',
    '^%.vault%-token$',
    '^%.gitlab%.nvim$', -- gitlab.nvim's `auth_token=` file
    '%.ppk$', -- PuTTY keys
    '%.p8$', -- PKCS#8 keys (App Store Connect, APNs)
    '%.jks$', -- Java keystores
    '%.keystore$',
    '%.kdbx$', -- KeePass databases
    '^%.htpasswd$',
    '^kubeconfig$', -- cluster credentials outside `~/.kube`
    '^kubeconfig%.ya?ml$',
    '%.kubeconfig$',
    '^application_default_credentials%.json$', -- gcloud
    '^credentials%.tfrc%.json$', -- Terraform Cloud token
    -- Terraform state holds every secret of what it manages in clear text.
    -- `*.tfvars` is left to the content rules: it is as often a committed
    -- list of sizes and regions, and a name rule cannot be waived.
    '%.tfstate$',
    '%.tfstate%.backup$',
  },
  --- Lua patterns matched against the end of the lower-cased full path, for
  --- files whose name alone is too common to hold back
  ---@type string[]
  path_patterns = {
    '/%.cargo/credentials%.toml$',
    '/%.cargo/credentials$',
    '/%.gem/credentials$',
  },
  --- Directory names: every file below one of them is sensitive, whatever it
  --- is called, because they hold credentials under ordinary names (`config`,
  --- `credentials`, `data/...`). Keys are lower case and matched against the
  --- lower-cased name, the directory itself included.
  ---@type table<string, boolean>
  dirs = {
    ['.password-store'] = true,
    ['.ssh'] = true,
    ['.gnupg'] = true,
    ['.aws'] = true,
    ['.kube'] = true,
    ['.docker'] = true,
    ['secrets'] = true,
  },
  --- Directories sensitive by where they are, checked by full path so they
  --- stay covered whatever becomes of the name rules above. `secrets/data` is
  --- the Dotfiles submodule of live credentials, and a clone of it (a
  --- worktree, a checkout elsewhere) is caught by the name rules instead.
  ---@type string[]
  paths = {
    vim.fs.joinpath(vim.env.HOME, 'Dotfiles', 'secrets', 'data'),
  },
  --- Filetypes sensitive by content rather than by path. A commit message
  --- buffer carries the staged diff as well under `git commit --verbose`, and
  --- that diff can be the very secret being committed.
  ---@type string[]
  filetypes = {
    'gitcommit',
  },
  --- Credentials recognised by what they look like, for the file the name
  --- rules cannot know about: a scratch buffer, a YAML of deployment values,
  --- a log pasted into a code file. A match holds the whole buffer back from
  --- every AI integration, so each pattern is written to recognise a token
  --- format and nothing else -- `AKIA...`, `ghp_...`, a PEM header. Anything
  --- vaguer (`password = ...`) would turn the guard off by crying wolf.
  ---
  --- The breadth is `betterleaks`' job: it lints every buffer with a rule set
  --- far larger than this one, and `util.sensitive` holds a buffer back on
  --- its findings too. These patterns are the half that answers the instant a
  --- key is pressed, before the linter has run and on a machine where it is
  --- not installed.
  ---
  --- `name` is what the report says a buffer was held back for. `pattern` is
  --- a Lua pattern, matched line by line.
  ---@type { name: string, pattern: string }[]
  content_patterns = {
    { name = 'private key block', pattern = 'BEGIN [%u ]*PRIVATE KEY' },
    -- The same block in base64, as a Kubernetes Secret or a kubeconfig's
    -- `client-key-data` holds it: `-----BEGIN ` and then ` PRIVATE K` at each
    -- of the three offsets base64 can put it at. A base64 certificate
    -- (`certificate-authority-data`) is public and matches none of them.
    {
      name = 'base64 private key',
      pattern = 'LS0tLS1CRUdJTi[%w+/]-UFJJVkFURSBL',
    },
    {
      name = 'base64 private key',
      pattern = 'LS0tLS1CRUdJTi[%w+/]-QUklWQVRF',
    },
    {
      name = 'base64 private key',
      pattern = 'LS0tLS1CRUdJTi[%w+/]-SVZBVEUg',
    },
    { name = 'age secret key', pattern = 'AGE%-SECRET%-KEY%-1[%u%d]+' },
    { name = 'AWS access key', pattern = 'A[KS]IA[%u%d][%u%d][%u%d][%u%d]+' },
    { name = 'GitHub token', pattern = '%f[%w]gh[pousr]_' .. token('%w') },
    { name = 'GitHub token', pattern = 'github_pat_[%w_]+' },
    { name = 'GitLab token', pattern = 'glpat%-[%w%-_]+' },
    { name = 'Slack token', pattern = 'xox[abprs]%-[%w%-]+' },
    { name = 'Slack webhook', pattern = 'hooks%.slack%.com/services/' },
    { name = 'Anthropic API key', pattern = 'sk%-ant%-[%w%-]+' },
    { name = 'OpenAI API key', pattern = 'sk%-proj%-[%w%-_]+' },
    { name = 'Google API key', pattern = '%f[%w]AIza' .. token('[%w%-_]') },
    { name = 'npm token', pattern = '%f[%w]npm_' .. token('%w') },
    { name = 'PyPI token', pattern = 'pypi%-AgE[%w%-_]+' },
    { name = 'Hugging Face token', pattern = '%f[%w]hf_' .. token('%w') },
    { name = 'Stripe key', pattern = '%f[%w][sr]k_live_' .. token('%w') },
    -- `header.payload.` of a JSON Web Token: both halves start from the
    -- base64 of `{"`, which is what makes this worth matching at all.
    { name = 'JSON Web Token', pattern = 'eyJ[%w%-_]+%.eyJ[%w%-_]+%.' },
    -- `scheme://user:password@host`
    { name = 'password in a URL', pattern = '://[%w%._%-]+:[^@/%s]+@' },
  },
  --- Names of the values worth hiding on screen, as Lua patterns matched
  --- against the lower-cased key
  ---
  --- The other half of the same question: `content_patterns` recognises a
  --- credential by the shape of its value, this one by what the value is
  --- called. `camouflage.nvim` masks a value whose key matches, so a
  --- Kubernetes manifest stays readable while its `password:` does not, and
  --- `util.sensitive.is_secret_key` is where it asks.
  ---@type string[]
  key_patterns = {
    'password',
    'passwd',
    'passphrase',
    'secret',
    'token',
    'credential',
    'api[_%-]*key',
    'access[_%-]*key',
    'private[_%-]*key',
  },
  --- The largest buffer searched for the patterns above. A bigger one is
  --- not searched, which would hold up the editor on a log of a few hundred
  --- megabytes, and is held back unless waived: what is not searched could
  --- hold a key.
  ---@type integer
  content_max_bytes = 2 * 1024 * 1024,
}
