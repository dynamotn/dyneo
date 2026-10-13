local h = require('helpers')

describe('util.cmp actions and snippets', function()
  local cmp

  before_each(function()
    h.unload('util.cmp')
    cmp = require('util.cmp')
  end)

  describe('map', function()
    it('runs the actions in turn until one handles the key', function()
      local ran = {}
      cmp.actions.first = function()
        table.insert(ran, 'first')
        return false
      end
      cmp.actions.second = function()
        table.insert(ran, 'second')
        return true
      end
      cmp.actions.third = function() table.insert(ran, 'third') end
      assert.is_true(cmp.map({ 'first', 'second', 'third' })())
      assert.are.same({ 'first', 'second' }, ran)
    end)

    it(
      'skips an action nothing has registered',
      function() assert.are.equal('<tab>', cmp.map({ 'ai_nes' }, '<tab>')()) end
    )

    it('calls a fallback function when no action handles the key', function()
      local called = false
      cmp.map({}, function()
        called = true
        return 'fell back'
      end)()
      assert.is_true(called)
    end)
  end)
end)
