-- Spec for pi-jail.terminal (+ project.current_ws): per-ws agent terminal,
-- one per tab, reuse across calls, exit handling, right-side split width.
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
  checks = checks + 1
  if not cond then
    failures = failures + 1
    print("FAIL: " .. msg)
  end
end

local function ne(actual, expected, msg)
  checks = checks + 1
  if actual == expected then
    failures = failures + 1
    print(("FAIL: %s: expected something other than %q"):format(msg, tostring(expected)))
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

-- Fixture: fake pj executable + start-marker file + a repo root dir.
-- `pj open <id>` echoes "fake-agent <id>" and appends "$PWD $1 $2" to the
-- marker (one line per spawned job, so the marker doubles as a spawn counter
-- and argv/cwd record), then sleeps until killed.
local fixture = nil
local opened = {} -- every entry ever returned by open_or_reuse, for teardown

local function setup_fixture()
  local dir = "/tmp/pj-term-" .. tostring(vim.loop and vim.loop.os_getpid() or 0)
  os.execute("rm -rf " .. dir)
  os.execute("mkdir -p " .. dir .. "/root/ws " .. dir .. "/root/shared")
  for _, name in ipairs({ "alpha", "gamma", "delta", "epsilon", "zeta", "omega" }) do
    os.execute("mkdir -p " .. dir .. "/root/ws/" .. name)
  end
  local script = dir .. "/pj"
  local h = io.open(script, "w")
  h:write(([[
#!/bin/sh
echo "fake-agent $2"
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

local function tab_wins_showing(tab, bufnr)
  local wins = {}
  if not vim.api.nvim_tabpage_is_valid(tab) then
    return wins
  end
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if vim.api.nvim_win_get_buf(w) == bufnr then
      wins[#wins + 1] = w
    end
  end
  return wins
end

-- Read a tabpage's local cwd; getcwd(-1, nr) takes a tabpage ORDINAL, not a
-- handle, so read via a window of the tab to keep arbitrary handles valid.
local function tab_cwd(tab)
  local win = vim.api.nvim_tabpage_list_wins(tab)[1]
  return vim.api.nvim_win_call(win, function()
    return vim.fn.getcwd(0)
  end)
end

-- Close the given tabpage safely: focus it, then close every window until the
-- tab itself is gone (closing the last window auto-closes the tab).
local function close_tab(tab)
  if not vim.api.nvim_tabpage_is_valid(tab) then
    return
  end
  vim.api.nvim_set_current_tabpage(tab)
  while vim.api.nvim_tabpage_is_valid(tab) and #vim.api.nvim_tabpage_list_wins(tab) > 0 do
    pcall(vim.api.nvim_win_close, vim.api.nvim_tabpage_list_wins(tab)[1], true)
  end
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
  config.setup({ pj = fixture.script })
  local root = fixture.root

  local global_cwd = vim.fn.getcwd(-1, -1)
  local before_tabs = vim.api.nvim_get_current_tabpage() -- the initial tab 1
  local ntabs = #vim.api.nvim_list_tabpages()

  local alpha = terminal.open_or_reuse("ws/alpha", root)
  table.insert(opened, alpha)

  test("open_or_reuse creates a new tab with pi_jail_name, tcd and right-side terminal split", function()
    -- given a fresh workspace; when opened; then a NEW tab exists carrying the
    -- terminal buffer in a right-side vertical split, t:pi_jail_name set, and
    -- the tab-local cwd pointing into the workspace dir
    ok(type(alpha) == "table", "open_or_reuse returns an entry table")
    ok(vim.api.nvim_buf_is_valid(alpha.bufnr), "entry.bufnr is a valid buffer")
    eq(vim.api.nvim_get_option_value("buftype", { buf = alpha.bufnr }), "terminal", "buftype=terminal")
    ok(alpha.job_id > 0, "entry.job_id is a real job handle")
    ok(job_alive(alpha.job_id), "job alive right after open")
    eq(alpha.ws, "ws/alpha", "entry carries the full ws id")
    ok(alpha.tab ~= nil, "entry records its tabpage")
    ok(vim.api.nvim_tabpage_is_valid(alpha.tab), "entry.tab is a valid tabpage")
    eq(#vim.api.nvim_list_tabpages(), ntabs + 1, "a new tab was created for the ws terminal")
    eq(vim.api.nvim_get_current_tabpage(), alpha.tab, "the new tab is current after open")
    eq(vim.api.nvim_tabpage_get_var(alpha.tab, "pi_jail_name"), "ws/alpha", "t:pi_jail_name set to the ws id")
    eq(vim.api.nvim_tabpage_get_var(alpha.tab, "tabname"), "ws/alpha", "t:tabname set for lualine's tabs component")
    eq(vim.api.nvim_tabpage_get_var(alpha.tab, "name"), "ws/alpha", "t:name set for bufferline's rename convention")
    eq(tab_cwd(alpha.tab), root .. "/ws/alpha", "tab-local cwd is the ws dir")
    eq(vim.fn.getcwd(-1, -1), global_cwd, "global cwd untouched")
    local wins = tab_wins_showing(alpha.tab, alpha.bufnr)
    eq(#wins, 1, "terminal displayed in exactly one window of its tab")
    eq(vim.api.nvim_win_get_width(wins[1]), 40, "width = floor(100 * 0.4 default size)")
    eq(
      vim.fn.win_screenpos(wins[1])[2] > vim.o.columns / 2,
      true,
      "terminal split sits on the right side of the tab"
    )
  end)

  test("open_or_reuse runs <pj> open <id> with cwd=root", function()
    ok(wait_for_marker(1), "fake pj wrote its start marker")
    eq(marker_lines()[1], root .. " open ws/alpha", "marker records cwd, subcommand and ws id in order")
    ok(wait_buf_contains(alpha.bufnr, "fake-agent ws/alpha"), "terminal shows the agent banner")
  end)

  test("second open_or_reuse for same ws reuses the same tab, buffer and job", function()
    -- given alpha's terminal is open with a live job; when opened again;
    -- then the same tab/buffer/job is reused, no new tab, no new marker line
    local again = terminal.open_or_reuse("ws/alpha", root)
    table.insert(opened, again)
    eq(again.bufnr, alpha.bufnr, "same buffer reused")
    eq(again.job_id, alpha.job_id, "same job reused")
    eq(again.tab, alpha.tab, "same tabpage recorded")
    eq(#vim.api.nvim_list_tabpages(), ntabs + 1, "no new tabpage created")
    eq(vim.api.nvim_get_current_tabpage(), alpha.tab, "switched to alpha's tab")
    eq(vim.api.nvim_win_get_buf(0), alpha.bufnr, "terminal window focused")
    vim.wait(300) -- give a hypothetical second spawn time to write its marker
    eq(#marker_lines(), 1, "marker still has exactly one start line")
    ok(job_alive(alpha.job_id), "original job still alive")
  end)

  test("reuse from another tab switches back to the entry's tab and focuses the terminal", function()
    -- given the caller sits on the initial tab (e.g. after opening a file);
    -- when opened again; then the entry's tab becomes current and the terminal
    -- window focused, still no new job
    vim.api.nvim_set_current_tabpage(before_tabs)
    local again = terminal.open_or_reuse("ws/alpha", root)
    table.insert(opened, again)
    eq(vim.api.nvim_get_current_tabpage(), alpha.tab, "switched back to alpha's tab")
    eq(vim.api.nvim_win_get_buf(0), alpha.bufnr, "terminal window focused")
    eq(#marker_lines(), 1, "still exactly one job for alpha")
  end)

  test("reuse reopens the right-side split after the terminal window was closed", function()
    -- given alpha's terminal window closed while the job keeps running;
    -- when opened again; then the same buffer in a reopened right-side split
    -- in the SAME tab, still one job
    local wins = tab_wins_showing(alpha.tab, alpha.bufnr)
    vim.api.nvim_win_close(wins[1], true)
    eq(#vim.fn.win_findbuf(alpha.bufnr), 0, "window closed, buffer hidden")
    local again = terminal.open_or_reuse("ws/alpha", root)
    table.insert(opened, again)
    eq(again.bufnr, alpha.bufnr, "same buffer reused after window close")
    eq(vim.api.nvim_get_current_tabpage(), alpha.tab, "still alpha's tab")
    local wins2 = tab_wins_showing(alpha.tab, alpha.bufnr)
    eq(#wins2, 1, "split reopened for the terminal in its tab")
    eq(vim.api.nvim_win_get_width(wins2[1]), 40, "reopened split keeps floor(columns*size) width")
    eq(vim.api.nvim_win_get_buf(0), alpha.bufnr, "reopened split focused")
    eq(#marker_lines(), 1, "still exactly one job for alpha")
  end)

  local gamma = nil

  test("two different workspaces get two separate tabs with their own names and cwds", function()
    -- given alpha's tab exists; when another workspace opens; then it gets its
    -- own new tab, its own t:pi_jail_name and tab-local cwd, and the global
    -- cwd is untouched
    local global_cwd = vim.fn.getcwd(-1, -1)
    gamma = terminal.open_or_reuse("ws/gamma", root)
    table.insert(opened, gamma)
    ok(wait_for_marker(2), "gamma job started")
    ok(vim.api.nvim_tabpage_is_valid(gamma.tab), "gamma tab valid")
    ne(gamma.tab, alpha.tab, "gamma tab differs from alpha tab")
    eq(#vim.api.nvim_list_tabpages(), ntabs + 2, "a second new tab was created")
    eq(vim.api.nvim_get_current_tabpage(), gamma.tab, "switched to gamma's tab")
    eq(vim.api.nvim_tabpage_get_var(gamma.tab, "pi_jail_name"), "ws/gamma", "gamma tab carries its own name")
    eq(vim.api.nvim_tabpage_get_var(gamma.tab, "tabname"), "ws/gamma", "gamma t:tabname carries its own name")
    eq(vim.api.nvim_tabpage_get_var(gamma.tab, "name"), "ws/gamma", "gamma t:name carries its own name")
    eq(tab_cwd(gamma.tab), root .. "/ws/gamma", "gamma tab-local cwd is its ws dir")
    eq(tab_cwd(alpha.tab), root .. "/ws/alpha", "alpha tab cwd unchanged")
    eq(vim.fn.getcwd(-1, -1), global_cwd, "global cwd unchanged by tab opens")
    -- switching between them via open_or_reuse changes the current tabpage
    local again = terminal.open_or_reuse("ws/alpha", root)
    table.insert(opened, again)
    eq(vim.api.nvim_get_current_tabpage(), alpha.tab, "open_or_reuse switches back to alpha's tab")
    local again2 = terminal.open_or_reuse("ws/gamma", root)
    table.insert(opened, again2)
    eq(vim.api.nvim_get_current_tabpage(), gamma.tab, "open_or_reuse switches to gamma's tab")
    eq(#marker_lines(), 2, "still exactly two jobs (alpha + gamma)")
  end)

  test("closing the ws tab with job alive re-opens a NEW tab reusing the same buffer and job", function()
    -- given gamma's tab closed by the user while the job lives; when opened
    -- again; then a fresh tab (pi_jail_name + tcd) displays the SAME buffer
    -- with the SAME job - no respawn
    local n0 = #marker_lines()
    local old_tab = gamma.tab
    close_tab(gamma.tab)
    ok(not vim.api.nvim_tabpage_is_valid(old_tab), "gamma tab closed")
    ok(vim.api.nvim_buf_is_valid(gamma.bufnr), "buffer survived the tab close")
    ok(job_alive(gamma.job_id), "job survived the tab close")
    local again = terminal.open_or_reuse("ws/gamma", root)
    table.insert(opened, again)
    ok(vim.api.nvim_tabpage_is_valid(again.tab), "reopened tab valid")
    ne(again.tab, old_tab, "a NEW tabpage was opened")
    eq(vim.api.nvim_tabpage_get_var(again.tab, "pi_jail_name"), "ws/gamma", "new tab carries pi_jail_name")
    eq(tab_cwd(again.tab), root .. "/ws/gamma", "new tab-local cwd is the ws dir")
    eq(again.bufnr, gamma.bufnr, "SAME buffer reused, not respawned")
    eq(again.job_id, gamma.job_id, "SAME job reused")
    eq(#marker_lines(), n0, "marker count unchanged - no new spawn")
    gamma = again
  end)

  local delta_entry = nil

  test("keep_on_exit=false wipes buffer and windows on job exit", function()
    -- given keep_on_exit=false and a running terminal; when the job is killed;
    -- then the windows are closed and the buffer wiped
    config.setup({ terminal = { keep_on_exit = false } })
    local n0 = #marker_lines()
    delta_entry = terminal.open_or_reuse("ws/delta", root)
    table.insert(opened, delta_entry)
    ok(wait_for_marker(n0 + 1), "delta job started")
    kill_job(delta_entry)
    local gone = vim.wait(3000, function()
      return not vim.api.nvim_buf_is_valid(delta_entry.bufnr)
    end, 50)
    ok(gone, "buffer wiped after job exit")
    local wins = vim.api.nvim_buf_is_valid(delta_entry.bufnr) and vim.fn.win_findbuf(delta_entry.bufnr) or {}
    eq(#wins, 0, "no window left showing the buffer")
    config.setup({ terminal = { keep_on_exit = true } })
  end)

  test("keep_on_exit=false starts a fresh terminal on next open after exit", function()
    config.setup({ terminal = { keep_on_exit = false } })
    local n0 = #marker_lines()
    local fresh = terminal.open_or_reuse("ws/delta", root)
    table.insert(opened, fresh)
    ok(wait_for_marker(n0 + 1), "a new job started for delta")
    ok(fresh.job_id ~= delta_entry.job_id, "new job, not the dead one")
    ok(vim.api.nvim_buf_is_valid(fresh.bufnr), "new buffer valid")
    ok(job_alive(fresh.job_id), "new job alive")
    eq(vim.api.nvim_get_option_value("buftype", { buf = fresh.bufnr }), "terminal", "new buffer is a terminal")
    config.setup({ terminal = { keep_on_exit = true } })
  end)

  local omega_entry = nil

  test("fresh terminal after cleanup reopens in the surviving tab, not a new one", function()
    -- given omega's first terminal was cleaned up (keep_on_exit=false) while
    -- its tab survives with its left window; when opened again; then the
    -- fresh terminal spawns in the SAME surviving tab - no duplicate ws tab
    config.setup({ terminal = { keep_on_exit = false } })
    local n0 = #marker_lines()
    omega_entry = terminal.open_or_reuse("ws/omega", root)
    table.insert(opened, omega_entry)
    ok(wait_for_marker(n0 + 1), "omega job started")
    local first_tab = omega_entry.tab
    kill_job(omega_entry)
    ok(
      vim.wait(3000, function()
        return not vim.api.nvim_buf_is_valid(omega_entry.bufnr)
      end, 50),
      "buffer wiped after job exit"
    )
    ok(vim.api.nvim_tabpage_is_valid(first_tab), "omega tab survived the cleanup")
    local tabs_before = #vim.api.nvim_list_tabpages()
    local again = terminal.open_or_reuse("ws/omega", root)
    table.insert(opened, again)
    eq(again.tab, first_tab, "SAME tabpage reused for the fresh terminal")
    eq(#vim.api.nvim_list_tabpages(), tabs_before, "no new tabpage created")
    ne(again.job_id, omega_entry.job_id, "a fresh job was spawned")
    ne(again.bufnr, omega_entry.bufnr, "a fresh buffer was created")
    eq(vim.api.nvim_tabpage_get_var(again.tab, "pi_jail_name"), "ws/omega", "tab still carries its name")
    local wins = tab_wins_showing(again.tab, again.bufnr)
    eq(#wins, 1, "fresh terminal displayed in the surviving tab")
    eq(vim.api.nvim_win_get_buf(0), again.bufnr, "fresh terminal window focused")
    config.setup({ terminal = { keep_on_exit = true } })
  end)

  local eps_entry = nil

  test("keep_on_exit=true (default) keeps the buffer valid and displayed after job exit", function()
    local n0 = #marker_lines()
    eps_entry = terminal.open_or_reuse("ws/epsilon", root)
    table.insert(opened, eps_entry)
    ok(wait_for_marker(n0 + 1), "epsilon job started")
    kill_job(eps_entry)
    local dead = vim.wait(3000, function()
      return not job_alive(eps_entry.job_id)
    end, 50)
    ok(dead, "job exited")
    ok(vim.api.nvim_buf_is_valid(eps_entry.bufnr), "buffer still valid")
    ok(#vim.fn.win_findbuf(eps_entry.bufnr) > 0, "a window still displays the buffer")
  end)

  test("dead terminal with keep_on_exit=true is reused, not respawned", function()
    -- given epsilon's job exited but keep_on_exit=true kept the buffer;
    -- when opened again; then the dead buffer is focused, no new job
    local n0 = #marker_lines()
    local again = terminal.open_or_reuse("ws/epsilon", root)
    table.insert(opened, again)
    eq(again.bufnr, eps_entry.bufnr, "same dead buffer reused")
    eq(#marker_lines(), n0, "no new job spawned")
    eq(vim.api.nvim_win_get_buf(0), eps_entry.bufnr, "dead terminal's window focused")
  end)

  test("reopened ws tab carries the tabline-plugin name vars again", function()
    -- given a ws tab closed while its job lives; when open_or_reuse reopens
    -- it; then the fresh tab carries t:tabname/t:name like a first open
    local old_tab = gamma.tab
    close_tab(gamma.tab)
    ok(not vim.api.nvim_tabpage_is_valid(old_tab), "gamma tab closed")
    local again = terminal.open_or_reuse("ws/gamma", root)
    table.insert(opened, again)
    eq(vim.api.nvim_tabpage_get_var(again.tab, "pi_jail_name"), "ws/gamma", "reopened tab carries pi_jail_name")
    eq(vim.api.nvim_tabpage_get_var(again.tab, "tabname"), "ws/gamma", "reopened tab carries t:tabname")
    eq(vim.api.nvim_tabpage_get_var(again.tab, "name"), "ws/gamma", "reopened tab carries t:name")
    gamma = again
  end)

  test("project.current_ws resolves the bare ws name from a buffer path", function()
    -- list_workspaces/current_ws keep returning bare names by design (jj-shaped);
    -- the ws/ prefix is composed by their callers.
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

  -- Tabby integration: names are pushed into tabby's tab_name module when it
  -- is installed (fake here), and a missing tabby is a silent no-op. Order
  -- matters: the no-preload path runs first, then the fake is seeded for the
  -- next open (package.loaded cache makes a later unload of the fake moot).
  -- Gamma's tab was already opened above with no tabby present: no calls.

  local fake_calls = {}
  package.preload["tabby.feature.tab_name"] = function()
    return { set = function(tab, name)
      fake_calls[#fake_calls + 1] = { tab = tab, name = name }
    end }
  end

  test("missing tabby is a no-op: opens before this point prove it", function()
    -- gamma and the earlier ws all opened with no tabby installed; reaching
    -- here without error IS the no-tabby contract
    ok(job_alive(gamma.job_id), "gamma's no-tabby open survives")
  end)

  local tabby_ws = terminal.open_or_reuse("ws/zeta", root)
  table.insert(opened, tabby_ws)

  test("opening a ws with tabby present pushes (tab, ws) into tabby's tab_name module", function()
    eq(#fake_calls, 1, "exactly one tabby set call")
    eq(fake_calls[1].name, "ws/zeta", "tabby got the ws id")
    ok(fake_calls[1].tab == tabby_ws.tab, "tabby got the new tabpage handle")
  end)

  test("reusing an already-open ws does not re-push the tabby name", function()
    local again = terminal.open_or_reuse("ws/zeta", root)
    table.insert(opened, again)
    eq(#fake_calls, 1, "still exactly one tabby set call")
    eq(again.tab, tabby_ws.tab, "same tab reused")
  end)

  test("reopened ws tab re-pushes the tabby name for the fresh tabpage", function()
    close_tab(tabby_ws.tab)
    local again = terminal.open_or_reuse("ws/zeta", root)
    table.insert(opened, again)
    eq(#fake_calls, 2, "a second set call for the reopened tab")
    eq(fake_calls[2].name, "ws/zeta", "tabby got the ws id again")
    ok(fake_calls[2].tab == again.tab, "tabby got the NEW tabpage handle")
  end)

  teardown_fixture()
end

-- Summary + exit code signal.
print(("=== test_terminal_spec: %d/%d checks passed, %d failures"):format(checks - failures, checks, failures))
if failures > 0 then
  vim.cmd("cq")
end
