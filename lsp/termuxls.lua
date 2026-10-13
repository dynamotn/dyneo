return {
  cmd = { 'termux-language-server' },
  -- The dialects `ftdetect/filetype.lua` gives a file
  filetypes = {
    -- ArchLinux/Windows Msys2
    'sh.PKGBUILD', -- PKGBUILD
    'sh.install', -- *.install
    -- Gentoo
    'sh.ebuild', -- *.ebuild
    'sh.eclass', -- *.eclass
  },
  root_markers = {
    'build.sh',
    'PKGBUILD',
    'makepkg.conf',
    'make.conf',
    '.git',
  },
}
