local M = {
  name = 'help',
}

local utils = require('outline.utils')

---@param bufnr integer
---@param config table?
function M.supports_buffer(bufnr, config)
  local ft = utils.buf_get_option(bufnr, 'ft')
  if ft ~= 'help' then
    return false
  end

  local status, parser = pcall(vim.treesitter.get_parser, bufnr, 'vimdoc')
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

---@param callback fun(symbols?:outline.ProviderSymbol[], opts?:table)
---@param opts table
function M.request_symbols(callback, opts)
  if not M.parser then
    local status, parser = pcall(vim.treesitter.get_parser, 0, 'vimdoc')
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

  local parse_fn = _G._outline_nvim_has[9] and vim.treesitter.query.parse
    or vim.treesitter.query.parse_query ---@diagnostic disable-line: deprecated

  -- h1  = "===...===" sections  → level 1
  -- h3  = "---...---" sections  → level 2
  -- tag = *tag-name*
  -- ignore (Parameters:, Attributes:, etc)
  local q_sections = parse_fn(
    'vimdoc',
    [[
    (h1 (heading) @h1)
    (h3 (heading) @h3)
  ]]
  )

  local q_tags = parse_fn(
    'vimdoc',
    [[
    (tag text: (word) @tag)
  ]]
  )

  local buf_line_count = vim.api.nvim_buf_line_count(0)
  local headings = {}

  ---@diagnostic disable-next-line: missing-parameter
  for id, node in q_sections:iter_captures(root, 0) do
    local cap = q_sections.captures[id]
    local level = (cap == 'h1') and 1 or 2

    local row1, col1, row2, col2 = node:range()
    local ok, result = pcall(vim.api.nvim_buf_get_text, 0, row1, col1, row2, col2, {})
    if not ok then
      goto next_section
    end
    local title = result[1] or ''
    title = title:gsub('^%s+', ''):gsub('%s+$', '')
    if title == '' then
      title = '(untitled)'
    end

    local parent_node = node:parent()
    local rr1, rc1
    if parent_node then
      rr1, rc1 = parent_node:range()
    else
      rr1, rc1 = row1, col1
    end

    table.insert(headings, {
      kind = 15,
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

    ::next_section::
  end

  ---@diagnostic disable-next-line: missing-parameter
  for id, node in q_tags:iter_captures(root, 0) do
    local row1, col1, row2, col2 = node:range()
    local line = vim.api.nvim_buf_get_lines(0, row1, row1 + 1, false)[1] or ''

    if line:match('%b()') then
      local ok2, result2 = pcall(vim.api.nvim_buf_get_text, 0, row1, col1, row2, col2, {})
      if not ok2 then
        goto next_tag
      end
      local tag_text = result2[1] or ''
      tag_text = tag_text:gsub('^%s+', ''):gsub('%s+$', '')

      if tag_text ~= '' then
        table.insert(headings, {
          kind = 12,
          name = tag_text,
          level = 3,
          line_num = row1,
          selectionRange = {
            start = { character = col1, line = row1 },
            ['end'] = { character = col2, line = row2 },
          },
          range = {
            start = { character = 0, line = row1 },
            ['end'] = { character = 0, line = row1 },
          },
          children = {},
        })
      end
    end
    ::next_tag::
  end

  table.sort(headings, function(a, b)
    return a.line_num < b.line_num
  end)

  -- clean up deduplicate
  local seen_lines = {}
  local deduped = {}
  for _, h in ipairs(headings) do
    if h.level ~= 3 then
      table.insert(deduped, h)
    elseif not seen_lines[h.line_num] then
      seen_lines[h.line_num] = true
      table.insert(deduped, h)
    end
  end

  for i, h in ipairs(deduped) do
    local end_line = buf_line_count - 1
    for j = i + 1, #deduped do
      if deduped[j].level <= h.level then
        end_line = deduped[j].line_num - 1
        break
      end
    end
    h.range['end'].line = end_line
  end

  local result = { children = {} }
  local stack = { { level = 0, node = result } }

  for _, heading in ipairs(deduped) do
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
