local Util = require('outline.pickers.utils')

local function format_title(str, icon, icon_hl)
  return {
    { ' ', 'FzfLuaTitle' },
    { (icon and icon .. ' ' or ''), icon_hl or 'FzfLuaTitle' },
    { str, 'FzfLuaTitle' },
    { ' ', 'FzfLuaTitle' },
  }
end

---@param contents string[]
local function get_width_and_height(contents)
  local max_height = 20
  local max_width = 50

  local height = #contents + 1
  local width = 0

  for _, symbol in pairs(contents) do
    width = math.max(width, vim.fn.strdisplaywidth(symbol))
  end

  local win_height = max_height < height and max_height or height
  local win_width = max_width > width and max_width or width

  return {
    win_height = win_height,
    win_width = win_width,
  }
end

return function(opts, contents)
  local fzf = require('fzf-lua')

  local win_opts = get_width_and_height(contents)
  local pad_entry = 3

  local entry_str = {}
  for _, symbol in pairs(contents) do
    if symbol ~= Util.all_kind then
      local kind = opts.o.symbols.icons
      if kind[symbol] then
        local icon = kind[symbol].icon
        local icon_hl = fzf.utils.ansi_from_hl(kind[symbol].hl, icon)
        local icon_width = vim.fn.strdisplaywidth(icon)

        local padding = pad_entry - icon_width
        local pad_str = string.rep(' ', padding)

        table.insert(entry_str, icon_hl .. pad_str .. symbol)
      end
    else
      table.insert(entry_str, string.format('%-2s %s', '', symbol))
    end
  end

  ---@diagnostic disable: missing-fields
  ---@type fzf-lua.config.Defaults
  local fzf_opts = {
    winopts = {
      title = format_title('Filter Symbols', ' '),
      width = win_opts.win_width,
      height = win_opts.win_height,
      col = 0.50,
      row = 0.50,
    },
    actions = {
      ['default'] = function(selected, _)
        if not selected then
          return
        end

        local symbols = {}

        if #selected == 1 then
          local sel = Util.strip_whitespace(selected[1])
          if sel ~= Util.all_kind then
            local str_e = fzf.utils.strip_ansi_coloring(sel)
            local symbol_name = str_e:match('[a-zA-Z].*$')
            if symbol_name then
              table.insert(symbols, symbol_name)
            end
          end
        else
          for _, sel in ipairs(selected) do
            local str_e = fzf.utils.strip_ansi_coloring(sel)
            str_e = Util.strip_whitespace(str_e)
            local symbol_name = str_e:match('[a-zA-Z].*$')
            if symbol_name then
              table.insert(symbols, symbol_name)
            end
          end
        end

        opts.set_filters(symbols)
      end,
    },
  }

  if type(opts.o.picker) == 'table' then
    fzf_opts = vim.tbl_deep_extend('force', fzf_opts, opts.o.picker.opts or {})
  end

  fzf.fzf_exec(entry_str, fzf_opts)
end
