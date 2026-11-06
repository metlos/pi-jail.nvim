-- pi-jail.terminal: one interactive agent terminal per workspace, reused across
-- invocations so the agent session survives.
--
-- The terminal runs `<pi> <mode> <ws>` (mode "ws" = agent TUI, "debug" = jail
-- shell) via termopen, cwd = adopted repo root. The buffer is registered per
-- workspace name and reused while its job lives; a dead buffer is reused only
-- when config.terminal.keep_on_exit kept it. tcd'ing into the workspace is the
-- caller's (init.lua) job; only the terminal lifecycle lives here.

local config = require("pi-jail.config")

local M = {}

-- ws_name -> { bufnr, job_id } for every terminal ever created here.
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

local function spawn(ws_name, root, mode)
  local bufnr = vim.api.nvim_create_buf(false, true)
  local width = math.floor(vim.o.columns * config.get().terminal.size)
  vim.api.nvim_open_win(bufnr, true, { vertical = true, width = width, split = "right" })
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
  local entry = { ws_name = ws_name, bufnr = bufnr, job_id = job_id }
  M.registry[ws_name] = entry
  return entry
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
        local width = math.floor(vim.o.columns * config.get().terminal.size)
        vim.api.nvim_open_win(entry.bufnr, true, { vertical = true, width = width, split = "right" })
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
