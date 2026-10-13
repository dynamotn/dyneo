local h = require('helpers')

--- The edges of a graph as `from -> to` strings, sorted
local function edges(graph)
  local out = vim.tbl_map(
    function(e) return e.from .. ' -> ' .. e.to end,
    graph.edges
  )
  table.sort(out)
  return out
end

describe('tools.architecture', function()
  local arch

  before_each(function()
    h.unload('tools.architecture')
    arch = require('tools.architecture')
  end)
  after_each(function() vim.cmd('silent! %bwipeout!') end)

  it('draws Terraform blocks and what they refer to', function()
    local graph = arch.terraform({
      ['/m/main.tf'] = {
        'resource "aws_instance" "web" {',
        '  ami    = data.aws_ami.base.id',
        '  subnet = module.vpc.private_subnets[0]',
        '  tags   = { Name = "web" } # aws_s3_bucket.logs in a comment',
        '}',
        'data "aws_ami" "base" {',
        '  owners = [var.owner_id]',
        '}',
        'resource "aws_lb_target_group_attachment" "web" {',
        '  target_id = aws_instance.web.id',
        '}',
      },
      ['/m/other.tf'] = {
        'module "vpc" {',
        '  source = "./vpc"',
        '}',
        'resource "aws_s3_bucket" "logs" {}',
      },
    })
    local ids = vim.tbl_map(function(n) return n.id end, graph.nodes)
    table.sort(ids)
    assert.same({
      'aws_instance.web',
      'aws_lb_target_group_attachment.web',
      'aws_s3_bucket.logs',
      'data.aws_ami.base',
      'module.vpc',
    }, ids)
    assert.same({
      'aws_instance.web -> data.aws_ami.base',
      'aws_instance.web -> module.vpc',
      'aws_lb_target_group_attachment.web -> aws_instance.web',
    }, edges(graph))
  end)

  it('cuts comments, not what a string holds', function()
    assert.same(
      { 'a = "https://x" ', 'a = "" ' },
      { arch.hcl_code('a = "https://x" # note') }
    )
    assert.same(
      { 'b = "${aws_lb.x.dns_name}/#"', 'b = ""' },
      { arch.hcl_code('b = "${aws_lb.x.dns_name}/#"') }
    )
    assert.same({ '', '' }, { arch.hcl_code('// all comment') })
    assert.same(
      { [[c = "a \" b" ]], [[c = "" ]] },
      { arch.hcl_code([[c = "a \" b" # x]]) }
    )
  end)

  it('keeps a block whole however its strings look', function()
    local graph = arch.terraform({
      ['/m/main.tf'] = {
        'resource "aws_s3_bucket" "logs" {',
        '  tags = { Source = "https://github.com/o/r" }',
        '  note = "{ not a block"',
        '}',
        'resource "aws_route53_record" "web" {',
        '  records = ["${aws_lb.main.dns_name}"]',
        '}',
        'resource "aws_lb" "main" {}',
      },
    })
    assert.equals(3, #graph.nodes)
    assert.same({ 'aws_route53_record.web -> aws_lb.main' }, edges(graph))
  end)

  it('draws the links the cluster makes, a missing one dashed', function()
    local graph = arch.kube({
      {
        apiVersion = 'v1',
        kind = 'Service',
        metadata = { name = 'web' },
        spec = { selector = { app = 'web' } },
      },
      {
        apiVersion = 'apps/v1',
        kind = 'Deployment',
        metadata = { name = 'web' },
        spec = {
          template = {
            metadata = { labels = { app = 'web', tier = 'front' } },
            spec = {
              serviceAccountName = 'web',
              containers = {
                {
                  envFrom = { { configMapRef = { name = 'web-config' } } },
                  env = { { valueFrom = { secretKeyRef = { name = 'db' } } } },
                },
              },
              volumes = { { persistentVolumeClaim = { claimName = 'data' } } },
            },
          },
        },
      },
      {
        apiVersion = 'apps/v1',
        kind = 'Deployment',
        metadata = { name = 'other' },
        spec = { template = { metadata = { labels = { app = 'other' } } } },
      },
      {
        apiVersion = 'networking.k8s.io/v1',
        kind = 'Ingress',
        metadata = { name = 'web' },
        spec = {
          rules = {
            {
              http = {
                paths = { { backend = { service = { name = 'web' } } } },
              },
            },
          },
        },
      },
      {
        apiVersion = 'v1',
        kind = 'ConfigMap',
        metadata = { name = 'web-config' },
      },
      {
        apiVersion = 'autoscaling/v2',
        kind = 'HorizontalPodAutoscaler',
        metadata = { name = 'web' },
        spec = { scaleTargetRef = { kind = 'Deployment', name = 'web' } },
      },
    })
    assert.same({
      'Deployment/web -> ConfigMap/web-config',
      'Deployment/web -> PersistentVolumeClaim/data',
      'Deployment/web -> Secret/db',
      'Deployment/web -> ServiceAccount/web',
      'HorizontalPodAutoscaler/web -> Deployment/web',
      'Ingress/web -> Service/web',
      'Service/web -> Deployment/web',
    }, edges(graph))
    local missing = vim.tbl_map(
      function(n) return n.id end,
      vim.tbl_filter(function(n) return n.missing end, graph.nodes)
    )
    table.sort(missing)
    assert.same(
      { 'PersistentVolumeClaim/data', 'Secret/db', 'ServiceAccount/web' },
      missing
    )
  end)

  it('draws compose services and what they depend on', function()
    local graph = arch.compose({
      services = {
        web = { image = 'nginx:1.27', depends_on = { 'api' } },
        api = {
          depends_on = { db = { condition = 'service_healthy' }, ghost = {} },
        },
        db = { image = 'postgres:16' },
      },
    })
    assert.same({ 'api -> db', 'web -> api' }, edges(graph))
    assert.equals('db\npostgres:16', graph.nodes[2].label)
  end)

  it('writes D2, quoting what needs it', function()
    local lines = arch.d2({
      nodes = {
        { id = 'a "b"', label = 'a\nb' },
        { id = 'c', label = 'c', missing = true },
      },
      edges = { { from = 'a "b"', to = 'c', label = 'uses' } },
    }, 'T')
    assert.same({
      '# T',
      '# Written by :DyArchitecture; edit freely.',
      'direction: right',
      '',
      [["a \"b\"": {label: "a\nb"}]],
      [["c": {label: "c\n(missing)"; style.stroke-dash: 4}]],
      '',
      [["a \"b\"" -> "c": "uses"]],
    }, lines)
  end)

  it('reads the manifests of a directory through yq', function()
    if vim.fn.executable('yq') ~= 1 then
      assert(not vim.env.CI, 'no yq on CI')
      return pending('yq is not installed')
    end
    local dir, cleanup = h.tmpdir()
    h.write(dir .. '/app.yaml', {
      'apiVersion: v1',
      'kind: Service',
      'metadata: {name: web}',
      'spec: {selector: {app: web}}',
      '---',
      'apiVersion: apps/v1',
      'kind: Deployment',
      'metadata: {name: web}',
      'spec: {template: {metadata: {labels: {app: web}}}}',
    })
    h.write(dir .. '/values.yaml', { 'replicas: 2' })
    -- A template and a broken file are left out, not fatal
    h.write(dir .. '/template.yaml', { '{{- if .Values.x }}', 'kind: X' })
    h.write(dir .. '/broken.yaml', { 'a: [' })
    vim.cmd.edit(dir .. '/app.yaml')
    vim.bo.filetype = 'yaml'
    local graph, title, skipped, done
    arch.read(function(g, t, s)
      graph, title, skipped, done = g, t, s, true
    end)
    -- yq runs off the main loop
    assert.is_nil(done)
    assert.is_true(vim.wait(5000, function() return done end, 10))
    assert.equals('Kubernetes: ' .. vim.fn.fnamemodify(dir, ':~'), title)
    assert.same({ 'Service/web -> Deployment/web' }, edges(graph))
    assert.same({ 'broken.yaml', 'template.yaml' }, skipped)

    local notes = {}
    local restore = h.stub(
      vim,
      'notify',
      function(msg) table.insert(notes, msg) end
    )
    arch.open()
    assert.is_true(vim.wait(5000, function() return #notes > 0 end, 10))
    restore()
    assert.is_truthy(
      notes[1]:find('left out: broken.yaml, template.yaml', 1, true)
    )
    assert.equals('d2', vim.bo.filetype)
    assert.is_truthy(
      vim.list_contains(
        vim.api.nvim_buf_get_lines(0, 0, -1, false),
        '"Service/web" -> "Deployment/web": "selects"'
      )
    )
    cleanup()
  end)

  it('says what it draws', function()
    local notes = {}
    local restore = h.stub(
      vim,
      'notify',
      function(msg) table.insert(notes, msg) end
    )
    vim.api.nvim_set_current_buf(h.buffer({ filetype = 'lua' }))
    arch.open()
    restore()
    assert.same(
      { 'Draws Terraform, Kubernetes manifests and compose files' },
      notes
    )
  end)
end)
