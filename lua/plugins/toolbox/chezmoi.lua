local enabled = require('util.chezmoi').enabled()

--- Pick a chezmoi managed file and edit it through `chezmoi edit --watch`
---
--- `chezmoi managed` walks the whole source tree, most of a second here, so
--- its list streams into the picker rather than being waited for.
local function pick_chezmoi()
  ---@type snacks.picker.Config
  local opts = {
    title = 'Chezmoi',
    format = 'file',
    finder = function(_, ctx)
      return require('snacks.picker.source.proc').proc(
        ctx:opts({
          cmd = 'chezmoi',
          args = {
            'managed',
            '--path-style',
            'absolute',
            '--include',
            'files',
            '--exclude',
            'externals',
          },
          notify = true,
          transform = function(item) item.file = item.text end,
        }),
        ctx
      )
    end,
    confirm = function(picker, item)
      picker:close()
      require('chezmoi.commands').edit({
        targets = { item.text },
        args = { '--watch' },
      })
    end,
  }
  Snacks.picker.pick(opts)
end

-- Specs of plugins used without chezmoi too, only extended when it is there
local extra_specs = not enabled and {}
  or {
    {
      -- The dashboard's config entry picks a managed file instead
      'folke/snacks.nvim',
      opts = function(_, opts)
        local keys = vim.tbl_get(opts, 'dashboard', 'preset', 'keys')
        if not keys then return end
        local chezmoi_entry = {
          icon = ' ',
          key = 'c',
          desc = 'Config',
          action = pick_chezmoi,
        }
        local config_index = #keys + 1
        for i = #keys, 1, -1 do
          if keys[i].key == 'c' then
            table.remove(keys, i)
            config_index = i
            break
          end
        end
        table.insert(keys, config_index, chezmoi_entry)
      end,
    },
    {
      -- Filetype icons
      'nvim-mini/mini.icons',
      opts = {
        file = {
          ['.chezmoiignore'] = { glyph = '', hl = 'MiniIconsGrey' },
          ['.chezmoiremove'] = { glyph = '', hl = 'MiniIconsGrey' },
          ['.chezmoiroot'] = { glyph = '', hl = 'MiniIconsGrey' },
          ['.chezmoiversion'] = { glyph = '', hl = 'MiniIconsGrey' },
          ['bash.tmpl'] = { glyph = '', hl = 'MiniIconsGrey' },
          ['json.tmpl'] = { glyph = '', hl = 'MiniIconsGrey' },
          ['ps1.tmpl'] = { glyph = '󰨊', hl = 'MiniIconsGrey' },
          ['sh.tmpl'] = { glyph = '', hl = 'MiniIconsGrey' },
          ['toml.tmpl'] = { glyph = '', hl = 'MiniIconsGrey' },
          ['yaml.tmpl'] = { glyph = '', hl = 'MiniIconsGrey' },
          ['zsh.tmpl'] = { glyph = '', hl = 'MiniIconsGrey' },
        },
      },
    },
  }

return {
  {
    -- Edit chezmoi managed files
    'xvzc/chezmoi.nvim',
    enabled = enabled,
    cmd = { 'ChezmoiEdit' },
    keys = {
      { '<leader>sz', pick_chezmoi, desc = 'Chezmoi' },
    },
    opts = {
      edit = {
        watch = false,
        force = false,
      },
      notification = {
        on_open = true,
        on_apply = true,
        on_watch = false,
      },
    },
  },
  extra_specs,
  {
    -- Edit chezmoi source files in place: the target language injected into
    -- `*.tmpl`, managed files typed by their target, `:Chezmoi` commands
    'dpezto/chezmoi-template.nvim',
    enabled = enabled,
    init = function()
      -- chezmoi templates everything under `.chezmoitemplates/` whatever the
      -- extension, so the plugin forces those partials to `gotmpl`. Plenty of
      -- them hold no action at all -- `dytoy` package data, `ssh` snippets --
      -- and as `gotmpl` they lose their schema, linter and formatter. Hand
      -- those back their own filetype; a partial that really templates stays
      -- `gotmpl`.
      vim.api.nvim_create_autocmd('FileType', {
        group = vim.api.nvim_create_augroup('chezmoi_plain_partials', {}),
        pattern = 'gotmpl',
        callback = function(ctx)
          local file = vim.api.nvim_buf_get_name(ctx.buf)
          if
            not file:find('/.chezmoitemplates/', 1, true)
            or file:match('%.tmpl$')
          then
            return
          end
          for _, line in
            ipairs(vim.api.nvim_buf_get_lines(ctx.buf, 0, -1, false))
          do
            if line:find('{{', 1, true) then return end
          end
          -- Seeded by the plugin from the attribute-stripped basename
          local ft = vim.b[ctx.buf].chezmoi_target_lang
            or vim.filetype.match({ filename = vim.fs.basename(file) })
          if ft and ft ~= '' and ft ~= 'gotmpl' then
            vim.bo[ctx.buf].filetype = ft
          end
        end,
      })
    end,
    -- Lazy-loads itself from `plugin/`, and its Tree-sitter directive has to
    -- be there before the first `gotmpl` tree is parsed
    lazy = false,
    opts = {
      -- Applying is asked for, never done behind a `:w`
      apply = { on_save = false },
      -- Templates here `decrypt` secrets, and both of these render the
      -- template to do their job: keep that to an explicit `:Chezmoi preview`
      -- rather than every keystroke or every write
      preview = { live = false },
      diagnostics = { enabled = false },
      -- `encrypted_*.age` files are opened and written by `tools.encrypted`,
      -- which keeps the clear text from the AI integrations and off the
      -- disk; two decryptions of one buffer would fight over it
      encryption = { enabled = false },
      inject = {
        -- Seeding the target language costs a `chezmoi managed` spawn, and
        -- that walks the whole source tree: around 600ms on this repository,
        -- paid inside `BufReadPre` before the buffer is even shown. Partials
        -- are the one case where it buys nothing -- they have no deploy
        -- target, so the seeding falls back to the attribute-stripped file
        -- name anyway, which is what the injection directive does by itself
        -- when nothing seeded the buffer. Opening a `dytoy` template went
        -- from ~800ms to ~235ms.
        exclude = { '/%.chezmoitemplates/' },
      },
      completion = {
        mask = {
          'secret',
          'token',
          'passw',
          'key',
          'api',
          'age',
          'private',
          'credential',
        },
      },
      picker = { backend = 'snacks' },
      -- `<localleader>c` in source buffers: preview, apply, diff, target,
      -- source, edit, pick
      keymaps = { enabled = true },
    },
    config = function(_, opts)
      require('chezmoi-template').setup(opts)

      -- The `helm` injection query inherits `gotmpl`, so `inject-chezmoi!` is
      -- asked for a language on helm trees too. On a buffer chezmoi does not
      -- manage the directive falls back to the filetype of the (attribute
      -- stripped) buffer name, and `templates/*.yaml` is `helm` -- so helm
      -- injects helm into itself, combined, and the parse recurses until
      -- Tree-sitter overflows the stack. Guard a tree against injecting its
      -- own language. `inject.setup()` registers the directive again when the
      -- plugin activates, so replace the function rather than its last result.
      local inject = require('chezmoi-template.inject')
      local resolve = require('chezmoi-template.resolve')

      -- `source_set()` lists every managed source path so that resolving one
      -- file's target costs no spawn of its own. On a source tree this size
      -- the trade is inverted: the listing walks 2300+ files for about 700ms,
      -- inside `BufReadPre`, before the buffer is on screen -- while the
      -- `target-path` call it saves answers in under 20ms. Returning nothing
      -- sends every lookup down the per-file path, and only pays off again
      -- past some forty templates in one session.
      --
      -- What the listing also does is catch a source file chezmoi does not
      -- deploy but `target-path` still answers for, such as a README.md at
      -- the source root. `seed_buffer` has already asked `is_managed`, so
      -- what slips through is narrow: the injected language of such a file is
      -- guessed from its name, which is what every unmanaged template gets.
      resolve.source_set = function() return nil end
      inject.register_directive = function()
        vim.treesitter.query.add_directive(
          'inject-chezmoi!',
          function(_, _, source, _, metadata)
            local buf = type(source) == 'number' and source
              or vim.api.nvim_get_current_buf()
            local lang = vim.b[buf].chezmoi_target_lang
            if not lang then
              local ft = vim.filetype.match({
                filename = resolve.resolve_path(vim.api.nvim_buf_get_name(buf)),
              })
              lang = ft and (vim.treesitter.language.get_lang(ft) or ft)
            end
            if
              not lang
              or lang
                == vim.treesitter.language.get_lang(vim.bo[buf].filetype)
            then
              return
            end
            if pcall(vim.treesitter.language.add, lang) then
              metadata['injection.language'] = lang
              metadata['injection.combined'] = true
            end
          end,
          { force = true }
        )
      end
      inject.register_directive()
    end,
  },
  {
    -- Complete `chezmoi data` keys inside template actions
    'blink.cmp',
    optional = true,
    opts = function(_, opts)
      if not enabled then return end
      DyNeo.completion_sources =
        vim.tbl_extend('force', DyNeo.completion_sources, {
          chezmoi = '「CZ」',
        })
      opts.sources = opts.sources or {}
      opts.sources.providers = opts.sources.providers or {}
      opts.sources.per_filetype = opts.sources.per_filetype or {}
      opts.sources.providers.chezmoi = {
        name = 'chezmoi',
        module = 'chezmoi-template.blink',
        score_offset = 21,
      }
      opts.sources.per_filetype.gotmpl =
        vim.list_extend({ 'chezmoi' }, require('util.cmp').sources('*'))
    end,
  },
}
