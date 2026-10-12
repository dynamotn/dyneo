return {
  {
    -- For gentoo filetypes
    'gentoo/gentoo-syntax',
    -- Its `ftdetect/`, `syntax/` and `ftplugin/` are all it is, and lazy.nvim
    -- sources none of them for a plugin that never loads: no `ft` can name
    -- the filetypes it is the one to detect
    lazy = false,
    -- Off Gentoo it claims every `metadata.xml` as `gentoo-metadata` and drops
    -- Gentoo skeletons into new `metadata.xml` and `files/*.init` files.
    -- `cond`, not `enabled`, so it stays installed and in the lockfile.
    cond = vim.uv.fs_stat('/etc/gentoo-release') ~= nil,
    -- Its `*.ebuild` autocmd sets `ebuild` outright, over the `sh.ebuild` of
    -- `ftdetect/filetype.lua` that the Bash parser and servers are given;
    -- its syntax and ftplugin still load, as half of `sh.ebuild`
    config = function()
      vim.api.nvim_clear_autocmds({
        group = 'filetypedetect',
        event = { 'BufNewFile', 'BufRead' },
        pattern = '*.e{build,class}',
      })
    end,
  },
  {
    -- Comment strings by treesitter language, for files mixing several of
    -- them, and uncommenting that takes any of a language's styles
    'folke/ts-comments.nvim',
    event = 'VeryLazy',
    opts = {},
  },
}
