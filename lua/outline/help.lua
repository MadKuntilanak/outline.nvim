local Float = require('outline.float')
local cfg = require('outline.config')
local utils = require('outline.utils')

local M = {}

---Shown in the help window (?). Actions not listed here fall back to the
---raw action name so new keymaps degrade gracefully.
local action_desc = {
  show_help = 'Show this help window',
  close = 'Close outline window',
  goto_location = 'Jump to symbol (may auto-close)',
  peek_location = 'Jump to symbol, keep focus on outline',
  goto_and_close = 'Jump to symbol and close outline',
  restore_location = 'Move outline cursor to match current code position',
  hover_symbol = 'Show LSP hover info for symbol',
  toggle_preview = 'Toggle code preview for symbol',
  rename_symbol = 'Rename symbol via LSP',
  code_actions = 'Show LSP code actions for symbol',
  fold = 'Fold / collapse node',
  unfold = 'Unfold / expand node',
  fold_toggle = 'Toggle fold for node',
  fold_toggle_all = 'Toggle fold for all nodes',
  fold_all = 'Fold all nodes',
  unfold_all = 'Unfold all nodes',
  fold_reset = 'Reset all folds to default',
  down_and_jump = 'Move down and peek location',
  up_and_jump = 'Move up and peek location',
  save_to_qf = 'Add symbol to quickfix list',
  refresh = 'Manually refresh outline symbols',
  freeze = 'Freeze outline (stop following buffer changes)',
  unfreeze = 'Unfreeze outline (resume following buffer changes)',
  toggle_freeze = 'Toggle freeze state',
  reference_symbol = 'Show LSP references as child nodes',
  next_ref_node = 'Jump to next node with references expanded',
  prev_ref_node = 'Jump to previous node with references expanded',
  open_in_vsplit = 'Open symbol location in vertical split',
  open_in_split = 'Open symbol location in horizontal split',
  open_in_tab = 'Open symbol location in new tab',
  open_in_float = 'Open symbol location in floating window',
  filter_symbols = 'Filter visible symbol kinds',
}

function M.show_keymap_help()
  local keyhint = 'Press q or <Esc> to close this window.'
  local title = 'Current keymaps:'
  local lines = { keyhint, '', title, '' }
  ---@type outline.HL[]
  local hl = { { line = 0, from = 0, to = #keyhint, name = 'OutlineHelpTip' } }
  local left = {}
  local right = {}
  local max_left_width = 0
  local indent = '    '
  local key_hl = 'OutlineKeymapHelpKey'

  local entries = {}
  for action, keys in pairs(cfg.o.keymaps) do
    local key_str, disabled
    if type(keys) == 'string' then
      key_str = keys
      disabled = false
    elseif next(keys) == nil then
      key_str = '(none)'
      disabled = true
    else
      key_str = table.concat(keys, ' / ')
      disabled = false
    end
    table.insert(entries, {
      key_str = key_str,
      desc = action_desc[action] or action,
      action = action,
      keys = keys,
      disabled = disabled,
    })
  end

  -- Hmm sort alphabetically by description? (case-insensitive).
  table.sort(entries, function(a, b)
    return a.desc:lower() < b.desc:lower()
  end)

  for _, entry in ipairs(entries) do
    table.insert(left, entry.key_str)
    if #entry.key_str > max_left_width then
      max_left_width = #entry.key_str
    end

    if entry.disabled then
      table.insert(hl, {
        line = #left + 3,
        from = #indent,
        name = 'OutlineKeymapHelpDisabled',
        to = #indent + 6,
      })
    elseif type(entry.keys) == 'string' then
      table.insert(hl, {
        line = #left + 3,
        from = #indent,
        to = #entry.key_str + #indent,
        name = key_hl,
      })
    else
      local i = #indent
      for _, key in ipairs(entry.keys) do
        table.insert(hl, {
          line = #left + 3,
          from = i,
          to = #key + i,
          name = key_hl,
        })
        i = i + #key + 3
      end
    end

    table.insert(right, entry.desc)
  end

  for i, l in ipairs(left) do
    local pad = string.rep(' ', max_left_width - #l + 2)
    table.insert(lines, indent .. l .. pad .. right[i])
  end

  local f = Float:new()
  f:open(lines, hl, 'Outline Help', 1)

  utils.nmap(f.bufnr, { 'q', '<Esc>' }, function()
    f:close()
  end)
end

local function get_filter_list_lines(f)
  if f == nil then
    return { '(not configured)' }
  elseif f == false or (f and #f == 0 and f.exclude) then
    return { '(all symbols included)' }
  end
  return vim.split(vim.inspect(f), '\n', { plain = true })
end

---Display outline window status in a floating window
---@param ctx outline.StatusContext
function M.show_status(ctx)
  local keyhint = 'Press q or <Esc> to close this window.'
  local lines = { keyhint, '' }
  ---@type outline.HL[]
  local hl = { { line = 0, from = 0, to = #keyhint, name = 'OutlineHelpTip' } }
  local p = ctx.provider
  ---@type string[]
  local priority = ctx.priority
  local pref
  local indent = '    '

  if ctx.ft then
    pref = 'Filetype of current or attached buffer: '
    table.insert(lines, pref .. ctx.ft)
    table.insert(hl, { line = #lines - 1, from = #pref, to = -1, name = 'OutlineStatusFt' })
    table.insert(lines, 'Symbols filter:')
    table.insert(lines, '')
    for _, line in ipairs(get_filter_list_lines(ctx.filter)) do
      table.insert(lines, indent .. line)
    end
    table.insert(lines, '')
  else
    table.insert(lines, 'Filetype of current or attached buffer: N/A')
    table.insert(lines, 'Symbols filter: N/A')
    table.insert(lines, 'Buffer number of code was invalid, could not get filetype!')
    table.insert(hl, { line = #lines - 1, from = 0, to = -1, name = 'OutlineStatusError' })
    table.insert(lines, '')
  end

  table.insert(lines, 'Default symbols filter:')
  table.insert(lines, '')
  for _, line in ipairs(get_filter_list_lines(ctx.default_filter)) do
    table.insert(lines, indent .. line)
  end
  table.insert(lines, '')

  if utils.table_has_content(priority) then
    pref = 'Configured providers are: '
    table.insert(lines, pref .. table.concat(priority, ', ') .. '.')
    local i = #pref
    for _, name in ipairs(priority) do
      table.insert(
        hl,
        { line = #lines - 1, from = i, to = i + #name, name = 'OutlineStatusProvider' }
      )
      i = i + #name + 2
    end
  else
    pref = 'config '
    local content = 'providers.priority'
    table.insert(lines, pref .. content .. ' is an empty list!')
    table.insert(
      hl,
      { line = #lines - 1, from = #pref, to = #pref + #content, name = 'OutlineStatusError' }
    )
  end

  if p ~= nil then
    pref = 'Current provider: '
    table.insert(lines, pref .. p.name)
    table.insert(hl, { line = #lines - 1, from = #pref, to = -1, name = 'OutlineStatusProvider' })
    if p.get_status then
      table.insert(lines, 'Provider info:')
      table.insert(lines, '')
      for _, line in ipairs(p.get_status(ctx.provider_info)) do
        table.insert(lines, indent .. line)
      end
    end

    table.insert(lines, '')

    table.insert(
      lines,
      ('Outline window is %s.'):format((ctx.outline_open and 'open') or 'not open')
    )

    if ctx.code_win_active then
      table.insert(lines, 'Code window is active.')
    else
      table.insert(lines, 'Code window is not active!')
      table.insert(lines, 'Try closing and reopening the outline.')
      table.insert(hl, { line = #lines - 2, from = 0, to = -1, name = 'OutlineStatusError' })
      table.insert(hl, { line = #lines - 1, from = 0, to = -1, name = 'OutlineStatusError' })
    end
  else
    table.insert(lines, 'No supported providers for current buffer.')
  end

  local f = Float:new()
  f:open(lines, hl, 'Outline Status', 1)
  utils.nmap(f.bufnr, { 'q', '<Esc>' }, function()
    f:close()
  end)
end

return M
