-- pi-jail.terminal: one interactive agent terminal per workspace, each living
-- in its own named tab, reused across invocations so the agent session survives.
--
-- The terminal runs `<pj> open <ws>` via termopen, cwd = adopted repo root.
-- ws is the full workspace id "ws/<name>". The buffer is registered per
-- workspace id and reused while its job lives; a dead buffer is reused only
-- when config.terminal.keep_on_exit kept it.
--
-- Layout: each ws terminal owns a tab (t:pi_jail_name = ws, tab-local cwd =
-- root/ws) and is displayed as a right-side vertical split sized by
-- config.terminal.size. Reuse switches to the entry's tab and re-splits the
-- same buffer if its window was closed; if the whole tab was closed by the
-- user while the job lives, a fresh tab is opened for the same buffer/job.
local config = require("pi-jail.config")

local M = {}

-- ws id ("ws/<name>") -> { ws, bufnr, job_id, root, tab } for every terminal ever created here.
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
  M.registry[entry.ws] = nil
end

-- Open bufnr as a right-side vertical split in the current tab and focus it.
local function open_split(bufnr)
  local width = math.floor(vim.o.columns * config.get().terminal.size)
  return vim.api.nvim_open_win(bufnr, true, { vertical = true, width = width, split = "right" })
end

-- Create a fresh tab for ws (name + tab-local cwd) and return its tabpage id.
local function new_ws_tab(ws, root)
  vim.cmd("tabnew")
  local tab = vim.api.nvim_get_current_tabpage()
  -- pi_jail_name is our seam; tabname (lualine) and name (bufferline's rename
  -- convention) mirror it so those tablines label jail tabs without config.
  vim.api.nvim_tabpage_set_var(tab, "pi_jail_name", ws)
  vim.api.nvim_tabpage_set_var(tab, "tabname", ws)
  vim.api.nvim_tabpage_set_var(tab, "name", ws)
  -- Push the name into tabby's tab_name module when tabby is installed; a
  -- missing tabby is a no-op (tabby keeps its own name map per tabid).
  local ok, tab_name = pcall(require, "tabby.feature.tab_name")
  if ok and type(tab_name.set) == "function" then
    tab_name.set(tab, ws)
  end
  vim.cmd("tcd " .. vim.fn.fnameescape(root .. "/" .. ws))
  return tab
end

local function spawn(ws, root)
  local bufnr = vim.api.nvim_create_buf(false, true)
  local tab = new_ws_tab(ws, root)
  vim.api.nvim_set_current_win(open_split(bufnr))
  -- termopen attaches to the current buffer, which is bufnr in its new split.
  -- job_id is pre-declared so the on_exit closure captures the local, not a global.
  local job_id
  job_id = vim.fn.termopen({ config.get().pj, "open", ws }, {
    cwd = root,
    on_exit = function()
      -- Defer: lets TermClose settle before closing/wiping the buffer.
      vim.schedule(function()
        local entry = M.registry[ws]
        if entry ~= nil and entry.job_id == job_id and not config.get().terminal.keep_on_exit then
          cleanup(entry)
        end
      end)
    end,
  })
  vim.cmd("startinsert")
  local entry = { ws = ws, bufnr = bufnr, job_id = job_id, root = root, tab = tab }
  M.registry[ws] = entry
  return entry
end

-- Display entry's buffer in the current tab (re-splitting if windowless) and
-- focus it. Caller must already be on the right tab.
local function focus_in_current_tab(entry)
  local wins = vim.fn.win_findbuf(entry.bufnr)
  if #wins == 0 then
    vim.api.nvim_set_current_win(open_split(entry.bufnr))
  else
    vim.api.nvim_set_current_win(wins[1])
  end
  vim.cmd("startinsert")
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

---Open (or reuse) the terminal for workspace ws.
---Reuses a live terminal's buffer and tab; a dead one only when
---config.terminal.keep_on_exit kept it around, else starts fresh.
---@param ws string workspace id "ws/<name>"
---@param root string adopted repo root, used as the process cwd
---@return table entry { ws, bufnr, job_id, tab }
function M.open_or_reuse(ws, root)
  local entry = M.registry[ws]
  if entry ~= nil and vim.api.nvim_buf_is_valid(entry.bufnr) then
    if job_alive(entry.job_id) or config.get().terminal.keep_on_exit then
      -- Existing terminal (live, or dead-but-kept): switch to its tab (a new
      -- one if the user closed it) and focus (or reopen) its split.
      if not vim.api.nvim_tabpage_is_valid(entry.tab) then
        entry.tab = new_ws_tab(ws, entry.root)
      else
        vim.api.nvim_set_current_tabpage(entry.tab)
      end
      focus_in_current_tab(entry)
      return entry
    end
    -- Dead terminal that keep_on_exit=false already deregistered; unreachable
    -- in practice, but never hand back a dead buffer as a live terminal.
    cleanup(entry)
  end
  return spawn(ws, root)
end

return M
