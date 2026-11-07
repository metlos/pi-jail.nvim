-- Spec for pi-jail.terminal (+ project.current_ws): per-ws agent terminal,
-- reuse across calls, exit handling, split width.
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

-- Fixture: fake pi executable + start-marker file + a repo root dir.
-- `pi ws <name>` echoes "fake-agent <name>", `pi debug <name>` echoes
-- "fake-debug <name>"; both append "$PWD $1 $2" to the marker (one line per
-- spawned job, so the marker doubles as a spawn counter and argv/cwd record)
-- and sleep until killed.
local fixture = nil
local opened = {} -- every entry ever returned by open_or_reuse, for teardown

local function setup_fixture()
  local dir = "/tmp/pj-term-" .. tostring(vim.loop and vim.loop.os_getpid() or 0)
  os.execute("rm -rf " .. dir)
  os.execute("mkdir -p " .. dir .. "/root/ws " .. dir .. "/root/shared")
  local script = dir .. "/pi"
  local h = io.open(script, "w")
  h:write(([[
#!/bin/sh
case "$1" in
  ws) echo "fake-agent $2" ;;
  debug) echo "fake-debug $2" ;;
esac
echo "$PWD $1 $2" >> "%s/marker"
while :; do sleep 0.2; done
]]):format(dir))
  h:close()
  os.execute("chmod +x " .. script)
  vim.o.columns = 100
  fixture = { dir = dir, script = script, root = dir .. "/root", marker = dir .. "/marker" }
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

local function marker_lines()
  local h = io.open(fixture.marker, "r")
  if h == nil then
    return {}
  end
  local lines = {}
  for line in h:lines() do
    lines[#lines + 1] = line
  end
  h:close()
  return lines
end

local function wait_for_marker(n)
  return vim.wait(3000, function()
    return #marker_lines() >= n
  end, 50)
end

local function wait_buf_contains(bufnr, text)
  return vim.wait(3000, function()
    for _, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
      if l:find(text, 1, true) ~= nil then
        return true
      end
    end
    return false
  end, 50)
end

local function job_alive(job_id)
  return vim.fn.jobwait({ job_id }, 0)[1] == -1
end

local function kill_job(entry)
  os.execute("kill " .. vim.fn.jobpid(entry.job_id))
end

print("=== test_terminal_spec: open_or_reuse + current_ws ===")

local terminal, terminal_err = load_module("pi-jail.terminal")
local project, project_err = load_module("pi-jail.project")
local config, config_err = load_module("pi-jail.config")

if terminal == nil or project == nil or config == nil then
  -- Red phase: module does not exist yet. Everything below must fail loudly.
  test("require pi-jail.terminal, pi-jail.project, pi-jail.config load", function()
    if terminal == nil then
      check(false, "require('pi-jail.terminal') failed: " .. tostring(terminal_err))
    end
    if project == nil then
      check(false, "require('pi-jail.project') failed: " .. tostring(project_err))
    end
    if config == nil then
      check(false, "require('pi-jail.config') failed: " .. tostring(config_err))
    end
  end)
else
  setup_fixture()
  config.setup({ pi = fixture.script })
  local root = fixture.root

  local alpha = terminal.open_or_reuse("alpha", root)
  opened[#opened + 1] = alpha

  test("open_or_reuse creates a terminal buffer with a live job", function()
    -- given a fresh workspace; when opened; then a terminal buffer with a running job exists
    ok(type(alpha) == "table", "open_or_reuse returns an entry table")
    ok(vim.api.nvim_buf_is_valid(alpha.bufnr), "entry.bufnr is a valid buffer")
    eq(vim.api.nvim_get_option_value("buftype", { buf = alpha.bufnr }), "terminal", "buftype=terminal")
    ok(alpha.job_id > 0, "entry.job_id is a real job handle")
    ok(job_alive(alpha.job_id), "job alive right after open")
  end)

  test("open_or_reuse runs <pi> ws <name> with cwd=root (default mode)", function()
    ok(wait_for_marker(1), "fake pi wrote its start marker")
    eq(marker_lines()[1], root .. " ws alpha", "marker records cwd, mode and ws name in order")
    ok(wait_buf_contains(alpha.bufnr, "fake-agent alpha"), "terminal shows the agent banner")
  end)

  test("second open_or_reuse for same ws reuses the same buffer and focuses its split", function()
    -- given alpha's terminal is open with a live job; when opened again;
    -- then the same buffer/job is reused and its split focused
    local again = terminal.open_or_reuse("alpha", root)
    opened[#opened + 1] = again
    eq(again.bufnr, alpha.bufnr, "same buffer reused")
    eq(again.job_id, alpha.job_id, "same job reused")
    eq(vim.api.nvim_win_get_buf(0), alpha.bufnr, "existing split focused")
  end)

  test("reuse does not spawn a second job", function()
    vim.wait(300) -- give a hypothetical second spawn time to write its marker
    eq(#marker_lines(), 1, "marker still has exactly one start line")
    ok(job_alive(alpha.job_id), "original job still alive")
  end)

  test("reuse focuses the existing split when another window is current", function()
    -- given the terminal split exists but a different window is current
    local term_win = vim.fn.win_findbuf(alpha.bufnr)[1]
    local other_win = nil
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if w ~= term_win then
        other_win = w
      end
    end
    ok(other_win ~= nil, "a window outside the terminal split exists")
    vim.api.nvim_set_current_win(other_win)
    -- when opened again; then the terminal's split is focused, no new job
    local again = terminal.open_or_reuse("alpha", root)
    opened[#opened + 1] = again
    eq(again.bufnr, alpha.bufnr, "same buffer reused")
    eq(vim.api.nvim_win_get_buf(0), alpha.bufnr, "terminal split focused from another window")
    eq(#marker_lines(), 1, "still exactly one job for alpha")
  end)

  test("reuse reopens a split after the window was closed", function()
    -- given alpha's split closed while the job keeps running
    local wins = vim.fn.win_findbuf(alpha.bufnr)
    vim.api.nvim_win_close(wins[1], true)
    eq(#vim.fn.win_findbuf(alpha.bufnr), 0, "window closed, buffer hidden")
    -- when opened again; then same buffer in a reopened split, still one job
    local again = terminal.open_or_reuse("alpha", root)
    opened[#opened + 1] = again
    eq(again.bufnr, alpha.bufnr, "same buffer reused after window close")
    ok(#vim.fn.win_findbuf(alpha.bufnr) > 0, "split reopened for the terminal")
    eq(vim.api.nvim_win_get_buf(0), alpha.bufnr, "reopened split focused")
    eq(#marker_lines(), 1, "still exactly one job for alpha")
  end)

  test("mode 'debug' spawns <pi> debug <name>", function()
    local dbg = terminal.open_or_reuse("beta", root, "debug")
    opened[#opened + 1] = dbg
    local n0 = #marker_lines()
    ok(wait_for_marker(n0 + 1), "debug job wrote its marker")
    eq(marker_lines()[#marker_lines()], root .. " debug beta", "marker records debug mode and ws name")
    ok(wait_buf_contains(dbg.bufnr, "fake-debug beta"), "terminal shows the debug banner")
  end)

  test("vertical split width is floor(columns * terminal.size)", function()
    eq(vim.o.columns, 100, "columns still 100 for the width computation")
    local e = terminal.open_or_reuse("gamma", root)
    opened[#opened + 1] = e
    local wins = vim.fn.win_findbuf(e.bufnr)
    eq(#wins, 1, "terminal displayed in exactly one split")
    eq(vim.api.nvim_win_get_width(wins[1]), 40, "width = floor(100 * 0.4 default size)")
  end)

  local delta_entry = nil

  test("keep_on_exit=false wipes buffer and split on job exit", function()
    -- given keep_on_exit=false and a running terminal; when the job is killed;
    -- then the split is closed and the buffer wiped
    config.setup({ terminal = { keep_on_exit = false } })
    local n0 = #marker_lines()
    delta_entry = terminal.open_or_reuse("delta", root)
    opened[#opened + 1] = delta_entry
    ok(wait_for_marker(n0 + 1), "delta job started")
    kill_job(delta_entry)
    local gone = vim.wait(3000, function()
      return not vim.api.nvim_buf_is_valid(delta_entry.bufnr)
    end, 50)
    ok(gone, "buffer wiped after job exit")
    local wins = vim.api.nvim_buf_is_valid(delta_entry.bufnr) and vim.fn.win_findbuf(delta_entry.bufnr) or {}
    eq(#wins, 0, "no split left showing the buffer")
  end)

  test("keep_on_exit=false starts a fresh terminal on next open after exit", function()
    config.setup({ terminal = { keep_on_exit = false } })
    local n0 = #marker_lines()
    local fresh = terminal.open_or_reuse("delta", root)
    opened[#opened + 1] = fresh
    ok(wait_for_marker(n0 + 1), "a new job started for delta")
    ok(fresh.job_id ~= delta_entry.job_id, "new job, not the dead one")
    ok(vim.api.nvim_buf_is_valid(fresh.bufnr), "new buffer valid")
    ok(job_alive(fresh.job_id), "new job alive")
    eq(vim.api.nvim_get_option_value("buftype", { buf = fresh.bufnr }), "terminal", "new buffer is a terminal")
    config.setup({ terminal = { keep_on_exit = true } })
  end)

  local eps_entry = nil

  test("keep_on_exit=true (default) keeps the buffer valid and displayed after job exit", function()
    local n0 = #marker_lines()
    eps_entry = terminal.open_or_reuse("epsilon", root)
    opened[#opened + 1] = eps_entry
    ok(wait_for_marker(n0 + 1), "epsilon job started")
    kill_job(eps_entry)
    local dead = vim.wait(3000, function()
      return not job_alive(eps_entry.job_id)
    end, 50)
    ok(dead, "job exited")
    ok(vim.api.nvim_buf_is_valid(eps_entry.bufnr), "buffer still valid")
    ok(#vim.fn.win_findbuf(eps_entry.bufnr) > 0, "split still displays the buffer")
  end)

  test("dead terminal with keep_on_exit=true is reused, not respawned", function()
    -- given epsilon's job exited but keep_on_exit=true kept the buffer;
    -- when opened again; then the dead buffer is focused, no new job
    local n0 = #marker_lines()
    local again = terminal.open_or_reuse("epsilon", root)
    opened[#opened + 1] = again
    eq(again.bufnr, eps_entry.bufnr, "same dead buffer reused")
    eq(#marker_lines(), n0, "no new job spawned")
    eq(vim.api.nvim_win_get_buf(0), eps_entry.bufnr, "dead terminal's split focused")
  end)

  test("project.current_ws resolves the ws name from a buffer path", function()
    local cases = {
      { root .. "/ws/alpha/main.lua", "alpha" },
      { root .. "/ws/alpha", "alpha" },
      { root .. "/ws/alpha/sub/deep.txt", "alpha" },
      { root .. "/ws/alpha/", "alpha" },
      { root .. "/ws", nil },
      { root .. "/ws/", nil },
      { root .. "/shared/project/x", nil },
      { root, nil },
      { root .. "/../elsewhere/x", nil },
      { "/tmp/pj-unrelated/x", nil },
    }
    for _, c in ipairs(cases) do
      eq(project.current_ws(root, c[1]), c[2], ("current_ws(%s)"):format(c[1]))
    end
  end)

  teardown_fixture()
end

-- Summary + exit code signal.
print(("=== test_terminal_spec: %d/%d checks passed, %d failures"):format(checks - failures, checks, failures))
if failures > 0 then
  vim.cmd("cq")
end
