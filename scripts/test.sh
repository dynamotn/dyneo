#!/usr/bin/env bash
# @file test.sh
# @brief Run the unit tests under tests/spec
# @description
#   Runs the specs with plenary-busted in a headless Neovim that loads nothing
#   of this configuration but the modules each spec requires.
#
#     scripts/test.sh                       # every spec
#     scripts/test.sh tests/spec/util       # one directory
#     scripts/test.sh tests/spec/util/sensitive_spec.lua
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
init="${repo}/tests/minimal_init.lua"
target="${1:-${repo}/tests/spec}"

if ! command -v nvim &> /dev/null; then
  echo "test: nvim not found" >&2
  exit 1
fi

# GNU `realpath` resolves a missing last component, and plenary passes a
# directory with no spec in it: a mistyped path would read as a green run.
if [[ ! -e "${target}" ]]; then
  echo "test: no such spec ${target}" >&2
  exit 1
fi
# Absolute before the `cd` below, so a path relative to where this was run
# from still names the same spec
target="$(realpath "${target}")"
if [[ -d "${target}" ]]; then
  spec="$(find "${target}" -name '*_spec.lua' -print -quit)"
  if [[ -z "${spec}" ]]; then
    echo "test: no *_spec.lua under ${target}" >&2
    exit 1
  fi
fi

cd "${repo}"
# The paths reach Lua through the environment, not pasted into a string, so a
# quote in one cannot end it early.
export DYNEO_TEST_TARGET="${target}" DYNEO_TEST_INIT="${init}"
if [[ -f "${target}" ]]; then
  # Run in this very Neovim, which has loaded minimal_init.lua already;
  # `PlenaryBustedFile` would start a child without it.
  command="lua require('plenary.busted').run(vim.env.DYNEO_TEST_TARGET)"
else
  options="{minimal_init = vim.env.DYNEO_TEST_INIT, sequential = true, timeout = 60000}"
  command="lua require('plenary.test_harness').test_directory(vim.env.DYNEO_TEST_TARGET, ${options})"
fi
exec nvim --headless --noplugin -i NONE -u "${init}" -c "${command}" < /dev/null
