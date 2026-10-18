-- Record every error notification from the very start, for
-- `scripts/check-startup.lua`
--
-- `check-startup.sh` loads this with `--cmd`, ahead of `init.lua`: the check
-- itself only runs once the configuration has loaded, and an error raised
-- before then -- `per_machine` failing, lazy.nvim's "Failed to run `config`"
-- for a plugin that loads at startup -- would reach a notifier that has no UI
-- to draw on, and be lost.
--
-- Plugins swap `vim.notify` out as they load, so the wrapper is put back on
-- top after each file sourced and each `User` event (`LazyDone`, `VeryLazy`).
--
-- An error is kept, not passed on: headless, the notifier echoes it on
-- stderr as `Error ...`, which `check-startup.sh` reads as the configuration
-- failing, while the check excuses one about a tool whose install it skipped
-- itself. The check prints the ones that stand, under the same `Error:`.

_G._dy_check_errors = _G._dy_check_errors or {}

local function wrap()
  local current = vim.notify
  if rawequal(current, _G._dy_check_notify) then return end
  _G._dy_check_notify = function(msg, level, opts)
    if (level or vim.log.levels.INFO) >= vim.log.levels.ERROR then
      table.insert(_G._dy_check_errors, tostring(msg))
      return
    end
    return current(msg, level, opts)
  end
  vim.notify = _G._dy_check_notify
end

wrap()
vim.api.nvim_create_autocmd({ 'SourcePost', 'User', 'VimEnter' }, {
  group = vim.api.nvim_create_augroup('dy_check_notify', { clear = true }),
  callback = function() wrap() end,
})
