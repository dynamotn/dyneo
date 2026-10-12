-- Mason's own package, with the `yls` server of nvim-lspconfig named, which
-- upstream leaves out, so mason-lspconfig installs it for a YARA rule
return {
  name = 'yls-yara',
  description = 'Language server for the YARA language.',
  homepage = 'https://avast.github.io/yls/',
  licenses = {
    'MIT',
  },
  languages = {
    'YARA',
  },
  categories = {
    'LSP',
  },
  source = {
    id = 'pkg:pypi/yls-yara@1.4.4',
    supported_platforms = { 'linux', 'win' },
  },
  bin = {
    yls = 'pypi:yls',
  },
  neovim = {
    lspconfig = 'yls',
  },
}
