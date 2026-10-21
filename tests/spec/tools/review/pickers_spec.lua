local h = require('helpers')

describe('tools.review.pickers', function()
  local pickers

  before_each(function()
    h.unload('tools.review.pickers')
    pickers = require('tools.review.pickers')
  end)

  describe('draft_cells', function()
    local function draft(fields)
      return vim.tbl_extend('force', {
        id = 'd',
        origin = 'user',
        state = 'ready',
        path = 'a.lua',
        side = 'new',
        line = 3,
        body = 'First line\nsecond',
      }, fields or {})
    end

    it('shows origin, state, severity, place and first line', function()
      assert.same(
        { 'me', 'ready', '', 'a.lua:3', 'First line' },
        pickers.draft_cells(draft())
      )
      assert.same(
        { 'AI', 'pending', 'nit', 'a.lua:3', 'First line' },
        pickers.draft_cells(draft({
          origin = 'ai',
          state = 'pending',
          severity = 'nit',
        }))
      )
    end)

    it(
      'says a draft carries a suggestion',
      function()
        assert.same(
          { 'AI', 'pending', '', 'a.lua:3', 'First line + suggestion' },
          pickers.draft_cells(draft({
            origin = 'ai',
            state = 'pending',
            suggestion = { 'x' },
          }))
        )
      end
    )
  end)
end)
