#!/usr/bin/env bash
# @file keymaps-doc.sh
# @brief Regenerate doc/dyneo-keymaps.txt
# @description
#   Loads this tree in a headless Neovim through keymaps-doc.lua, which writes
#   every mapping it sets into the help file, then refreshes the help tags.
#   Neovim is pointed at this tree rather than at `$HOME`, as check-startup.sh
#   does, so the file follows what is about to be committed.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT
mkdir -p "${workdir}/config"
ln -s "${repo}" "${workdir}/config/${NVIM_APPNAME:-nvim}"

# Only keymaps-doc.lua quits Neovim: an error before it gets there would leave
# the hook waiting for ever
XDG_CONFIG_HOME="${workdir}/config" timeout --kill-after=10 300 nvim --headless -i NONE \
  --cmd "luafile ${repo}/scripts/keymaps-doc.lua" < /dev/null
# Ex mode, so a bad tag fails the script: an error in `-c` leaves exit 0
nvim --headless -u NONE -es +"helptags ${repo}/doc" +q
