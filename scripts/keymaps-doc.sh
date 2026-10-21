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
# GNU `timeout`, which stock macOS lacks; Homebrew's coreutils names it
# `gtimeout`
if command -v timeout &> /dev/null; then
  timeout_bin=timeout
elif command -v gtimeout &> /dev/null; then
  timeout_bin=gtimeout
else
  echo "keymaps-doc: needs timeout or gtimeout (GNU coreutils)" >&2
  exit 1
fi

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT
mkdir -p "${workdir}/config"
ln -s "${repo}" "${workdir}/config/${NVIM_APPNAME:-nvim}"

# Only keymaps-doc.lua quits Neovim: an error before it gets there would leave
# the hook waiting for ever
# The paths go through the environment and `fnameescape`, for a checkout
# under a path with a space
XDG_CONFIG_HOME="${workdir}/config" KEYMAPS_DOC_REPO="${repo}" \
  "${timeout_bin}" --kill-after=10 90 nvim --headless -i NONE \
  --cmd 'exe "luafile" fnameescape(getenv("KEYMAPS_DOC_REPO") .. "/scripts/ci-trace.lua")' \
  --cmd 'exe "luafile" fnameescape(getenv("KEYMAPS_DOC_REPO") .. "/scripts/keymaps-doc.lua")' \
  < /dev/null
# Ex mode, so a bad tag fails the script: an error in `-c` leaves exit 0
KEYMAPS_DOC_REPO="${repo}" nvim --headless -u NONE -es \
  +'exe "helptags" fnameescape(getenv("KEYMAPS_DOC_REPO") .. "/doc")' +q
