return {
  -- Project setting
  {
    'mrjones2014/codesettings.nvim',
    -- A server starting `require`s it, which loads it then
    cmd = 'Codesettings',
    keys = {
      {
        '<leader>pss',
        '<cmd>Codesettings show<cr>',
        desc = 'LSP settings of the clients',
      },
      {
        '<leader>psl',
        '<cmd>Codesettings local<cr>',
        desc = 'Project settings',
      },
      {
        '<leader>psf',
        '<cmd>Codesettings files<cr>',
        desc = 'Project settings files',
      },
      {
        '<leader>pse',
        '<cmd>Codesettings edit<cr>',
        desc = 'Edit project settings',
      },
    },
  },
  {
    -- Integrate project management with which-key
    'folke/which-key.nvim',
    opts = {
      spec = {
        { '<leader>p', group = 'project' },
        { '<leader>ps', group = 'settings (codesettings)' },
      },
    },
  },
  {
    -- Open alternative files in the project
    'rgroli/other.nvim',
    main = 'other-nvim',
    cmd = { 'Other', 'OtherTabNew', 'OtherSplit', 'OtherVSplit', 'OtherClear' },
    opts = {
      mappings = {
        'angular',
        'laravel',
        'rails',
        'golang',
        'python',
        'react',
        'rust',
        {
          pattern = '/src/(.*).sh$',
          target = '/test/%1.bats',
          context = 'test',
        },
      },
    },
    keys = {
      {
        '<leader>pa',
        function() require('other-nvim').openVSplit() end,
        desc = 'Open alternative file',
        -- Not in a terminal: `<leader>` is a space there, typed all the time
      },
    },
  },
  {
    -- Devcontainer
    'esensar/nvim-dev-container',
    -- stylua: ignore
    keys = {
      { '<leader>pd', '', desc = '+devcontainer' },
      { '<leader>pds', '<cmd>DevcontainerStart<cr>', desc = 'Start Devcontainer' },
      { '<leader>pda', '<cmd>DevcontainerAttach<cr>', desc = 'Attach to Devcontainer' },
      { '<leader>pde', '<cmd>DevcontainerExec<cr>', desc = 'Exec in Devcontainer' },
      { '<leader>pdl', '<cmd>DevcontainerLogs<cr>', desc = 'Devcontainer Logs' },
      { '<leader>pdx', '<cmd>DevcontainerStop<cr>', desc = 'Stop Devcontainer' },
      { '<leader>pdc', '<cmd>DevcontainerEditNearestConfig<cr>', desc = 'Edit Devcontainer Config' },
    },
    -- The commands only exist once `setup` has run
    cmd = {
      'DevcontainerStart',
      'DevcontainerAttach',
      'DevcontainerExec',
      'DevcontainerStop',
      'DevcontainerStopAll',
      'DevcontainerRemoveAll',
      'DevcontainerLogs',
      'DevcontainerEditNearestConfig',
    },
    opts = {},
    dependencies = {
      'nvim-treesitter/nvim-treesitter',
      opts = function(_, opts)
        opts.ensure_installed = vim.list_extend(opts.ensure_installed, {
          'json', -- for devcontainer.json
        })
      end,
    },
  },
}
