local h = require('helpers')

describe('util.day_night', function()
  local day_night, restore

  before_each(function()
    h.unload('util.day_night')
    day_night = require('util.day_night')
    restore = {
      h.stub(
        DyNeo,
        'day_night',
        { enabled = false, day_start = 6, night_start = 18 }
      ),
      h.stub(DyNeo, 'dark_mode', true),
    }
  end)
  after_each(function()
    for _, undo in ipairs(restore) do
      undo()
    end
    pcall(vim.api.nvim_del_augroup_by_name, 'dy_day_night')
  end)

  describe('is_dark', function()
    it('is dark before the day starts and from the night on', function()
      assert.is_true(day_night.is_dark(0))
      assert.is_true(day_night.is_dark(5))
      assert.is_false(day_night.is_dark(6))
      assert.is_false(day_night.is_dark(17))
      assert.is_true(day_night.is_dark(18))
      assert.is_true(day_night.is_dark(23))
    end)

    it('is always dark when both hours are the same', function()
      DyNeo.day_night.day_start, DyNeo.day_night.night_start = 8, 8
      for hour = 0, 23 do
        assert.is_true(day_night.is_dark(hour))
      end
    end)

    it('handles a light stretch running past midnight', function()
      DyNeo.day_night.day_start, DyNeo.day_night.night_start = 22, 6
      assert.is_false(day_night.is_dark(23))
      assert.is_false(day_night.is_dark(3))
      assert.is_true(day_night.is_dark(6))
      assert.is_true(day_night.is_dark(12))
      assert.is_true(day_night.is_dark(21))
      assert.is_false(day_night.is_dark(22))
    end)
  end)

  describe('init', function()
    it('follows DyNeo.dark_mode when disabled', function()
      DyNeo.dark_mode = false
      day_night.init()
      assert.equals('light', vim.o.background)
      DyNeo.dark_mode = true
      day_night.init()
      assert.equals('dark', vim.o.background)
    end)

    it('leaves the background alone when it is already right', function()
      DyNeo.dark_mode = true
      day_night.init()
      -- Setting it at all redraws and fires `OptionSet`, so count the sets
      local sets, options = 0, vim.o
      local undo = h.stub(
        vim,
        'o',
        setmetatable({}, {
          __index = options,
          __newindex = function(_, key, value)
            sets = sets + 1
            options[key] = value
          end,
        })
      )
      day_night.init()
      undo()
      assert.equals(0, sets)
    end)

    it('lets the clock decide when enabled', function()
      DyNeo.day_night.enabled = true
      local hour = tonumber(os.date('%H'))
      -- Make the current hour light, then dark.
      DyNeo.day_night.day_start, DyNeo.day_night.night_start =
        hour, (hour + 1) % 24
      DyNeo.dark_mode = true
      day_night.init()
      assert.is_false(DyNeo.dark_mode)
      assert.equals('light', vim.o.background)

      DyNeo.day_night.day_start, DyNeo.day_night.night_start = hour, hour
      day_night.init()
      assert.is_true(DyNeo.dark_mode)
      assert.equals('dark', vim.o.background)
    end)
  end)

  describe('apply', function()
    local colorscheme, calls
    before_each(function()
      calls = 0
      package.loaded['config.defaults'] = { colorscheme = 'test-scheme' }
      colorscheme = h.stub(
        vim.cmd,
        'colorscheme',
        function() calls = calls + 1 end
      )
    end)
    after_each(function()
      colorscheme()
      package.loaded['config.defaults'] = nil
    end)

    it('reloads the colorscheme when the background changes', function()
      vim.o.background = 'dark'
      DyNeo.dark_mode = false
      day_night.apply()
      assert.equals('light', vim.o.background)
      assert.equals(1, calls)
    end)

    it('leaves the colorscheme alone when nothing changed', function()
      vim.o.background = 'dark'
      DyNeo.dark_mode = true
      day_night.apply()
      assert.equals(0, calls)
    end)
  end)

  describe('setup', function()
    it('does nothing when disabled', function()
      day_night.setup()
      assert.is_false(
        pcall(vim.api.nvim_get_autocmds, { group = 'dy_day_night' })
      )
    end)

    it('watches focus and resume when enabled', function()
      DyNeo.day_night.enabled = true
      day_night.setup()
      day_night.setup() -- a second call replaces the first
      local events = {}
      for _, au in ipairs(vim.api.nvim_get_autocmds({ group = 'dy_day_night' })) do
        table.insert(events, au.event)
      end
      table.sort(events)
      assert.same({ 'FocusGained', 'VimResume' }, events)
    end)
  end)
end)
