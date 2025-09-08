local Util = require('outline.pickers.utils')

-- Init telescope
local actions, action_state, pickers, finders, sorters
local function init_telescope()
  local oke, _ = pcall(require, 'telescope')
  if not oke then
    return false
  end

  actions = require('telescope.actions')
  action_state = require('telescope.actions.state')
  pickers = require('telescope.pickers')
  finders = require('telescope.finders')
  sorters = require('telescope.sorters').Sorter
  return true
end

local function format_display_entry(entry_tbl)
  local width_entry = 0
  for _, entry in pairs(entry_tbl) do
    width_entry = math.max(width_entry, vim.fn.strdisplaywidth(entry.value))
  end

  local display = require('telescope.pickers.entry_display').create({
    separator = ' ',
    items = {
      { width = 2 },
      { width = width_entry },
      { remaining = true },
    },
  })

  return function(entry)
    return display({
      { entry.kind, entry.hl and entry.hl or 'Text' },
      { entry.ordinal, 'Text' },
      { '' },
    })
  end
end

return function(opts, contents)
  if not init_telescope() then
    return
  end

  local entry_str = {}

  for _, symbol in pairs(contents) do
    if symbol ~= Util.all_kind then
      local kind = opts.o.symbols.icons
      if kind[symbol] then
        entry_str[#entry_str + 1] = {
          label = symbol,
          hl = kind[symbol].hl,
          kind = kind[symbol].icon,
          value = symbol,
        }
      end
    else
      entry_str[#entry_str + 1] = {
        label = symbol,
        kind = '',
        hl = '',
        value = symbol,
      }
    end
  end

  local make_display = format_display_entry(entry_str)

  local telescope_opts = {
    results_title = false,
    default_mode = 'insert',
    layout_strategy = 'vertical', -- ivy, cursor, dropdown
    layout_config = {
      height = 0.6,
      width = 0.3,
      prompt_position = 'top',
    },
    prompt_title = '  Filter Symbols',
    debounce = 100,
    finder = finders.new_table({
      results = entry_str,
      entry_maker = function(entry)
        return {
          args = entry.args,
          hl = entry.hl,
          kind = entry.kind,
          ordinal = entry.label,
          value = entry.value,
          display = make_display,
        }
      end,
    }),
    sorter = sorters:new({
      scoring_function = function(_, prompt, line)
        if not prompt or prompt == '' then
          return 1
        end

        local terms = vim.split(prompt, '|', { trimempty = true })
        for _, term in ipairs(terms) do
          if line:lower():find(Util.strip_whitespace(term:lower()), 1, true) then
            return 0
          end
        end
        return -1
      end,
      highlighter = function(_, prompt, display)
        -- taken from https://github.com/nvim-telescope/telescope.nvim/blob/b4da76be54691e854d3e0e02c36b0245f945c2c7/lua/telescope/sorters.lua#L6
        local ngram_len = 2

        local highlights = {}
        display = display:lower()

        for disp_index = 1, #display do
          local char = display:sub(disp_index, disp_index + ngram_len - 1)
          if prompt:find(char, 1, true) then
            table.insert(highlights, {
              start = disp_index,
              finish = disp_index + ngram_len - 1,
            })
          end
        end

        return highlights
      end,
    }),
    attach_mappings = function(prompt_bufnr, _)
      local apply_code_action = function(close_picker)
        local picker = action_state.get_current_picker(prompt_bufnr)
        local selections = picker:get_multi_selection()
        if not selections then
          require('telescope.utils').__warn_no_selection('code_action')
          return
        end
        local filters = {}

        if close_picker then
          actions.close(prompt_bufnr)
        end

        if vim.tbl_isempty(selections) then
          local sel = action_state.get_selected_entry()
          if sel.ordinal ~= Util.all_kind then
            table.insert(filters, sel.ordinal)
          end
        else
          for _, sel in pairs(selections) do
            if sel.ordinal ~= Util.all_kind then
              table.insert(filters, sel.ordinal)
            end
          end
        end

        opts.set_filters(filters)
      end

      actions.select_default:replace(function()
        apply_code_action(true)
      end)

      return true
    end,
  }

  if type(opts.o.picker) == 'table' then
    telescope_opts = vim.tbl_deep_extend('force', telescope_opts, opts.o.picker.opts or {})
  end

  return pickers.new({}, telescope_opts):find()
end
