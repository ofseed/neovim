local protocol = require('vim.lsp.protocol')
local json_rpc = require('vim.json.rpc')
local validate = vim.validate

local M = {}

--- Mapping of error codes used by the client
--- @enum vim.lsp.rpc.ClientErrors
local client_errors = {
  INVALID_SERVER_MESSAGE = 1,
  INVALID_SERVER_JSON = 2,
  NO_RESULT_CALLBACK_FOUND = 3,
  READ_ERROR = 4,
  NOTIFICATION_HANDLER_ERROR = 5,
  SERVER_REQUEST_HANDLER_ERROR = 6,
  SERVER_RESULT_CALLBACK_ERROR = 7,
}

--- @type table<string,integer> | table<integer,string>
--- @nodoc
M.client_errors = vim.deepcopy(client_errors)
for k, v in pairs(client_errors) do
  M.client_errors[v] = k
end

--- Constructs an error message from an LSP error object.
---
---@param err table The error object
---@return string error_message The formatted error message
function M.format_rpc_error(err)
  validate('err', err, 'table')

  -- There is ErrorCodes in the LSP specification,
  -- but in ResponseError.code it is not used and the actual type is number.
  local code --- @type string
  if protocol.ErrorCodes[err.code] then
    code = string.format('code_name = %s,', protocol.ErrorCodes[err.code])
  else
    code = string.format('code_name = unknown, code = %s,', err.code)
  end

  local message_parts = { 'RPC[Error]', code }
  if err.message then
    table.insert(message_parts, 'message =')
    table.insert(message_parts, string.format('%q', err.message))
  end
  if err.data then
    table.insert(message_parts, 'data =')
    table.insert(message_parts, vim.inspect(err.data))
  end
  return table.concat(message_parts, ' ')
end

--- Creates an RPC response table `error` to be sent to the LSP response.
---
---@param code integer RPC error code defined, see `vim.lsp.protocol.ErrorCodes`
---@param message? string arbitrary message to send to server
---@param data? any arbitrary data to send to server
---
---@see lsp.ErrorCodes See `vim.lsp.protocol.ErrorCodes`
---@return lsp.ResponseError
function M.rpc_response_error(code, message, data)
  -- TODO should this error or just pick a sane error (like InternalError)?
  ---@type string
  local code_name = assert(protocol.ErrorCodes[code], 'Invalid RPC error code')
  return setmetatable({
    code = code,
    message = message or code_name,
    data = data,
  }, {
    __tostring = M.format_rpc_error,
  })
end

--- Dispatchers for LSP message types.
--- @class vim.lsp.rpc.Dispatchers
--- @inlinedoc
--- @field notification fun(method: vim.lsp.protocol.Method.ClientToServer.Notification, params: table)
--- @field server_request fun(method: vim.lsp.protocol.Method.ClientToServer.Request, params: table): any?, lsp.ResponseError?
--- @field on_exit fun(code: integer, signal: integer)
--- @field on_error fun(code: integer, err: any)

M.create_read_loop = json_rpc.create_read_loop

--- Client RPC object
--- @class vim.lsp.rpc.Client
---
--- See [vim.lsp.rpc.request()]
--- @field request fun(method: vim.lsp.protocol.Method.ClientToServer.Request, params: table?, callback: fun(err?: lsp.ResponseError, result: any, request_id: integer), notify_reply_callback?: fun(message_id: integer)):boolean,integer?
---
--- See [vim.lsp.rpc.notify()]
--- @field notify fun(method: vim.lsp.protocol.Method.ClientToServer.Notification, params: any): boolean
---
--- Indicates if the RPC is closing.
--- @field is_closing fun(): boolean
---
--- Terminates the RPC client.
--- @field terminate fun()

--- Preserve the legacy `vim.lsp.rpc` dot-call API.
---@param client vim.json.rpc.Peer
local function to_lsp_rpc(client)
  local result = client --[[@as vim.lsp.rpc.Client]]
  local Client = require('vim.json.rpc').__Peer

  ---@private
  function result.is_closing()
    return Client.is_closing(result)
  end

  ---@private
  function result.terminate()
    Client.terminate(result)
  end

  --- Sends a request to the LSP server and runs {callback} upon response.
  ---
  ---@param method (vim.lsp.protocol.Method.ClientToServer.Request) The invoked LSP method
  ---@param params (table?) Parameters for the invoked LSP method
  ---@param callback fun(err: lsp.ResponseError?, result: any) Callback to invoke
  ---@param notify_reply_callback? fun(message_id: integer) Callback to invoke as soon as a request is no longer pending
  ---@return boolean success `true` if request could be sent, `false` if not
  ---@return integer? message_id if request could be sent, `nil` if not
  function result.request(method, params, callback, notify_reply_callback)
    return Client.request(result, method, params, callback, notify_reply_callback)
  end

  --- Sends a notification to the LSP server.
  ---@param method (vim.lsp.protocol.Method.ClientToServer.Notification) The invoked LSP method
  ---@param params (table?) Parameters for the invoked LSP method
  ---@return boolean `true` if notification could be sent, `false` if not
  function result.notify(method, params)
    return Client.notify(result, method, params)
  end

  return result
end

---@param dispatchers? vim.lsp.rpc.Dispatchers
---@return vim.json.rpc.Dispatchers?
local function to_dispatchers(dispatchers)
  if dispatchers then
    return {
      on_notify = dispatchers.notification,
      on_request = dispatchers.server_request,
      on_exit = dispatchers.on_exit,
      on_error = dispatchers.on_error,
    }
  end
end

--- Create a LSP RPC client factory that connects to either:
---
---  - a named pipe (windows)
---  - a domain socket (unix)
---  - a host and port via TCP
---
--- Return a function that can be passed to the `cmd` field for
--- |vim.lsp.start()|.
---
---@param host_or_path string host to connect to or path to a pipe/domain socket
---@param port integer? TCP port to connect to. If absent the first argument must be a pipe
---@return fun(dispatchers: vim.lsp.rpc.Dispatchers): vim.lsp.rpc.Client
function M.connect(host_or_path, port)
  return function(dispatchers)
    return to_lsp_rpc(json_rpc.connect(host_or_path, port, to_dispatchers(dispatchers)))
  end
end

--- Additional context for the LSP server process.
--- @class vim.lsp.rpc.ExtraSpawnParams : vim.transport.ExtraSpawnParams
--- @inlinedoc
--- @field cwd? string Working directory for the LSP server process
--- @field detached? boolean Detach the LSP server process from the current process
--- @field env? table<string,string> environment variables for LSP server process. See |vim.system()|

--- Starts an LSP server process and create an LSP RPC client object to
--- interact with it. Communication with the spawned process happens via stdio. For
--- communication via TCP, spawn a process manually and use |vim.lsp.rpc.connect()|
---
--- @param cmd string[] Command to start the LSP server.
--- @param dispatchers? vim.lsp.rpc.Dispatchers
--- @param extra_spawn_params? vim.lsp.rpc.ExtraSpawnParams
--- @return vim.lsp.rpc.Client
function M.start(cmd, dispatchers, extra_spawn_params)
  return to_lsp_rpc(json_rpc.run(cmd, extra_spawn_params, to_dispatchers(dispatchers)))
end

return M
