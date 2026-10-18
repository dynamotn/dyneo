#!/usr/bin/env bash
# @file coverage.sh
# @brief Run the unit tests under luacov and write an lcov report
# @description
#   Runs scripts/test.sh with `DYNEO_COVERAGE` set, so that every spec's
#   Neovim counts the lines it runs into one fresh stats file, then has
#   scripts/coverage.lua turn the stats into `.tests/coverage/lcov.info` and
#   print the totals. CI uploads that file to Coveralls.
#
#     scripts/coverage.sh                       # every spec
#     scripts/coverage.sh tests/spec/util       # one directory
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
stats="${repo}/.tests/coverage/luacov.stats.out"

# A count left by an earlier run would be added to this one
rm -f "${stats}"
DYNEO_COVERAGE=1 "${repo}/scripts/test.sh" "$@"
exec nvim --clean --headless -l "${repo}/scripts/coverage.lua"
