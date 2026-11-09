-- Spec for pi-jail.tabline: tabline rendering for jail tabs (t:pi_jail_name
-- labels, buffer-name fallback, current-tab marker) and idempotent setup()
-- of the vim.o.tabline expression.
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

-- Keep exactly the first tabpage (with its pi_jail_name cleared) as current,
-- closing the rest; never closes the last remaining tab.
local function reset_tabs()
  local tabs = vim.api.nvim_list_tabpages()
  vim.api.nvim_set_current_tabpage(tabs[1])
  while #vim.api.nvim_list_tabpages() > 1 do
    vim.cmd("$tabclose")
  end
  pcall(vim.api.nvim_tabpage_del_var, tabs[1], "pi_jail_name")
  return vim.api.nvim_list_tabpages()
end

print("=== test_tabline_spec: pi-jail.tabline render + setup ===")

local tabline, tabline_err = load_module("pi-jail.tabline")

if tabline == nil then
  -- Red phase: module does not exist yet. Everything below must fail loudly.
  test("require pi-jail.tabline loads", function()
    check(false, "require('pi-jail.tabline') failed: " .. tostring(tabline_err))
  end)
else
  test("render labels a pi_jail_name tab and an unnamed-buffer tab in tab order", function()
    -- given tab 1 on a plain unnamed buffer and tab 2 carrying pi_jail_name;
    -- when rendered; then both labels appear with their tab numbers, tab 1 first
    reset_tabs()
    vim.cmd("tabnew")
    local tabs = vim.api.nvim_list_tabpages()
    eq(#tabs, 2, "two tabs open")
    vim.api.nvim_tabpage_set_var(tabs[2], "pi_jail_name", "ws/alpha")
    local out = tabline.render()
    local plain = out:find("[No Name]", 1, true)
    local named = out:find("ws/alpha", 1, true)
    ok(plain ~= nil, "fallback label for the unnamed tab present")
    ok(named ~= nil, "pi_jail_name label present")
    ok(plain ~= nil and named ~= nil and plain < named, "tab 1 label before tab 2 label")
    ok(out:find("1", 1, true) ~= nil, "tab number 1 present")
    ok(out:find("2", 1, true) ~= nil, "tab number 2 present")
  end)

  test("render marks the current tabpage distinctly", function()
    reset_tabs()
    vim.cmd("tabnew")
    local tabs = vim.api.nvim_list_tabpages()
    vim.api.nvim_set_current_tabpage(tabs[1])
    local out1 = tabline.render()
    ok(out1:find("> 1", 1, true) ~= nil, "current tab 1 carries the marker")
    ok(out1:find("> 2", 1, true) == nil, "non-current tab 2 has no marker")
    vim.api.nvim_set_current_tabpage(tabs[2])
    local out2 = tabline.render()
    ok(out2:find("> 2", 1, true) ~= nil, "current tab 2 carries the marker")
    ok(out2:find("> 1", 1, true) == nil, "non-current tab 1 has no marker")
    ok(out1 ~= out2, "rendering differs when the current tab changes")
  end)

  test("missing pi_jail_name falls back to the first window's buffer name", function()
    -- given a tab without pi_jail_name whose buffer is named; when rendered;
    -- then the buffer name is used and no error escapes
    reset_tabs()
    vim.cmd("tabnew")
    local tab = vim.api.nvim_get_current_tabpage()
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_name(buf, "/tmp/pj-tabline-spec-named.lua")
    local okv = pcall(vim.api.nvim_tabpage_get_var, tab, "pi_jail_name")
    ok(not okv, "fixture really has no pi_jail_name var")
    local out = tabline.render()
    ok(out:find("pj-tabline-spec-named.lua", 1, true) ~= nil, "buffer name used as the label")
  end)

  test("setup sets the tabline option once and never overwrites a non-empty one", function()
    vim.o.tabline = ""
    tabline.setup()
    eq(vim.o.tabline, "%{v:lua.require('pi-jail.tabline').render()}", "empty tabline set to the v:lua expression")
    tabline.setup()
    eq(vim.o.tabline, "%{v:lua.require('pi-jail.tabline').render()}", "second setup leaves the option unchanged")
    vim.o.tabline = "custom"
    tabline.setup()
    eq(vim.o.tabline, "custom", "pre-set non-empty tabline left untouched")
    vim.o.tabline = ""
  end)

  test("render after the named tab was closed drops its label without error", function()
    -- given a tab labeled via pi_jail_name; when that tab is closed;
    -- then rendering succeeds and its label is gone
    reset_tabs()
    vim.cmd("tabnew")
    local tabs = vim.api.nvim_list_tabpages()
    vim.api.nvim_tabpage_set_var(tabs[2], "pi_jail_name", "ws/gone")
    ok(tabline.render():find("ws/gone", 1, true) ~= nil, "label present before the close")
    vim.api.nvim_set_current_tabpage(tabs[1])
    if #vim.api.nvim_list_tabpages() > 1 then
      vim.cmd("$tabclose")
    end
    local out = tabline.render()
    ok(out:find("ws/gone", 1, true) == nil, "label dropped after the close")
    ok(#vim.api.nvim_list_tabpages() >= 1, "at least one tab remains")
  end)
end

-- Summary + exit code signal.
print(("=== test_tabline_spec: %d/%d checks passed, %d failures"):format(checks - failures, checks, failures))
if failures > 0 then
  vim.cmd("cq")
end
