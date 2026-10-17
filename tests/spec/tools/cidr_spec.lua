local h = require('helpers')

describe('tools.cidr', function()
  local cidr

  before_each(function()
    h.unload('tools.cidr')
    cidr = require('tools.cidr')
  end)

  it('maps the overlaps in a Terraform buffer', function()
    dofile(h.root .. '/plugin/cidr.lua')
    for _, filetype in ipairs({ 'terraform', 'terraform-vars' }) do
      local bufnr = h.buffer({ filetype = filetype })
      local maps = vim.api.nvim_buf_get_keymap(bufnr, 'n')
      vim.api.nvim_buf_delete(bufnr, { force = true })
      assert.same(
        { '<Cmd>DyCidr overlaps<CR>' },
        vim.tbl_map(function(map) return map.rhs end, maps)
      )
    end
  end)

  it('reads a range, and refuses what is none', function()
    local range = assert(cidr.parse('10.0.1.7/24'))
    assert.equals('10.0.1.0', cidr.dotted(range.first))
    assert.equals('10.0.1.255', cidr.dotted(range.last))
    assert.equals('255.255.255.255', cidr.dotted(cidr.parse('0.0.0.0/0').last))
    assert.is_nil(cidr.parse('10.0.0.256/24'))
    assert.is_nil(cidr.parse('10.0.0.0/33'))
    assert.is_nil(cidr.parse('10.0.0.0'))
  end)

  it('says what a range holds', function()
    assert.same({
      'Network   10.0.1.0/24',
      'Netmask   255.255.255.0',
      'Hosts     10.0.1.1 – 10.0.1.254 (254)',
      'Broadcast 10.0.1.255',
      'Addresses 256',
      '10.0.1.7/24 is not the network address',
    }, cidr.describe(assert(cidr.parse('10.0.1.7/24'))))
    assert.equals(
      'Hosts     192.168.0.0 – 192.168.0.1 (2)',
      cidr.describe(assert(cidr.parse('192.168.0.0/31')))[3]
    )
  end)

  it('finds the range under the cursor', function()
    local line = 'cidr_block = "10.0.0.0/16" # or 172.16.0.0/12'
    assert.equals('10.0.0.0/16', cidr.at(line, 16))
    assert.equals('172.16.0.0/12', cidr.at(line, 36))
    assert.is_nil(cidr.at(line, 1))
  end)

  it('collects the ranges that define a network, lists included', function()
    local entries = cidr.collect({
      'cidr = "10.0.0.0/16"',
      'private_subnets = [',
      '  "10.0.1.0/24",',
      '  "10.0.2.0/24",',
      ']',
      'cidr_blocks = ["0.0.0.0/0"]',
      'public_subnets = ["10.0.101.0/24"]',
      'description = "10.9.9.0/24"',
    }, 'main.tf')
    assert.same(
      { '10.0.0.0/16', '10.0.1.0/24', '10.0.2.0/24', '10.0.101.0/24' },
      vim.tbl_map(function(e) return e.text end, entries)
    )
    assert.equals(3, entries[2].lnum)
  end)

  it('flags the same range twice, and subnets inside subnets', function()
    local entries = cidr.collect({
      'cidr = "10.0.0.0/16"',
      'subnets = ["10.0.1.0/24", "10.0.1.128/25", "10.0.2.0/24"]',
      'other_cidr = "10.0.0.0/16"',
    }, 'main.tf')
    assert.same(
      {
        { '10.0.0.0/16', 'same', '10.0.0.0/16' },
        { '10.0.1.128/25', 'inside', '10.0.1.0/24' },
      },
      vim.tbl_map(
        function(o) return { o.entry.text, o.kind, o.other.text } end,
        cidr.overlaps(entries)
      )
    )
  end)

  it('takes only a whole network for a parent', function()
    local entries = cidr.collect({
      'resource "aws_vpc" "main" {',
      '  cidr_block = "10.0.0.0/16"',
      '}',
      'resource "aws_subnet" "a" {',
      '  cidr_block = "10.0.0.0/23"',
      '}',
      'resource "aws_subnet" "b" {',
      '  cidr_block = "10.0.1.0/24"',
      '}',
      'vpc_cidr = "10.0.0.0/8"',
    }, 'main.tf')
    assert.same(
      {
        { '10.0.0.0/16', 'inside', '10.0.0.0/8' },
        { '10.0.1.0/24', 'inside', '10.0.0.0/23' },
      },
      vim.tbl_map(
        function(o) return { o.entry.text, o.kind, o.other.text } end,
        cidr.overlaps(entries)
      )
    )
  end)

  it('counts the IPv6 ranges it does not read', function()
    local entries, ipv6 = cidr.collect({
      'ipv6_cidr_block = "2001:db8::/56"',
      'address_space = ["10.0.0.0/16", "fd00::/8"]',
      'description = "fd00::/8"',
    }, 'main.tf')
    assert.equals(1, #entries)
    assert.equals(2, ipv6)
  end)

  it('lists the overlaps of the module in the quickfix list', function()
    local dir, cleanup = h.tmpdir()
    h.write(dir .. '/vpc.tf', { 'cidr_block = "10.0.0.0/16"' })
    h.write(dir .. '/subnets.tf', {
      'resource "aws_subnet" "a" {',
      '  cidr_block = "10.0.1.0/24"',
      '  cidr_block = "10.0.1.0/24"',
      '}',
    })
    h.write(dir .. '/notes.md', { 'cidr = "10.0.0.0/16"' })
    vim.cmd.edit(dir .. '/vpc.tf')
    local restore = h.stub(vim, 'notify', function() end)
    cidr.command({ fargs = { 'overlaps' } })
    restore()
    local items = vim.fn.getqflist()
    vim.cmd('cclose | silent! %bwipeout!')
    cleanup()
    assert.equals(1, #items)
    assert.equals(3, items[1].lnum)
    assert.equals(
      '10.0.1.0/24 is the same range as 10.0.1.0/24 (subnets.tf:2)',
      items[1].text
    )
  end)

  it('says once that IPv6 ranges are not read', function()
    local dir, cleanup = h.tmpdir()
    h.write(dir .. '/main.tf', {
      'ipv6_cidr_block = "2001:db8::/56"',
      'subnets = ["10.0.1.0/24", "2001:db8:0:1::/64"]',
    })
    vim.cmd.edit(dir .. '/main.tf')
    local notes = {}
    local restore = h.stub(
      vim,
      'notify',
      function(msg) table.insert(notes, msg) end
    )
    cidr.command({ fargs = { 'overlaps' } })
    restore()
    vim.cmd('silent! %bwipeout!')
    cleanup()
    assert.same({
      '2 IPv6 ranges not checked: only IPv4 is read',
      'No overlap among 1 ranges',
    }, notes)
  end)

  it('says which file it read only part of', function()
    local dir, cleanup = h.tmpdir()
    h.write(dir .. '/main.tf', { 'cidr_block = "10.0.0.0/16"' })
    h.write(dir .. '/big.tf', { ('#'):rep(2000), 'cidr_block = "10.0.0.0/16"' })
    vim.cmd.edit(dir .. '/main.tf')
    local notes = {}
    local restores = {
      h.stub(vim, 'notify', function(msg) table.insert(notes, msg) end),
      h.stub(cidr, 'MAX_BYTES', 1024),
    }
    cidr.command({ fargs = { 'overlaps' } })
    for _, restore in ipairs(restores) do
      restore()
    end
    vim.cmd('silent! %bwipeout!')
    cleanup()
    assert.same({
      'Only the first 1 KiB read of big.tf',
      'No overlap among 1 ranges',
    }, notes)
  end)

  it('reads a file, not the loaded buffer named like it', function()
    local dir, cleanup = h.tmpdir()
    h.write(dir .. '/prod.tf', { 'cidr_block = "10.0.0.0/16"' })
    h.write(dir .. '/prod.tfvars', { 'subnets = ["10.0.1.0/24"]' })
    vim.cmd.edit(dir .. '/prod.tfvars')
    local notes = {}
    local restore = h.stub(
      vim,
      'notify',
      function(msg) table.insert(notes, msg) end
    )
    vim.fn.setqflist({})
    cidr.command({ fargs = { 'overlaps' } })
    restore()
    local items = vim.fn.getqflist()
    vim.cmd('cclose | silent! %bwipeout!')
    cleanup()
    assert.same({}, items)
    assert.equals('No overlap among 2 ranges', notes[1])
  end)
end)
