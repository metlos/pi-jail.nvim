-- pi-jail.terminal: one interactive agent terminal per workspace, reused across
-- invocations so the agent session survives.
--
-- The terminal runs `<pi> <mode> <ws>` (mode "ws" = agent TUI, "debug" = jail
-- shell) via termopen, cwd = adopted repo root. The buffer is registered per
-- workspace name and reused while its job lives; a dead buffer is reused only
-- when config.terminal.keep_on_exit kept it. chdir'ing into the workspace is
-- the caller's (init.lua) job; only the terminal lifecycle lives here.
--
-- Layout: the first terminal is a right-side vertical split sized by
-- config.terminal.size; every further terminal splits below an existing
-- terminal window, so all terminals share one right-side column.

local config = require("pi-jail.config")

local M = {}

-- ws_name -> { bufnr, job_id, root } for every terminal ever created here.
M.registry = {}

local function job_alive(job_id)
  return vim.fn.jobwait({ job_id }, 0)[1] == -1
end

local function close_windows(bufnr)
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    vim.api.nvim_win_close(win, true)
  end
end

local function cleanup(entry)
  close_windows(entry.bufnr)
  vim.api.nvim_buf_delete(entry.bufnr, { force = true })
  M.registry[entry.ws_name] = nil
end

-- The bottom-most window in this tabpage displaying a registered terminal
-- buffer; anchors further terminals to the bottom of the terminal column.
local function column_anchor_win()
  local term_bufnrs = {}
  for _, entry in pairs(M.registry) do
    if vim.api.nvim_buf_is_valid(entry.bufnr) then
      term_bufnrs[entry.bufnr] = true
    end
  end
  local anchor, anchor_row = nil, -1
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if term_bufnrs[vim.api.nvim_win_get_buf(win)] then
      local row = vim.fn.win_screenpos(win)[1]
      if row > anchor_row then
        anchor, anchor_row = win, row
      end
    end
  end
  return anchor
end

local function open_split(bufnr)
  local width = math.floor(vim.o.columns * config.get().terminal.size)
  local anchor = column_anchor_win()
  if anchor == nil then
    -- First terminal: right-side vertical split, as before.
    return vim.api.nvim_open_win(bufnr, true, { vertical = true, width = width, split = "right" })
  end
  -- Further terminals stack below the column, sharing its width.
  local win
  vim.api.nvim_win_call(anchor, function()
    win = vim.api.nvim_open_win(bufnr, true, { split = "below" })
  end)
  return win
end

local function spawn(ws_name, root, mode)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_win(open_split(bufnr))
  -- termopen attaches to the current buffer, which is bufnr in its new split.
  -- job_id is pre-declared so the on_exit closure captures the local, not a global.
  local job_id
  job_id = vim.fn.termopen({ config.get().pi, mode, ws_name }, {
    cwd = root,
    on_exit = function()
      -- Defer: lets TermClose settle before closing/wiping the buffer.
      vim.schedule(function()
        local entry = M.registry[ws_name]
        if entry ~= nil and entry.job_id == job_id and not config.get().terminal.keep_on_exit then
          cleanup(entry)
        end
      end)
    end,
  })
  vim.cmd("startinsert")
  local entry = { ws_name = ws_name, bufnr = bufnr, job_id = job_id, root = root }
  M.registry[ws_name] = entry
  return entry
end

---Look up the registry entry owning a buffer, or nil for non-terminal buffers.
---@param bufnr integer
---@return table|nil entry
function M.entry_for_buf(bufnr)
  for _, entry in pairs(M.registry) do
    if entry.bufnr == bufnr then
      return entry
    end
  end
  return nil
end

---Open (or reuse) the terminal for workspace ws_name.
---Reuses a live terminal's buffer and split; a dead one only when
---config.terminal.keep_on_exit kept it around, else starts fresh.
---@param ws_name string workspace (worktree) name
---@param root string adopted repo root, used as the process cwd
---@param mode string|nil "ws" (agent, default) or "debug" (jail shell)
---@return table entry { ws_name, bufnr, job_id }
function M.open_or_reuse(ws_name, root, mode)
  mode = mode or "ws"
  local entry = M.registry[ws_name]
  if entry ~= nil and vim.api.nvim_buf_is_valid(entry.bufnr) then
    if job_alive(entry.job_id) or config.get().terminal.keep_on_exit then
      -- Existing terminal (live, or dead-but-kept): focus (or reopen) its split.
      local wins = vim.fn.win_findbuf(entry.bufnr)
      if #wins == 0 then
        vim.api.nvim_set_current_win(open_split(entry.bufnr))
      elseif vim.api.nvim_get_current_win() ~= wins[1] then
        vim.api.nvim_set_current_win(wins[1])
      end
      vim.api.nvim_win_set_cursor(0, { vim.fn.line("$"), 0 })
      vim.cmd("startinsert")
      return entry
    end
    -- Dead terminal that keep_on_exit=false already deregistered; unreachable
    -- in practice, but never hand back a dead buffer as a live terminal.
    cleanup(entry)
  end
  return spawn(ws_name, root, mode)
end

return M
