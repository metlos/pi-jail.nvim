-- Spec for pi-jail.follow (+ terminal.entry_for_buf): focusing a workspace's
-- terminal buffer chdirs the CURRENT TAB into that workspace (always tcd, the
-- tab model forces it); the global cwd is never touched.
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
  end
  checks = checks + 1
end

-- Set up module resolution under -u NONE.
package.path = "lua/?.lua;" .. package.path

local function load_module(name)
  local okmod, mod = pcall(require, name)
  if not okmod then
    return nil, mod
  end
  return mod
end

local function test(name, fn)
  local oktest, err = pcall(fn)
  if not oktest then
    failures = failures + 1
    print("FAIL: " .. name .. " (error) " .. tostring(err))
  else
    print("  - " .. name)
  end
end

-- Fixture: fake pj executable (banner + sleep forever) and a repo root with
-- two workspace dirs. No marker needed: follow never inspects the job.
local fixture = nil
local opened = {} -- every entry ever opened, for teardown
local detour_buf = nil -- sacrificial buffer for the focus helper

local function setup_fixture()
  local dir = "/tmp/pj-follow-" .. tostring(vim.loop and vim.loop.os_getpid() or 0)
  os.execute("rm -rf " .. dir)
  os.execute("mkdir -p " .. dir .. "/root/ws/alpha " .. dir .. "/root/ws/beta")
  local script = dir .. "/pj"
  local h = io.open(script, "w")
  h:write("#!/bin/sh\necho \"fake-$1-$2\"\nwhile :; do sleep 0.2; done\n")
  h:close()
  os.execute("chmod +x " .. script)
  fixture = { dir = dir, script = script, root = dir .. "/root" }
  return fixture
end

local function teardown_fixture()
  if fixture then
    for _, e in ipairs(opened) do
      pcall(vim.fn.jobstop, e.job_id)
    end
    vim.wait(2000, function()
      for _, e in ipairs(opened) do
        if vim.fn.jobwait({ e.job_id }, 0)[1] == -1 then
          return false
        end
      end
      return true
    end, 50)
    os.execute("rm -rf " .. fixture.dir)
  end
end

local function job_alive(job_id)
  return vim.fn.jobwait({ job_id }, 0)[1] == -1
end

---Focus a buffer like a real refocus would: always a genuine buffer switch,
---detouring through a sacrificial buffer when the target is already current
---(`:buffer` on the current buffer fires no BufEnter).
local function focus(bufnr)
  if vim.api.nvim_get_current_buf() == bufnr then
    vim.cmd("buffer " .. detour_buf)
  end
  vim.cmd("buffer " .. bufnr)
end

-- Read a tabpage's local cwd; getcwd(-1, nr) takes a tabpage ORDINAL, not a
-- handle, so read via a window of the tab to keep arbitrary handles valid.
local function tab_cwd(tab)
  local win = vim.api.nvim_tabpage_list_wins(tab)[1]
  return vim.api.nvim_win_call(win, function()
    return vim.fn.getcwd(0)
  end)
end

print("=== test_follow_spec: focus-follow tab-local chdir ===")

local terminal, terminal_err = load_module("pi-jail.terminal")
local config, config_err = load_module("pi-jail.config")
local follow, follow_err = load_module("pi-jail.follow")

if follow == nil or terminal == nil or config == nil then
  -- Red phase: module does not exist yet. Everything below must fail loudly.
  test("require pi-jail.follow, pi-jail.terminal, pi-jail.config load", function()
    if follow == nil then
      check(false, "require('pi-jail.follow') failed: " .. tostring(follow_err))
    end
    if terminal == nil then
      check(false, "require('pi-jail.terminal') failed: " .. tostring(terminal_err))
    end
    if config == nil then
      check(false, "require('pi-jail.config') failed: " .. tostring(config_err))
    end
  end)
else
  setup_fixture()
  config.setup({ pj = fixture.script, terminal = { keep_on_exit = true } })
  follow.setup()
  detour_buf = vim.api.nvim_create_buf(false, true)
  local root = fixture.root
  local alpha_dir = root .. "/ws/alpha"
  local beta_dir = root .. "/ws/beta"

  test("follow.setup registers exactly one BufEnter autocmd, idempotently", function()
    -- given nothing registered yet; when setup runs twice;
    -- then the group holds exactly one BufEnter autocmd
    follow.setup()
    follow.setup()
    local cmds = vim.api.nvim_get_autocmds({ group = "pi-jail-follow" })
    eq(#cmds, 1, "one autocmd in the pi-jail-follow group after double setup")
    eq(cmds[1].event, "BufEnter", "the autocmd listens on BufEnter")
  end)

  local alpha = nil

  test("entry_for_buf maps a registered buffer to its entry, root included", function()
    -- given a terminal for alpha; when looked up by buffer; then its entry
    alpha = terminal.open_or_reuse("ws/alpha", root)
    opened[#opened + 1] = alpha
    local entry = terminal.entry_for_buf(alpha.bufnr)
    ok(entry ~= nil, "entry found for alpha's terminal buffer")
    eq(entry.ws, "ws/alpha", "entry is alpha's")
    eq(entry.root, root, "entry carries the repo root")
    local scratch = vim.api.nvim_create_buf(false, true)
    eq(terminal.entry_for_buf(scratch), nil, "unknown buffer maps to nil")
  end)

  test("focusing a ws terminal chdirs the current tab, not the global cwd", function()
    -- given the global cwd at root and alpha's terminal spawned (its tab is
    -- current and cwd already root via new_ws_tab's tcd);
    vim.cmd("cd " .. vim.fn.fnameescape(root))
    local tab = vim.api.nvim_get_current_tabpage()
    eq(vim.fn.getcwd(-1, -1), root, "global cwd at root")
    -- when the terminal buffer gains focus; then the TAB's cwd moves into the
    -- workspace while the global cwd stays at root
    focus(alpha.bufnr)
    eq(vim.fn.getcwd(), alpha_dir, "current tab's cwd is ws/alpha after focusing")
    eq(tab_cwd(tab), alpha_dir, "the tab's local cwd is ws/alpha")
    eq(vim.fn.getcwd(-1, -1), root, "global cwd still root (tcd, never cd)")
  end)

  test("focusing a non-terminal buffer leaves the cwd alone", function()
    -- given the current tab's cwd is alpha's ws; when a scratch buffer gains
    -- focus; then no chdir
    local scratch = vim.api.nvim_create_buf(false, true)
    focus(scratch)
    eq(vim.fn.getcwd(), alpha_dir, "scratch focus does not chdir")
    eq(vim.fn.getcwd(-1, -1), root, "global cwd still root")
  end)

  test("no DirChanged fires when the cwd already matches the workspace", function()
    -- given the current tab's cwd already alpha's ws; when focus leaves and
    -- returns; then no chdir happened at all
    vim.api.nvim_clear_autocmds({ event = "DirChanged" })
    local fired = 0
    vim.api.nvim_create_autocmd("DirChanged", {
      callback = function()
        fired = fired + 1
      end,
    })
    local scratch = vim.api.nvim_create_buf(false, true)
    focus(scratch)
    focus(alpha.bufnr)
    -- then no chdir happened at all
    eq(fired, 0, "redundant chdir skipped by the getcwd guard")
    eq(vim.fn.getcwd(), alpha_dir, "cwd still alpha's ws")
    eq(vim.fn.getcwd(-1, -1), root, "global cwd still root")
  end)

  local beta = nil

  test("two ws terminals in two tabs keep their own tab cwds, scope tabpage", function()
    -- given alpha's terminal in its tab (tab cwd ws/alpha) and the global cwd
    -- at root; when a second ws terminal opens in its own tab;
    eq(vim.fn.getcwd(-1, -1), root, "global cwd at root (precondition)")
    beta = terminal.open_or_reuse("ws/beta", root)
    opened[#opened + 1] = beta
    eq(vim.api.nvim_get_current_tabpage(), beta.tab, "beta's tab is current after open")
    -- park beta's tab at root so focusing its terminal must actually chdir
    -- (the spawn's tcd already put the tab at ws/beta; the getcwd guard
    -- would rightly skip a redundant chdir otherwise)
    vim.cmd("tcd " .. vim.fn.fnameescape(root))
    local scope_seen = nil
    vim.api.nvim_clear_autocmds({ event = "DirChanged" })
    vim.api.nvim_create_autocmd("DirChanged", {
      callback = function()
        scope_seen = vim.v.event.scope
      end,
    })
    -- when beta's terminal is focused; then beta's tab chdirs (DirChanged
    -- scope tabpage) and alpha's tab keeps its own cwd
    focus(beta.bufnr)
    eq(vim.fn.getcwd(), beta_dir, "beta's tab cwd is ws/beta after focusing")
    eq(scope_seen, "tabpage", "DirChanged fired with tabpage scope")
    eq(tab_cwd(alpha.tab), alpha_dir, "alpha's tab still at ws/alpha")
    -- when focus moves to alpha's terminal (tab switch + buffer switch),
    -- alpha's tab parked at root the same way;
    vim.api.nvim_set_current_tabpage(alpha.tab)
    vim.cmd("tcd " .. vim.fn.fnameescape(root))
    scope_seen = nil
    vim.api.nvim_clear_autocmds({ event = "DirChanged" })
    vim.api.nvim_create_autocmd("DirChanged", {
      callback = function()
        scope_seen = vim.v.event.scope
      end,
    })
    focus(alpha.bufnr)
    -- then alpha's tab chdirs (scope tabpage) and beta's tab keeps its own
    eq(vim.fn.getcwd(), alpha_dir, "alpha's tab cwd is ws/alpha after focusing")
    eq(scope_seen, "tabpage", "DirChanged scope still tabpage")
    eq(tab_cwd(beta.tab), beta_dir, "beta's tab still at ws/beta")
    eq(vim.fn.getcwd(-1, -1), root, "global cwd never moved off root")
  end)

  test("dead-but-kept terminal still chdirs on focus", function()
    -- given alpha's job exited while keep_on_exit=true kept the buffer, and
    -- its tab parked elsewhere;
    os.execute("kill " .. vim.fn.jobpid(alpha.job_id))
    ok(vim.wait(3000, function()
      return not job_alive(alpha.job_id)
    end, 50), "alpha's job exited")
    ok(vim.api.nvim_buf_is_valid(alpha.bufnr), "buffer still valid (kept)")
    -- when the dead buffer gains focus in a tab parked at root; then the tab
    -- still chdirs into the ws
    vim.api.nvim_set_current_tabpage(beta.tab)
    vim.cmd("cd " .. vim.fn.fnameescape(root)) -- sets the GLOBAL cwd (tab has none)
    focus(alpha.bufnr) -- switches buffer inside this tab: BufEnter must tcd
    eq(vim.fn.getcwd(), alpha_dir, "focusing a kept dead terminal chdirs into ws/alpha")
    eq(vim.fn.getcwd(-1, -1), root, "global cwd still root")
  end)

  teardown_fixture()
end

-- Summary + exit code signal.
print(("=== test_follow_spec: %d/%d checks passed, %d failures"):format(checks - failures, checks, failures))
if failures > 0 then
  vim.cmd("cq")
end
