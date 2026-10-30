-- Defaults first, through a `map` that leaves alone any key a plugin spec
-- claims with `keys`
local map = require('util.plugin').safe_keymap_set
local root = require('util.root')
local format = require('util.format')

-- better up/down
map(
  { 'n', 'x' },
  'j',
  "v:count == 0 ? 'gj' : 'j'",
  { desc = 'Down', expr = true, silent = true }
)
map(
  { 'n', 'x' },
  '<Down>',
  "v:count == 0 ? 'gj' : 'j'",
  { desc = 'Down', expr = true, silent = true }
)
map(
  { 'n', 'x' },
  'k',
  "v:count == 0 ? 'gk' : 'k'",
  { desc = 'Up', expr = true, silent = true }
)
map(
  { 'n', 'x' },
  '<Up>',
  "v:count == 0 ? 'gk' : 'k'",
  { desc = 'Up', expr = true, silent = true }
)

-- Move to window using the <ctrl> hjkl keys
map('n', '<C-h>', '<C-w>h', { desc = 'Go to Left Window', remap = true })
map('n', '<C-j>', '<C-w>j', { desc = 'Go to Lower Window', remap = true })
map('n', '<C-k>', '<C-w>k', { desc = 'Go to Upper Window', remap = true })
map('n', '<C-l>', '<C-w>l', { desc = 'Go to Right Window', remap = true })

-- Move Lines
map(
  'n',
  '<A-j>',
  "<cmd>execute 'move .+' . v:count1<cr>==",
  { desc = 'Move Down' }
)
map(
  'n',
  '<A-k>',
  "<cmd>execute 'move .-' . (v:count1 + 1)<cr>==",
  { desc = 'Move Up' }
)
map('i', '<A-j>', '<esc><cmd>m .+1<cr>==gi', { desc = 'Move Down' })
map('i', '<A-k>', '<esc><cmd>m .-2<cr>==gi', { desc = 'Move Up' })
map(
  'v',
  '<A-j>',
  ":<C-u>execute \"'<,'>move '>+\" . v:count1<cr>gv=gv",
  { desc = 'Move Down' }
)
map(
  'v',
  '<A-k>',
  ":<C-u>execute \"'<,'>move '<-\" . (v:count1 + 1)<cr>gv=gv",
  { desc = 'Move Up' }
)

-- buffers
map('n', '<S-h>', '<cmd>bprevious<cr>', { desc = 'Prev Buffer' })
map('n', '<S-l>', '<cmd>bnext<cr>', { desc = 'Next Buffer' })
map('n', '[b', '<cmd>bprevious<cr>', { desc = 'Prev Buffer' })
map('n', ']b', '<cmd>bnext<cr>', { desc = 'Next Buffer' })
map('n', '<leader>bb', '<cmd>e #<cr>', { desc = 'Switch to Other Buffer' })
map(
  'n',
  '<leader>bd',
  function() Snacks.bufdelete() end,
  { desc = 'Delete Buffer' }
)
map(
  'n',
  '<leader>bo',
  function() Snacks.bufdelete.other() end,
  { desc = 'Delete Other Buffers' }
)
map(
  'n',
  '<leader>bi',
  function() Snacks.bufdelete.invisible() end,
  { desc = 'Delete Invisible Buffers' }
)
map('n', '<leader>bD', '<cmd>:bd<cr>', { desc = 'Delete Buffer and Window' })
map('n', '<leader>by', function()
  -- The system clipboard outlives the buffer and is read by other programs
  if vim.b.dy_encrypted or require('util.sensitive').is_sensitive(0) then
    return require('util.notify').titled('Keys')(
      'Not copying a sensitive buffer to the clipboard',
      vim.log.levels.WARN
    )
  end
  vim.cmd('%yank +')
end, { desc = 'Yank Buffer' })
map('n', '<leader>bR', function()
  -- Changes are only thrown away once that is confirmed
  if
    vim.bo.modified
    and vim.fn.confirm('Discard the changes?', '&Discard\n&Keep', 2) ~= 1
  then
    return
  end
  vim.cmd.edit({ bang = true })
end, { desc = 'Reload Buffer (discard changes)' })
map('n', '<leader>bf', function()
  vim.ui.select(
    vim.fn.getcompletion('', 'filetype'),
    { prompt = 'Filetype' },
    function(filetype)
      if filetype then vim.bo.filetype = filetype end
    end
  )
end, { desc = 'Set Filetype' })

-- Clear search and stop snippet on escape
map({ 'i', 'n', 's' }, '<esc>', function()
  vim.cmd('noh')
  require('util.cmp').actions.snippet_stop()
  return '<esc>'
end, { expr = true, desc = 'Escape and Clear hlsearch' })

-- Clear search, diff update and redraw
-- taken from runtime/lua/_editor.lua
map(
  'n',
  '<leader>ur',
  '<Cmd>nohlsearch<Bar>diffupdate<Bar>normal! <C-L><CR>',
  { desc = 'Redraw / Clear hlsearch / Diff Update' }
)

-- https://github.com/mhinz/vim-galore#saner-behavior-of-n-and-n
map(
  'n',
  'n',
  "'Nn'[v:searchforward].'zv'",
  { expr = true, desc = 'Next Search Result' }
)
map(
  'x',
  'n',
  "'Nn'[v:searchforward]",
  { expr = true, desc = 'Next Search Result' }
)
map(
  'o',
  'n',
  "'Nn'[v:searchforward]",
  { expr = true, desc = 'Next Search Result' }
)
map(
  'n',
  'N',
  "'nN'[v:searchforward].'zv'",
  { expr = true, desc = 'Prev Search Result' }
)
map(
  'x',
  'N',
  "'nN'[v:searchforward]",
  { expr = true, desc = 'Prev Search Result' }
)
map(
  'o',
  'N',
  "'nN'[v:searchforward]",
  { expr = true, desc = 'Prev Search Result' }
)

-- Add undo break-points
map('i', ',', ',<c-g>u')
map('i', '.', '.<c-g>u')
map('i', ';', ';<c-g>u')

-- save file
map({ 'i', 'x', 'n', 's' }, '<C-s>', '<cmd>w<cr><esc>', { desc = 'Save File' })

--keywordprg
map('n', '<leader>K', '<cmd>norm! K<cr>', { desc = 'Keywordprg' })

-- better indenting
map('x', '<', '<gv')
map('x', '>', '>gv')

-- commenting
map(
  'n',
  'gco',
  'o<esc>Vcx<esc><cmd>normal gcc<cr>fxa<bs>',
  { desc = 'Add Comment Below' }
)
map(
  'n',
  'gcO',
  'O<esc>Vcx<esc><cmd>normal gcc<cr>fxa<bs>',
  { desc = 'Add Comment Above' }
)

-- lazy
map('n', '<leader>l', '<cmd>Lazy<cr>', { desc = 'Lazy' })

-- new file
map('n', '<leader>fn', '<cmd>enew<cr>', { desc = 'New File' })

-- `[q` and `]q` are Neovim's own, which take a count; `trouble.nvim` claims
-- them when it is loaded.

-- formatting
map(
  { 'n', 'x' },
  '<leader>cf',
  function() format({ force = true }) end,
  { desc = 'Format' }
)

-- Every file can be renamed, with or without a language server to tell
map(
  'n',
  '<leader>cR',
  function() require('util.rename').rename_file() end,
  { desc = 'Rename File' }
)

-- diagnostic
local diagnostic_goto = function(next, severity)
  return function()
    vim.diagnostic.jump({
      count = (next and 1 or -1) * vim.v.count1,
      severity = severity and vim.diagnostic.severity[severity] or nil,
      on_jump = function(diagnostic, bufnr)
        if not diagnostic then return end
        vim.diagnostic.open_float({
          bufnr = bufnr,
          scope = 'cursor',
          focus = false,
        })
      end,
    })
  end
end
map('n', '<leader>cd', vim.diagnostic.open_float, { desc = 'Line Diagnostics' })
map('n', ']d', diagnostic_goto(true), { desc = 'Next Diagnostic' })
map('n', '[d', diagnostic_goto(false), { desc = 'Prev Diagnostic' })
map('n', ']e', diagnostic_goto(true, 'ERROR'), { desc = 'Next Error' })
map('n', '[e', diagnostic_goto(false, 'ERROR'), { desc = 'Prev Error' })
map('n', ']w', diagnostic_goto(true, 'WARN'), { desc = 'Next Warning' })
map('n', '[w', diagnostic_goto(false, 'WARN'), { desc = 'Prev Warning' })

-- The diagnostics of the cursor line, to paste into an issue or a chat
map('n', '<leader>xc', function()
  -- A linter's message may quote the line it is about
  if vim.b.dy_encrypted or require('util.sensitive').is_sensitive(0) then
    return require('util.notify').titled('Keys')(
      'Not copying a sensitive buffer to the clipboard',
      vim.log.levels.WARN
    )
  end
  local lnum = vim.api.nvim_win_get_cursor(0)[1] - 1
  local messages = vim.tbl_map(
    function(diagnostic)
      return diagnostic.source
          and ('%s: %s'):format(diagnostic.source, diagnostic.message)
        or diagnostic.message
    end,
    vim.diagnostic.get(0, { lnum = lnum })
  )
  if #messages == 0 then
    return vim.notify('No diagnostics on this line', vim.log.levels.WARN)
  end
  vim.fn.setreg('+', table.concat(messages, '\n'))
  vim.notify(('Copied %d diagnostics'):format(#messages))
end, { desc = 'Copy Line Diagnostics' })

-- Merge conflict markers, diff3's `|||||||` included
local conflict_goto = function(next)
  return function()
    for _ = 1, vim.v.count1 do
      local found = vim.fn.search(
        [[^\(<<<<<<<\||||||||\|=======\|>>>>>>>\)\( \|$\)]],
        next and 'W' or 'bW'
      )
      if found == 0 then return end
    end
  end
end
map('n', ']x', conflict_goto(true), { desc = 'Next Conflict Marker' })
map('n', '[x', conflict_goto(false), { desc = 'Prev Conflict Marker' })

-- stylua: ignore start

-- toggle options
format.snacks_toggle():map("<leader>uf")
format.snacks_toggle(true):map("<leader>uF")
Snacks.toggle.option("spell", { name = "Spelling" }):map("<leader>us")
Snacks.toggle.option("wrap", { name = "Wrap" }):map("<leader>uw")
Snacks.toggle.option("relativenumber", { name = "Relative Number" }):map("<leader>uL")
Snacks.toggle.diagnostics():map("<leader>ud")
Snacks.toggle.line_number():map("<leader>ul")
Snacks.toggle.option("conceallevel", { off = 0, on = vim.o.conceallevel > 0 and vim.o.conceallevel or 2, name = "Conceal Level" }):map("<leader>uc")
Snacks.toggle.option("colorcolumn", { off = "", on = vim.o.colorcolumn ~= "" and vim.o.colorcolumn or "+1", name = "Color Column" }):map("<leader>u|")
Snacks.toggle.option("showtabline",{ off = 0, on = vim.o.showtabline > 0 and vim.o.showtabline or 2, name = "Tabline" }):map("<leader>uA")
Snacks.toggle.treesitter():map("<leader>uT")
Snacks.toggle.option("background", { off = "light", on = "dark" , name = "Dark Background" }):map("<leader>ub")
Snacks.toggle.dim():map("<leader>uD")
Snacks.toggle.animate():map("<leader>ua")
Snacks.toggle.indent():map("<leader>ug")
Snacks.toggle.scroll():map("<leader>uS")
Snacks.toggle.profiler():map("<leader>dpp")
Snacks.toggle.profiler_highlights():map("<leader>dph")

Snacks.toggle.inlay_hints():map("<leader>uh")

-- lazygit
if vim.fn.executable("lazygit") == 1 then
  map("n", "<leader>gg", function() Snacks.lazygit( { cwd = root.git() }) end, { desc = "Lazygit (Root Dir)" })
  map("n", "<leader>gG", function() Snacks.lazygit() end, { desc = "Lazygit (cwd)" })
end

map("n", "<leader>gL", function() Snacks.picker.git_log() end, { desc = "Git Log (cwd)" })
map("n", "<leader>gb", function() Snacks.picker.git_log_line() end, { desc = "Git Blame Line" })
map("n", "<leader>gf", function() Snacks.picker.git_log_file() end, { desc = "Git Current File History" })
-- the history of a definition, and who owns a file (`tools.history`, `tools.owners`)
map("n", "<leader>gF", "<cmd>DyHistory<cr>", { desc = "Function History" })
map("x", "<leader>gF", ":DyHistory<cr>", { desc = "Selection History" })
map("n", "<leader>gO", "<cmd>DyOwners<cr>", { desc = "Code Owners" })
map("n", "<leader>gU", "<cmd>DyOwners unowned<cr>", { desc = "Files Nobody Owns" })
map("n", "<leader>gl", function() Snacks.picker.git_log({ cwd = root.git() }) end, { desc = "Git Log" })
map({ "n", "x" }, "<leader>gB", function() Snacks.gitbrowse() end, { desc = "Git Browse (open)" })
map({"n", "x" }, "<leader>gY", function()
  Snacks.gitbrowse({ open = function(url) vim.fn.setreg("+", url) end, notify = false })
end, { desc = "Git Browse (copy)" })

-- the state of the project on one page (`tools.project`)
map("n", "<leader>pp", "<cmd>DyProject<cr>", { desc = "Project Overview" })

-- jira, on the issue the branch is named after or one picked (`tools.jira`)
map("n", "<leader>pjj", "<cmd>DyJira<cr>", { desc = "My Issues" })
map("n", "<leader>pjs", "<cmd>DyJira search<cr>", { desc = "Search Issues (JQL)" })
map("n", "<leader>pjb", "<cmd>DyJira branch<cr>", { desc = "Branch From Issue" })
map("n", "<leader>pjm", "<cmd>DyJira move<cr>", { desc = "Move Issue" })
map("n", "<leader>pjw", "<cmd>DyJira worklog<cr>", { desc = "Log Work" })
map("n", "<leader>pjv", "<cmd>DyJira view<cr>", { desc = "View Issue" })
map("n", "<leader>pjo", "<cmd>DyJira open<cr>", { desc = "Open Issue in Browser" })
map("n", "<leader>pji", "<cmd>DyJira insert<cr>", { desc = "Insert Issue Key" })
map("n", "<leader>pjy", "<cmd>DyJira copy<cr>", { desc = "Copy Issue Key" })

-- decision records of the project (`tools.adr`)
map("n", "<leader>prr", "<cmd>DyAdr list<cr>", { desc = "Decision Records" })
map("n", "<leader>prn", "<cmd>DyAdr new<cr>", { desc = "New Decision" })
map("n", "<leader>prs", "<cmd>DyAdr status<cr>", { desc = "Set Status" })
map("n", "<leader>prS", "<cmd>DyAdr supersede<cr>", { desc = "Supersede This Decision" })
map("n", "<leader>prp", "<cmd>DyPostmortem new<cr>", { desc = "New Postmortem" })
map("n", "<leader>prP", "<cmd>DyPostmortem<cr>", { desc = "Postmortem Open Actions" })
map("n", "<leader>pR", "<cmd>DyRoot<cr>", { desc = "Project Roots" })

-- reviewing a pull request of any forge remote (`tools.review`)
map("n", "<leader>pvv", "<cmd>DyReview pick<cr>", { desc = "Review a Pull Request" })
map("n", "<leader>pvb", "<cmd>DyReview branch<cr>", { desc = "Review This Branch's Pull Request" })
map("n", "<leader>pva", "<cmd>DyReview ai<cr>", { desc = "AI Review Pass" })
map("n", "<leader>pvd", "<cmd>DyReview drafts<cr>", { desc = "Review Drafts" })
map("n", "<leader>pvs", "<cmd>DyReview submit<cr>", { desc = "Submit Review" })
map("n", "<leader>pvq", "<cmd>DyReview close<cr>", { desc = "Close Review" })

-- architecture work (`tools.nfr`, `tools.cidr`, `tools.war`, `tools.deps`, `tools.threat`)
map("n", "<leader>pAn", "<cmd>DyNfr<cr>", { desc = "Service Levels (NFR)" })
-- The objective is typed on the command line
map("n", "<leader>pAs", function() vim.api.nvim_feedkeys(":DyNfr slo ", "n", false) end, { desc = "SLO Burn-Rate Alerts" })
map("n", "<leader>pAc", "<cmd>DyCidr<cr>", { desc = "Explain IPv4 Range" })
map("n", "<leader>pAw", "<cmd>DyWar<cr>", { desc = "Well-Architected Open Questions" })
map("n", "<leader>pAW", "<cmd>DyWar new<cr>", { desc = "New Well-Architected Review" })
map("n", "<leader>pAd", "<cmd>DyDeps<cr>", { desc = "Check Dependency Rules" })
map("n", "<leader>pAt", "<cmd>DyThreat<cr>", { desc = "Threat Model Open Questions" })
map("n", "<leader>pAT", "<cmd>DyThreat new<cr>", { desc = "New Threat Model" })

-- infrastructure beyond the buffer: what a directory declares, what a
-- certificate or a token says, logs, and the cluster in use
map("n", "<leader>ia", "<cmd>DyArchitecture<cr>", { desc = "Architecture Diagram" })
map("n", "<leader>ii", "<cmd>DyInspect<cr>", { desc = "Decode Certificate, Key or JWT" })
map("n", "<leader>ie", "<cmd>DyInspect expiry<cr>", { desc = "Certificate Expiry" })
map("n", "<leader>ix", "<cmd>DyCert<cr>", { desc = "Certificate Chain of File" })
map("n", "<leader>il", function()
  local file = vim.api.nvim_buf_get_name(0)
  if file == "" then return vim.notify("The buffer has no file", vim.log.levels.WARN, { title = "DyNeo" }) end
  vim.cmd({ cmd = "DyLog", args = { file } })
end, { desc = "Read File as Log" })
map("n", "<leader>ij", "<cmd>DyLog journal<cr>", { desc = "Journal" })
-- The pod is typed on the command line, where it completes
map("n", "<leader>ip", function() vim.api.nvim_feedkeys(":DyLog kube ", "n", false) end, { desc = "Pod Logs" })
map("n", "<leader>it", "<cmd>DyCron<cr>", { desc = "Explain Cron Schedule" })
map("n", "<leader>iq", "<cmd>DyQuery<cr>", { desc = "Query JSON/YAML (jq, yq)" })
map("n", "<leader>ir", "<cmd>DyRego<cr>", { desc = "Rego Playground" })
map("n", "<leader>iR", "<cmd>DyRego test<cr>", { desc = "Rego Tests and Coverage" })
map("n", "<leader>id", "<cmd>DyEnvDiff<cr>", { desc = "Compare Environments" })
map("n", "<leader>im", "<cmd>DyPromQL<cr>", { desc = "Run PromQL Under Cursor" })
map("x", "<leader>im", ":DyPromQL<cr>", { desc = "Run PromQL Under Cursor" })
map("n", "<leader>iM", "<cmd>DyPromQL test<cr>", { desc = "Check Prometheus Rules" })
map("n", "<leader>ih", "<cmd>DyCert host<cr>", { desc = "Certificates a Host Serves" })
map("n", "<leader>ic", "<cmd>DyKube context<cr>", { desc = "Switch Kube Context" })
map("n", "<leader>in", "<cmd>DyKube namespace<cr>", { desc = "Switch Kube Namespace" })

-- data files and SQL over them, through DuckDB (`tools.data`)
map("n", "<leader>Dd", "<cmd>DyData<cr>", { desc = "Sum Up Data File" })
map("n", "<leader>Ds", "<cmd>DyData stats<cr>", { desc = "Column Statistics" })
map("n", "<leader>Dq", "<cmd>DyData sql<cr>", { desc = "Run SQL in DuckDB" })
map("x", "<leader>Dq", ":DyData sql<cr>", { desc = "Run SQL in DuckDB" })

-- supply chain, scanner findings and the AI guard (`tools.lazy-quarantine`,
-- `tools.sbom`, `tools.outdated`, `tools.images`, `tools.sarif`, `tools.hex`,
-- `util.ai_guard`)
map("n", "<leader>kq", "<cmd>DyQuarantine<cr>", { desc = "Held Back Updates" })
map("n", "<leader>kr", "<cmd>DyQuarantine review<cr>", { desc = "Review Pending Updates" })
map("n", "<leader>ks", "<cmd>DySbom<cr>", { desc = "SBOM of the Editor" })
map("n", "<leader>ko", "<cmd>DySbom osv<cr>", { desc = "Vulnerable Plugins (OSV)" })
map("n", "<leader>kl", "<cmd>DySbom lock<cr>", { desc = "Vulnerable Dependencies (OSV)" })
map("n", "<leader>kc", "<cmd>DySbom license<cr>", { desc = "Licenses of the Editor" })
map("n", "<leader>ku", "<cmd>DyOutdated<cr>", { desc = "Outdated Dependencies" })
map("n", "<leader>kU", "<cmd>DyOutdated bump<cr>", { desc = "Bump Dependency on Line" })
map("n", "<leader>ki", "<cmd>DyImageScan<cr>", { desc = "Scan Images" })
map("n", "<leader>kp", "<cmd>DyImagePin<cr>", { desc = "Pin Images to Digests" })
map("n", "<leader>kv", "<cmd>DyImageVerify<cr>", { desc = "Verify Image Signatures" })
map("n", "<leader>kf", "<cmd>DySarif<cr>", { desc = "Findings of a SARIF Report" })
map("n", "<leader>kh", "<cmd>DyHex<cr>", { desc = "Hex Dump of the File" })
map("n", "<leader>ka", "<cmd>DyAiGuardCheck<cr>", { desc = "Why Kept From AI" })
map("n", "<leader>kA", "<cmd>DyAiGuardAllow<cr>", { desc = "Allow Buffer for AI" })
map("n", "<leader>kR", "<cmd>DyAiGuardAllow!<cr>", { desc = "Recheck Buffer for AI" })
map("n", "<leader>kL", "<cmd>DyAiGuardLog<cr>", { desc = "AI Handover Log" })

-- AI actions (`tools.ai`): a prompt about the selection, or the whole buffer
map("n", "<leader>ai", "<cmd>DyAi<cr>", { desc = "AI Actions" })
map("x", "<leader>ai", ":DyAi<cr>", { desc = "AI Actions" })
map("n", "<leader>al", "<cmd>DyAi prompts<cr>", { desc = "AI Prompt Library" })
map("x", "<leader>al", ":DyAi prompts<cr>", { desc = "AI Prompt Library" })
map("n", "<leader>ae", "<cmd>DyAi explain<cr>", { desc = "AI Explain" })
map("x", "<leader>ae", ":DyAi explain<cr>", { desc = "AI Explain" })
map("n", "<leader>ar", "<cmd>DyAi review<cr>", { desc = "AI Review" })
map("x", "<leader>ar", ":DyAi review<cr>", { desc = "AI Review" })
map("n", "<leader>au", "<cmd>DyAi tests<cr>", { desc = "AI Write Tests" })
map("x", "<leader>au", ":DyAi tests<cr>", { desc = "AI Write Tests" })
map("n", "<leader>ao", "<cmd>DyAi docs<cr>", { desc = "AI Document" })
map("x", "<leader>ao", ":DyAi docs<cr>", { desc = "AI Document" })
map("n", "<leader>ax", "<cmd>DyAi fix<cr>", { desc = "AI Fix Diagnostics" })
map("x", "<leader>ax", ":DyAi fix<cr>", { desc = "AI Fix Diagnostics" })
map("n", "<leader>ag", "<cmd>DyAi staged<cr>", { desc = "AI Review Staged Changes" })
map("n", "<leader>aG", "<cmd>DyAi pr<cr>", { desc = "AI Pull Request Description" })

-- spell files from the word lists (`plugin/spell.lua`); the list is typed
map("n", "<leader>zm", function() vim.api.nvim_feedkeys(":DySpell ", "n", false) end, { desc = "Make Spell File" })

-- quit
map("n", "<leader>qq", "<cmd>qa<cr>", { desc = "Quit All" })

-- highlights under cursor
map("n", "<leader>ui", vim.show_pos, { desc = "Inspect Pos" })
map("n", "<leader>uI", function() vim.treesitter.inspect_tree() vim.api.nvim_input("I") end, { desc = "Inspect Tree" })

-- floating terminal
map("n", "<leader>fT", function() Snacks.terminal() end, { desc = "Terminal (cwd)" })
map("n", "<leader>ft", function() Snacks.terminal(nil, { cwd = root() }) end, { desc = "Terminal (Root Dir)" })
map({"n","t"}, "<c-/>",function() Snacks.terminal.focus(nil, { cwd = root() }) end, { desc = "Terminal (Root Dir)" })
map({"n","t"}, "<c-_>",function() Snacks.terminal.focus(nil, { cwd = root() }) end, { desc = "which_key_ignore" })

-- windows
map("n", "<leader>-", "<C-W>s", { desc = "Split Window Below", remap = true })
map("n", "<leader>|", "<C-W>v", { desc = "Split Window Right", remap = true })
map("n", "<leader>wd", "<C-W>c", { desc = "Delete Window", remap = true })
Snacks.toggle.zoom():map("<leader>wm")
Snacks.toggle.zen():map("<leader>uz")

-- tabs
map("n", "<leader><tab>l", "<cmd>tablast<cr>", { desc = "Last Tab" })
map("n", "<leader><tab>o", "<cmd>tabonly<cr>", { desc = "Close Other Tabs" })
map("n", "<leader><tab>f", "<cmd>tabfirst<cr>", { desc = "First Tab" })
map("n", "<leader><tab><tab>", "<cmd>tabnew<cr>", { desc = "New Tab" })
map("n", "<leader><tab>]", "<cmd>tabnext<cr>", { desc = "Next Tab" })
map("n", "<leader><tab>d", "<cmd>tabclose<cr>", { desc = "Close Tab" })
map("n", "<leader><tab>[", "<cmd>tabprevious<cr>", { desc = "Previous Tab" })

-- lua
map({"n", "x"}, "<localleader>r", function() Snacks.debug.run() end, { desc = "Run Lua", ft = "lua" })
-- stylua: ignore end

--- Create command abbreviation that only fires as a whole command
---
--- A plain `cnoreabbrev` expands wherever its word turns up, so `:e foo/W `
--- came out as `:e foo/w `. Checking the command line as a whole keeps the
--- shorthand and drops the surprise.
---@param input string key sequence
---@param replace string key sequence
local function cabbrev(input, replace)
  map('ca', input, function()
    if vim.fn.getcmdtype() == ':' and vim.fn.getcmdline() == input then
      return replace
    end
    return input
  end, { expr = true, desc = ':' .. replace })
end

-- Only a whole command expands, so `ww` typed in a search or a path stays.
-- `plugin/sudo_write.lua` defines the command.
cabbrev('ww', 'DySudoWrite')

-- No one is really happy until you have these shortcuts
cabbrev('W!', 'w!')
cabbrev('Q!', 'q!')
cabbrev('Qa!', 'qa!')
cabbrev('Wq', 'wq')
cabbrev('Wa', 'wa')
cabbrev('wQ', 'wq')
cabbrev('WQ', 'wq')
cabbrev('W', 'w')
cabbrev('Q', 'q')
cabbrev('Qa', 'qa')

-- Neovim's own LSP keys under `gr` can never be reached: `gr` itself is the
-- references picker, set `nowait`. The same actions sit under `<leader>c`.
for mode, keys in pairs({
  n = { 'grn', 'gra', 'grr', 'gri', 'grt', 'grx' },
  x = { 'gra' },
}) do
  for _, lhs in ipairs(keys) do
    pcall(vim.keymap.del, mode, lhs)
  end
end

-- Change word faster. Left as it is where nothing can be changed, and in the
-- command-line window, where `<C-c>` goes back to the command line.
map('n', '<C-c>', function()
  if vim.bo.modifiable and vim.fn.getcmdwintype() == '' then return 'ciw' end
  return '<C-c>'
end, { desc = 'Change word', expr = true })

-- Smart delete: clearing blank lines sends them to the black-hole register,
-- so it does not overwrite what was yanked.
-- Only whole-line commands are mapped: an operator such as `d}` starting on a
-- blank line still takes the paragraph after it, which must be kept. A register
-- given explicitly (`"add`) is always honoured.
local function default_register()
  local clipboard = vim.o.clipboard
  if clipboard:find('unnamedplus', 1, true) then return '+' end
  if clipboard:find('unnamed', 1, true) then return '*' end
  return '"'
end

local function all_blank(first, last)
  if first > last then
    first, last = last, first
  end
  for _, line in ipairs(vim.api.nvim_buf_get_lines(0, first - 1, last, false)) do
    if not line:match('^%s*$') then return false end
  end
  return true
end

local smart_delete = function(key, visual)
  if vim.v.register ~= default_register() then return key end
  local first = vim.fn.line(visual and 'v' or '.')
  local last = vim.fn.line('.')
  if not visual then last = first + vim.v.count1 - 1 end
  return (all_blank(first, last) and '"_' or '') .. key
end

-- `s` and `S` are left alone, they belong to `flash.nvim`.
-- Visual mode only (`x`): in Select mode these keys must type text.
for _, key in ipairs({ 'dd', 'cc', 'x', 'X', 'C' }) do
  map(
    'n',
    key,
    function() return smart_delete(key) end,
    { expr = true, desc = 'Smart delete' }
  )
end
for _, key in ipairs({ 'd', 'x', 'c', 'C', 'X' }) do
  map(
    'x',
    key,
    function() return smart_delete(key, true) end,
    { expr = true, desc = 'Smart delete' }
  )
end

-- Fast tab
for number = 1, 9 do
  map(
    'n',
    '<leader><tab>' .. number,
    '<cmd>tabn' .. number .. '<cr>',
    { desc = 'Go to Tab ' .. number }
  )
end

-- Copy path of current file
local copy_path = require('util.copy_path')
map('n', '<leader>fyy', copy_path.copy_relative, { desc = 'Path (relative)' })
map('n', '<leader>fyY', copy_path.copy_absolute, { desc = 'Path (absolute)' })
map(
  'n',
  '<leader>fyl',
  copy_path.copy_relative_with_line,
  { desc = 'Path (relative, :line)' }
)
map(
  'n',
  '<leader>fyL',
  copy_path.copy_absolute_with_line,
  { desc = 'Path (absolute, :line)' }
)
map(
  'n',
  '<leader>fyc',
  copy_path.copy_relative_with_line_column,
  { desc = 'Path (relative, :line:col)' }
)
map(
  'n',
  '<leader>fyC',
  copy_path.copy_absolute_with_line_column,
  { desc = 'Path (absolute, :line:col)' }
)
map(
  'n',
  '<leader>fyd',
  copy_path.copy_relative_directory,
  { desc = 'Directory (relative)' }
)
map(
  'n',
  '<leader>fyD',
  copy_path.copy_absolute_directory,
  { desc = 'Directory (absolute)' }
)
map('n', '<leader>fyP', copy_path.copy_project, { desc = 'Project Root' })
map('n', '<leader>fyn', copy_path.copy_filename, { desc = 'Filename' })
map(
  'n',
  '<leader>fyN',
  copy_path.copy_filename_no_ext,
  { desc = 'Filename (no ext)' }
)

-- Fast search and replace
-- Not silent: each leaves a command line to finish, which a silent mapping
-- would keep out of sight until the next key
map(
  'x',
  '/',
  '<Esc>/\\%V',
  { desc = 'Search in visual region', silent = false }
)
-- The selection is read in place rather than yanked, so the clipboard is left
-- alone, and is matched literally (`\V`) whatever it holds.
local function selected_pattern(delimiter)
  local text = vim.fn.getregion(
    vim.fn.getpos('v'),
    vim.fn.getpos('.'),
    { type = vim.fn.mode() }
  )
  local pattern = vim
    .fn
    .escape(table.concat(text, '\n'), '\\' .. delimiter)
    -- A raw newline is read as <CR>, which would run `:s` on the first line
    -- alone; `\n` still matches a line break under `\V`
    :gsub(
      '\n',
      '\\n'
    )
  -- The result is read as keys: a `<` must not start a key code
  return '\\V' .. pattern:gsub('<', '<lt>')
end
map(
  'x',
  '<C-f>',
  function() return '<Esc>/' .. selected_pattern('/') end,
  { desc = 'Search selected text', silent = false, expr = true }
)
map(
  'x',
  '<C-r>',
  function() return '<Esc>:%s#' .. selected_pattern('#') .. '#' end,
  { desc = 'Replace selected text', silent = false, expr = true }
)
