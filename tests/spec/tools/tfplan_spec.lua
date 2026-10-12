local h = require('helpers')

local PLAN = {
  resource_changes = {
    {
      address = 'aws_s3_bucket.logs',
      mode = 'managed',
      type = 'aws_s3_bucket',
      name = 'logs',
      change = { actions = { 'update' } },
    },
    {
      address = 'aws_instance.web[0]',
      mode = 'managed',
      type = 'aws_instance',
      name = 'web',
      change = {
        actions = { 'delete', 'create' },
        replace_paths = { { 'ami' } },
      },
    },
    {
      address = 'aws_instance.web[1]',
      mode = 'managed',
      type = 'aws_instance',
      name = 'web',
      change = {
        actions = { 'create', 'delete' },
        replace_paths = { { 'ami' }, { 'ebs_block_device', 0, 'size' } },
      },
    },
    {
      address = 'data.aws_iam_policy.read',
      mode = 'data',
      type = 'aws_iam_policy',
      name = 'read',
      change = { actions = { 'read' } },
    },
    {
      address = 'module.vpc.aws_subnet.private["a"]',
      module_address = 'module.vpc',
      mode = 'managed',
      type = 'aws_subnet',
      name = 'private',
      change = { actions = { 'create' } },
    },
    {
      address = 'module.vpc.module.nat.aws_eip.this',
      module_address = 'module.vpc.module.nat',
      mode = 'managed',
      type = 'aws_eip',
      name = 'this',
      change = { actions = { 'delete' } },
    },
    {
      address = 'aws_sqs_queue.old',
      mode = 'managed',
      type = 'aws_sqs_queue',
      name = 'old',
      change = { actions = { 'delete' } },
    },
    {
      address = 'aws_kms_key.same',
      mode = 'managed',
      type = 'aws_kms_key',
      name = 'same',
      change = { actions = { 'no-op' } },
    },
  },
}

describe('tools.tfplan', function()
  local tfplan, dir, cleanup, restore_confirm

  before_each(function()
    h.unload('tools.tfplan')
    tfplan = require('tools.tfplan')
    -- Planning is agreed to unless a spec says otherwise
    restore_confirm = h.stub(vim.fn, 'confirm', function() return 1 end)
    dir, cleanup = h.tmpdir()
    h.write(dir .. '/main.tf', {
      'resource "aws_s3_bucket" "logs" {',
      '  bucket = "logs"',
      '}',
      '',
      '  resource "aws_instance" "web" {',
      '  count = 2',
      '}',
      'data "aws_iam_policy" "read" {',
      '}',
    })
    h.write(
      dir .. '/modules.tf',
      { 'module "vpc" {', '  source = "./vpc"', '}' }
    )
    h.write(dir .. '/README.md', { 'resource "aws_x" "not_code" {' })
  end)
  after_each(function()
    restore_confirm()
    tfplan.clear()
    vim.cmd('silent! %bwipeout!')
    cleanup()
  end)

  it('reads the changes of a plan, leaving out what stays', function()
    local changes = tfplan.changes(PLAN)
    assert.equals(7, #changes)
    assert.same({
      action = 'replace',
      address = 'aws_instance.web[1]',
      mode = 'managed',
      type = 'aws_instance',
      name = 'web',
      forces = { 'ami', 'ebs_block_device[0].size' },
    }, changes[3])
    assert.equals('vpc', changes[6].module)
    assert.equals('destroy', changes[6].action)
  end)

  it('finds where each block starts, in the .tf files only', function()
    local blocks = tfplan.index(dir)
    assert.same(
      { file = dir .. '/main.tf', line = 1 },
      blocks['resource.aws_s3_bucket.logs']
    )
    assert.same(
      { file = dir .. '/main.tf', line = 5 },
      blocks['resource.aws_instance.web']
    )
    assert.same(
      { file = dir .. '/main.tf', line = 8 },
      blocks['data.aws_iam_policy.read']
    )
    assert.same({ file = dir .. '/modules.tf', line = 1 }, blocks['module.vpc'])
    assert.is_nil(blocks['resource.aws_x.not_code'])
  end)

  it('says one thing per block, loudest first, with what forces it', function()
    local entries = tfplan.entries(tfplan.changes(PLAN), tfplan.index(dir))
    local by_text = {}
    for _, entry in ipairs(entries) do
      by_text[entry.text] = entry
    end

    local web =
      by_text['-/+ replace ×2 (forced by ami, ebs_block_device[0].size)']
    assert.equals(5, web.line)
    assert.equals(vim.diagnostic.severity.WARN, web.severity)

    assert.equals(1, by_text['~ update in place'].line)
    assert.equals(
      vim.diagnostic.severity.INFO,
      by_text['~ update in place'].severity
    )
    assert.equals(8, by_text['<= read'].line)

    -- A module gathers every change below it, nested modules included
    local vpc = by_text['- destroy, + create']
    assert.equals(dir .. '/modules.tf', vpc.file)
    assert.equals(vim.diagnostic.severity.WARN, vpc.severity)

    -- A block that is nowhere in the files still says what it is
    local old = by_text['aws_sqs_queue.old: - destroy']
    assert.is_nil(old.file)
  end)

  it('sums the plan up the way plan does', function()
    assert.equals(
      'Plan: 1 to add, 1 to change, 2 to destroy, 2 to replace',
      tfplan.summary(tfplan.changes(PLAN))
    )
    assert.equals('No changes', tfplan.summary({}))
  end)

  describe('plan', function()
    local path, bin, restore_notify, notes

    before_each(function()
      bin = dir .. '/bin'
      vim.fn.mkdir(bin, 'p')
      h.write(dir .. '/plan.json', { vim.json.encode(PLAN) })
      -- A tofu that plans into the file it is given and shows plan.json
      h.write(bin .. '/tofu', {
        '#!/bin/sh',
        'case "$1" in',
        '  plan) for a; do case "$a" in -out=*) echo plan > "${a#-out=}";; esac; done',
        '        echo "$@" > "' .. dir .. '/plan.args";;',
        '  show) test -f "$3" || exit 3; cat "' .. dir .. '/plan.json";;',
        'esac',
      })
      vim.fn.setfperm(bin .. '/tofu', 'rwxr-xr-x')
      path = vim.env.PATH
      vim.env.PATH = bin .. ':' .. path
      notes = {}
      restore_notify = h.stub(
        vim,
        'notify',
        function(msg) table.insert(notes, msg) end
      )
    end)
    after_each(function()
      vim.env.PATH = path
      restore_notify()
    end)

    it('plans the module of the buffer and shows it on its blocks', function()
      vim.cmd.edit(dir .. '/main.tf')
      local bufnr = vim.api.nvim_get_current_buf()
      tfplan.plan()
      assert.is_true(
        vim.wait(10000, function() return #notes >= 2 end, 20),
        'the plan never finished'
      )
      assert.equals(
        'Plan: 1 to add, 1 to change, 2 to destroy, 2 to replace',
        notes[#notes]
      )

      local args = table.concat(vim.fn.readfile(dir .. '/plan.args'), ' ')
      assert.is_truthy(args:find('-lock=false', 1, true))
      assert.is_truthy(args:find('-input=false', 1, true))
      -- The plan file, secrets and all, is gone once it was read
      local planfile = args:match('%-out=(%S+)')
      assert.equals(0, vim.fn.filereadable(planfile))

      local messages = vim.tbl_map(
        function(d) return d.lnum .. ' ' .. d.message end,
        vim.diagnostic.get(bufnr)
      )
      table.sort(messages)
      assert.same({
        '0 ~ update in place',
        '4 -/+ replace ×2 (forced by ami, ebs_block_device[0].size)',
        '7 <= read',
      }, messages)
      assert.equals(5, #vim.fn.getqflist())

      tfplan.clear()
      assert.same({}, vim.diagnostic.get(bufnr))
      assert.same({}, vim.fn.getqflist())
    end)

    it('says why a plan failed', function()
      h.write(
        bin .. '/tofu',
        { '#!/bin/sh', 'echo "Error: no credentials" >&2', 'exit 1' }
      )
      vim.cmd.edit(dir .. '/main.tf')
      tfplan.plan()
      assert.is_true(vim.wait(10000, function() return #notes >= 2 end, 20))
      assert.is_truthy(
        notes[#notes]:find('plan failed:\nError: no credentials', 1, true)
      )
    end)
  end)

  it(
    'counts what a removed block forgets',
    function()
      assert.equals(
        'Plan: 0 to add, 0 to change, 0 to destroy, 0 to replace, 1 to forget',
        tfplan.summary({ { action = 'forget' } })
      )
    end
  )

  describe('drift', function()
    local DRIFTED = {
      resource_drift = {
        {
          address = 'aws_s3_bucket.logs',
          mode = 'managed',
          type = 'aws_s3_bucket',
          name = 'logs',
          change = { actions = { 'update' } },
        },
        {
          address = 'aws_sqs_queue.gone',
          mode = 'managed',
          type = 'aws_sqs_queue',
          name = 'gone',
          change = { actions = { 'delete' } },
        },
      },
      resource_changes = {},
    }

    it('reads what changed outside the code, told as drift', function()
      local changes = tfplan.changes(DRIFTED, 'resource_drift')
      assert.equals(2, #changes)
      assert.same({}, tfplan.changes(DRIFTED))

      local entries = tfplan.entries(changes, tfplan.index(dir), true)
      assert.equals('~ changed outside the code', entries[1].text)
      assert.equals(1, entries[1].line)
      assert.equals(vim.diagnostic.severity.WARN, entries[1].severity)
      assert.equals(
        'aws_sqs_queue.gone: - deleted outside the code',
        entries[2].text
      )
    end)

    it('sums drift up', function()
      assert.equals('No drift', tfplan.drift_summary({}))
      assert.equals(
        'Drift: 1 changed, 1 deleted outside the code',
        tfplan.drift_summary(tfplan.changes(DRIFTED, 'resource_drift'))
      )
    end)
  end)

  describe('cost', function()
    local BREAKDOWN = {
      currency = 'EUR',
      projects = {
        {
          breakdown = {
            resources = {
              { name = 'aws_instance.web[0]', monthlyCost = '10.5' },
              { name = 'aws_instance.web[1]', monthlyCost = '10.5' },
              { name = 'module.vpc.aws_nat_gateway.this', monthlyCost = '32' },
              { name = 'module.vpc.module.nat.aws_eip.x', monthlyCost = '3' },
              -- Priced by usage only: no monthly cost to add
              { name = 'aws_s3_bucket.logs', monthlyCost = vim.NIL },
            },
          },
        },
      },
    }

    it('keys each priced address by its block', function()
      assert.equals(
        'resource.aws_instance.web',
        tfplan.cost_key('aws_instance.web[0]')
      )
      assert.equals(
        'resource.aws_instance.web',
        tfplan.cost_key('aws_instance.web["a.b"]')
      )
      assert.equals('module.vpc', tfplan.cost_key('module.vpc.aws_eip.x'))
      assert.equals('module.vpc', tfplan.cost_key('module.vpc["x"].aws_eip.x'))
    end)

    it('sums the monthly cost of each block', function()
      local costs = tfplan.costs(BREAKDOWN)
      assert.same({
        ['resource.aws_instance.web'] = 21,
        ['module.vpc'] = 35,
      }, costs.blocks)
      assert.equals(56, costs.total)
      assert.equals('EUR', costs.currency)
      assert.equals('USD', tfplan.costs({}).currency)
      assert.equals('≈ 21.00 EUR/month', tfplan.cost_text(21, 'EUR'))
    end)

    it('shows costs on loaded buffers, and on those opened later', function()
      vim.cmd.edit(dir .. '/main.tf')
      local main = vim.api.nvim_get_current_buf()
      local cost_ns = vim.api.nvim_create_namespace('dy_tfplan_cost')
      tfplan.show_costs(tfplan.costs(BREAKDOWN), tfplan.index(dir))

      local marks =
        vim.api.nvim_buf_get_extmarks(main, cost_ns, 0, -1, { details = true })
      assert.equals(1, #marks)
      assert.equals(4, marks[1][2])
      assert.equals('  ≈ 21.00 EUR/month', marks[1][4].virt_text[1][1])

      vim.cmd.edit(dir .. '/modules.tf')
      local modules = vim.api.nvim_get_current_buf()
      tfplan.attach(modules)
      assert.equals(
        1,
        #vim.api.nvim_buf_get_extmarks(modules, cost_ns, 0, -1, {})
      )

      tfplan.clear()
      assert.same({}, vim.api.nvim_buf_get_extmarks(main, cost_ns, 0, -1, {}))
      tfplan.attach(modules)
      assert.same(
        {},
        vim.api.nvim_buf_get_extmarks(modules, cost_ns, 0, -1, {})
      )
    end)
  end)

  describe('impact', function()
    local CONFIGURATION = {
      root_module = {
        resources = {
          {
            address = 'aws_instance.web',
            expressions = {
              ami = {
                references = { 'data.aws_ami.base.id', 'data.aws_ami.base' },
              },
            },
          },
          {
            address = 'aws_lb_target_group_attachment.web',
            expressions = {
              target_id = {
                references = { 'aws_instance.web[0].id', 'aws_instance.web' },
              },
            },
          },
          {
            address = 'aws_route53_record.web',
            expressions = {
              records = {
                references = {
                  'aws_lb_target_group_attachment.web.id',
                  'var.zone',
                },
              },
            },
          },
          {
            address = 'aws_s3_bucket.logs',
            depends_on = { 'aws_instance.web' },
          },
          {
            address = 'aws_sqs_queue.alone',
            expressions = { name = { references = { 'local.name' } } },
          },
        },
        module_calls = {
          dns = {
            expressions = {
              target = { references = { 'aws_route53_record.web.fqdn' } },
            },
          },
        },
      },
    }

    it('reads the block a reference points at', function()
      assert.equals(
        'aws_instance.web',
        tfplan.ref_address('aws_instance.web[0].id')
      )
      assert.equals('module.vpc', tfplan.ref_address('module.vpc.vpc_id'))
      assert.equals('module.vpc', tfplan.ref_address('module.vpc["a"].id'))
      assert.equals(
        'data.aws_ami.base',
        tfplan.ref_address('data.aws_ami.base.id')
      )
      for _, ref in ipairs({
        'var.zone',
        'local.name',
        'each.key',
        'count.index',
        'path.module',
        'self.id',
      }) do
        assert.is_nil(tfplan.ref_address(ref), ref)
      end
    end)

    it('finds what depends on each block, depends_on included', function()
      local dependents = tfplan.dependents(CONFIGURATION)
      table.sort(dependents['aws_instance.web'])
      assert.same(
        { 'aws_lb_target_group_attachment.web', 'aws_s3_bucket.logs' },
        dependents['aws_instance.web']
      )
      assert.same({ 'module.dns' }, dependents['aws_route53_record.web'])
      assert.same({ 'aws_instance.web' }, dependents['data.aws_ami.base'])
      assert.is_nil(dependents['aws_sqs_queue.alone'])
      assert.same({}, tfplan.dependents(nil))
    end)

    it('takes count and for_each as references too', function()
      local dependents = tfplan.dependents({
        root_module = {
          resources = {
            {
              address = 'aws_route_table.each',
              for_each_expression = { references = { 'aws_instance.web.tags' } },
            },
          },
          module_calls = {
            replicas = {
              count_expression = { references = { 'aws_instance.web' } },
            },
          },
        },
      })
      table.sort(dependents['aws_instance.web'])
      assert.same(
        { 'aws_route_table.each', 'module.replicas' },
        dependents['aws_instance.web']
      )
    end)

    it('follows a replacement through everything depending on it', function()
      local reached = tfplan.affected({
        {
          action = 'replace',
          mode = 'managed',
          type = 'aws_instance',
          name = 'web',
          forces = {},
        },
        {
          action = 'update',
          mode = 'managed',
          type = 'aws_sqs_queue',
          name = 'alone',
          forces = {},
        },
      }, tfplan.dependents(CONFIGURATION))
      local addresses = vim.tbl_keys(reached)
      table.sort(addresses)
      assert.same({
        'aws_lb_target_group_attachment.web',
        'aws_route53_record.web',
        'aws_s3_bucket.logs',
        'module.dns',
      }, addresses)
      assert.same({ 'aws_instance.web (replace)' }, reached['module.dns'])

      local entries = tfplan.impact_entries(
        reached,
        { ['module.dns'] = { file = '/m.tf', line = 3 } }
      )
      local dns =
        vim.tbl_filter(function(e) return e.file == '/m.tf' end, entries)[1]
      assert.equals('↳ depends on aws_instance.web (replace)', dns.text)
      assert.equals(3, dns.line)
      assert.is_truthy(
        vim.tbl_filter(
          function(e)
            return e.text
              == 'aws_s3_bucket.logs: ↳ depends on aws_instance.web (replace)'
          end,
          entries
        )[1]
      )
    end)
  end)

  describe('run', function()
    local path, bin, restore_notify, notes

    before_each(function()
      bin = dir .. '/bin'
      vim.fn.mkdir(bin, 'p')
      h.write(dir .. '/plan.json', {
        vim.json.encode({
          resource_changes = PLAN.resource_changes,
          resource_drift = {
            {
              address = 'aws_s3_bucket.logs',
              mode = 'managed',
              type = 'aws_s3_bucket',
              name = 'logs',
              change = { actions = { 'update' } },
            },
          },
        }),
      })
      h.write(bin .. '/tofu', {
        '#!/bin/sh',
        'case "$1" in',
        '  plan) for a; do case "$a" in -out=*) echo plan > "${a#-out=}";; esac; done',
        '        echo "$@" > "' .. dir .. '/plan.args";;',
        '  show) test -f "$3" || exit 3; cat "' .. dir .. '/plan.json";;',
        'esac',
      })
      -- An infracost that records the file it prices, and how private it is
      h.write(bin .. '/infracost', {
        '#!/bin/sh',
        'echo "$@" > "' .. dir .. '/infracost.args"',
        'stat -c %a "$3" > "' .. dir .. '/infracost.mode"',
        'test -s "$3" || exit 4',
        'echo \'{"currency":"USD","projects":[{"breakdown":{"resources":'
          .. '[{"name":"aws_instance.web[0]","monthlyCost":"7.25"}]}}]}\'',
      })
      vim.fn.setfperm(bin .. '/tofu', 'rwxr-xr-x')
      vim.fn.setfperm(bin .. '/infracost', 'rwxr-xr-x')
      path = vim.env.PATH
      vim.env.PATH = bin .. ':' .. path
      notes = {}
      restore_notify = h.stub(
        vim,
        'notify',
        function(msg) table.insert(notes, msg) end
      )
    end)
    after_each(function()
      vim.env.PATH = path
      restore_notify()
    end)

    it('looks for drift with a refresh-only plan', function()
      vim.cmd.edit(dir .. '/main.tf')
      local bufnr = vim.api.nvim_get_current_buf()
      tfplan.command({ fargs = { 'drift' } })
      assert.is_true(vim.wait(10000, function() return #notes >= 2 end, 20))
      assert.equals('Drift: 1 changed, 0 deleted outside the code', notes[2])

      local args = table.concat(vim.fn.readfile(dir .. '/plan.args'), ' ')
      assert.is_truthy(args:find('-refresh-only', 1, true))
      assert.equals(0, vim.fn.filereadable(args:match('%-out=(%S+)')))

      local diagnostics = vim.diagnostic.get(bufnr)
      assert.equals(1, #diagnostics)
      assert.equals('drift', diagnostics[1].source)
      assert.equals('~ changed outside the code', diagnostics[1].message)
      assert.is_truthy(
        vim.fn.getqflist({ title = 0 }).title:find('^Terraform drift')
      )
    end)

    it('prices the plan from a private copy, gone once read', function()
      vim.cmd.edit(dir .. '/main.tf')
      local bufnr = vim.api.nvim_get_current_buf()
      tfplan.command({ fargs = { 'cost' } })
      assert.is_true(vim.wait(10000, function() return #notes >= 3 end, 20))
      assert.equals('Monthly cost: ≈ 7.25 USD/month', notes[3])

      local args = table.concat(vim.fn.readfile(dir .. '/infracost.args'), ' ')
      local jsonfile = args:match('%-%-path (%S+)')
      assert.is_truthy(args:find('--format json', 1, true))
      assert.same({ '600' }, vim.fn.readfile(dir .. '/infracost.mode'))
      assert.equals(0, vim.fn.filereadable(jsonfile))

      local cost_ns = vim.api.nvim_create_namespace('dy_tfplan_cost')
      local marks = vim.api.nvim_buf_get_extmarks(bufnr, cost_ns, 0, -1, {})
      assert.equals(1, #marks)
      -- The plan itself is still shown alongside
      assert.is_true(#vim.diagnostic.get(bufnr) > 0)
    end)

    it('takes a project infracost priced nothing of as free', function()
      h.write(bin .. '/infracost', {
        '#!/bin/sh',
        [[echo '{"currency":null,"projects":[{"breakdown":{"resources":null}}]}']],
      })
      vim.cmd.edit(dir .. '/main.tf')
      tfplan.cost()
      assert.is_true(vim.wait(10000, function() return #notes >= 3 end, 20))
      assert.equals('Monthly cost: ≈ 0.00 USD/month', notes[3])
    end)

    it('shows what depends on a replacement, with the plan', function()
      h.write(dir .. '/plan.json', {
        vim.json.encode({
          resource_changes = PLAN.resource_changes,
          configuration = {
            root_module = {
              resources = {
                {
                  address = 'aws_s3_bucket.logs',
                  expressions = {
                    tags = { references = { 'aws_instance.web.id' } },
                  },
                },
              },
            },
          },
        }),
      })
      vim.cmd.edit(dir .. '/main.tf')
      local bufnr = vim.api.nvim_get_current_buf()
      tfplan.command({ fargs = { 'impact' } })
      assert.is_true(vim.wait(10000, function() return #notes >= 2 end, 20))
      assert.equals(
        'Plan: 1 to add, 1 to change, 2 to destroy, 2 to replace;'
          .. ' 1 blocks depend on what is replaced or destroyed',
        notes[2]
      )
      local messages = vim.tbl_map(
        function(d) return d.lnum .. ' ' .. d.message end,
        vim.diagnostic.get(bufnr)
      )
      assert.is_truthy(
        vim.list_contains(
          messages,
          '0 ↳ depends on aws_instance.web (replace)'
        )
      )
      -- One plan, not one more started from inside it
      assert.is_false(vim.wait(300, function() return #notes > 2 end, 20))
    end)

    it('says when infracost is missing, without planning', function()
      vim.fn.delete(bin .. '/infracost')
      local restore = h.stub(vim.fn, 'executable', function(name)
        if name == 'infracost' then return 0 end
        return 1
      end)
      tfplan.cost()
      restore()
      assert.same({ 'infracost is not installed' }, notes)
      assert.equals(0, vim.fn.filereadable(dir .. '/plan.args'))
    end)

    it('refuses an unknown subcommand', function()
      tfplan.command({ fargs = { 'nope' } })
      assert.same({ 'Unknown subcommand: nope' }, notes)
    end)
  end)

  describe('trust', function()
    local path, restores, asked
    before_each(function()
      vim.fn.mkdir(dir .. '/bin', 'p')
      h.write(dir .. '/bin/tofu', {
        '#!/bin/sh',
        'echo "$@" >> "' .. dir .. '/ran"',
        'exit 1',
      })
      vim.fn.setfperm(dir .. '/bin/tofu', 'rwxr-xr-x')
      path = vim.env.PATH
      vim.env.PATH = dir .. '/bin:' .. path
      asked = 0
      restores = { h.stub(vim, 'notify', function() end) }
      vim.cmd.edit(dir .. '/main.tf')
    end)
    after_each(function()
      vim.env.PATH = path
      for i = #restores, 1, -1 do
        restores[i]()
      end
    end)

    ---@param answer integer
    local function answering(answer)
      table.insert(
        restores,
        h.stub(vim.fn, 'confirm', function()
          asked = asked + 1
          return answer
        end)
      )
    end

    it('runs nothing of a project it was not allowed to', function()
      answering(2)
      tfplan.run()
      vim.wait(300, function() return false end)
      assert.are.equal(1, asked)
      assert.are.equal(0, vim.fn.filereadable(dir .. '/ran'))
    end)

    it('asks once a session for a directory', function()
      answering(1)
      tfplan.run()
      tfplan.run()
      assert.is_true(
        vim.wait(
          2000,
          function() return vim.fn.filereadable(dir .. '/ran') == 1 end
        )
      )
      assert.are.equal(1, asked)
    end)
  end)
end)
