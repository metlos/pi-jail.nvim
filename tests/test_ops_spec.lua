-- Spec for pi-jail.config + pi-jail.ops: setup/merge and run_pctl against a fake pctl.
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

-- Fixture: fake pctl executable + recording marker dir + a root dir to run in.
-- The script records "$PWD $*" to <dir>/record, and fails with a stderr message
-- when <dir>/fail marker exists.
local fixture = nil

local function setup_fixture()
  local dir = "/tmp/pj-ops-" .. tostring(vim.loop and vim.loop.os_getpid() or 0)
  os.execute("rm -rf " .. dir)
  os.execute("mkdir -p " .. dir .. "/root/ws " .. dir .. "/root/shared")
  local script = dir .. "/pctl"
  local h = io.open(script, "w")
  h:write(([[
#!/bin/sh
if [ -e "%s/fail" ]; then
  echo "pctl: simulated failure" >&2
  exit 1
fi
echo "$PWD $*" > "%s/record"
exit 0
]]):format(dir, dir))
  h:close()
  os.execute("chmod +x " .. script)
  fixture = { dir = dir, script = script, root = dir .. "/root" }
  return fixture
end

local function teardown_fixture()
  if fixture then
    os.execute("rm -rf " .. fixture.dir)
  end
end

local function read_record()
  local h = io.open(fixture.dir .. "/record", "r")
  if h == nil then
    return nil
  end
  local out = h:read("*a"):gsub("\n$", "")
  h:close()
  os.remove(fixture.dir .. "/record")
  return out
end

print("=== test_ops_spec: config setup/merge + ops.run_pctl ===")

local config, config_err = load_module("pi-jail.config")
local ops, ops_err = load_module("pi-jail.ops")

if config == nil or ops == nil then
  -- Red phase: modules do not exist yet. Everything below must fail loudly.
  test("require pi-jail.config and pi-jail.ops load", function()
    if config == nil then
      check(false, "require('pi-jail.config') failed: " .. tostring(config_err))
    end
    if ops == nil then
      check(false, "require('pi-jail.ops') failed: " .. tostring(ops_err))
    end
  end)
else
  test("config.setup exists and config.get returns a table", function()
    ok(type(config.setup) == "function", "config.setup is a function")
    ok(type(config.get) == "function", "config.get is a function")
    ok(type(config.get()) == "table", "config.get() returns a table")
  end)

  test("config defaults: pctl, pi, terminal", function()
    local cfg = config.get()
    eq(cfg.pctl, "pctl", "default pctl executable")
    eq(cfg.pi, "pi", "default pi executable")
    eq(cfg.terminal.keep_on_exit, true, "default terminal.keep_on_exit")
    eq(cfg.terminal.size, 0.4, "default terminal.size")
  end)

  setup_fixture()

  test("config.setup overrides pctl executable", function()
    config.setup({ pctl = fixture.script })
    eq(config.get().pctl, fixture.script, "setup overrides pctl")
  end)

  test("config.setup merges: later setup keeps unspecified keys and merges nested tables", function()
    config.setup({ terminal = { size = 0.2 } })
    eq(config.get().pctl, fixture.script, "later setup keeps pctl from earlier setup")
    eq(config.get().terminal.size, 0.2, "later setup overrides nested terminal.size")
    eq(config.get().terminal.keep_on_exit, true, "later setup keeps sibling terminal.keep_on_exit")
  end)

  test("config.setup merges over defaults too", function()
    -- Reset observability: a fresh require via dofile to check default merge,
    -- without disturbing the shared module table used by ops below.
    local fresh = dofile("lua/pi-jail/config.lua")
    fresh.setup({ terminal = { size = 0.25 } })
    eq(fresh.get().terminal.size, 0.25, "fresh setup overrides terminal.size")
    eq(fresh.get().terminal.keep_on_exit, true, "fresh setup keeps terminal.keep_on_exit default")
    eq(fresh.get().pctl, "pctl", "fresh setup keeps default pctl")
    eq(fresh.get().dir_change_scope, "cd", "fresh setup keeps default dir_change_scope")
  end)

  test("run_pctl returns ok result with empty stderr on success", function()
    config.setup({ pctl = fixture.script })
    local res = ops.run_pctl({ "fill", "alpha" }, fixture.root)
    eq(res.ok, true, "ok=true on exit 0")
    eq(res.code, 0, "code=0 on success")
    eq(res.stderr, "", "stderr empty on success")
    eq(res.stdout, "", "stdout empty when command prints nothing")
  end)

  test("run_pctl passes args in order and cwd=root", function()
    ops.run_pctl({ "new", "gamma", "--extra" }, fixture.root)
    local rec = read_record()
    check(rec ~= nil, "fake pctl recorded its invocation")
    if rec ~= nil then
      eq(rec, fixture.root .. " new gamma --extra", "recorded '$PWD $*' shows root and args in order")
    end
  end)

  test("run_pctl failure returns ok=false with stderr verbatim", function()
    os.execute("touch " .. fixture.dir .. "/fail")
    local res = ops.run_pctl({ "drop", "--force", "alpha" }, fixture.root)
    os.execute("rm -f " .. fixture.dir .. "/fail")
    eq(res.ok, false, "ok=false on nonzero exit")
    eq(res.code, 1, "code passed through")
    check(
      res.stderr:find("pctl: simulated failure", 1, true) ~= nil,
      "stderr contains failure message (verbatim, incl. trailing newline)"
    )
    eq(res.stderr, "pctl: simulated failure\n", "stderr verbatim incl. trailing newline")
    check(read_record() == nil, "failing fake pctl does not record")
  end)

  teardown_fixture()
end

-- Summary + exit code signal.
print(("=== test_ops_spec: %d/%d checks passed, %d failures"):format(checks - failures, checks, failures))
if failures > 0 then
  vim.cmd("cq")
end
