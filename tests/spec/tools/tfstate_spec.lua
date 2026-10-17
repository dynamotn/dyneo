local h = require('helpers')

describe('tools.tfstate', function()
  local tfstate, dir, cleanup, path, notes, restore_notify, log
  local restore_confirm, asked

  local MAIN = {
    'resource "aws_s3_bucket" "logs" {',
    '  bucket = "logs"',
    '}',
    '',
    'resource "aws_instance" "web" {',
    '  count = 2',
    '  ami   = "ami-1"',
    '}',
    '',
    'data "aws_iam_policy" "read" {',
    '  name = "read"',
    '}',
    '',
    'module "vpc" {',
    '  source = "./vpc"',
    '}',
    '',
    'locals {',
    '  x = 1',
    '}',
  }

  --- A `tofu` whose state holds `addresses`, and that logs each call
  local function tofu(addresses)
    h.write(dir .. '/bin/tofu', {
      '#!/bin/sh',
      'echo "tofu $* TF_INPUT=$TF_INPUT" >> "' .. log .. '"',
      'case "$2" in',
      '  list)',
      '    if [ -n "$3" ]; then',
      "      printf '%s\\n' "
        .. table.concat(
          vim.tbl_map(function(a) return "'" .. a .. "'" end, addresses),
          ' '
        )
        .. ' | grep -F "$3" || true',
      '    else',
      "      printf '%s\\n' "
        .. table.concat(
          vim.tbl_map(function(a) return "'" .. a .. "'" end, addresses),
          ' '
        ),
      '    fi ;;',
      '  show) echo "# $4:"; echo "resource \\"x\\" \\"y\\" { id = \\"i-1\\" }" ;;',
      'esac',
    })
    vim.fn.setfperm(dir .. '/bin/tofu', 'rwxr-xr-x')
  end

  before_each(function()
    h.unload('tools.tfstate')
    h.unload('tools.tfplan')
    tfstate = require('tools.tfstate')
    dir, cleanup = h.tmpdir()
    log = dir .. '/calls.log'
    h.write(dir .. '/main.tf', MAIN)
    vim.fn.mkdir(dir .. '/bin', 'p')
    path = vim.env.PATH
    vim.env.PATH = dir .. '/bin:' .. path
    asked = {}
    restore_confirm = h.stub(vim.fn, 'confirm', function(question)
      table.insert(asked, question)
      return 1
    end)
    notes = {}
    restore_notify = h.stub(
      vim,
      'notify',
      function(msg) table.insert(notes, msg) end
    )
  end)
  after_each(function()
    vim.env.PATH = path
    restore_confirm()
    restore_notify()
    vim.cmd('silent! only')
    vim.cmd('silent! %bwipeout!')
    cleanup()
  end)

  local function settle(check) assert.is_true(vim.wait(10000, check, 20)) end

  local function edit_at(row)
    vim.cmd.edit(dir .. '/main.tf')
    vim.api.nvim_win_set_cursor(0, { row, 0 })
  end

  describe('block_at', function()
    it('names the block the cursor is in, as the state does', function()
      local logs = assert(tfstate.block_at(MAIN, 2))
      assert.equals('aws_s3_bucket.logs', logs.address)
      assert.equals(1, logs.row)
      assert.is_false(logs.counted)
      local web = assert(tfstate.block_at(MAIN, 8))
      assert.equals('aws_instance.web', web.address)
      assert.is_true(web.counted)
      assert.equals(
        'data.aws_iam_policy.read',
        tfstate.block_at(MAIN, 10).address
      )
      assert.equals('module.vpc', tfstate.block_at(MAIN, 15).address)
    end)

    it('names none between blocks or in another kind of block', function()
      assert.is_nil(tfstate.block_at(MAIN, 4))
      assert.is_nil(tfstate.block_at(MAIN, 19))
    end)
  end)

  it('finds what the state holds that no block declares', function()
    local blocks = require('tools.tfplan').index(dir)
    assert.same(
      { 'aws_iam_role.old', 'module.dns.aws_route53_zone.main' },
      tfstate.orphans({
        'aws_s3_bucket.logs',
        'aws_instance.web[0]',
        'aws_instance.web[1]',
        'aws_iam_role.old',
        'data.aws_iam_policy.read',
        'module.vpc.aws_vpc.main',
        'module.dns.aws_route53_zone.main',
      }, blocks)
    )
    assert.equals('module.vpc', tfstate.declared('module.vpc[0].aws_vpc.this'))
    assert.equals(
      'resource.aws_instance.web',
      tfstate.declared('aws_instance.web["a.b"]')
    )
  end)

  it('shows the state of the block, held back from AI', function()
    tofu({ 'aws_s3_bucket.logs' })
    edit_at(2)
    tfstate.show()
    settle(
      function()
        return vim.bo.filetype == 'terraform' and vim.bo.buftype == 'nofile'
      end
    )
    assert.equals(
      '# aws_s3_bucket.logs:',
      vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]
    )
    assert.is_true(require('util.sensitive').is_sensitive(0))
    local calls = vim.fn.readfile(log)
    assert.equals('tofu state list aws_s3_bucket.logs TF_INPUT=0', calls[1])
    assert.equals(
      'tofu state show -no-color aws_s3_bucket.logs TF_INPUT=0',
      calls[2]
    )
  end)

  it('reads no state of a directory not trusted', function()
    tofu({ 'aws_s3_bucket.logs' })
    restore_confirm()
    restore_confirm = h.stub(vim.fn, 'confirm', function(question)
      table.insert(asked, question)
      return 2
    end)
    edit_at(2)
    tfstate.show()
    vim.wait(200)
    assert.equals(1, #asked)
    assert.truthy(asked[1]:find('tofu state', 1, true))
    assert.equals(0, vim.fn.filereadable(log))
    assert.is_not.equals('nofile', vim.bo.buftype)
  end)

  it('asks once a session before reading the state', function()
    tofu({ 'aws_s3_bucket.logs' })
    edit_at(2)
    tfstate.show()
    settle(function() return vim.bo.buftype == 'nofile' end)
    assert.equals(1, #asked)
  end)

  it('asks which instance of a counted block to show', function()
    tofu({ 'aws_instance.web[0]', 'aws_instance.web[1]' })
    local offered
    local restore = h.stub(vim.ui, 'select', function(items, _, choose)
      offered = items
      choose(items[2])
    end)
    edit_at(6)
    tfstate.show()
    settle(function() return vim.bo.buftype == 'nofile' end)
    restore()
    assert.same({ 'aws_instance.web[0]', 'aws_instance.web[1]' }, offered)
    assert.equals(
      '# aws_instance.web[1]:',
      vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]
    )
  end)

  it('lists the orphans of the state', function()
    tofu({ 'aws_s3_bucket.logs', 'aws_iam_role.old' })
    edit_at(1)
    tfstate.list_orphans()
    settle(function() return vim.bo.buftype == 'nofile' end)
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    assert.equals('aws_iam_role.old', lines[#lines])
  end)

  it('writes an import block above a resource the state lacks', function()
    tofu({ 'aws_instance.web[0]' })
    local restore = h.stub(
      vim.ui,
      'input',
      function(_, answer) answer('logs-bucket') end
    )
    edit_at(2)
    tfstate.import()
    settle(
      function()
        return vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == 'import {'
      end
    )
    restore()
    assert.same({
      'import {',
      '  to = aws_s3_bucket.logs',
      '  id = "logs-bucket"',
      '}',
      '',
      'resource "aws_s3_bucket" "logs" {',
    }, vim.api.nvim_buf_get_lines(0, 0, 6, false))
  end)

  it('writes no import block for what the state holds', function()
    tofu({ 'aws_s3_bucket.logs' })
    edit_at(2)
    tfstate.import()
    settle(function() return #notes > 0 end)
    assert.equals('aws_s3_bucket.logs is in the state already', notes[1])
    assert.equals(
      'resource "aws_s3_bucket" "logs" {',
      vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]
    )
  end)

  it('says so when the state cannot be read', function()
    h.write(
      dir .. '/bin/tofu',
      { '#!/bin/sh', 'echo "Backend not initialized" >&2', 'exit 1' }
    )
    vim.fn.setfperm(dir .. '/bin/tofu', 'rwxr-xr-x')
    edit_at(2)
    tfstate.show()
    settle(function() return #notes > 0 end)
    assert.equals('tofu state list failed:\nBackend not initialized', notes[1])
  end)

  it('maps a Terraform buffer', function()
    local bufnr = h.buffer({ lines = MAIN })
    tfstate.attach(bufnr)
    local descs = vim.tbl_map(
      function(map) return map.desc end,
      vim.api.nvim_buf_get_keymap(bufnr, 'n')
    )
    table.sort(descs)
    assert.same({
      'Import Block (Terraform)',
      'State Not In Code (Terraform)',
      'State Of Block (Terraform)',
    }, descs)
  end)
end)
