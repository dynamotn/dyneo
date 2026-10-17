-- `config.lua` is rendered by chezmoi from `config.lua.tmpl`, so a plain clone
-- of this repository has none, and the defaults in `config.globals` stand.
-- Only that case is quiet: an error raised inside a rendered file is reported,
-- instead of being swallowed along with the missing module.
local ok, err = pcall(require, 'per_machine.config')
if
  not ok
  and not tostring(err):find("module 'per_machine.config' not found", 1, true)
then
  vim.notify(
    'per_machine: failed to load config\n' .. tostring(err),
    vim.log.levels.ERROR
  )
end

-- A machine lists its languages in whatever order it likes, but what is built
-- from the list walks it in order and expects the order `config.globals` gives
if type(DyNeo.enabled_languages) == 'table' then
  table.sort(DyNeo.enabled_languages)
end
