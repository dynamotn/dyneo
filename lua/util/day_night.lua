--- Follow the clock with the background, and the colorscheme with it
---
--- Catppuccin is set to `flavour = 'auto'`, which means it reads
--- `vim.o.background` while it loads and picks latte or macchiato from it.
--- So the whole job here is to keep that one option honest: work out whether
--- it is day, set it, and ask for the colorscheme again when the answer
--- changes. `DyNeo.dark_mode` stays the manual override it always was -- with
--- `DyNeo.day_night.enabled` off, it is the only thing consulted.

local M = {}

---@type uv.uv_timer_t? Kept so a second `setup()` does not leave two running
local timer

--- Whether the given hour falls in the dark half of the day
---@param hour integer 0-23
---@return boolean
function M.is_dark(hour)
  local day_start, night_start =
    DyNeo.day_night.day_start, DyNeo.day_night.night_start
  if day_start == night_start then return true end
  if day_start < night_start then
    return hour < day_start or hour >= night_start
  end
  -- A light stretch that runs past midnight, e.g. 22:00 to 06:00
  return hour >= night_start and hour < day_start
end

--- Resolve `DyNeo.dark_mode` and put it on `vim.o.background`
---
--- Called once from `config.options`, before any plugin has loaded, so that
--- the colorscheme comes up in the right half straight away instead of
--- flipping a moment later.
function M.init()
  if DyNeo.day_night.enabled then
    DyNeo.dark_mode = M.is_dark(tonumber(os.date('%H')) --[[@as integer]])
  end
  local background = DyNeo.dark_mode and 'dark' or 'light'
  -- Setting it at all fires `OptionSet` and redraws, even to the same value
  if vim.o.background ~= background then vim.o.background = background end
end

--- Re-resolve, and reload the colorscheme if the half of the day changed
function M.apply()
  local was = vim.o.background
  M.init()
  if vim.o.background == was then return end
  -- The flavour is chosen while the colorscheme loads, so a new background
  -- only reaches the highlights by loading it again.
  pcall(vim.cmd.colorscheme, require('config.defaults').colorscheme)
end

--- Start watching the clock
---
--- `enabled` is read once, here: a `per_machine` that pins `DyNeo.dark_mode`
--- turns this off and nothing below ever runs.
function M.setup()
  if not DyNeo.day_night.enabled then return end

  if timer then
    timer:stop()
    timer:close()
  end
  timer = vim.uv.new_timer()
  local interval = 60 * 1000
  timer:start(interval, interval, vim.schedule_wrap(M.apply))

  -- A laptop that slept through sunset wakes with yesterday's background,
  -- and the timer does not fire while it is suspended.
  vim.api.nvim_create_autocmd({ 'FocusGained', 'VimResume' }, {
    group = vim.api.nvim_create_augroup('dy_day_night', { clear = true }),
    desc = 'Re-check the time of day',
    callback = function() vim.schedule(M.apply) end,
  })
end

return M
