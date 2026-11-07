-- Spec for pi-jail.follow (+ terminal.entry_for_buf): focusing a workspace's
-- terminal buffer chdirs into that workspace, honoring config.dir_change_scope.
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

-- Fixture: fake pi executable (banner + sleep forever) and a repo root with
-- two workspace dirs. No marker needed: follow never inspects the job.
local fixture = nil
local opened = {} -- every entry ever opened, for teardown
local detour_buf = nil -- sacrificial buffer for the focus helper

local function setup_fixture()
  local dir = "/tmp/pj-follow-" .. tostring(vim.loop and vim.loop.os_getpid() or 0)
  os.execute("rm -rf " .. dir)
  os.execute("mkdir -p " .. dir .. "/root/ws/alpha " .. dir .. "/root/ws/beta")
  local script = dir .. "/pi"
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

print("=== test_follow_spec: focus-follow chdir ===")

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
  config.setup({ pi = fixture.script, terminal = { keep_on_exit = true } })
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
    alpha = terminal.open_or_reuse("alpha", root)
    opened[#opened + 1] = alpha
    local entry = terminal.entry_for_buf(alpha.bufnr)
    ok(entry ~= nil, "entry found for alpha's terminal buffer")
    eq(entry.ws_name, "alpha", "entry is alpha's")
    eq(entry.root, root, "entry carries the repo root")
    local scratch = vim.api.nvim_create_buf(false, true)
    eq(terminal.entry_for_buf(scratch), nil, "unknown buffer maps to nil")
  end)

  test("spawning alone does not chdir; focusing the terminal does (cd scope)", function()
    -- given the terminal spawned and cwd still at root;
    vim.cmd("cd " .. vim.fn.fnameescape(root))
    eq(vim.fn.getcwd(), root, "cwd unchanged by the spawn itself")
    -- when the terminal buffer gains focus; then cwd moves into the workspace
    focus(alpha.bufnr)
    eq(vim.fn.getcwd(), alpha_dir, "focusing alpha's terminal chdirs into ws/alpha")
  end)

  test("focusing a non-terminal buffer leaves the cwd alone", function()
    -- given cwd is alpha's ws; when a scratch buffer gains focus; then no chdir
    local scratch = vim.api.nvim_create_buf(false, true)
    focus(scratch)
    eq(vim.fn.getcwd(), alpha_dir, "scratch focus does not chdir")
  end)

  test("no DirChanged fires when the cwd already matches the workspace", function()
    -- given cwd already alpha's ws; when focus leaves and returns;
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
  end)

  local dbg = nil

  test("focus-follow also applies to debug terminals", function()
    -- given a debug terminal for beta and cwd at root;
    vim.cmd("cd " .. vim.fn.fnameescape(root))
    dbg = terminal.open_or_reuse("beta", root, "debug")
    opened[#opened + 1] = dbg
    -- when its buffer gains focus; then cwd moves into beta's ws
    focus(dbg.bufnr)
    eq(vim.fn.getcwd(), beta_dir, "focusing beta's debug terminal chdirs into ws/beta")
  end)

  test("dead-but-kept terminal still chdirs on focus", function()
    -- given alpha's job exited while keep_on_exit=true kept the buffer;
    os.execute("kill " .. vim.fn.jobpid(alpha.job_id))
    ok(vim.wait(3000, function()
      return not job_alive(alpha.job_id)
    end, 50), "alpha's job exited")
    ok(vim.api.nvim_buf_is_valid(alpha.bufnr), "buffer still valid (kept)")
    vim.cmd("cd " .. vim.fn.fnameescape(root))
    -- when the dead buffer gains focus; then cwd still moves into the ws
    focus(alpha.bufnr)
    eq(vim.fn.getcwd(), alpha_dir, "focusing a kept dead terminal chdirs into ws/alpha")
  end)

  test("tcd scope changes only the focused tab", function()
    -- given tcd scope and a second tab inheriting the global cwd;
    config.setup({ dir_change_scope = "tcd" })
    local scope_seen = nil
    vim.api.nvim_create_autocmd("DirChanged", {
      callback = function()
        scope_seen = vim.v.event.scope
      end,
    })
    vim.cmd("cd " .. vim.fn.fnameescape(root))
    local tab1 = vim.api.nvim_get_current_tabpage()
    focus(detour_buf) -- park tab1 on a non-terminal buffer: switching back must not re-trigger follow
    vim.cmd("tabnew")
    -- when the terminal buffer gains focus in that tab;
    focus(alpha.bufnr)
    -- then that tab's cwd is the ws, DirChanged fired tab-scoped, and the
    -- first tab keeps the global cwd
    eq(vim.fn.getcwd(), alpha_dir, "focused tab's cwd is ws/alpha")
    eq(scope_seen, "tabpage", "DirChanged fired with tab scope")
    vim.api.nvim_set_current_tabpage(tab1)
    eq(vim.fn.getcwd(), root, "other tab's cwd unchanged")
  end)

  teardown_fixture()
end

-- Summary + exit code signal.
print(("=== test_follow_spec: %d/%d checks passed, %d failures"):format(checks - failures, checks, failures))
if failures > 0 then
  vim.cmd("cq")
end
