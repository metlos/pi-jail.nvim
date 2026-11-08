-- Spec for pi-jail.project: root discovery and workspace listing.
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

-- Simple deep equality for table-driven workspace assertions.
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

-- Set up module resolution under -u NONE.
package.path = "lua/?.lua;" .. package.path

local function load_project()
  local okmod, mod = pcall(require, "pi-jail.project")
  if not okmod then
    return nil, mod
  end
  return mod
end

-- Fixture: adopted pi-jail repo (pj layout: narrowed jj root with ws/ and
-- shared/, workspaces with full sparse) with two workspaces.
local fixture = nil

local function setup_fixture()
  local root = "/tmp/pj-fixture-" .. tostring(vim.loop and vim.loop.os_getpid() or 0)
  os.execute("rm -rf " .. root)
  local sh = function(cmd)
    local h = io.popen(cmd .. " 2>&1")
    local out = h:read("*a")
    local okclose = h:close()
    return out, okclose
  end
  sh("jj git init --colocate " .. root)
  sh("mkdir -p " .. root .. "/ws")
  sh("(cd " .. root .. " && jj workspace add --colocate -r @ " .. root .. "/ws/alpha)")
  sh("(cd " .. root .. " && jj workspace add --colocate -r @ " .. root .. "/ws/beta)")
  -- Dirty marker in beta: jj only snapshots a workspace's working copy when a
  -- command runs inside it, so trigger the snapshot from within ws/beta.
  -- Before the root narrows: after it, the ws/ subtree is outside the root's
  -- sparse pattern and root-run jj commands cannot see the file at all.
  sh("touch " .. root .. "/ws/beta/dirty.txt")
  sh("(cd " .. root .. "/ws/beta && jj st)")
  -- pj init's adoption marks: ws/ dir + root narrowed to a ws-only sparse
  -- pattern (the plugin's find_root mirrors pj's is_root: ws/ or shared/
  -- present, .jj/repo a real dir, and a narrowed root sparse pattern).
  sh("(cd " .. root .. " && jj sparse set --clear --add ws)")
  sh("mkdir -p " .. root .. "/shared/project")
  sh("mkdir -p " .. root .. "/ws/alpha/sub")
  fixture = { root = root, sh = sh }
  return fixture
end

local function teardown_fixture()
  if fixture then
    os.execute("rm -rf " .. fixture.root)
  end
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

print("=== test_project_spec: find_root + list_workspaces ===")

local project, load_err = load_project()

if project == nil then
  -- Red phase: module does not exist yet. Everything below must fail loudly.
  test("require pi-jail.project loads", function()
    check(false, "require('pi-jail.project') failed: " .. tostring(load_err))
  end)
else
  setup_fixture()
  local root = fixture.root

  test("find_root from inside ws/<name> returns repo root", function()
    eq(project.find_root(root .. "/ws/alpha/sub"), root, "find_root(ws/alpha/sub)")
  end)

  test("find_root from repo root returns root", function()
    eq(project.find_root(root), root, "find_root(root)")
  end)

  test("find_root returns nil for dir with no .jj above", function()
    eq(project.find_root("/tmp"), nil, "find_root(/tmp)")
  end)

  test("find_root returns nil for non-adopted plain jj repo", function()
    -- A bare jj repo without ws/ + shared/ under its root.
    local plain = "/tmp/pj-plain-" .. tostring(vim.loop and vim.loop.os_getpid() or 0)
    os.execute("rm -rf " .. plain)
    fixture.sh("jj git init --colocate " .. plain)
    eq(project.find_root(plain), nil, "find_root(plain jj repo)")
    os.execute("rm -rf " .. plain)
  end)

  test("find_root matches pj is_root: ws/ only (no shared/) still adopts", function()
    -- pj accepts either layout dir as the adoption mark.
    local ws_only = "/tmp/pj-wsonly-" .. tostring(vim.loop and vim.loop.os_getpid() or 0)
    os.execute("rm -rf " .. ws_only)
    fixture.sh("jj git init --colocate " .. ws_only)
    fixture.sh("(cd " .. ws_only .. " && jj sparse set --clear --add ws)")
    fixture.sh("mkdir -p " .. ws_only .. "/ws")
    eq(project.find_root(ws_only), ws_only, "find_root(ws/-only adopted repo)")
    os.execute("rm -rf " .. ws_only)
  end)

  test("find_root matches pj is_root: shared/ only (no ws/) still adopts", function()
    local shared_only = "/tmp/pj-sharedonly-" .. tostring(vim.loop and vim.loop.os_getpid() or 0)
    os.execute("rm -rf " .. shared_only)
    fixture.sh("jj git init --colocate " .. shared_only)
    fixture.sh("(cd " .. shared_only .. " && jj sparse set --clear --add ws)")
    fixture.sh("mkdir -p " .. shared_only .. "/shared")
    eq(project.find_root(shared_only), shared_only, "find_root(shared/-only adopted repo)")
    os.execute("rm -rf " .. shared_only)
  end)

  test("find_root matches pj is_root: full-checkout look-alike is not a root", function()
    -- A plain jj repo with ws/ + shared/ dirs but a full sparse checkout: pj
    -- rejects it (shared/ is a common name; adoption also narrows the root).
    local lookalike = "/tmp/pj-lookalike-" .. tostring(vim.loop and vim.loop.os_getpid() or 0)
    os.execute("rm -rf " .. lookalike)
    fixture.sh("jj git init --colocate " .. lookalike)
    fixture.sh("mkdir -p " .. lookalike .. "/ws " .. lookalike .. "/shared")
    eq(project.find_root(lookalike), nil, "find_root(full-checkout look-alike)")
    os.execute("rm -rf " .. lookalike)
  end)

  test("find_root matches pj is_root: .jj/repo pointer file is not a root", function()
    -- An added workspace's .jj/repo is a pointer file, not a real dir; a
    -- look-alike ws/ layout below it must not be mistaken for a root.
    local nested = root .. "/ws/alpha/sub"
    fixture.sh("mkdir -p " .. nested)
    fixture.sh("cp " .. root .. "/ws/alpha/.jj/repo " .. nested .. "/.jj-repo-pointer 2>/dev/null || true")
    eq(project.find_root(nested), root, "find_root below a workspace stays at the true root")
  end)

  test("list_workspaces parses names, excludes default, marks empty (clean)", function()
    local wss = project.list_workspaces(root)
    ok(wss ~= nil, "list_workspaces returns a table")
    if wss == nil then
      return
    end
    local names = {}
    for _, ws in ipairs(wss) do
      names[#names + 1] = ws.name
    end
    eq_deep(names, { "alpha", "beta" }, "workspace names, default excluded")
    for _, ws in ipairs(wss) do
      if ws.name == "alpha" then
        eq(ws.dirty, false, "alpha dirty flag (has (empty) marker)")
      end
    end
  end)

  test("list_workspaces marks workspace dirty when (empty) absent", function()
    -- beta is dirty via dirty.txt + in-ws snapshot from setup.
    local wss = project.list_workspaces(root)
    ok(wss ~= nil, "list_workspaces returns a table")
    if wss == nil then
      return
    end
    for _, ws in ipairs(wss) do
      if ws.name == "beta" then
        eq(ws.dirty, true, "beta dirty=true after uncommitted dirty.txt")
      end
    end
  end)

  test("list_workspaces flags current workspace via explicit ref_dir", function()
    -- jj's (current) marker follows the *process* cwd (= root here, always marking
    -- the excluded `default`), so current must be computed from a reference dir.
    local wss = project.list_workspaces(root, root .. "/ws/alpha/sub")
    ok(wss ~= nil, "list_workspaces returns a table")
    if wss == nil then
      return
    end
    for _, ws in ipairs(wss) do
      eq(ws.current, ws.name == "alpha", ws.name .. " current flag with ref_dir in ws/alpha")
    end
  end)

  test("list_workspaces flags no current workspace when ref_dir is root", function()
    local wss = project.list_workspaces(root, root)
    ok(wss ~= nil, "list_workspaces returns a table")
    if wss == nil then
      return
    end
    for _, ws in ipairs(wss) do
      eq(ws.current, false, ws.name .. " current=false when ref_dir is root")
    end
  end)

  test("list_workspaces defaults ref_dir to nvim cwd", function()
    local old_cwd = vim.loop.cwd()
    pcall(vim.cmd, "cd " .. root .. "/ws/alpha")
    local wss = project.list_workspaces(root)
    pcall(vim.cmd, "cd " .. old_cwd)
    ok(wss ~= nil, "list_workspaces returns a table")
    if wss == nil then
      return
    end
    for _, ws in ipairs(wss) do
      if ws.name == "alpha" then
        eq(ws.current, true, "alpha current=true when cwd inside ws/alpha")
      end
    end
  end)

  test("list_workspaces sorted by name", function()
    fixture.sh("(cd " .. root .. " && jj workspace add --colocate -r @ " .. root .. "/ws/zeta)")
    fixture.sh("(cd " .. root .. " && jj workspace add --colocate -r @ " .. root .. "/ws/mid)")
    local wss = project.list_workspaces(root)
    ok(wss ~= nil, "list_workspaces returns a table")
    if wss == nil then
      return
    end
    local names = {}
    for _, ws in ipairs(wss) do
      names[#names + 1] = ws.name
    end
    local sorted = vim.deepcopy(names)
    table.sort(sorted)
    eq_deep(names, sorted, "workspace names sorted ascending")
  end)

  teardown_fixture()
end

-- Summary + exit code signal.
print(("=== test_project_spec: %d/%d checks passed, %d failures"):format(checks - failures, checks, failures))
if failures > 0 then
  vim.cmd("cq")
end
