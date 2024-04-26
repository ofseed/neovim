local util = require('vim.lsp.util')
local log = require('vim.lsp.log')
local ms = require('vim.lsp.protocol').Methods
local api = vim.api
local validate = vim.validate
local M = {}

---@class (private) vim.lsp.codelens.bufstate
---@field refreshing? true To throttle refreshes to at most one at a time
---@field client_lenses? table<integer, lsp.CodeLens[]> client_id -> lenses
---@type table<integer, vim.lsp.codelens.bufstate>
local bufstates = {}

---@type table<integer, integer> client_id -> namespace
local namespaces = vim.defaulttable(function(key)
  return api.nvim_create_namespace('vim_lsp_codelens:' .. key)
end)

---@private
M.__namespaces = namespaces

local augroup = api.nvim_create_augroup('vim_lsp_codelens', {})

api.nvim_create_autocmd('LspDetach', {
  group = augroup,
  callback = function(ev)
    M.clear(ev.data.client_id, ev.buf)
  end,
})

--- Returns the buffer number for the given {bufnr}.
---
--- @param bufnr (integer|nil) Buffer number to resolve. Defaults to current buffer
--- @return integer bufnr
local function resolve_bufnr(bufnr)
  validate({ bufnr = { bufnr, 'n', true } })
  if bufnr == nil or bufnr == 0 then
    return api.nvim_get_current_buf()
  end
  return bufnr
end

---@param lens lsp.CodeLens
---@param bufnr integer
---@param client_id integer
local function execute_lens(lens, bufnr, client_id)
  local line = lens.range.start.line
  api.nvim_buf_clear_namespace(bufnr, namespaces[client_id], line, line + 1)

  local client = vim.lsp.get_client_by_id(client_id)
  assert(client, 'Client is required to execute lens, client_id=' .. client_id)
  client:_exec_cmd(lens.command, { bufnr = bufnr }, function(...)
    vim.lsp.handlers[ms.workspace_executeCommand](...)
    M.refresh()
  end)
end

--- Return all lenses for the given buffer
---
---@param bufnr integer  Buffer number. 0 can be used for the current buffer.
---@return lsp.CodeLens[]
function M.get(bufnr)
  bufnr = resolve_bufnr(bufnr)
  local bufstate = bufstates[bufnr] or {}
  local client_lenses = bufstate.client_lenses
  if not client_lenses then
    return {}
  end
  local lenses = {}
  for _, iter_lenses in pairs(client_lenses) do
    vim.list_extend(lenses, iter_lenses)
  end
  return lenses
end

--- Run the code lens in the current line
---
function M.run()
  local line = api.nvim_win_get_cursor(0)[1]
  local bufnr = api.nvim_get_current_buf()
  local bufstate = bufstates[bufnr] or {}
  local options = {} --- @type {client: integer, lens: lsp.CodeLens}[]
  local client_lenses = bufstate.client_lenses or {}
  for client, lenses in pairs(client_lenses) do
    for _, lens in pairs(lenses) do
      if lens.range.start.line == (line - 1) and lens.command and lens.command.command ~= '' then
        table.insert(options, { client = client, lens = lens })
      end
    end
  end
  if #options == 0 then
    vim.notify('No executable codelens found at current line')
  elseif #options == 1 then
    local option = options[1]
    execute_lens(option.lens, bufnr, option.client)
  else
    vim.ui.select(options, {
      prompt = 'Code lenses:',
      kind = 'codelens',
      format_item = function(option)
        return option.lens.command.title
      end,
    }, function(option)
      if option then
        execute_lens(option.lens, bufnr, option.client)
      end
    end)
  end
end

--- Clear the lenses
---
---@param client_id integer|nil filter by client_id. All clients if nil
---@param bufnr integer|nil filter by buffer. All buffers if nil, 0 for current buffer
function M.clear(client_id, bufnr)
  ---@type integer[]
  local buffers
  if bufnr then
    bufnr = resolve_bufnr(bufnr)
    buffers = { bufnr }
  else
    buffers = vim.tbl_filter(api.nvim_buf_is_loaded, api.nvim_list_bufs())
  end
  for _, iter_bufnr in pairs(buffers) do
    local client_ids = client_id and { client_id } or vim.tbl_keys(namespaces)
    local bufstate = bufstates[iter_bufnr] or {}
    for _, iter_client_id in pairs(client_ids) do
      local ns = namespaces[iter_client_id]
      -- there can be display()ed lenses, which are not stored in cache
      if bufstate.client_lenses then
        bufstate.client_lenses[iter_client_id] = {}
      end
      api.nvim_buf_clear_namespace(iter_bufnr, ns, 0, -1)
    end
  end
end

--- Display the lenses using virtual text
---
---@param lenses? lsp.CodeLens[] lenses to display
---@param bufnr integer
---@param client_id integer
function M.display(lenses, bufnr, client_id)
  if not api.nvim_buf_is_loaded(bufnr) then
    return
  end

  local ns = namespaces[client_id]
  if not lenses or not next(lenses) then
    api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    return
  end

  local lnum_lenses = {} ---@type table<integer, lsp.CodeLens[]>
  for _, lens in pairs(lenses) do
    local line_lenses = lnum_lenses[lens.range.start.line]
    if not line_lenses then
      line_lenses = {}
      lnum_lenses[lens.range.start.line] = line_lenses
    end
    table.insert(line_lenses, lens)
  end
  local num_lines = api.nvim_buf_line_count(bufnr)
  for i = 0, num_lines do
    local line_lenses = lnum_lenses[i] or {}
    api.nvim_buf_clear_namespace(bufnr, ns, i, i + 1)
    local chunks = {}
    local num_line_lenses = #line_lenses
    table.sort(line_lenses, function(a, b)
      return a.range.start.character < b.range.start.character
    end)
    for j, lens in ipairs(line_lenses) do
      local text = lens.command and lens.command.title or 'Unresolved lens ...'
      table.insert(chunks, { text, 'LspCodeLens' })
      if j < num_line_lenses then
        table.insert(chunks, { ' | ', 'LspCodeLensSeparator' })
      end
    end
    if #chunks > 0 then
      api.nvim_buf_set_extmark(bufnr, ns, i, 0, {
        virt_text = chunks,
        hl_mode = 'combine',
      })
    end
  end
end

--- Store lenses for a specific buffer and client
---
---@param lenses? lsp.CodeLens[] lenses to store
---@param bufnr integer
---@param client_id integer
function M.save(lenses, bufnr, client_id)
  bufnr = resolve_bufnr(bufnr)
  if not api.nvim_buf_is_loaded(bufnr) then
    return
  end

  local bufstate = bufstates[bufnr] or {}
  local client_lenses = bufstate.client_lenses
  if not client_lenses then
    client_lenses = {}
    bufstate.client_lenses = client_lenses
    bufstates[bufnr] = bufstate
    local ns = namespaces[client_id]
    api.nvim_buf_attach(bufnr, false, {
      on_detach = function(_, b)
        if bufstates[b] then
          bufstates[b].client_lenses = nil
        end
      end,
      on_lines = function(_, b, _, first_lnum, last_lnum)
        api.nvim_buf_clear_namespace(b, ns, first_lnum, last_lnum)
      end,
    })
  end
  client_lenses[client_id] = lenses
end

---@param lenses? lsp.CodeLens[]
---@param bufnr integer
---@param client_id integer
---@param callback fun()
local function resolve_lenses(lenses, bufnr, client_id, callback)
  lenses = lenses or {}
  local num_lens = vim.tbl_count(lenses)
  if num_lens == 0 then
    callback()
    return
  end

  local function countdown()
    num_lens = num_lens - 1
    if num_lens == 0 then
      callback()
    end
  end
  local ns = namespaces[client_id]
  local client = vim.lsp.get_client_by_id(client_id)
  for _, lens in pairs(lenses or {}) do
    if lens.command then
      countdown()
    else
      assert(client)
      client.request(ms.codeLens_resolve, lens, function(_, result)
        if api.nvim_buf_is_loaded(bufnr) and result and result.command then
          lens.command = result.command
          -- Eager display to have some sort of incremental feedback
          -- Once all lenses got resolved there will be a full redraw for all lenses
          -- So that multiple lens per line are properly displayed

          local num_lines = api.nvim_buf_line_count(bufnr)
          if lens.range.start.line <= num_lines then
            api.nvim_buf_set_extmark(
              bufnr,
              ns,
              lens.range.start.line,
              0,
              { virt_text = { { lens.command.title, 'LspCodeLens' } }, hl_mode = 'combine' }
            )
          end
        end

        countdown()
      end, bufnr)
    end
  end
end

--- |lsp-handler| for the method `textDocument/codeLens`
---
---@param err lsp.ResponseError?
---@param result lsp.CodeLens[]
---@param ctx lsp.HandlerContext
function M.on_codelens(err, result, ctx, _)
  local bufstate = bufstates[assert(ctx.bufnr)] or {}
  if err then
    bufstate.refreshing = nil
    log.error('codelens', err)
    return
  end

  M.save(result, ctx.bufnr, ctx.client_id)

  -- Eager display for any resolved (and unresolved) lenses and refresh them
  -- once resolved.
  M.display(result, ctx.bufnr, ctx.client_id)
  resolve_lenses(result, ctx.bufnr, ctx.client_id, function()
    bufstate.refreshing = nil
    M.display(result, ctx.bufnr, ctx.client_id)
  end)
end

--- @class vim.lsp.codelens.refresh.Opts
--- @inlinedoc
--- @field bufnr integer? filter by buffer. All buffers if nil, 0 for current buffer

--- Refresh the lenses.
---
--- It is recommended to trigger this using an autocmd or via keymap.
---
--- Example:
---
--- ```vim
--- autocmd BufEnter,CursorHold,InsertLeave <buffer> lua vim.lsp.codelens.refresh({ bufnr = 0 })
--- ```
---
--- @param opts? vim.lsp.codelens.refresh.Opts Optional fields
function M.refresh(opts)
  opts = opts or {}
  ---@type integer[]
  local buffers
  if opts.bufnr then
    local bufnr = resolve_bufnr(opts.bufnr)
    buffers = { bufnr }
  else
    buffers = vim.tbl_filter(api.nvim_buf_is_loaded, api.nvim_list_bufs())
  end

  for _, buf in ipairs(buffers) do
    local bufstate = bufstates[buf]
    if not bufstate then
      bufstate = {}
      bufstates[buf] = bufstate
    end
    if not bufstate.refreshing then
      local params = {
        textDocument = util.make_text_document_params(buf),
      }
      bufstate.refreshing = true

      local request_ids = vim.lsp.buf_request(buf, ms.textDocument_codeLens, params, M.on_codelens)
      if vim.tbl_isempty(request_ids) then
        bufstate.refreshing = nil
      end
    end
  end
end

return M
