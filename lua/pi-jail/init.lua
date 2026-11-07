-- pi-jail: plugin entry. Registers the :Pj user command and dispatches to the
-- existing modules; this file is UX glue only (picker, prompts, confirms,
-- notifications) and holds no business logic of its own.
--
-- Subcommands:
--   :Pj [ws [name]]  pick or name a workspace: set cwd into it + agent terminal
--   :Pj new [name]   pctl new (create only: no chdir, no agent)
--   :Pj drop [name]  pctl drop with confirm + unlanded-work --force flow
--   :Pj fill [name]  pctl fill, targeting the buffer's workspace by default
--   :Pj debug        jail shell for the buffer's workspace (picker fallback)

local config = require("pi-jail.config")
local ops = require("pi-jail.ops")
local project = require("pi-jail.project")
local terminal = require("pi-jail.terminal")

local M = {}

local SUBCOMMANDS = { "ws", "new", "drop", "fill", "debug" }

---Notify a pctl result: subject one-liner on success, stderr verbatim on failure.
---@param res table ops.run_pctl result { ok, stdout, stderr, code }
---@param subject string success message, e.g. "pctl new ws/gamma"
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
    vim.notify("not a pi-jail project: no pctl-adopted jj repo above " .. vim.loop.cwd(), vim.log.levels.ERROR)
  end
  return root
end

---Workspace picker: "name" / "name *" items, current-ws highlighted via
---list_workspaces' flags. Cancelled picks do nothing.
---@param root string
---@param on_choice fun(name: string)
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
    items[#items + 1] = ws.name .. (ws.dirty and " *" or "")
  end
  vim.ui.select(items, { prompt = "pi-jail workspace:" }, function(choice)
    if choice ~= nil then
      on_choice((choice:gsub(" %*$", "")))
    end
  end)
end

---Set the workspace cwd (scope from config.dir_change_scope: "cd" global
---or "tcd" tab-local) and open the workspace's terminal. chdir happens first
---so a spawned agent inherits it.
---@param name string workspace name
---@param root string adopted repo root
---@param mode string "ws" (agent) or "debug" (jail shell)
local function enter_ws(name, root, mode)
  local ws_dir = root .. "/ws/" .. name
  if vim.fn.isdirectory(ws_dir) ~= 1 then
    vim.notify("ws/" .. name .. " does not exist (create it with :Pj new)", vim.log.levels.ERROR)
    return
  end
  vim.cmd(config.get().dir_change_scope .. " " .. vim.fn.fnameescape(ws_dir))
  terminal.open_or_reuse(name, root, mode)
end

local function run_new(name, root)
  notify_result(ops.run_pctl({ "new", name }, root), "pctl new ws/" .. name)
end

---@param name string
---@param root string
---@param force boolean retry pass: append --force
local function run_drop(name, root, force)
  local args = force and { "drop", name, "--force" } or { "drop", name }
  local subject = "pctl drop ws/" .. name .. (force and " --force" or "")
  local res = ops.run_pctl(args, root)
  if res.ok then
    vim.notify(subject, vim.log.levels.INFO)
  elseif not force and res.stderr:find("unlanded work", 1, true) then
    local prompt = ("ws/%s has unlanded work. Drop anyway (--force)?"):format(name)
    if vim.fn.confirm(prompt, "&Yes\n&No", 2) == 1 then
      run_drop(name, root, true)
    end
  else
    vim.notify(res.stderr, vim.log.levels.ERROR)
  end
end

local function run_fill(name, root)
  notify_result(ops.run_pctl({ "fill", name }, root), "pctl fill ws/" .. name)
end

---Workspace the current buffer lives in, or nil (picker fallback for callers).
---@param root string
---@return string|nil name
local function buffer_ws(root)
  local path = vim.api.nvim_buf_get_name(0)
  if path == "" then
    return nil
  end
  return project.current_ws(root, path)
end

local function cmd_new(args, root)
  if args[1] ~= nil then
    run_new(args[1], root)
    return
  end
  vim.ui.input({ prompt = "new workspace name: " }, function(input)
    if input ~= nil and input ~= "" then
      run_new(input, root)
    end
  end)
end

local function cmd_drop(args, root)
  -- Dropping is destructive: confirm no matter how the name was resolved.
  local function proceed(name)
    local prompt = ("Drop ws/%s?"):format(name)
    if vim.fn.confirm(prompt, "&Yes\n&No", 2) == 1 then
      run_drop(name, root, false)
    end
  end
  if args[1] ~= nil then
    proceed(args[1])
  else
    pick_ws(root, proceed)
  end
end

local function cmd_fill(args, root)
  local name = args[1] or buffer_ws(root)
  if name ~= nil then
    run_fill(name, root)
  else
    pick_ws(root, function(n)
      run_fill(n, root)
    end)
  end
end

local function cmd_debug(root)
  local name = buffer_ws(root)
  if name ~= nil then
    enter_ws(name, root, "debug")
  else
    pick_ws(root, function(n)
      enter_ws(n, root, "debug")
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
  if sub == nil or sub == "ws" then
    if sub == "ws" and args[1] ~= nil then
      enter_ws(args[1], root, "ws")
    else
      pick_ws(root, function(name)
        enter_ws(name, root, "ws")
      end)
    end
  elseif sub == "new" then
    cmd_new(args, root)
  elseif sub == "drop" then
    cmd_drop(args, root)
  elseif sub == "fill" then
    cmd_fill(args, root)
  elseif sub == "debug" then
    cmd_debug(root)
  else
    vim.notify("unknown subcommand: " .. tostring(sub), vim.log.levels.ERROR)
  end
end

---Plugin setup: forwards opts to config (pctl, pi, terminal.keep_on_exit,
---terminal.size).
---@param opts table|nil
function M.setup(opts)
  config.setup(opts)
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
