local api = vim.api
local fn = vim.fn
local uv = vim.uv

--- @alias vim.explorer.EntryType
--- | 'directory'
--- | 'file'

--- @class vim.explorer.Entry
--- @field name string
--- @field path string
--- @field type vim.explorer.EntryType

--- @class vim.explorer.Snapshot
--- @field lines string[]
--- @field entries table<string, vim.explorer.Entry>

--- @class vim.explorer.ChangePlan
--- @field created string[]
--- @field deleted string[]
--- @field before vim.explorer.Snapshot
--- @field after vim.explorer.Snapshot

--- @class vim.explorer.State
--- @field buf integer
--- @field path string
--- @field entries vim.explorer.Entry[]
--- @field source_snapshot vim.explorer.Snapshot?
--- @field rendered_snapshot vim.explorer.Snapshot?
--- @field pending_change_plan vim.explorer.ChangePlan?
--- @field loading boolean
--- @field scan_id integer
--- @field renderer table

local M = {}

local augroup = api.nvim_create_augroup('nvim.explorer', {})

local renderer = {}

---@type table<integer, vim.explorer.State>
M._states = {}
M._initialized = false

---@param path string?
---@param fallback_to_cwd boolean?
---@return string?
local function normalize_dir(path, fallback_to_cwd)
  if (path == nil or path == '') and fallback_to_cwd then
    path = fn.getcwd()
  end

  if path == nil or path == '' then
    return nil
  end

  local expanded = fn.fnamemodify(path, ':p')
  if expanded == '' then
    return nil
  end

  return vim.fs.normalize(expanded)
end

---@param path string?
---@return boolean
local function is_directory(path)
  if not path or path == '' then
    return false
  end

  local stat = uv.fs_stat(path)
  return stat ~= nil and stat.type == 'directory'
end

---@param entries vim.explorer.Entry[]
local function sort_entries(entries)
  table.sort(entries, function(left, right)
    if left.type ~= right.type then
      return left.type == 'directory'
    end

    return left.name:lower() < right.name:lower()
  end)
end

---@param entry vim.explorer.Entry
---@return string
function renderer.format_entry(entry)
  if entry.type == 'directory' then
    return entry.name .. '/'
  end

  return entry.name
end

---@param path string
---@return string[]
function renderer.render_loading(path)
  return {
    ('Loading %s'):format(path),
    '',
  }
end

---@param path string
---@param entries vim.explorer.Entry[]
---@return string[]
function renderer.render_entries(path, entries)
  local lines = { path, '' }

  for _, entry in ipairs(entries) do
    lines[#lines + 1] = renderer.format_entry(entry)
  end

  if #entries == 0 then
    lines[#lines + 1] = '(empty)'
  end

  return lines
end

---@param path string
---@param err string
---@return string[]
function renderer.render_error(path, err)
  return {
    path,
    '',
    'Failed to read directory:',
    err,
  }
end

---@param buf integer
---@param lines string[]
---@param modifiable boolean
local function set_buffer_lines(buf, lines, modifiable)
  if not api.nvim_buf_is_valid(buf) then
    return
  end

  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = modifiable
  vim.bo[buf].modified = false
end

---@param entries vim.explorer.Entry[]
---@return vim.explorer.Snapshot
local function snapshot_from_entries(entries)
  local lines = {}
  local snapshot_entries = {}

  for _, entry in ipairs(entries) do
    local line = renderer.format_entry(entry)
    lines[#lines + 1] = line
    snapshot_entries[line] = entry
  end

  return {
    lines = lines,
    entries = snapshot_entries,
  }
end

---@param lines string[]
---@return vim.explorer.Snapshot
local function snapshot_from_lines(lines)
  local snapshot_entries = {}

  for _, line in ipairs(lines) do
    if line ~= '' and line ~= '(empty)' then
      local type = line:sub(-1) == '/' and 'directory' or 'file'
      local name = type == 'directory' and line:sub(1, -2) or line
      snapshot_entries[line] = {
        name = name,
        path = name,
        type = type,
      }
    end
  end

  return {
    lines = vim.deepcopy(lines),
    entries = snapshot_entries,
  }
end

---@param before vim.explorer.Snapshot
---@param after vim.explorer.Snapshot
---@return vim.explorer.ChangePlan
local function build_change_plan(before, after)
  local created = {}
  local deleted = {}

  for line in pairs(after.entries) do
    if before.entries[line] == nil then
      created[#created + 1] = line
    end
  end

  for line in pairs(before.entries) do
    if after.entries[line] == nil then
      deleted[#deleted + 1] = line
    end
  end

  table.sort(created)
  table.sort(deleted)

  return {
    created = created,
    deleted = deleted,
    before = before,
    after = after,
  }
end

---@param buf integer
---@param path string
---@return vim.explorer.State
local function ensure_state(buf, path)
  local state = M._states[buf]
  if state then
    state.path = path
    return state
  end

  state = {
    buf = buf,
    path = path,
    entries = {},
    loading = false,
    scan_id = 0,
    renderer = renderer,
  }
  M._states[buf] = state
  return state
end

---@param state vim.explorer.State
local function configure_buffer(state)
  local buf = state.buf

  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'explorer'
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = false

  vim.b[buf].explorer = true
  vim.b[buf].explorer_path = state.path
end

---@param state vim.explorer.State
local function render_loading(state)
  set_buffer_lines(state.buf, state.renderer.render_loading(state.path), false)
end

---@param state vim.explorer.State
local function render_entries(state)
  local lines = state.renderer.render_entries(state.path, state.entries)
  set_buffer_lines(state.buf, lines, true)
  state.rendered_snapshot = snapshot_from_entries(state.entries)
end

---@param state vim.explorer.State
---@param err string
local function render_error(state, err)
  set_buffer_lines(state.buf, state.renderer.render_error(state.path, err), false)
end

---@param state vim.explorer.State
---@param scan_id integer
---@param dir uv.luv_dir_t
---@param acc vim.explorer.Entry[]
local function scan_next_batch(state, scan_id, dir, acc)
  dir:readdir(vim.schedule_wrap(function(err, entries)
    if not api.nvim_buf_is_valid(state.buf) or state.scan_id ~= scan_id then
      dir:closedir()
      return
    end

    if err then
      dir:closedir()
      state.loading = false
      render_error(state, err)
      return
    end

    if not entries or vim.tbl_isempty(entries) then
      dir:closedir()
      sort_entries(acc)
      state.entries = acc
      state.source_snapshot = snapshot_from_entries(acc)
      state.loading = false
      render_entries(state)
      return
    end

    for _, entry in ipairs(entries) do
      if entry.name ~= '.' and entry.name ~= '..' and (entry.type == 'directory' or entry.type == 'file') then
        acc[#acc + 1] = {
          name = entry.name,
          path = vim.fs.joinpath(state.path, entry.name),
          type = entry.type,
        }
      end
    end

    scan_next_batch(state, scan_id, dir, acc)
  end))
end

---@param state vim.explorer.State
local function scan_directory(state)
  state.scan_id = state.scan_id + 1
  state.loading = true
  render_loading(state)

  local scan_id = state.scan_id
  uv.fs_opendir(state.path, function(err, dir)
    vim.schedule(function()
      if not api.nvim_buf_is_valid(state.buf) or state.scan_id ~= scan_id then
        if dir then
          dir:closedir()
        end
        return
      end

      if err or not dir then
        state.loading = false
        render_error(state, err or 'failed to open directory')
        return
      end

      scan_next_batch(state, scan_id, dir, {})
    end)
  end, 256)
end

---@param buf integer
---@param path string
local function attach_directory_buffer(buf, path)
  local existing = M._states[buf]
  if existing and existing.path == path then
    return
  end

  local state = ensure_state(buf, path)
  configure_buffer(state)
  scan_directory(state)
end

---@param buf integer
---@return string[]
local function get_editable_lines(buf)
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  local start = 3

  if #lines < start then
    return {}
  end

  local editable = {}
  for i = start, #lines do
    editable[#editable + 1] = lines[i]
  end
  return editable
end

---@param ev { buf: integer }
local function on_write_cmd(ev)
  local state = M._states[ev.buf]
  if not state or not state.rendered_snapshot then
    return
  end

  local current_snapshot = snapshot_from_lines(get_editable_lines(ev.buf))
  state.pending_change_plan = build_change_plan(state.rendered_snapshot, current_snapshot)

  if #state.pending_change_plan.created == 0 and #state.pending_change_plan.deleted == 0 then
    vim.bo[ev.buf].modified = false
    return
  end

  vim.notify('nvim.explorer: writing directory changes is not implemented yet', vim.log.levels.WARN)
end

---@param ev { buf: integer }
local function maybe_open_directory(ev)
  if vim.bo[ev.buf].buftype == 'terminal' then
    return
  end

  local path = normalize_dir(api.nvim_buf_get_name(ev.buf), false)
  if not is_directory(path) then
    return
  end

  attach_directory_buffer(ev.buf, path)
end

---@class vim.explorer.open.Opts

function M.setup()
  if M._initialized then
    return
  end

  M._initialized = true

  api.nvim_create_autocmd('BufEnter', {
    group = augroup,
    pattern = '*',
    callback = maybe_open_directory,
    desc = 'Open directories in nvim.explorer',
  })

  api.nvim_create_autocmd('BufWriteCmd', {
    group = augroup,
    callback = on_write_cmd,
    desc = 'Prepare directory edits for nvim.explorer',
  })

  api.nvim_create_autocmd('BufWipeout', {
    group = augroup,
    callback = function(ev)
      M._states[ev.buf] = nil
    end,
    desc = 'Clean up nvim.explorer state',
  })

  api.nvim_create_autocmd('VimEnter', {
    group = augroup,
    once = true,
    callback = function()
      for _, win in ipairs(api.nvim_list_wins()) do
        local buf = api.nvim_win_get_buf(win)
        maybe_open_directory({ buf = buf })
      end
    end,
    desc = 'Replace initial directory buffers with nvim.explorer',
  })
end

---@param buf? integer
---@return vim.explorer.State?
function M.get_state(buf)
  return M._states[buf or api.nvim_get_current_buf()]
end

---@param path string?
---@param opts? vim.explorer.open.Opts
function M.open(path, opts)
  vim.validate('opts', opts, 'table', true)
  M.setup()

  local dir = normalize_dir(path, true)
  if not is_directory(dir) then
    error(('nvim.explorer: %s is not a directory'):format(tostring(path)))
  end

  vim.cmd.edit(fn.fnameescape(dir))
end

return M
