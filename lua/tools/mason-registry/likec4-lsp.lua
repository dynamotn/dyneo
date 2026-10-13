return {
  name = 'likec4-lsp',
  description = 'Language server of LikeC4, architecture as code.',
  homepage = 'https://likec4.dev',
  licenses = {
    'MIT',
  },
  languages = {
    'LikeC4',
  },
  categories = {
    'LSP',
  },
  source = {
    id = 'pkg:npm/%40likec4/lsp@1.59.4',
  },
  bin = {
    ['likec4-lsp'] = 'npm:likec4-lsp',
  },
  neovim = {
    lspconfig = 'likec4',
  },
}
