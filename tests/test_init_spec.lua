-- Spec for pi-jail.init: :Pj command dispatch + UX glue (picker, prompts,
-- confirms, notifications) on top of project/config/ops/terminal.
-- Boundaries (find_root, list_workspaces, run_pj, open_or_reuse, vim.ui.*,
-- vim.fn.confirm, vim.notify) are stubbed with programmatic versions.
-- Signals failure via `vim.cmd("cq")` after counting failures; run.sh greps the exit code.

local failures = 0
local checks = 0

local function check(cond, msg)
  checks = checks + 1
  if not cond then
    failures = failures + 1
    print("FAIL: " .. msg)
  end
end

local function eq(actual, expected, msg)
  if actual ~= expected then
    failures = failures + 1
    checks = checks + 1
    print(("FAIL: %s: expected %q, got %q"):format(msg, tostring(expected), tostring(actual)))
  else
    checks = checks + 1
  end
end

local function ok(cond, msg)
  if not cond then
    failures = failures + 1
    print("FAIL: " .. msg)
  else
    checks = checks + 1
  end
end

local function deep_eq(a, b)
  if type(a) ~= type(b) then
    return false
  end
  if type(a) ~= "table" then
    return a == b
  end
  for k, v in pairs(a) do
    if not deep_eq(v, b[k]) then
      return false
    end
  end
  for k in pairs(b) do
    if a[k] == nil then
      return false
    end
  end
  return true
end

local function eq_deep(actual, expected, msg)
  ok(deep_eq(actual, expected), ("%s: expected %s, got %s"):format(
    msg,
    vim.inspect and vim.inspect(expected) or tostring(expected),
    vim.inspect and vim.inspect(actual) or tostring(actual)
  ))
end

-- Set up module resolution under -u NONE (?/init.lua for require("pi-jail")).
-- run.sh cds to the repo root, so the repo's own lua/ dir is relative-safe.
package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local function load_module(name)
  local okmod, mod = pcall(require, name)
  if not okmod then
    return nil, mod
  end
  return mod
end

-- Per-test reset hook; nil in the red phase, set once the stubs exist.
local before_each = nil

local function test(name, fn)
  if before_each ~= nil then
    before_each()
  end
  local oktest, err = pcall(fn)
  if not oktest then
    failures = failures + 1
    print("FAIL: " .. name .. " (error) " .. tostring(err))
  else
    print("  - " .. name)
  end
end

-- Fixture: fake adopted repo root with real workspace dirs (tcd + isdirectory
-- need them); every other boundary is stubbed.
local dir = "/tmp/pj-init-" .. tostring(vim.loop and vim.loop.os_getpid() or 0)
os.execute("rm -rf " .. dir)
os.execute(
  "mkdir -p "
    .. dir
    .. "/root/ws/alpha "
    .. dir
    .. "/root/ws/beta "
    .. dir
    .. "/root/ws/gamma "
    .. dir
    .. "/root/shared"
)
local root = dir .. "/root"

print("=== test_init_spec: :Pj dispatch + UX glue ===")

local init, init_err = load_module("pi-jail")

if init == nil then
  -- Red phase: module does not exist yet. Everything below must fail loudly.
  test("require pi-jail loads", function()
    check(false, "require('pi-jail') failed: " .. tostring(init_err))
  end)
else
  local project = require("pi-jail.project")
  local ops = require("pi-jail.ops")
  local terminal = require("pi-jail.terminal")
  local config = require("pi-jail.config")

  -- Saved originals for teardown.
  local saved = {
    find_root = project.find_root,
    list_workspaces = project.list_workspaces,
    run_pj = ops.run_pj,
    open_or_reuse = terminal.open_or_reuse,
    select = vim.ui.select,
    input = vim.ui.input,
    confirm = vim.fn.confirm,
    notify = vim.notify,
  }

  -- Every recorded boundary call, in order.
  local rec = {
    find_root = {},
    list_ws = {},
    select = {},
    input = {},
    confirm = {},
    pj = {},
    open = {},
    notify = {},
  }

  -- Scriptable stub results.
  local stub = {
    root = root,
    workspaces = { { name = "alpha", dirty = false }, { name = "beta", dirty = true } },
    select_choice = "ws/alpha",
    select_cancel = false,
    input_value = "ws/gamma",
    input_cancel = false,
    confirm_results = {},
    pj_results = {},
  }

  local function next_from(queue, default)
    if #queue == 0 then
      return default
    end
    return table.remove(queue, 1)
  end

  project.find_root = function(start_dir)
    rec.find_root[#rec.find_root + 1] = start_dir
    return stub.root
  end

  project.list_workspaces = function(r)
    rec.list_ws[#rec.list_ws + 1] = r
    return stub.workspaces
  end

  ops.run_pj = function(args, r)
    rec.pj[#rec.pj + 1] = { args = args, root = r }
    return next_from(stub.pj_results, { ok = true, stdout = "", stderr = "", code = 0 })
  end

  terminal.open_or_reuse = function(name, r, mode)
    rec.open[#rec.open + 1] = { name = name, root = r, mode = mode }
  end

  vim.ui.select = function(items, opts, on_choice)
    local copy = {}
    for i, v in ipairs(items) do
      copy[i] = v
    end
    rec.select[#rec.select + 1] = { items = copy, prompt = opts and opts.prompt }
    if stub.select_cancel then
      on_choice(nil)
    else
      on_choice(stub.select_choice)
    end
  end

  vim.ui.input = function(opts, on_input)
    rec.input[#rec.input + 1] = { prompt = opts and opts.prompt }
    if stub.input_cancel then
      on_input(nil)
    else
      on_input(stub.input_value)
    end
  end

  vim.fn.confirm = function(prompt)
    rec.confirm[#rec.confirm + 1] = prompt
    return next_from(stub.confirm_results, 1)
  end

  vim.notify = function(msg, level)
    rec.notify[#rec.notify + 1] = { msg = msg, level = level }
  end

  local buf_counter = 0

  -- Fresh current buffer whose file lives at <path>/buf<N>.c (unique names so
  -- nvim_buf_set_name never collides with a buffer from an earlier test).
  local function set_current_buf_dir(path)
    buf_counter = buf_counter + 1
    local b = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(b, path .. "/buf" .. buf_counter .. ".c")
    vim.api.nvim_set_current_buf(b)
  end

  before_each = function()
    for k in pairs(rec) do
      rec[k] = {}
    end
    stub.root = root
    stub.workspaces = { { name = "alpha", dirty = false }, { name = "beta", dirty = true } }
    stub.select_choice = "ws/alpha"
    stub.select_cancel = false
    stub.input_value = "ws/gamma"
    stub.input_cancel = false
    stub.confirm_results = {}
    stub.pj_results = {}
    -- Reset both cwd scopes so drift from a previous test cannot leak in.
    -- dir_change_scope is NOT reset here: the default-scope test must observe
    -- the real default, and the tcd test restores it itself.
    vim.cmd("tcd " .. vim.fn.fnameescape(root))
    vim.cmd("cd " .. vim.fn.fnameescape(root))
    set_current_buf_dir(root)
  end

  test(":Pj is registered with nargs=* and subcommand completion", function()
    -- given the plugin is loaded; when inspecting user commands;
    -- then :Pj exists with nargs=* and completes only the subcommand position
    local cmds = vim.api.nvim_get_commands({})
    ok(cmds.Pj ~= nil, ":Pj appears in nvim_get_commands")
    if cmds.Pj == nil then
      return
    end
    eq(cmds.Pj.nargs, "*", ":Pj takes any number of args")
    eq_deep(cmds.Pj.complete("d", ":Pj d", 5), { "drop", "debug" }, "completing 'd' lists drop+debug")
    eq_deep(
      cmds.Pj.complete("", ":Pj ", 4),
      { "open", "new", "drop", "fill", "debug" },
      "completing '' lists all subcommands"
    )
    eq_deep(cmds.Pj.complete("zz", ":Pj zz", 5), {}, "unknown lead completes nothing")
    eq_deep(cmds.Pj.complete("", ":Pj open ", 9), {}, "only the subcommand position completes")
  end)

  test("bare dispatch lists formatted workspaces in the picker", function()
    -- given two workspaces (alpha clean, beta dirty); when :Pj runs bare;
    -- then the picker shows them formatted "ws/name" / "ws/name *"
    init.run(nil, {})
    eq(#rec.select, 1, "picker opened once")
    eq_deep(rec.select[1].items, { "ws/alpha", "ws/beta *" }, "items formatted ws/name + dirty marker")
    eq(rec.select[1].prompt, "pi-jail workspace:", "picker prompt")
  end)

  test("bare dispatch on_choice enters the workspace terminal", function()
    -- given the picker offers ws/alpha; when chosen; then chdir + agent terminal
    stub.select_choice = "ws/alpha"
    local cwd_before = vim.loop.cwd()
    init.run(nil, {})
    eq(#rec.find_root, 1, "root resolved once")
    eq(rec.find_root[1], cwd_before, "find_root called with the cwd at dispatch time")
    eq(vim.fn.getcwd(0), root .. "/ws/alpha", "entering changed the window cwd into ws/alpha")
    eq(#rec.open, 1, "terminal opened once")
    eq(rec.open[1].name, "ws/alpha", "terminal for the chosen ws")
    eq(rec.open[1].root, root, "terminal rooted at the repo root")
    eq(rec.open[1].mode, "open", "agent mode")
  end)

  test(":Pj command routes a bare invocation through the dispatch", function()
    vim.api.nvim_command("Pj")
    eq(#rec.select, 1, "picker opened for :Pj with no args")
    eq(#rec.open, 1, "terminal opened after choosing")
  end)

  test(":Pj open <ws/name> enters that workspace without the picker", function()
    init.run("open", { "ws/beta" })
    eq(#rec.select, 0, "no picker for an explicit ws id")
    eq(vim.fn.getcwd(0), root .. "/ws/beta", "cwd into ws/beta")
    eq(#rec.open, 1, "terminal opened once")
    eq(rec.open[1].name, "ws/beta", "terminal for ws/beta")
    eq(rec.open[1].mode, "open", "agent mode")
  end)

  test(":Pj command parses 'open ws/beta' into subcommand + args", function()
    vim.api.nvim_command("Pj open ws/beta")
    eq(#rec.select, 0, "no picker")
    eq(rec.open[1].name, "ws/beta", "arg routed to the open handler")
    eq(vim.fn.getcwd(0), root .. "/ws/beta", "cwd into ws/beta")
  end)

  test(":Pj open without a ws id falls back to the picker", function()
    init.run("open", {})
    eq(#rec.select, 1, "picker opened")
    eq(rec.open[1].name, "ws/alpha", "chosen ws entered")
  end)

  test("bad-form ws ids are rejected before anything runs", function()
    -- given every subcommand that takes a ws id; when given a bad form;
    -- then one ERROR notify naming the input and no boundary call happens
    local bad = { "gamma", "ws/", "ws//x", "ws/a/b", "ws/..", "ws/." }
    for _, sub in ipairs({ "open", "new", "drop", "fill" }) do
      for _, arg in ipairs(bad) do
        for k in pairs(rec) do
          rec[k] = {}
        end
        init.run(sub, { arg })
        local label = sub .. " " .. arg
        eq(#rec.notify, 1, label .. ": one notify")
        eq(rec.notify[1].level, vim.log.levels.ERROR, label .. ": at ERROR")
        ok(rec.notify[1].msg:find(arg, 1, true) ~= nil, label .. ": message names the input")
        eq(
          #rec.pj + #rec.open + #rec.select + #rec.input + #rec.confirm,
          0,
          label .. ": nothing ran"
        )
      end
    end
  end)

  test("default dir_change_scope=cd sets the global cwd", function()
    -- given untouched config; when entering a workspace; then the global cwd
    -- changes (window-local follows)
    init.run("open", { "ws/alpha" })
    eq(vim.fn.getcwd(-1, -1), root .. "/ws/alpha", "global cwd changed into ws/alpha")
    eq(vim.fn.getcwd(0), root .. "/ws/alpha", "window cwd follows the global one")
  end)

  test("dir_change_scope=tcd sets only the tab-local cwd", function()
    -- given dir_change_scope=tcd set after init was already required; when
    -- entering a workspace; then the tab cwd changes but the global cwd stays
    -- untouched (also proves the scope is read at call time, not cached)
    config.setup({ dir_change_scope = "tcd" })
    init.run("open", { "ws/beta" })
    eq(vim.fn.getcwd(-1, -1), root, "global cwd unchanged")
    eq(vim.fn.getcwd(0), root .. "/ws/beta", "tab cwd changed into ws/beta")
    config.setup({ dir_change_scope = "cd" }) -- restore the default
  end)

  test(":Pj new with a ws id creates the workspace only", function()
    -- given an explicit ws id; when :Pj new runs; then pj new is called with
    -- no chdir and no agent start (create only)
    init.run("new", { "ws/gamma" })
    eq(#rec.pj, 1, "one pj call")
    eq_deep(rec.pj[1].args, { "new", "ws/gamma" }, "pj new ws/gamma")
    eq(rec.pj[1].root, root, "pj run at the repo root")
    eq(#rec.select + #rec.input, 0, "no picker or prompt with an explicit ws id")
    eq(#rec.open, 0, "no agent terminal started")
    eq(vim.fn.getcwd(0), root, "no chdir")
    eq(rec.notify[1].msg, "pj new ws/gamma", "success notification")
    eq(rec.notify[1].level, vim.log.levels.INFO, "success at INFO")
  end)

  test(":Pj new without a ws id prompts for one", function()
    stub.input_value = "ws/gamma"
    init.run("new", {})
    eq(#rec.input, 1, "input prompt shown")
    ok(
      rec.input[1].prompt ~= nil and rec.input[1].prompt:find("ws/", 1, true) ~= nil,
      "prompt mentions the ws/ form"
    )
    eq_deep(rec.pj[1].args, { "new", "ws/gamma" }, "entered ws id used")
    eq(rec.notify[1].msg, "pj new ws/gamma", "success notification")
  end)

  test(":Pj new input cancelled runs nothing", function()
    stub.input_cancel = true
    init.run("new", {})
    eq(#rec.pj, 0, "no pj call on cancelled prompt")
    eq(#rec.notify, 0, "no notification")
  end)

  test(":Pj new prompt with a bad form notifies and runs nothing", function()
    stub.input_value = "gamma"
    init.run("new", {})
    eq(#rec.pj, 0, "no pj call on bad form")
    eq(#rec.notify, 1, "one notification")
    eq(rec.notify[1].level, vim.log.levels.ERROR, "at ERROR")
    ok(rec.notify[1].msg:find("gamma", 1, true) ~= nil, "message names the input")
  end)

  test(":Pj new failure notifies stderr verbatim at ERROR", function()
    stub.pj_results = { { ok = false, stdout = "", stderr = "pj: name taken\n", code = 1 } }
    init.run("new", { "ws/gamma" })
    eq(rec.notify[1].msg, "pj: name taken\n", "stderr verbatim")
    eq(rec.notify[1].level, vim.log.levels.ERROR, "failure at ERROR")
  end)

  test(":Pj drop picks, confirms, then drops", function()
    -- given the picker offers "ws/beta *" (dirty); when chosen and confirmed;
    -- then the dirty marker is stripped and pj drop ws/beta runs
    stub.select_choice = "ws/beta *"
    init.run("drop", {})
    eq(#rec.select, 1, "picker opened")
    eq(#rec.confirm, 1, "one confirmation")
    ok(rec.confirm[1]:find("ws/beta", 1, true) ~= nil, "confirm names the workspace")
    eq_deep(rec.pj[1].args, { "drop", "ws/beta" }, "dirty marker stripped from the choice")
    eq(rec.notify[1].msg, "pj drop ws/beta", "success notification")
  end)

  test(":Pj drop declined at the first confirm drops nothing", function()
    stub.confirm_results = { 2 }
    init.run("drop", {})
    eq(#rec.pj, 0, "no pj call when declined")
    eq(#rec.notify, 0, "no notification")
  end)

  test(":Pj drop with unlanded work offers --force", function()
    -- given drop fails with "unlanded work" in stderr; when both confirms
    -- accepted; then drop is retried with --force before the ws id
    stub.select_choice = "ws/beta *"
    stub.pj_results = {
      {
        ok = false,
        stdout = "",
        stderr = "pj: ws/beta has unlanded work in its working copy; use --force to drop anyway\n",
        code = 1,
      },
    }
    stub.confirm_results = { 1, 1 }
    init.run("drop", {})
    eq(#rec.confirm, 2, "force confirmation offered")
    ok(rec.confirm[2]:find("%-%-force", 1) ~= nil, "second confirm mentions --force")
    eq(#rec.pj, 2, "drop retried with --force")
    eq_deep(rec.pj[2].args, { "drop", "--force", "ws/beta" }, "pj drop --force ws/beta")
    eq(rec.notify[1].msg, "pj drop --force ws/beta", "success notification for the forced drop")
  end)

  test(":Pj drop unlanded work declined leaves the ws alone", function()
    stub.pj_results = {
      {
        ok = false,
        stdout = "",
        stderr = "pj: ws/alpha has unlanded work in its working copy; use --force to drop anyway\n",
        code = 1,
      },
    }
    stub.confirm_results = { 1, 2 }
    init.run("drop", {})
    eq(#rec.pj, 1, "only the plain drop attempted")
    eq(#rec.notify, 0, "no notification when force declined")
  end)

  test(":Pj drop failure without unlanded work notifies stderr", function()
    stub.pj_results = { { ok = false, stdout = "", stderr = "pj: nope\n", code = 1 } }
    init.run("drop", { "ws/gamma" })
    eq(#rec.confirm, 1, "no force offer")
    eq(rec.notify[1].msg, "pj: nope\n", "stderr verbatim")
    eq(rec.notify[1].level, vim.log.levels.ERROR, "at ERROR")
  end)

  test(":Pj drop with an explicit ws id skips the picker", function()
    init.run("drop", { "ws/gamma" })
    eq(#rec.select, 0, "no picker")
    eq_deep(rec.pj[1].args, { "drop", "ws/gamma" }, "direct drop")
  end)

  test(":Pj fill targets the buffer's workspace", function()
    -- given the current buffer is inside ws/alpha; when :Pj fill runs;
    -- then ws/alpha is filled without the picker
    set_current_buf_dir(root .. "/ws/alpha")
    init.run("fill", {})
    eq(#rec.select, 0, "no picker inside a ws")
    eq_deep(rec.pj[1].args, { "fill", "ws/alpha" }, "fill ws/alpha from the buffer path")
    eq(rec.notify[1].msg, "pj fill ws/alpha", "success notification")
  end)

  test(":Pj fill falls back to the picker outside a ws", function()
    set_current_buf_dir(root)
    stub.select_choice = "ws/beta *"
    init.run("fill", {})
    eq(#rec.select, 1, "picker opened outside a ws")
    eq_deep(rec.pj[1].args, { "fill", "ws/beta" }, "fill the chosen ws")
  end)

  test(":Pj fill with an explicit ws id skips detection", function()
    set_current_buf_dir(root .. "/ws/alpha")
    init.run("fill", { "ws/gamma" })
    eq(#rec.select, 0, "no picker")
    eq_deep(rec.pj[1].args, { "fill", "ws/gamma" }, "explicit ws id wins")
  end)

  test(":Pj debug opens the jail shell for the buffer's workspace", function()
    set_current_buf_dir(root .. "/ws/alpha")
    init.run("debug", {})
    eq(#rec.select, 0, "no picker inside a ws")
    eq(vim.fn.getcwd(0), root .. "/ws/alpha", "cwd into ws/alpha")
    eq(rec.open[1].name, "ws/alpha", "terminal for ws/alpha")
    eq(rec.open[1].mode, "debug", "debug mode")
  end)

  test(":Pj debug falls back to the picker outside a ws", function()
    set_current_buf_dir(root)
    stub.select_choice = "ws/alpha"
    init.run("debug", {})
    eq(#rec.select, 1, "picker opened")
    eq(rec.open[1].mode, "debug", "debug mode after choosing")
  end)

  test("unknown subcommand notifies an error", function()
    init.run("bogus", {})
    eq(#rec.pj + #rec.open, 0, "nothing ran")
    eq(rec.notify[1].level, vim.log.levels.ERROR, "at ERROR")
    ok(rec.notify[1].msg:find("bogus", 1, true) ~= nil, "message names the subcommand")
  end)

  test("no root: commands notify an error and run nothing", function()
    stub.root = nil
    init.run("new", { "ws/gamma" })
    eq(#rec.notify, 1, "one notification")
    eq(rec.notify[1].level, vim.log.levels.ERROR, "at ERROR")
    ok(rec.notify[1].msg:find("pi%-jail", 1) ~= nil, "message identifies the plugin")
    eq(#rec.pj + #rec.open + #rec.select, 0, "no boundary called past the guard")
  end)

  test(":Pj open with an unknown name notifies and opens nothing", function()
    init.run("open", { "ws/nope" })
    eq(#rec.open, 0, "no terminal for an unknown ws")
    eq(vim.fn.getcwd(0), root, "cwd unchanged")
    eq(rec.notify[1].level, vim.log.levels.ERROR, "at ERROR")
  end)

  test("jj failure in the picker notifies an error", function()
    stub.workspaces = nil
    init.run(nil, {})
    eq(#rec.select, 0, "no picker without a workspace list")
    eq(rec.notify[1].level, vim.log.levels.ERROR, "at ERROR")
  end)

  test("empty workspace list notifies an error", function()
    stub.workspaces = {}
    init.run(nil, {})
    eq(#rec.select, 0, "no picker")
    eq(rec.notify[1].level, vim.log.levels.ERROR, "at ERROR")
  end)

  test("picker cancel does nothing", function()
    stub.select_cancel = true
    init.run(nil, {})
    eq(#rec.open + #rec.pj, 0, "nothing opened or run")
    eq(vim.fn.getcwd(0), root, "cwd unchanged")
  end)

  test("setup forwards opts to config", function()
    init.setup({ pj = "/custom/pj" })
    eq(require("pi-jail.config").get().pj, "/custom/pj", "config.setup called with opts")
  end)

  test("setup registers the focus-follow BufEnter autocmd", function()
    -- given the follow group cleared; when setup runs;
    pcall(vim.api.nvim_del_augroup_by_name, "pi-jail-follow") -- absent until first setup
    init.setup({})
    -- then the group holds exactly one BufEnter autocmd
    local cmds = vim.api.nvim_get_autocmds({ group = "pi-jail-follow" })
    eq(#cmds, 1, "setup registered one BufEnter autocmd")
    eq(cmds[1].event, "BufEnter", "listening on BufEnter")
  end)

  -- Teardown: restore every stubbed boundary.
  project.find_root = saved.find_root
  project.list_workspaces = saved.list_workspaces
  ops.run_pj = saved.run_pj
  terminal.open_or_reuse = saved.open_or_reuse
  vim.ui.select = saved.select
  vim.ui.input = saved.input
  vim.fn.confirm = saved.confirm
  vim.notify = saved.notify
  os.execute("rm -rf " .. dir)
end

-- Summary + exit code signal.
print(("=== test_init_spec: %d/%d checks passed, %d failures"):format(checks - failures, checks, failures))
if failures > 0 then
  vim.cmd("cq")
end
