return {
  {
    -- For gentoo filetypes
    'gentoo/gentoo-syntax',
    -- Its `ftdetect/`, `syntax/` and `ftplugin/` are all it is, and lazy.nvim
    -- sources none of them for a plugin that never loads: no `ft` can name
    -- the filetypes it is the one to detect
    lazy = false,
  },
  {
    -- Comment strings by treesitter language, for files mixing several of
    -- them, and uncommenting that takes any of a language's styles
    'folke/ts-comments.nvim',
    event = 'VeryLazy',
    opts = {},
  },
}
