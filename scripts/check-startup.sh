#!/usr/bin/env bash
# @file check-startup.sh
# @brief Load the configuration in a throwaway Neovim and fail on any error
# @description
#   Opens a file of each language in it (see check-startup.lua).
#
# By default a spread of languages is opened, to keep the pre-commit hook
# quick; `CHECK_STARTUP_ALL=1` opens every one of them, as CI does.
# `CHECK_STARTUP_TIMEOUT` is how many seconds Neovim gets before it is killed
# (900 by default).
#
# The unit tests (scripts/test.sh) load modules one at a time, so a syntax
# error or a bad `require` in the wiring between them is only found by opening
# the editor -- and in a chezmoi `mode: symlink` setup that is the real editor,
# already broken. Neovim is pointed at this tree
# rather than at `$HOME`, so the check reads what is about to be committed and
# not what was applied last time.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v nvim &> /dev/null; then
  echo "check-startup: nvim not found, skipping" >&2
  exit 0
fi

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT
mkdir -p "${workdir}/config"
ln -s "${repo}" "${workdir}/config/${NVIM_APPNAME:-nvim}"

output="${workdir}/output.txt"
set +e
# The Lua file quits on its own once it is done. `cquit` is only reached when
# it failed before that, which would otherwise leave Neovim waiting for input
# that never comes; stdin is closed for the same reason.
# Run from the scratch directory: a server with no project marker to go by
# (clojure-lsp) takes the working directory as its root, and leaves its cache
# there. Every file is opened by an absolute path.
# An error echoed while `init.lua` loads can still leave a headless Neovim
# waiting, deaf to SIGTERM: `timeout` sends SIGKILL after a grace period.
(
  cd "${workdir}" \
    && XDG_CONFIG_HOME="${workdir}/config" CHECK_STARTUP_WORKDIR="${workdir}" \
      timeout --kill-after=10 "${CHECK_STARTUP_TIMEOUT:-900}" \
      nvim --headless -i NONE \
      --cmd "luafile ${repo}/scripts/lib/notify-watch.lua" \
      -c "luafile ${repo}/scripts/check-startup.lua" -c 'cquit' \
      < /dev/null &> "${output}"
)
status=$?
set -e

# Neovim reports a broken configuration on stderr and still exits 0, so the
# output has to be looked at as well as the exit code.
if [[ ${status} -eq 124 || ${status} -eq 137 ]]; then
  echo "check-startup: Neovim did not quit within ${CHECK_STARTUP_TIMEOUT:-900}s" >&2
fi
if [[ ${status} -ne 0 ]] || grep -qE '^(E[0-9]+:|Error)' "${output}"; then
  echo "check-startup: the configuration failed to load" >&2
  cat "${output}" >&2
  exit 1
fi
# What was opened and what would have been installed, for a log to show.
grep '^check-startup:' "${output}" || true
