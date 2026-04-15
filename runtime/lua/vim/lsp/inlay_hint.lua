local util = require('vim.lsp.util')
local log = require('vim.lsp.log')
local api = vim.api
local M = {}

local Capability = require('vim.lsp._capability')

local namespace = api.nvim_create_namespace('nvim.lsp.inlayhint')

---@class (private) vim.lsp.inlay_hint.ClientState
---@field line_hints table<integer, lsp.InlayHint[]?> line -> hints

---@class (private) vim.lsp.inlay_hint.Provider : vim.lsp.Capability
---@field active table<integer, vim.lsp.inlay_hint.Provider?>
---
--- `TextDocument` version current state corresponds to.
---@field version? integer
---
--- Last version of hints applied to this line.
---@field applied table<integer, integer?>
local Provider = {
  name = 'inlay_hint',
  method = 'textDocument/inlayHint',
  active = {},
}
Provider.__index = Provider
setmetatable(Provider, Capability)
Capability.all[Provider.name] = Provider

---@package
---@param bufnr integer
---@return vim.lsp.inlay_hint.Provider
function Provider:new(bufnr)
  ---@type vim.lsp.inlay_hint.Provider
  self = Capability.new(self, bufnr)
  self.applied = {}

  api.nvim_create_autocmd('LspNotify', {
    group = self.augroup,
    buffer = bufnr,
    callback = function(ev)
      if ev.data.method ~= 'textDocument/didChange' and ev.data.method ~= 'textDocument/didOpen' then
        return
      end

      local provider = Provider.active[ev.buf]
      if provider and provider.client_state[ev.data.client_id] then
        provider:request(ev.data.client_id)
      end
    end,
  })

  api.nvim_buf_attach(bufnr, false, {
    on_reload = function(_, buf)
      local provider = Provider.active[buf]
      if provider then
        provider.applied = {}
        provider:clear()
        provider:request()
      end
    end,
  })

  return self
end

---@package
function Provider:destroy()
  self:clear()
  api.nvim_del_augroup_by_id(self.augroup)
  self.active[self.bufnr] = nil
end

---@package
---@param client_id integer
function Provider:on_attach(client_id)
  self.client_state[client_id] = { line_hints = {} }
  self:request(client_id)
end

---@package
---@param client_id integer
function Provider:on_detach(client_id)
  if self.client_state[client_id] then
    self.client_state[client_id] = nil
    self.applied = {}

    if next(self.client_state) then
      api.nvim__redraw({ buf = self.bufnr, valid = true, flush = false })
    end
  end
end

---@private
function Provider:clear()
  api.nvim_buf_clear_namespace(self.bufnr, namespace, 0, -1)
  api.nvim__redraw({ buf = self.bufnr, valid = true, flush = false })
end

---@package
---@param client_id? integer
function Provider:request(client_id)
  local bufnr = self.bufnr

  for id in pairs(self.client_state) do
    if not client_id or client_id == id then
      local client = assert(vim.lsp.get_client_by_id(id))
      client:request('textDocument/inlayHint', {
        textDocument = util.make_text_document_params(bufnr),
        range = util._make_line_range_params(
          bufnr,
          0,
          api.nvim_buf_line_count(bufnr) - 1,
          client.offset_encoding
        ),
      }, nil, bufnr)
    end
  end
end

--- `lsp.Handler` for `textDocument/inlayHint`.
---
---@package
---@param err? lsp.ResponseError
---@param result? lsp.InlayHint[]
---@param ctx lsp.HandlerContext
function Provider:handler(err, result, ctx)
  local state = self.client_state[ctx.client_id]
  if not state then
    return
  end

  if err then
    log.error('inlay_hint', err)
    return
  end

  local bufnr = assert(ctx.bufnr)
  if util.buf_versions[bufnr] ~= ctx.version or not api.nvim_buf_is_loaded(bufnr) then
    return
  end

  local client = assert(vim.lsp.get_client_by_id(ctx.client_id))
  local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local line_hints = vim.defaulttable()

  for _, hint in ipairs(result or {}) do
    local lnum = hint.position.line
    local line = lines[lnum + 1] or ''
    hint.position.character =
      vim.str_byteindex(line, client.offset_encoding, hint.position.character, false)
    table.insert(line_hints[lnum], hint)
  end

  state.line_hints = line_hints
  self.version = ctx.version
  api.nvim__redraw({ buf = bufnr, valid = true, flush = false })
end

---@package
---@param topline integer
---@param botline integer
function Provider:on_win(topline, botline)
  if self.version ~= util.buf_versions[self.bufnr] then
    return
  end

  for lnum = topline, botline do
    if self.applied[lnum] ~= self.version then
      api.nvim_buf_clear_namespace(self.bufnr, namespace, lnum, lnum + 1)

      local hint_virtual_texts = {} --- @type table<integer, [string, string?][]>
      for _, state in pairs(self.client_state) do
        local hints = state.line_hints[lnum] or {}
        for _, hint in ipairs(hints) do
          local text = ''
          local label = hint.label
          if type(label) == 'string' then
            text = label
          else
            for _, part in ipairs(label) do
              text = text .. part.value
            end
          end

          local virt_text = hint_virtual_texts[hint.position.character] or {}
          if hint.paddingLeft then
            virt_text[#virt_text + 1] = { ' ' }
          end
          virt_text[#virt_text + 1] = { text, 'LspInlayHint' }
          if hint.paddingRight then
            virt_text[#virt_text + 1] = { ' ' }
          end
          hint_virtual_texts[hint.position.character] = virt_text
        end
      end

      for pos, virt_text in pairs(hint_virtual_texts) do
        api.nvim_buf_set_extmark(self.bufnr, namespace, lnum, pos, {
          virt_text_pos = 'inline',
          ephemeral = false,
          virt_text = virt_text,
        })
      end

      self.applied[lnum] = self.version
    end
  end

  if botline == api.nvim_buf_line_count(self.bufnr) - 1 then
    api.nvim_buf_clear_namespace(self.bufnr, namespace, botline + 1, -1)
  end
end

--- |lsp-handler| for the method `textDocument/inlayHint`
--- Store hints for a specific buffer and client
---@param result lsp.InlayHint[]?
---@param ctx lsp.HandlerContext
---@private
function M.on_inlayhint(err, result, ctx)
  local bufnr = ctx.bufnr
  local provider = bufnr and Provider.active[bufnr]
  if provider then
    provider:handler(err, result, ctx)
  elseif err then
    log.error('inlay_hint', err)
  end
end

--- |lsp-handler| for the method `workspace/inlayHint/refresh`
---@param ctx lsp.HandlerContext
---@private
function M.on_refresh(err, _, ctx)
  if err then
    return vim.NIL
  end

  local client = vim.lsp.get_client_by_id(ctx.client_id)
  if not client then
    return vim.NIL
  end

  for bufnr in pairs(client.attached_buffers or {}) do
    local provider = Provider.active[bufnr]
    if provider and provider.client_state[ctx.client_id] then
      for _, winid in ipairs(api.nvim_list_wins()) do
        if api.nvim_win_get_buf(winid) == bufnr then
          provider.applied = {}
          provider:request()
          break
        end
      end
    end
  end

  return vim.NIL
end

local decoration_provider = api.nvim_create_namespace('nvim.lsp.inlay_hint')
api.nvim_set_decoration_provider(decoration_provider, {
  on_win = function(_, _, bufnr, topline, botline)
    local provider = Provider.active[bufnr]
    if provider then
      provider:on_win(topline, botline)
    end
  end,
})

--- Optional filters |kwargs|:
--- @class vim.lsp.inlay_hint.get.Filter
--- @inlinedoc
--- @field bufnr integer?
--- @field range lsp.Range?

--- @class vim.lsp.inlay_hint.get.ret
--- @inlinedoc
--- @field bufnr integer
--- @field client_id integer
--- @field inlay_hint lsp.InlayHint

--- Get the list of inlay hints, (optionally) restricted by buffer or range.
---
--- Example usage:
---
--- ```lua
--- local hint = vim.lsp.inlay_hint.get({ bufnr = 0 })[1] -- 0 for current buffer
---
--- local client = vim.lsp.get_client_by_id(hint.client_id)
--- local resp = client:request_sync('inlayHint/resolve', hint.inlay_hint, 100, 0)
--- local resolved_hint = assert(
---   resp and resp.result,
---   resp and resp.err and vim.lsp.rpc.format_rpc_error(resp.err) or 'request failed'
--- )
--- vim.lsp.util.apply_text_edits(resolved_hint.textEdits, 0, client.encoding)
---
--- location = resolved_hint.label[1].location
--- client:request('textDocument/hover', {
---   textDocument = { uri = location.uri },
---   position = location.range.start,
--- })
--- ```
---
--- @param filter vim.lsp.inlay_hint.get.Filter?
--- @return vim.lsp.inlay_hint.get.ret[]
--- @since 12
function M.get(filter)
  vim.validate('filter', filter, 'table', true)
  filter = filter or {}

  local bufnr = filter.bufnr
  if not bufnr then
    --- @type vim.lsp.inlay_hint.get.ret[]
    local hints = {}
    --- @param buf integer
    vim.tbl_map(function(buf)
      vim.list_extend(hints, M.get(vim.tbl_extend('keep', { bufnr = buf }, filter)))
    end, api.nvim_list_bufs())
    return hints
  end
  bufnr = vim._resolve_bufnr(bufnr)

  local provider = Provider.active[bufnr]
  if not provider then
    return {}
  end

  local clients = vim.lsp.get_clients({
    bufnr = bufnr,
    method = 'textDocument/inlayHint',
  })
  if #clients == 0 then
    return {}
  end

  local range = filter.range
  if not range then
    range = {
      start = { line = 0, character = 0 },
      ['end'] = { line = api.nvim_buf_line_count(bufnr), character = 0 },
    }
  end

  --- @type vim.lsp.inlay_hint.get.ret[]
  local result = {}
  for _, client in pairs(clients) do
    local state = provider.client_state[client.id]
    local line_hints = state and state.line_hints
    if line_hints then
      for lnum = range.start.line, range['end'].line do
        local hints = line_hints[lnum] or {}
        for _, hint in ipairs(hints) do
          local line, char = hint.position.line, hint.position.character
          if
            (line > range.start.line or char >= range.start.character)
            and (line < range['end'].line or char <= range['end'].character)
          then
            table.insert(result, {
              bufnr = bufnr,
              client_id = client.id,
              inlay_hint = hint,
            })
          end
        end
      end
    end
  end
  return result
end

--- Query whether inlay hint is enabled in the {filter}ed scope
--- @param filter? vim.lsp.inlay_hint.enable.Filter
--- @return boolean
--- @since 12
function M.is_enabled(filter)
  vim.validate('filter', filter, 'table', true)
  return vim.lsp._capability.is_enabled('inlay_hint', filter)
end

--- Optional filters |kwargs|, or `nil` for all.
--- @class vim.lsp.inlay_hint.enable.Filter
--- @inlinedoc
--- Buffer number, or 0 for current buffer, or nil for all.
--- @field bufnr integer?

--- Enables or disables inlay hints for the {filter}ed scope.
---
--- To "toggle", pass the inverse of `is_enabled()`:
---
--- ```lua
--- vim.lsp.inlay_hint.enable(not vim.lsp.inlay_hint.is_enabled())
--- ```
---
--- @param enable (boolean|nil) true/nil to enable, false to disable
--- @param filter vim.lsp.inlay_hint.enable.Filter?
--- @since 12
function M.enable(enable, filter)
  vim.validate('enable', enable, 'boolean', true)
  vim.validate('filter', filter, 'table', true)
  vim.lsp._capability.enable('inlay_hint', enable, filter)
end

return M
