local util = require('outline.pickers.utils')
local M = {}

local function default_picker()
  return 'default'
end

local silent_warn_notify = false

---@param picker_name string?
local function get_picker(picker_name)
  picker_name = picker_name or ''

  if util.is_blank(picker_name) or silent_warn_notify then
    picker_name = default_picker()
  end

  local ok, picker = pcall(require, string.format('outline.pickers.%s', picker_name))

  if not ok then
    if not silent_warn_notify then
      vim.notify(
        string.format(
          'The picker `%s` has not been implemented yet.\nFalling back to the default `vim.ui.select`.',
          picker_name
        ),
        vim.log.levels.WARN
      )

      silent_warn_notify = true
    end

    return get_picker('default')
  end

  return picker
end

---@param sidebar outline.Sidebar
function M.select_symbols(cfg_outline, sidebar)
  local picker_name
  if cfg_outline.o.picker and type(cfg_outline.o.picker) == 'table' then
    picker_name = cfg_outline.o.picker[1]
  else
    picker_name = cfg_outline.o.picker
  end

  local picker = get_picker(picker_name)

  local contents = util.get_contents_symbols(cfg_outline)
  if not contents or #contents == 0 then
    return
  end

  ---@param symbols table|nil
  cfg_outline.set_filters = function(symbols)
    if #symbols == 0 then
      symbols = nil
    end

    cfg_outline.o.symbols.filter = symbols
    cfg_outline.o.outline_window.width = 25 -- hard code is bad!
    cfg_outline.setup(vim.tbl_deep_extend('force', {}, cfg_outline.defaults, cfg_outline.o or {}))

    if sidebar.view:is_open() and sidebar:has_code_win() then
      sidebar:close()
    end

    -- wait some time to avoid buffer-name conflict
    vim.wait(1500, function()
      return sidebar.view:is_open()
    end)

    sidebar:open()
  end

  if picker then
    picker(cfg_outline, contents)
  end
end

return M
