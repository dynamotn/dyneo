return {
  {
    -- Catppuccin for both Dark (Macchiato) and Light (Latte) colorscheme
    'catppuccin/nvim',
    name = 'catppuccin',
    lazy = true,
    event = 'UIEnter',
    opts = {
      -- `auto` drops the fixed flavour and reads `background` instead, so
      -- the pair below is what actually decides. `util.day_night` owns that
      -- option, and re-running `:colorscheme` is all a switch takes.
      flavour = 'auto',
      background = {
        light = 'latte',
        dark = 'macchiato',
      },
      lsp_styles = {
        underlines = {
          errors = { 'undercurl' },
          hints = { 'undercurl' },
          warnings = { 'undercurl' },
          information = { 'undercurl' },
        },
      },
      -- Detecting integrations walks every installed plugin and loads
      -- catppuccin's whole mapping table on each startup, about a tenth of
      -- it. So they are named here instead, and a plugin added later with a
      -- catppuccin integration goes here too.
      auto_integrations = false,
      integrations = {
        avante = true,
        blink_cmp = true,
        dadbod_ui = true,
        dap = true,
        -- diffview-plus.nvim, set up when `glab` is there
        diffview = true,
        dropbar = { enabled = true },
        flash = true,
        gitsigns = true,
        grug_far = true,
        harpoon = true,
        lsp_trouble = true,
        markview = true,
        mason = true,
        mini = true,
        neotest = true,
        noice = true,
        octo = true,
        overseer = true,
        rainbow_delimiters = true,
        snacks = true,
        treesitter_context = true,
        which_key = true,
      },
      -- The terminal's 16 colours from the flavour, so a `:terminal` or a
      -- Snacks terminal follows the switch between day and night
      term_colors = true,
      transparent_background = false,
      dim_inactive = {
        enabled = true,
        shade = 'light',
        percentage = 0.5,
      },
      styles = {
        keywords = { 'italic', 'bold' },
        functions = { 'bold' },
      },
      custom_highlights = function(colors)
        local util = require('catppuccin.utils.colors')
        return {
          Type = { fg = colors.sapphire },
          -- Whitespace left at the end of a line, marked by `mini.hipatterns`
          DyTrailingWhitespace = { bg = colors.red },
          CurSearch = { fg = colors.mantle, bg = colors.peach },
          Search = { fg = colors.text, bg = colors.blue },
          -- The completion menu is blink's, whose groups only fall back on
          -- nvim-cmp's under `use_nvim_cmp_as_default`
          BlinkCmpLabelMatch = {
            fg = colors.blue,
            bg = colors.none,
            bold = true,
          },
          BlinkCmpSource = {
            fg = colors.sapphire,
            bg = colors.none,
            bold = true,
          },

          BlinkCmpKindField = {
            fg = util.lighten(colors.surface0, 0.9, colors.green),
            bg = colors.green,
          },
          BlinkCmpKindProperty = {
            fg = util.lighten(colors.surface0, 0.9, colors.green),
            bg = colors.green,
          },
          BlinkCmpKindUnit = {
            fg = util.lighten(colors.surface0, 0.9, colors.green),
            bg = colors.green,
          },

          BlinkCmpKindText = {
            fg = util.lighten(colors.surface0, 0.9, colors.teal),
            bg = colors.teal,
          },
          BlinkCmpKindEnum = {
            fg = util.lighten(colors.surface0, 0.9, colors.teal),
            bg = colors.teal,
          },
          BlinkCmpKindKeyword = {
            fg = util.lighten(colors.surface0, 0.9, colors.teal),
            bg = colors.teal,
          },

          BlinkCmpKindEvent = {
            fg = util.lighten(colors.surface0, 0.9, colors.blue),
            bg = colors.blue,
          },
          BlinkCmpKindFunction = {
            fg = util.lighten(colors.surface0, 0.9, colors.blue),
            bg = colors.blue,
          },
          BlinkCmpKindStruct = {
            fg = util.lighten(colors.surface0, 0.9, colors.blue),
            bg = colors.blue,
          },
          BlinkCmpKindConstructor = {
            fg = util.lighten(colors.surface0, 0.9, colors.blue),
            bg = colors.blue,
          },
          BlinkCmpKindModule = {
            fg = util.lighten(colors.surface0, 0.9, colors.blue),
            bg = colors.blue,
          },
          BlinkCmpKindOperator = {
            fg = util.lighten(colors.surface0, 0.9, colors.blue),
            bg = colors.blue,
          },
          BlinkCmpKindFile = {
            fg = util.lighten(colors.surface0, 0.9, colors.blue),
            bg = colors.blue,
          },
          BlinkCmpKindFolder = {
            fg = util.lighten(colors.surface0, 0.9, colors.blue),
            bg = colors.blue,
          },
          BlinkCmpKindTypeParameter = {
            fg = util.lighten(colors.surface0, 0.9, colors.blue),
            bg = colors.blue,
          },
          BlinkCmpKindMethod = {
            fg = util.lighten(colors.surface0, 0.9, colors.blue),
            bg = colors.blue,
          },

          BlinkCmpKindConstant = {
            fg = util.lighten(colors.surface0, 0.9, colors.peach),
            bg = colors.peach,
          },
          BlinkCmpKindValue = {
            fg = util.lighten(colors.surface0, 0.9, colors.peach),
            bg = colors.peach,
          },

          BlinkCmpKindReference = {
            fg = util.lighten(colors.surface0, 0.9, colors.red),
            bg = colors.red,
          },
          BlinkCmpKindEnumMember = {
            fg = util.lighten(colors.surface0, 0.9, colors.red),
            bg = colors.red,
          },
          BlinkCmpKindColor = {
            fg = util.lighten(colors.surface0, 0.9, colors.red),
            bg = colors.red,
          },

          BlinkCmpKindClass = {
            fg = util.lighten(colors.surface0, 0.9, colors.yellow),
            bg = colors.yellow,
          },
          BlinkCmpKindInterface = {
            fg = util.lighten(colors.surface0, 0.9, colors.yellow),
            bg = colors.yellow,
          },
          BlinkCmpKindVariable = {
            fg = util.lighten(colors.surface0, 0.9, colors.flamingo),
            bg = colors.flamingo,
          },
          BlinkCmpKindSnippet = {
            fg = util.lighten(colors.surface0, 0.9, colors.mauve),
            bg = colors.mauve,
          },
          -- Avante's sidebar sits on the float background, behind a
          -- separator drawn in that same colour. Every other panel shares the
          -- editor's background and its plain separator, so Avante does too.
          AvanteSidebarNormal = { link = 'Normal' },
          AvanteSidebarWinSeparator = { link = 'WinSeparator' },
          AvanteSidebarWinHorizontalSeparator = { link = 'WinSeparator' },
          -- Its prompt float looks like every other prompt: Snacks' input
          AvantePromptInput = { link = 'SnacksInputNormal' },
          AvantePromptInputBorder = { link = 'SnacksInputBorder' },
        }
      end,
    },
    specs = {
      {
        -- Bufferline in catppuccin's colours
        'akinsho/bufferline.nvim',
        optional = true,
        opts = function(_, opts)
          if (vim.g.colors_name or ''):find('catppuccin') then
            opts.highlights =
              require('catppuccin.special.bufferline').get_theme()
          end
        end,
      },
    },
  },
}
