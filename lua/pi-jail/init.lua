-- pi-jail: plugin entry. Registers the :Pj user command and dispatches to the
-- existing modules; this file is UX glue only (picker, prompts, confirms,
-- notifications) and holds no business logic of its own.
--
-- Subcommands:
--   :Pj [open [ws/name]]  pick or name a workspace: dedicated tab + agent terminal
--   :Pj new [ws/name]      pj new, then enter the fresh workspace
--   :Pj drop [ws/name]     pj drop with confirm + unlanded-work --force flow
--   :Pj fill [ws/name]     pj fill, targeting the buffer's workspace by default
--
-- Workspace ids are always the relative path form "ws/<name>" (like pj's own
-- shell completion); the bare-name form is not accepted.

local config = require("pi-jail.config")
local ops = require("pi-jail.ops")
local project = require("pi-jail.project")
local terminal = require("pi-jail.terminal")
local follow = require("pi-jail.follow")

local M = {}

local SUBCOMMANDS = { "open", "new", "drop", "fill" }

---Validate a user-supplied workspace id: must be "ws/<name>" with a single
---path segment that is neither "." nor "..". pj stays the authority for
---everything beyond the shape (bracket-like names etc.); its stderr surfaces
---verbatim when it rejects them.
---@param id string|nil
---@return boolean valid
local function valid_ws_id(id)
  local name = id:match("^ws/([^/]+)$")
  return name ~= nil and name ~= "." and name ~= ".."
end

---Notify a pj result: subject one-liner on success, stderr verbatim on failure.
---@param res table ops.run_pj result { ok, stdout, stderr, code }
---@param subject string success message, e.g. "pj new ws/gamma"
local function notify_result(res, subject)
  if res.ok then
    vim.notify(subject, vim.log.levels.INFO)
  else
    vim.notify(res.stderr, vim.log.levels.ERROR)
  end
end

---Resolve the adopted repo root from the cwd, or notify + return nil.
---@return string|nil root
local function resolve_root()
  local root = project.find_root(vim.loop.cwd())
  if root == nil then
    vim.notify("not a pi-jail project: no pj-adopted jj repo above " .. vim.loop.cwd(), vim.log.levels.ERROR)
  end
  return root
end

---Does any open tabpage carry t:pi_jail_name == id?
---@param id string workspace id "ws/<name>"
---@return boolean
local function ws_has_tab(id)
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    local okv, v = pcall(vim.api.nvim_tabpage_get_var, tab, "pi_jail_name")
    if okv and v == id then
      return true
    end
  end
  return false
end

---Workspace picker: "ws/name" items, " [tab]" when a live tab holds the ws,
---" *" when jj reports it dirty (composed: "ws/name [tab] *"). jj's bare
---names get the path prefix composed here. Cancelled picks do nothing.
---@param root string
---@param on_choice fun(id: string)
local function pick_ws(root, on_choice)
  local wss = project.list_workspaces(root)
  if wss == nil then
    vim.notify("jj workspace list failed", vim.log.levels.ERROR)
    return
  end
  if #wss == 0 then
    vim.notify("no workspaces (run :Pj new first)", vim.log.levels.ERROR)
    return
  end
  local items = {}
  for _, ws in ipairs(wss) do
    local id = "ws/" .. ws.name
    items[#items + 1] = id
      .. (ws_has_tab(id) and " [tab]" or "")
      .. (ws.dirty and " *" or "")
  end
  vim.ui.select(items, { prompt = "pi-jail workspace:" }, function(choice)
    if choice ~= nil then
      on_choice((choice:gsub(" %[tab%]", ""):gsub(" %*$", "")))
    end
  end)
end

---Open the workspace's terminal; terminal.open_or_reuse owns the tab
---creation and the chdir into the ws inside it. Guarded on the ws dir
---existing on disk.
---@param id string workspace id "ws/<name>"
---@param root string adopted repo root
local function enter_ws(id, root)
  local ws_dir = root .. "/" .. id
  if vim.fn.isdirectory(ws_dir) ~= 1 then
    vim.notify(id .. " does not exist (create it with :Pj new)", vim.log.levels.ERROR)
    return
  end
  terminal.open_or_reuse(id, root)
end

---pj new, then enter the fresh workspace (create-then-open).
---@param id string
---@param root string
local function run_new(id, root)
  local res = ops.run_pj({ "new", id }, root)
  notify_result(res, "pj new " .. id)
  if res.ok then
    enter_ws(id, root)
  end
end

---@param id string
---@param root string
---@param force boolean retry pass: prepend --force (pj wants it before the name)
local function run_drop(id, root, force)
  local args = force and { "drop", "--force", id } or { "drop", id }
  local subject = "pj drop " .. (force and "--force " or "") .. id
  local res = ops.run_pj(args, root)
  if res.ok then
    vim.notify(subject, vim.log.levels.INFO)
  elseif not force and res.stderr:find("unlanded work", 1, true) then
    local prompt = ("%s has unlanded work. Drop anyway (--force)?"):format(id)
    if vim.fn.confirm(prompt, "&Yes\n&No", 2) == 1 then
      run_drop(id, root, true)
    end
  else
    vim.notify(res.stderr, vim.log.levels.ERROR)
  end
end

local function run_fill(id, root)
  notify_result(ops.run_pj({ "fill", id }, root), "pj fill " .. id)
end

---Workspace id for the current buffer ("ws/<name>"), or nil (picker fallback).
---@param root string
---@return string|nil id
local function buffer_ws(root)
  local path = vim.api.nvim_buf_get_name(0)
  if path == "" then
    return nil
  end
  local name = project.current_ws(root, path)
  return name ~= nil and "ws/" .. name or nil
end

---Notify a bad user-supplied workspace id and return false.
---@param id string
---@return boolean ok
local function check_ws_id(id)
  if valid_ws_id(id) then
    return true
  end
  vim.notify("expected ws/<name>: " .. id, vim.log.levels.ERROR)
  return false
end

local function cmd_new(args, root)
  if args[1] ~= nil then
    if check_ws_id(args[1]) then
      run_new(args[1], root)
    end
    return
  end
  vim.ui.input({ prompt = "new workspace (ws/<name>): " }, function(input)
    if input ~= nil and input ~= "" then
      if check_ws_id(input) then
        run_new(input, root)
      end
    end
  end)
end

local function cmd_drop(args, root)
  -- Dropping is destructive: confirm no matter how the id was resolved.
  local function proceed(id)
    local prompt = ("Drop %s?"):format(id)
    if vim.fn.confirm(prompt, "&Yes\n&No", 2) == 1 then
      run_drop(id, root, false)
    end
  end
  if args[1] ~= nil then
    if check_ws_id(args[1]) then
      proceed(args[1])
    end
  else
    pick_ws(root, proceed)
  end
end

local function cmd_fill(args, root)
  local id = args[1] or buffer_ws(root)
  if id ~= nil then
    if check_ws_id(id) then
      run_fill(id, root)
    end
  else
    pick_ws(root, function(n)
      run_fill(n, root)
    end)
  end
end

---Dispatch a :Pj invocation. sub nil = bare command.
---@param sub string|nil subcommand
---@param args string[]|nil remaining arguments
function M.run(sub, args)
  local root = resolve_root()
  if root == nil then
    return
  end
  args = args or {}
  if sub == nil or sub == "open" then
    if sub == "open" and args[1] ~= nil then
      if check_ws_id(args[1]) then
        enter_ws(args[1], root)
      end
    else
      pick_ws(root, function(id)
        enter_ws(id, root)
      end)
    end
  elseif sub == "new" then
    cmd_new(args, root)
  elseif sub == "drop" then
    cmd_drop(args, root)
  elseif sub == "fill" then
    cmd_fill(args, root)
  else
    vim.notify("unknown subcommand: " .. tostring(sub), vim.log.levels.ERROR)
  end
end

---Plugin setup: forwards opts to config (pj, terminal.keep_on_exit,
---terminal.size), registers the focus-follow autocmd and installs the
---tabline.
---@param opts table|nil
function M.setup(opts)
  config.setup(opts)
  follow.setup()
  require("pi-jail.tabline").setup()
end

vim.api.nvim_create_user_command("Pj", function(opts)
  local parts = vim.split(opts.args, "%s+", { trimempty = true })
  M.run(table.remove(parts, 1), parts)
end, {
  nargs = "*",
  desc = "pi-jail workspace commands",
  complete = function(lead, line, _)
    local words = vim.split(line, "%s+", { trimempty = true })
    -- Completing the subcommand position iff no full word precedes the lead.
    if #words > 1 and not (#words == 2 and lead ~= "") then
      return {}
    end
    local matches = {}
    for _, s in ipairs(SUBCOMMANDS) do
      if vim.startswith(s, lead) then
        matches[#matches + 1] = s
      end
    end
    return matches
  end,
})

return M
