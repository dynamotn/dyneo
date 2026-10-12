return {
  {
    -- Generate annotation
    'danymat/neogen',
    cmd = 'Neogen',
    keys = {
      {
        '<leader>cn',
        function() require('neogen').generate() end,
        desc = 'Generate Annotations (Neogen)',
      },
      {
        '<leader>cN',
        function()
          require('neogen').generate({
            type = 'any',
            annotation_convention = { sh = 'sh_docs' },
          })
        end,
        ft = require('util.neogen').filetypes('sh_docs'),
        desc = 'Generate Annotations (sh-docs)',
      },
    },
    opts = function(_, opts)
      -- Expand through LuaSnip, the snippet engine of this config
      opts.snippet_engine = 'luasnip'
      opts.languages = vim.tbl_extend(
        'force',
        require('util.neogen').languages(),
        opts.languages or {}
      )
    end,
    config = function(_, opts)
      require('neogen').setup(opts)
      require('util.neogen').install_arg_sentinel_fixup()
    end,
  },
}
