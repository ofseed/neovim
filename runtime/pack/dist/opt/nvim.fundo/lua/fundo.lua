local M = {}
local api = vim.api
local fn = vim.fn
local cmd = vim.cmd
local fs = vim.fs
local uv = vim.uv
local async = require('vim._async')

---@class vim.fundo.Config
local defaults = {
  archives_dir = fs.joinpath(fn.stdpath('cache'), 'fundo'),
  limit_archives_size = 512,
}

---@type vim.fundo.Config
local config = {
  archives_dir = fn.expand(defaults.archives_dir),
  limit_archives_size = defaults.limit_archives_size,
}

---@type integer?
local group_id
local enabled = false

-- Bridge libuv callback APIs into async.nvim and surface fs errors as Lua errors.
local function await_fs(argc, op, ...)
  local err, result = async.await(argc, op, ...)
  if err then
    error(err, 0)
  end
  return result
end

---@class vim.fundo.Undo
---@field name? string Absolute path of the file currently tracked by this buffer.
---@field undo_path? string Path of Neovim's undofile for the tracked file.
---@field fallback_path? string Archive file used by fundo to restore undo state.
---@field is_dirty? boolean Whether the fallback archive should be refreshed on the next sync.
---@field dir string Absolute path of fundo's archive directory.
---@field bufnr number Buffer handle associated with this state object.
---@field attached boolean Whether fundo is currently managing this buffer.
local Undo = {}

---@return vim.fundo.Undo
function Undo.new(bufnr, dir)
  local undo = setmetatable({}, { __index = Undo })
  undo.bufnr = bufnr
  undo.dir = dir
  return undo
end

---Attach fundo state to a buffer if it uses an undofile.
function Undo:attach()
  local buftype = vim.bo[self.bufnr].bt
  local name = api.nvim_buf_get_name(self.bufnr)
  if fs.normalize(fs.dirname(name)) == self.dir then
    vim.bo[self.bufnr].undofile = false
  end
  self.attached = (buftype == '' or buftype == 'acwrite') and vim.bo[self.bufnr].undofile
  if self.attached then
    self:reset()
  end
  return self.attached
end

function Undo:dispose()
  self.attached = false
end

---Refresh tracked file paths after a buffer name change or write.
---@param dirty? boolean
---@param buf_name? string
function Undo:reset(dirty, buf_name)
  if not self.attached then
    return
  end
  local name = buf_name or api.nvim_buf_get_name(self.bufnr)
  if name ~= self.name then
    self.undo_path = fn.undofile(name)
    self.fallback_path = fs.joinpath(self.dir, fs.basename(self.undo_path))
  end
  self.name = name
  self.is_dirty = dirty and self.undo_path ~= '' and vim.bo[self.bufnr].undolevels ~= 0
end

function Undo:is_empty()
  local undolist = api.nvim_buf_call(self.bufnr, function()
    return api.nvim_exec2('undolist', { output = true }).output
  end)
  return not undolist:match('^number')
end

---Load the undo file into the target buffer.
function Undo:load_undo()
  return api.nvim_buf_call(self.bufnr, function()
    return pcall(function()
      return cmd('sil rundo ' .. fn.fnameescape(self.undo_path))
    end)
  end)
end

---Restore fallback file contents while preserving the current buffer text and view.
function Undo:load_file_and_undo(winid)
  local view
  if winid then
    view = api.nvim_win_call(winid, fn.winsaveview)
  end

  -- Temporarily replace the buffer with the archived file so :rundo can rebuild
  -- the undo tree, then restore the user's current text and window view.
  local eventignore = vim.o.eventignore
  vim.o.eventignore = 'all'
  pcall(function()
    local modified = vim.bo[self.bufnr].modified
    local lines = api.nvim_buf_get_lines(self.bufnr, 0, -1, false)
    api.nvim_buf_call(self.bufnr, function()
      cmd(([[
                keepalt sil %dread %s
                keepj sil 1,%ddelete_
            ]]):format(#lines, fn.fnameescape(self.fallback_path), #lines))
    end)
    self:load_undo()
    api.nvim_buf_set_lines(self.bufnr, 0, -1, false, lines)
    vim.bo[self.bufnr].modified = modified

    if winid then
      api.nvim_win_call(winid, function()
        fn.winrestview(view)
      end)
    end
  end)
  vim.o.eventignore = eventignore
end

---Restore fallback contents for every visible window showing this buffer.
function Undo:load_fallback()
  if not uv.fs_stat(self.fallback_path) then
    return
  end
  -- Apply the rebuilt undo state in every window that is currently showing
  -- this buffer so each window keeps a consistent view/restoration point.
  local winids = {}
  for _, winid in ipairs(api.nvim_list_wins()) do
    if self.bufnr == api.nvim_win_get_buf(winid) then
      table.insert(winids, winid)
    end
  end
  if #winids == 0 then
    self:load_file_and_undo()
  elseif #winids > 1 then
    for _, winid in ipairs(winids) do
      self:load_file_and_undo(winid)
    end
  else
    self:load_file_and_undo(winids[1])
  end
end

function Undo:should_transfer()
  return self.attached and self.is_dirty
end

---Copy the current buffer file to the fallback archive when the undofile exists.
function Undo:transfer()
  return async.run(function()
    if not self:should_transfer() then
      return
    end
    local stat = await_fs(2, uv.fs_stat, self.undo_path)
    if stat then
      -- Write to a temporary archive first so a partial copy never replaces
      -- the last good fallback file.
      local temp_path = self.fallback_path .. '.__'
      await_fs(4, uv.fs_copyfile, self.name, temp_path)
      pcall(await_fs, 3, uv.fs_rename, temp_path, self.fallback_path)
    end
    self.is_dirty = false
  end)
end

---Recover fallback contents when the current undofile is empty.
function Undo:check()
  if not self.attached or self.undo_path == '' then
    return
  end
  if self:is_empty() then
    self:load_fallback()
  end
end

---@class vim.fundo.Manager
---@field initialized boolean Whether fundo has already created runtime state.
---@field undos table<number, vim.fundo.Undo> Undo state indexed by buffer handle.
---@field last_scanned_time number Last archive scan time in nanoseconds.
---@field mutex vim.async.Semaphore Serializes sync work across editor events.
---@field archives_dir? string Normalized directory used to store fallback archives.
---@field limit_archives_size? number Maximum archive size in MiB before pruning.
local Manager = {}

---Attach fundo tracking to a buffer on first use.
---@param bufnr number
---@return vim.fundo.Undo?
function Manager:attach(bufnr)
  if not self.undos[bufnr] then
    local undo_state = Undo.new(bufnr, self.archives_dir)
    if undo_state:attach() then
      self.undos[bufnr] = undo_state
    end
  end
  return self.undos[bufnr]
end

---Stop tracking a buffer and drop its cached undo state.
---@param bufnr number
function Manager:detach(bufnr)
  local undo_state = self.undos[bufnr]
  if undo_state then
    undo_state:dispose()
    self.undos[bufnr] = nil
  end
end

---Collect file stat information for every archive file in a directory.
---@param dir string
---@param buffer_size? number
---@return vim.async.Task<table<string, uv.fs_stat_t>>
function Manager:list_file_stats(dir, buffer_size)
  return async.run(function()
    local stream = await_fs(2, uv.fs_opendir, dir, nil, buffer_size or 32)
    local file_stats = {}
    -- Always close the directory handle before re-raising any traversal error.
    local ok, err = pcall(function()
      while true do
        local entries = await_fs(2, uv.fs_readdir, stream)
        if not entries then
          break
        end
        for _, entry in ipairs(entries) do
          if entry.type == 'file' then
            local name = entry.name
            file_stats[name] = await_fs(2, uv.fs_stat, fs.joinpath(dir, name))
          end
        end
      end
    end)
    await_fs(2, uv.fs_closedir, stream)
    assert(ok, err)
    return file_stats
  end)
end

---Remove old archive files when the archive directory exceeds the configured size.
---@return vim.async.Task
function Manager:scan_archives_dir()
  return async.run(function()
    local file_stats = async.await(self:list_file_stats(self.archives_dir, 1024))
    local archives = {}
    for name, stat in pairs(file_stats) do
      table.insert(archives, { name = name, mtime = stat.mtime.sec, size = stat.size })
    end
    table.sort(archives, function(a, b)
      return a.mtime > b.mtime
    end)
    local size = 0
    local limit = self.limit_archives_size * 1024 * 1024
    -- Keep newer archives first and delete older ones once the size limit
    -- has already been exceeded by the files retained so far.
    for _, stat in ipairs(archives) do
      if size > limit then
        local path = fs.joinpath(self.archives_dir, stat.name)
        await_fs(2, uv.fs_unlink, path)
      end
      size = size + stat.size
    end
  end)
end

---Sync every dirty buffer to its fallback archive.
---@param block? boolean
---@return vim.async.Task
function Manager:sync_all(block)
  return async.run(function()
    -- Editor events can overlap, so serialize sync work behind one semaphore.
    return self.mutex:with(function()
      return async.run(function()
        local sync_task = async.run(function()
          local transfer_tasks = {}
          for _, undo_state in pairs(self.undos) do
            if undo_state:should_transfer() then
              table.insert(transfer_tasks, undo_state:transfer())
            end
          end
          if vim.tbl_isempty(transfer_tasks) then
            return
          end
          return async.await_all(transfer_tasks)
        end)
        local sync_completed = false
        sync_task:wait(function()
          sync_completed = true
        end)
        local current_time = uv.hrtime()
        if block then
          -- Preserve the original behavior: perform a bounded synchronous
          -- wait first, then still await the task to completion below.
          vim.wait(1000, function()
            return sync_completed
          end, 30, false)
        end
        async.await(sync_task)
        -- 60 * 60 * 1e9 ns = 1 hour
        if not block and current_time - self.last_scanned_time > 60 * 60 * 1e9 then
          self.last_scanned_time = current_time
          async.await(self:scan_archives_dir())
        end
      end)
    end)
  end)
end

---Initialize runtime state for the current configuration.
---@param cfg vim.fundo.Config
---@return vim.fundo.Manager
function Manager:initialize(cfg)
  if self.initialized then
    return self
  end
  self.initialized = true
  self.archives_dir = fs.normalize(cfg.archives_dir)
  self.limit_archives_size = cfg.limit_archives_size
  uv.fs_mkdir(self.archives_dir, 493)
  self.undos = {}
  self.last_scanned_time = uv.hrtime()
  self.mutex = async.semaphore(1)
  return self
end

---Get the tracked undo state for a buffer.
---@param bufnr number
---@return vim.fundo.Undo?
function Manager:get(bufnr)
  return self.undos[bufnr]
end

---Dispose all tracked undo state and reset manager runtime fields.
function Manager:dispose()
  for _, undo in pairs(self.undos) do
    undo:dispose()
  end
  self.initialized = false
  self.undos = {}
  self.last_scanned_time = 0
end

local function create_events()
  group_id = api.nvim_create_augroup('nvim.fundo', {})
  api.nvim_create_autocmd('BufReadPost', {
    group = group_id,
    callback = function(ev)
      local undo = Manager:attach(ev.buf)
      if undo then
        undo:check()
      end
    end,
  })
  api.nvim_create_autocmd('BufWritePost', {
    group = group_id,
    callback = function(ev)
      local undo = Manager:get(ev.buf)
      if undo then
        undo:reset(true)
      end
    end,
  })
  api.nvim_create_autocmd('BufWipeout', {
    group = group_id,
    callback = function(ev)
      Manager:detach(ev.buf)
    end,
  })
  api.nvim_create_autocmd('CmdlineEnter', {
    group = group_id,
    pattern = ':',
    callback = function(ev)
      if ev.file ~= ':' then
        return
      end
      -- Re-check on the next loop tick so command-line mode/type is fully updated
      -- before deciding whether fundo should flush pending undo state.
      vim.schedule(function()
        if api.nvim_get_mode().mode == 'c' and fn.getcmdtype() == ':' then
          Manager:sync_all():raise_on_error()
        end
      end)
    end,
  })
  api.nvim_create_autocmd({ 'VimLeave', 'VimSuspend' }, {
    group = group_id,
    callback = function()
      Manager:sync_all(true):raise_on_error()
    end,
  })
  api.nvim_create_autocmd({ 'TermEnter', 'FocusLost' }, {
    group = group_id,
    callback = function()
      Manager:sync_all():raise_on_error()
    end,
  })
end

function M.enable()
  if enabled then
    return false
  end
  create_events()
  Manager:initialize(config)
  enabled = true
  return true
end

function M.disable()
  if not enabled then
    return false
  end
  if group_id then
    pcall(api.nvim_del_augroup_by_id, group_id)
    group_id = nil
  end
  Manager:dispose()
  enabled = false
  return true
end

---Setup configuration and enable fundo
---@param opts? vim.fundo.Config
function M.setup(opts)
  local archives_dir = opts and opts.archives_dir or defaults.archives_dir
  local limit_archives_size = opts and opts.limit_archives_size or defaults.limit_archives_size
  vim.validate('archives_dir', archives_dir, 'string')
  vim.validate('limit_archives_size', limit_archives_size, 'number')
  config = {
    archives_dir = fn.expand(archives_dir),
    limit_archives_size = limit_archives_size,
  }
  if enabled then
    -- Rebuild runtime state so an already enabled plugin starts using the new
    -- archive directory and size limit immediately.
    M.disable()
    M.enable()
  end
end

return M
