local M = {
  name = 'org',
}

local utils = require('outline.utils')

---@param bufnr integer
---@param config table?
function M.supports_buffer(bufnr, config)
  if utils.buf_get_option(bufnr, 'ft') ~= 'org' then
    return false
  end

  local status, parser = pcall(vim.treesitter.get_parser, bufnr, 'org')
  if not status or not parser then
    return false
  end

  M.parser = parser
  return true
end

---@param node outline.ProviderSymbol
---@param field string
local function rec_remove_field(node, field)
  node[field] = nil
  if node.children then
    for _, child in ipairs(node.children) do
      rec_remove_field(child, field)
    end
  end
end

local function level_to_kind(_level)
  return 15
end

---@param callback fun(symbols?:outline.ProviderSymbol[], opts?:table)
---@param opts table
function M.request_symbols(callback, opts)
  if not M.parser then
    local status, parser = pcall(vim.treesitter.get_parser, 0, 'org')
    if not status or not parser then
      callback(nil, opts)
      return
    end
    M.parser = parser
  end

  local root = M.parser:parse()[1]:root()
  if not root then
    callback(nil, opts)
    return
  end

  local query_str = [[
    (section
      headline: (headline
        stars: (stars) @stars
        item: (item) @name))
  ]]

  local query
  if _G._outline_nvim_has[9] then
    query = vim.treesitter.query.parse('org', query_str)
  else
    ---@diagnostic disable-next-line: deprecated
    query = vim.treesitter.query.parse_query('org', query_str)
  end

  local buf_line_count = vim.api.nvim_buf_line_count(0)
  local headings = {}

  ---@diagnostic disable-next-line: missing-parameter
  for _, match, _ in query:iter_matches(root, 0) do
    local stars_node = nil
    local name_node = nil

    for id, node in pairs(match) do
      local cap = query.captures[id]
      -- Neovim >= 0.10: iter_matches returns { [id] = {node, ...} }
      -- Neovim < 0.10:  iter_matches returns { [id] = node }
      local actual_node = type(node) == 'table' and node[1] or node
      if cap == 'stars' then
        stars_node = actual_node
      elseif cap == 'name' then
        name_node = actual_node
      end
    end

    if stars_node and name_node then
      local sr, sc, er, ec = stars_node:range()
      local stars_text = vim.api.nvim_buf_get_text(0, sr, sc, er, ec, {})[1] or ''
      local level = #(stars_text:match('^%*+') or '')
      if level == 0 then
        level = 1
      end

      local row1, col1, row2, col2 = name_node:range()
      local title = vim.api.nvim_buf_get_text(0, row1, col1, row2, col2, {})[1] or ''
      title = title:gsub('^%s+', ''):gsub('%s+$', '')
      title = title:gsub('^%u+%s+', '') -- strip TODO keywords
      title = title:gsub('%s*:[%w_@#%%:]+:%s*$', '') -- strip :tags:
      if title == '' then
        title = '(untitled)'
      end

      local headline_node = name_node:parent()
      local section_node = headline_node and headline_node:parent()
      local range_node = section_node or headline_node
      local rr1, rc1 = range_node:range()

      table.insert(headings, {
        kind = level_to_kind(level),
        name = title,
        level = level,
        line_num = row1,
        selectionRange = {
          start = { character = col1, line = row1 },
          ['end'] = { character = col2, line = row2 },
        },
        range = {
          start = { character = rc1, line = rr1 },
          ['end'] = { character = 0, line = rr1 },
        },
        children = {},
      })
    end
  end

  for i, h in ipairs(headings) do
    local end_line = buf_line_count - 1
    for j = i + 1, #headings do
      if headings[j].level <= h.level then
        end_line = headings[j].line_num - 1
        break
      end
    end
    h.range['end'].line = end_line
  end

  local result = { children = {} }
  local stack = { { level = 0, node = result } }

  for _, heading in ipairs(headings) do
    while #stack > 1 and stack[#stack].level >= heading.level do
      table.remove(stack, #stack)
    end

    local parent = stack[#stack].node
    table.insert(parent.children, heading)
    table.insert(stack, { level = heading.level, node = heading })
  end

  rec_remove_field(result, 'level')
  rec_remove_field(result, 'line_num')

  callback(result.children, opts)
end

return M
