local log = require('vim.lsp.log')
local lsp = require('vim.lsp')
local util = require('vim.lsp.util')
local ms = require('vim.lsp.protocol').Methods
local api = vim.api

local M = {}

---@param result? lsp.TextEdit[]
---@type lsp.Handler
local function handler(err, result, ctx)
  if err then
    log.error(err)
  end

  if not result then
    return
  end

  local client = assert(lsp.get_client_by_id(ctx.client_id))
  vim.notify(vim.inspect(result))
  util.apply_text_edits(result, ctx.bufnr, client.offset_encoding)
end

---@class vim.lsp.on_type_formatting.EnableFilter
---@field bufnr integer

---@param enable boolean
---@param filter vim.lsp.on_type_formatting.EnableFilter
function M.enable(enable, filter)
  local bufnr = filter.bufnr
  api.nvim_buf_attach(bufnr, false, {
    on_bytes = function(_, _, _, start_row, start_col, _, _, _, _, new_end_row, new_end_col)
      if new_end_col <= 0 and new_end_row <= 0 then
        return
      end

      local end_row, end_col = start_row + new_end_row, start_col + new_end_col
      local text = api.nvim_buf_get_text(bufnr, start_row, start_col, end_row, end_col, {})
      local ch = table.concat(text, '\n'):sub(-1)

      for _, client in
        ipairs(lsp.get_clients({ bufnr = bufnr, method = ms.textDocument_onTypeFormatting }))
      do
        if
          ch == client.server_capabilities.documentOnTypeFormattingProvider.firstTriggerCharacter
          or vim.tbl_contains(
            client.server_capabilities.documentOnTypeFormattingProvider.moreTriggerCharacter,
            ch
          )
        then
          local formattingParams = util.make_formatting_params()
          ---@type lsp.DocumentOnTypeFormattingParams
          local params = {
            ch = ch,
            position = {
              line = end_row,
              character = vim.str_utfindex(
                api.nvim_buf_get_lines(bufnr, end_row, end_row + 1, true)[1],
                'utf-8',
                end_col,
                true
              ),
            },
            textDocument = formattingParams.textDocument,
            options = formattingParams.options,
          }
          client:request(ms.textDocument_onTypeFormatting, params, handler)
        end
      end
    end,
  })
end

return M
