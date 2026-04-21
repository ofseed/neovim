local log = require('vim.lsp.log')
local vim_transport = require('vim._transport')
local strbuffer = require('vim._core.stringbuffer')
local validate = vim.validate

--- Embeds the given string into a table and correctly computes `Content-Length`.
---
--- @param message string
--- @return string message with `Content-Length` attribute
local function format_message_with_content_length(message)
  return table.concat({
    'Content-Length: ',
    tostring(#message),
    '\r\n\r\n',
    message,
  })
end

--- Extract `content-length` from the header.
---
--- The structure of header fields conforms to [HTTP semantics](https://tools.ietf.org/html/rfc7230#section-3.2),
--- i.e., `header-field = field-name : OWS field-value OWS`. OWS means optional whitespace (space/horizontal tabs).
---
--- We ignore lines ending with `\n` that don't contain `content-length`, since some servers
--- write log to standard output and there's no way to avoid it.
--- See https://github.com/neovim/neovim/pull/35743#pullrequestreview-3379705828
--- @param header string The header to parse
--- @return integer
local function get_content_length(header)
  local state = 'name'
  local i, len = 1, #header
  local j, name = 1, 'content-length'
  local buf = strbuffer.new()
  local digit = true
  while i <= len do
    local c = header:byte(i)
    if state == 'name' then
      if c >= 65 and c <= 90 then -- lower case
        c = c + 32
      end
      if (c == 32 or c == 9) and j == 1 then -- luacheck: ignore 542
        -- skip OWS for compatibility only
      elseif c == name:byte(j) then
        j = j + 1
      elseif c == 58 and j == 15 then
        state = 'colon'
      else
        state = 'invalid'
      end
    elseif state == 'colon' then
      if c ~= 32 and c ~= 9 then -- skip OWS normally
        state = 'value'
        i = i - 1
      end
    elseif state == 'value' then
      if c == 13 and header:byte(i + 1) == 10 then -- must end with \r\n
        local value = buf:get()
        if digit then
          return vim._assert_integer(value)
        end
        error('value of Content-Length is not number: ' .. value)
      else
        buf:put(string.char(c))
      end
      if c < 48 and c ~= 32 and c ~= 9 or c > 57 then
        digit = false
      end
    elseif state == 'invalid' then
      if c == 10 then -- reset for next line
        state, j = 'name', 1
      end
    end
    i = i + 1
  end
  error('Content-Length not found in header: ' .. header)
end

local M = {}

--- Mapping of error codes used by the client
--- @enum vim.json.rpc.ClientErrors
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

--- Dispatchers for incoming JSON-RPC message types.
--- @class vim.json.rpc.Dispatchers
--- @inlinedoc
--- @field on_notify fun(method: string, params: table?)
--- @field on_request fun(method: string, params: table?): any?, vim.json.rpc.Error?
--- @field on_exit fun(code: integer, signal: integer)
--- @field on_error fun(code: integer, err: any)

--- @type vim.json.rpc.Dispatchers
local default_dispatchers = {
  --- Default dispatcher for notifications received from the other peer.
  ---
  ---@param method string The invoked JSON-RPC method
  ---@param params table? Parameters for the invoked method
  on_notify = function(method, params)
    log.debug('remote_notification', method, params)
  end,

  --- Default dispatcher for requests received from the other peer.
  ---
  ---@param method string The invoked JSON-RPC method
  ---@param params table? Parameters for the invoked method
  ---@return any result (always nil for the default dispatchers)
  ---@return vim.json.rpc.Error error `vim.lsp.protocol.ErrorCodes.MethodNotFound`
  on_request = function(method, params)
    log.debug('remote_request', method, params)
    ---@type vim.json.rpc.Error
    local error = { code = -32601, message = 'Method not found' }
    return nil, error
  end,

  --- Default dispatcher for when this peer exits.
  ---
  ---@param code integer Exit code
  ---@param signal integer Number describing the signal used to terminate (if any)
  on_exit = function(code, signal)
    log.info('local_peer_exit', { code = code, signal = signal })
  end,

  --- Default dispatcher for this peer errors.
  ---
  ---@param code integer Error code
  ---@param err any Details about the error
  on_error = function(code, err)
    log.error('local_peer_error', M.client_errors[code], err)
  end,
}

--- @async
local function request_parser_loop()
  local buf = strbuffer.new()
  while true do
    local msg = buf:tostring()
    local header_end = msg:find('\r\n\r\n', 1, true)
    if header_end then
      local header = buf:get(header_end + 1)
      buf:skip(2) -- skip past header boundary
      local content_length = get_content_length(header)
      while strbuffer.len(buf) < content_length do
        buf:put(coroutine.yield())
      end
      local body = buf:get(content_length)
      buf:put(coroutine.yield(body))
    else
      buf:put(coroutine.yield())
    end
  end
end

--- @private
--- @param handle_body fun(body: string)
--- @param on_exit? fun()
--- @param on_error? fun(err: any, errkind: vim.lsp.rpc.ClientErrors)
function M.create_read_loop(handle_body, on_exit, on_error)
  on_exit = on_exit or function() end
  on_error = on_error or function() end
  local co = coroutine.create(request_parser_loop)
  coroutine.resume(co)
  return function(err, chunk)
    if err then
      on_error(err, M.client_errors.READ_ERROR)
      return
    end

    if not chunk then
      on_exit()
      return
    end

    if coroutine.status(co) == 'dead' then
      return
    end

    while true do
      local ok, res = coroutine.resume(co, chunk)
      if not ok then
        on_error(res, M.client_errors.INVALID_SERVER_MESSAGE)
        break
      elseif res then
        handle_body(res)
        chunk = ''
      else
        break
      end
    end
  end
end

--- JSON-RPC peer object
--- @class vim.json.rpc.Peer
--- @field private message_index integer
--- @field private message_callbacks table<integer, function> dict of message_id to callback
--- @field private notify_reply_callbacks table<integer, function> dict of message_id to callback
--- @field private transport vim.Transport
--- @field private dispatchers vim.json.rpc.Dispatchers
local Peer = {}

---@package
---@param dispatchers vim.json.rpc.Dispatchers
---@param transport vim.Transport
---@return vim.json.rpc.Peer
function Peer.new(dispatchers, transport)
  local self = setmetatable({
    message_index = 0,
    message_callbacks = {},
    notify_reply_callbacks = {},
    transport = transport,
    dispatchers = dispatchers,
  }, { __index = Peer })

  --- @param message string
  local function handle_body(message)
    self:handle_body(message)
  end

  local function on_exit()
    ---@diagnostic disable-next-line: invisible
    self.transport:terminate()
  end

  --- @param errkind vim.json.rpc.ClientErrors
  local function on_error(err, errkind)
    self:on_error(errkind, err)
    if errkind == M.client_errors.INVALID_SERVER_MESSAGE then
      ---@diagnostic disable-next-line: invisible
      self.transport:terminate()
    end
  end

  local on_read = M.create_read_loop(handle_body, on_exit, on_error)
  transport:listen(on_read, dispatchers.on_exit)
  return self
end

--- Indicates if this JSON-RPC peer is closing.
function Peer:is_closing()
  return self.transport:is_closing()
end

--- Terminates this JSON-RPC peer.
function Peer:terminate()
  return self.transport:terminate()
end

---@private
---@param message vim.json.rpc.Message
function Peer:encode_and_send(message)
  log.debug('rpc.send', message)
  if self.transport:is_closing() then
    return false
  end
  local jsonstr = vim.json.encode(message)

  self.transport:write(format_message_with_content_length(jsonstr))
  return true
end

--- Sends a notification to the other peer.
---@param method string The invoked JSON-RPC method
---@param params any Parameters for the invoked method
---@return boolean `true` if notification could be sent, `false` if not
function Peer:notify(method, params)
  return self:encode_and_send(
    ---@type vim.json.rpc.Notification
    {
      jsonrpc = '2.0',
      method = method,
      params = params,
    }
  )
end

---@private
--- Sends a response to the other peer.
function Peer:respond(request_id, err, result)
  return self:encode_and_send(
    ---@type vim.json.rpc.Response
    {
      id = request_id,
      jsonrpc = '2.0',
      error = err,
      result = result,
    }
  )
end

--- Sends a request to the other peer and runs {callback} upon response.
---
---@param method string The invoked JSON-RPC method
---@param params table? Parameters for the invoked method
---@param callback fun(err?: vim.json.rpc.Error, result: any, message_id: integer) Callback to invoke
---@param notify_reply_callback? fun(message_id: integer) Callback to invoke as soon as a request is no longer pending
---@return boolean success `true` if request could be sent, `false` if not
---@return integer? message_id if request could be sent, `nil` if not
function Peer:request(method, params, callback, notify_reply_callback)
  validate('callback', callback, 'function')
  validate('notify_reply_callback', notify_reply_callback, 'function', true)
  self.message_index = self.message_index + 1
  local message_id = self.message_index
  local result = self:encode_and_send(
    ---@type vim.json.rpc.Request
    {
      id = message_id,
      jsonrpc = '2.0',
      method = method,
      params = params,
    }
  )

  if not result then
    return false
  end

  self.message_callbacks[message_id] = vim.schedule_wrap(callback)
  if notify_reply_callback then
    self.notify_reply_callbacks[message_id] = vim.schedule_wrap(notify_reply_callback)
  end
  return result, message_id
end

---@package
---@param errkind vim.json.rpc.ClientErrors
---@param err any
function Peer:on_error(errkind, err)
  assert(M.client_errors[errkind])
  -- TODO what to do if this fails?
  pcall(self.dispatchers.on_error, errkind, err)
end

---@private
---@param errkind integer
---@param fn function
---@param ... any
---@return boolean success
---@return any result
---@return any ...
function Peer:try_call(errkind, fn, ...)
  local args = vim.F.pack_len(...)
  return xpcall(function()
    -- PUC Lua 5.1 xpcall() does not support forwarding extra arguments.
    return fn(vim.F.unpack_len(args))
  end, function(err)
    self:on_error(errkind, err)
  end)
end

-- TODO periodically check message_callbacks for old requests past a certain
-- time and log them. This would require storing the timestamp. I could call
-- them with an error then, perhaps.

--- @package
--- @param body string
function Peer:handle_body(body)
  local ok, decoded = pcall(vim.json.decode, body)
  if not ok then
    self:on_error(M.client_errors.INVALID_SERVER_JSON, decoded)
    return
  elseif type(decoded) ~= 'table' then
    self:on_error(M.client_errors.INVALID_SERVER_MESSAGE, decoded)
    return
  end
  ---@cast decoded vim.json.rpc.Message

  log.debug('rpc.receive', decoded)

  -- Received a request.
  if type(decoded.method) == 'string' and decoded.id then
    ---@cast decoded vim.json.rpc.Request
    -- Schedule here so that the users functions don't trigger an error and
    -- we can still use the result.
    vim.schedule(coroutine.wrap(function()
      --- @type boolean, any, vim.json.rpc.Error?
      local success, result, err = self:try_call(
        M.client_errors.SERVER_REQUEST_HANDLER_ERROR,
        self.dispatchers.on_request,
        decoded.method,
        decoded.params
      )
      log.debug('remote_request: callback result', { status = success, result = result, err = err })
      -- Dispatcher returns without an exception.
      if success then
        if result == nil and err == nil then
          error(
            string.format(
              'method %q: either a result or an error must be sent to the server in response',
              decoded.method
            )
          )
        end
        if err then
          validate('result', result, 'nil')
          validate('err', err, 'table')
          validate('err.code', err.code, 'number')
          validate('err.message', err.message, 'string')
          -- The error codes from and including -32768 to -32000
          -- are reserved for pre-defined errors. Any code within this range,
          -- but not defined explicitly below is reserved for future use.
          -- The error codes are nearly the same as those suggested for XML-RPC at the
          -- following url: http://xmlrpc-epi.sourceforge.net/specs/rfc.fault_codes.php
          if -32768 <= err.code and err.code <= -32000 then
            error(
              string.format(
                'method %q: error code %d is reserved by the JSON-RPC specification for pre-defined errors',
                decoded.method,
                err.code
              )
            )
          end
        end
      else
        -- On an exception, result will contain the error message,
        -- and it should be an internal error.
        ---@type vim.json.rpc.Error
        err = { code = -32603, message = result }
        result = nil
      end
      self:respond(decoded.id, err, result)
    end))
  elseif
    -- Received a response to a request we sent.
    -- Proceed only if exactly one of 'result' or 'error' is present,
    -- as required by the JSON-RPC spec:
    -- * If 'error' is nil, then 'result' must be present.
    -- * If 'result' is nil, then 'error' must be present (and not vim.NIL).
    decoded.id
    and (
      (decoded.error == nil and decoded.result ~= nil)
      or (decoded.result == nil and decoded.error ~= nil and decoded.error ~= vim.NIL)
    )
  then
    ---@cast decoded vim.json.rpc.Response
    -- We sent a number, so we expect a number.
    local result_id = vim._assert_integer(decoded.id)

    -- Notify the user that a response was received for the request
    local notify_reply_callback = self.notify_reply_callbacks[result_id]
    if notify_reply_callback then
      validate('notify_reply_callback', notify_reply_callback, 'function')
      notify_reply_callback(result_id)
      self.notify_reply_callbacks[result_id] = nil
    end

    local callback = self.message_callbacks[result_id]
    if callback then
      self.message_callbacks[result_id] = nil
      validate('callback', callback, 'function')
      self:try_call(
        M.client_errors.SERVER_RESULT_CALLBACK_ERROR,
        callback,
        decoded.error,
        decoded.result ~= vim.NIL and decoded.result or nil,
        result_id
      )
    else
      self:on_error(M.client_errors.NO_RESULT_CALLBACK_FOUND, decoded)
      log.error('No callback found for response id ' .. result_id)
    end
  elseif type(decoded.method) == 'string' then
    ---@cast decoded vim.json.rpc.Notification
    -- Received a notification.
    self:try_call(
      M.client_errors.NOTIFICATION_HANDLER_ERROR,
      self.dispatchers.on_notify,
      decoded.method,
      decoded.params
    )
  else
    -- Invalid server message
    self:on_error(M.client_errors.INVALID_SERVER_MESSAGE, decoded)
  end
end

---@param dispatchers vim.json.rpc.Dispatchers?
---@return vim.json.rpc.Dispatchers
local function merge_dispatchers(dispatchers)
  if not dispatchers then
    return default_dispatchers
  end
  ---@diagnostic disable-next-line: no-unknown
  for name, fn in pairs(dispatchers) do
    if type(fn) ~= 'function' then
      error(string.format('dispatcher.%s must be a function', name))
    end
  end
  ---@type vim.json.rpc.Dispatchers
  local merged = {
    on_notify = (
      dispatchers.on_notify and vim.schedule_wrap(dispatchers.on_notify)
      or default_dispatchers.on_notify
    ),
    on_error = (
      dispatchers.on_error and vim.schedule_wrap(dispatchers.on_error)
      or default_dispatchers.on_error
    ),
    on_exit = dispatchers.on_exit or default_dispatchers.on_exit,
    on_request = dispatchers.on_request or default_dispatchers.on_request,
  }
  return merged
end

--- Create a JSON-RPC peer that connects to either:
---
---  - a named pipe (windows)
---  - a domain socket (unix)
---  - a host and port via TCP
---
--- Communication uses stream-based JSON-RPC framed with `Content-Length` headers.
---
---@param host_or_path string host to connect to or path to a pipe/domain socket
---@param port integer? TCP port to connect to. If absent the first argument must be a pipe
--- @param dispatchers? vim.json.rpc.Dispatchers
---@return vim.json.rpc.Peer
function M.connect(host_or_path, port, dispatchers)
  log.info('Connecting RPC peer', { host_or_path = host_or_path, port = port })

  validate('host_or_path', host_or_path, 'string')
  validate('port', port, 'number', true)
  validate('dispatchers', dispatchers, 'table', true)

  dispatchers = merge_dispatchers(dispatchers)

  local transport = vim_transport.TransportConnect.new(host_or_path, port)
  return Peer.new(dispatchers, transport)
end

--- Additional context for the spawned process.
--- @class vim.transport.ExtraSpawnParams
--- @inlinedoc
--- @field cwd? string Working directory for the spawned process
--- @field detached? boolean Detach the spawned process from the current process
--- @field env? table<string,string> Additional environment variables for spawned process. See |vim.system()|

--- Starts a process and creates a JSON-RPC peer object to interact with it.
--- Communication with the spawned process happens via stdio. For communication via
--- TCP, create a process manually and use |vim.json.rpc.connect()|.
---
--- @param cmd string[] Command to start the peer process.
--- @param dispatchers? vim.json.rpc.Dispatchers
--- @param extra_spawn_params? vim.transport.ExtraSpawnParams
--- @return vim.json.rpc.Peer
function M.run(cmd, extra_spawn_params, dispatchers)
  log.info('Starting RPC peer', { cmd = cmd, extra = extra_spawn_params })

  validate('cmd', cmd, 'table')
  validate('extra_spawn_params', extra_spawn_params, 'table', true)
  validate('dispatchers', dispatchers, 'table', true)

  dispatchers = merge_dispatchers(dispatchers)

  local transport = vim_transport.TransportRun.new(cmd, extra_spawn_params)
  return Peer.new(dispatchers, transport)
end

M.__Peer = Peer

return M
