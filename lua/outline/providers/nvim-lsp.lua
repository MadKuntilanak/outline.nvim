local cfg = require('outline.config')
local folding = require('outline.folding')
local jsx = require('outline.providers.jsx')
local lsp_utils = require('outline.utils.lsp')
local utils = require('outline.utils')

local l = vim.lsp

local M = {
  name = 'lsp',
}

local request_timeout = 2000

---@param info table? Must be the table received from `supports_buffer`
function M.get_status(info)
  if not info then
    return { 'No clients' }
  end
  return { 'client: ' .. info.client.name }
end

---@param client vim.lsp.Client
---@param capability string
---@return boolean
local function _check_client(client, capability)
  if cfg.is_client_blacklisted(client) then
    return false
  end
  return client.server_capabilities[capability]
end

---@param bufnr integer
---@param capability string
---@return vim.lsp.Client?
local function get_appropriate_client(bufnr, capability)
  local clients, use_client

  if _G._outline_nvim_has[8] then
    if _G._outline_nvim_has[10] then
      clients = l.get_clients({ bufnr = bufnr })
    else
      ---@diagnostic disable-next-line: deprecated
      clients = l.get_active_clients({ bufnr = bufnr })
    end
    for _, client in ipairs(clients) do
      if _check_client(client, capability) then
        use_client = client
        break
      end
    end
  else
    -- Returns client_id:client pairs
    ---@diagnostic disable-next-line
    clients = l.buf_get_clients(bufnr)
    for _, client in pairs(clients) do
      if _check_client(client, capability) then
        use_client = client
        break
      end
    end
  end

  return use_client
end

---@return boolean, table?
function M.supports_buffer(bufnr)
  local client = get_appropriate_client(bufnr, 'documentSymbolProvider')
  if not client then
    return false
  end
  return true, { client = client }
end

---Include JSX symbols if applicable, and merge it with existing symbols
---@param symbols outline.ProviderSymbol[]
---@return outline.ProviderSymbol[]
local function postprocess_symbols(symbols)
  local jsx_symbols = jsx.get_symbols()

  if #jsx_symbols > 0 then
    return lsp_utils.merge_symbols(symbols, jsx_symbols)
  else
    return symbols
  end
end

-- XXX: Only one LSP client is supported here, to prevent checking blacklisting
-- over again
---@param on_symbols fun(symbols?:outline.ProviderSymbol[], opts?:table)
---@param opts table?
---@param info table? Must be the table received from `supports_buffer`
function M.request_symbols(on_symbols, opts, info)
  if not info then
    return on_symbols(nil, opts)
  end

  local params = {
    textDocument = l.util.make_text_document_params(),
  }
  -- XXX: Is bufnr=0 ok here?
  local method = 'textDocument/documentSymbol'
  local callback = function(err, response)
    if err or not response then
      on_symbols({}, opts)
    else
      response = postprocess_symbols(response)
      on_symbols(response, opts)
    end
  end
  local bufnr = 0
  local status
  if _G._outline_nvim_has[11] then
    status = info.client:request(method, params, callback, bufnr)
  else
    status = info.client.request(method, params, callback, bufnr)
  end
  if not status then
    on_symbols(nil, opts)
  end
end

-- No good way to update outline when LSP action complete for now

---@param sidebar outline.Sidebar
---@return boolean success
function M.code_actions(sidebar)
  local client = get_appropriate_client(sidebar.code.buf, 'codeActionProvider')
  if not client then
    return false
  end
  -- NOTE: Unfortunately the code_action function provided by neovim does a
  -- lot, yet it doesn't let us filter clients. Since handling of code_actions
  -- is beyond the scope of outline.nvim itself, we will not respect
  -- blacklist_clients for code actions for now. Code actions feature would not
  -- actually be included if I were to write this plugin from scratch. However
  -- we still keep it because many people are moving here from
  -- symbols-outline.nvim, which happened to implement this feature.
  sidebar:wrap_goto_location(function()
    l.buf.code_action()
  end)
  return true
end

---@see rename_symbol
---@param sidebar outline.Sidebar
---@param client vim.lsp.Client
---@param node outline.FlatSymbol
---@return boolean success
local function legacy_rename(sidebar, client, node)
  -- Using fn.input so it's synchronous
  local new_name = vim.fn.input({ prompt = 'New Name: ', default = node.name })
  if not new_name or new_name == '' or new_name == node.name then
    return true
  end

  local params = {
    textDocument = { uri = 'file://' .. vim.api.nvim_buf_get_name(sidebar.code.buf) },
    position = { line = node.line, character = node.character },
    bufnr = sidebar.code.buf,
    newName = new_name,
  }
  local status, err
  if _G._outline_nvim_has[11] then
    status, err =
      client:request_sync('textDocument/rename', params, request_timeout, sidebar.code.buf)
  else
    ---@diagnostic disable-next-line
    status, err =
      client.request_sync('textDocument/rename', params, request_timeout, sidebar.code.buf)
  end
  if status == nil or status.err or err or status.result == nil then
    return false
  end

  l.util.apply_workspace_edit(status.result, client.offset_encoding)
  node.name = new_name
  sidebar:_update_lines(false)
  return true
end

---Synchronously request rename from LSP
---@param sidebar outline.Sidebar
---@return boolean success
function M.rename_symbol(sidebar)
  local client = get_appropriate_client(sidebar.code.buf, 'renameProvider')
  if not client then
    return false
  end
  local node = sidebar:_current_node()
  if not node then
    return false
  end

  if _G._outline_nvim_has[8] then
    sidebar:wrap_goto_location(function()
      -- Options table with filter key only added in nvim-0.8
      -- Use vim.lsp's function because it has better support.
      l.buf.rename(nil, {
        filter = function(cl)
          return not cfg.is_client_blacklisted(cl)
        end,
      })
    end)
    return true
  else
    return legacy_rename(sidebar, client, node)
  end
end

---Synchronously request and show hover info from LSP
---@param sidebar outline.Sidebar
---@return boolean success
function M.show_hover(sidebar)
  local client = get_appropriate_client(sidebar.code.buf, 'hoverProvider')
  if not client then
    return false
  end

  local node = sidebar:_current_node()
  if not node then
    return false
  end
  local params = {
    textDocument = { uri = vim.uri_from_bufnr(sidebar.code.buf) },
    position = { line = node.line, character = node.character },
    bufnr = sidebar.code.buf,
  }

  local status, err
  if _G._outline_nvim_has[11] then
    status, err = client:request_sync('textDocument/hover', params, request_timeout)
  else
    status, err = client.request_sync('textDocument/hover', params, request_timeout)
  end
  if status == nil or status.err or err or not status.result or not status.result.contents then
    return false
  end

  local md_lines = l.util.convert_input_to_markdown_lines(status.result.contents.value)
  if _G._outline_nvim_has[10] then
    md_lines = vim.split(status.result.contents.value, '\n', { trimempty = true })
  else
    ---@diagnostic disable-next-line:deprecated
    md_lines = l.util.trim_empty_lines(md_lines)
  end
  if vim.tbl_isempty(md_lines) then
    -- Request was successful, but there is no hover content
    return true
  end
  local code_width = vim.api.nvim_win_get_width(sidebar.code.win)
  local bufnr, winnr = l.util.open_floating_preview(md_lines, 'markdown', {
    border = cfg.o.preview_window.border,
    width = code_width,
  })
  utils.win_set_option(winnr, 'winhighlight', cfg.o.preview_window.winhl)
  return true
end

---Show LSP references of the symbol under cursor as child nodes in the outline.
---Each reference appears as `filename:line` under the symbol in the hierarchy.
---Calling again on the same symbol toggles them off.
---@param sidebar outline.Sidebar
function M.show_references(sidebar)
  if not sidebar.view:is_open() then
    utils.echo('Outline is not open.')
    return false
  end
  if not sidebar.provider then
    utils.echo('No provider attached.')
    return false
  end

  local node = sidebar:_current_node()
  if not node then
    utils.echo('No symbol under cursor.')
    return false
  end

  -- Toggle off: restore original children.
  if node._ref_shown then
    node._ref_shown = nil
    node.children = node._ref_orig_children
    node._ref_orig_children = nil
    if sidebar._ref_cache then
      local cache_key = tostring(sidebar.code.buf) .. ':' .. tostring(node.line)
      sidebar._ref_cache[cache_key] = nil
    end
    sidebar:_update_lines(false)
    return true
  end

  -- node.line/character = selection start (0-based) for LSP position params.
  -- node.range_start/range_end = plain line numbers (not tables).
  local params = {
    textDocument = { uri = vim.uri_from_bufnr(sidebar.code.buf) },
    position = {
      line = node.line,
      character = node.character,
    },
    context = { includeDeclaration = false },
  }

  utils.echo('Fetching references…')

  vim.lsp.buf_request(sidebar.code.buf, 'textDocument/references', params, function(err, result)
    if err or not result or #result == 0 then
      utils.echo('No references found.')
      return
    end

    local ref_children = {}
    for _, loc in ipairs(result) do
      local fname = vim.uri_to_fname(loc.uri)
      local short = fname:match('([^/\\]+)$') or fname
      local lnum = loc.range.start.line + 1

      local ref_depth = (node.depth or 1) + 1
      -- hierarchy: array of isLast booleans for each ancestor level,
      -- used by build_outline to draw tree guide prefix chars.
      local ref_hir = {}
      for i, v in ipairs(node.hierarchy or {}) do
        ref_hir[i] = v
      end
      table.insert(ref_hir, (#result == #ref_children + 1)) -- isLast for parent level

      ref_children[#ref_children + 1] = {
        _i = 1,
        isLast = false,
        hierarchy = ref_hir,
        depth = ref_depth,
        parent = node,
        -- symbol fields
        name = short .. ':' .. lnum,
        kind = node.kind,
        icon = (cfg.o.references and cfg.o.references.icon) or '󰌹 ',
        detail = nil,
        deprecated = false,
        -- match parser.lua convention: plain line numbers
        line = loc.range.start.line,
        character = loc.range.start.character,
        range_start = loc.range.start.line,
        range_end = loc.range['end'].line,
        -- jump logic: open this file instead of code.buf
        _is_ref = true,
        _ref_file = fname,
        children = {},
      }
    end

    if #ref_children > 0 then
      ref_children[#ref_children].isLast = true
    end

    -- Inject references as children; stash originals for toggle-off.
    node._ref_orig_children = node.children
    node._ref_shown = true
    node.children = ref_children

    if folding.is_foldable(node) and folding.is_folded(node) then
      node.folded = false
    end

    -- Persist to cache so references survive buffer switches.
    -- Key: "<bufnr>:<line>" — unique per symbol per buffer.
    sidebar._ref_cache = sidebar._ref_cache or {}
    local cache_key = tostring(sidebar.code.buf) .. ':' .. tostring(node.line)
    sidebar._ref_cache[cache_key] = {
      node_name = node.name,
      orig_children = node._ref_orig_children,
      ref_children = ref_children,
    }

    sidebar:_update_lines(false)
    utils.echo(('Found %d reference(s) for "%s"'):format(#ref_children, node.name))
  end)
  return true
end

return M
