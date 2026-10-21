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
  # A check that cannot run must not read as one that passed
  echo "check-startup: nvim not found" >&2
  exit 1
fi

# GNU `timeout`, which stock macOS lacks; Homebrew's coreutils names it
# `gtimeout`
if command -v timeout &> /dev/null; then
  timeout_bin=timeout
elif command -v gtimeout &> /dev/null; then
  timeout_bin=gtimeout
else
  echo "check-startup: needs timeout or gtimeout (GNU coreutils)" >&2
  exit 1
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
# The scripts are named through the environment and `fnameescape`, so a
# checkout under a path with a space still loads them.
# mise reads its global versions under the real config home: without them its
# shims (the `go` gopls runs) have no version to run.
mise_config="${MISE_CONFIG_DIR:-${XDG_CONFIG_HOME:-${HOME}/.config}/mise}"
(
  cd "${workdir}" \
    && MISE_CONFIG_DIR="${mise_config}" \
      XDG_CONFIG_HOME="${workdir}/config" CHECK_STARTUP_WORKDIR="${workdir}" \
      CHECK_STARTUP_REPO="${repo}" \
      "${timeout_bin}" --kill-after=10 "${CHECK_STARTUP_TIMEOUT:-900}" \
      nvim --headless -i NONE \
      --cmd 'exe "luafile" fnameescape(getenv("CHECK_STARTUP_REPO") .. "/scripts/lib/notify-watch.lua")' \
      -c 'exe "luafile" fnameescape(getenv("CHECK_STARTUP_REPO") .. "/scripts/check-startup.lua")' \
      -c 'cquit' \
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
# Not anchored: a plugin's message without a newline can run into a line.
grep -o 'check-startup: .*' "${output}" || true
