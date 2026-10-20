-- `:DySbom`: what this editor runs that it did not write, as CycloneDX, what
-- OSV knows to be wrong with it, and the licenses it comes under. The module
-- only loads when asked.
vim.api.nvim_create_user_command(
  'DySbom',
  function(args) require('tools.sbom').command(args) end,
  {
    nargs = '?',
    complete = function(lead)
      return vim.list_extend(
        vim.tbl_filter(
          function(word) return word:find(lead, 1, true) == 1 end,
          { 'osv', 'lock', 'license' }
        ),
        vim.fn.getcompletion(lead, 'file')
      )
    end,
    desc = 'Plugins and Mason packages as a CycloneDX SBOM, or asked of OSV',
  }
)
