-- pi-jail.project: root discovery and workspace listing for a pj-adopted jj repo.
--
-- Root detection mirrors pj's is_root: the dir carries the adoption marks
-- (ws/ or shared/ exists, .jj/repo is a real dir - added workspaces carry only
-- a pointer file), and its default workspace has a narrowed sparse checkout
-- (pj init dematerializes the root; a full-checkout look-alike is not a root).

local M = {}

local function is_dir(path)
  local stat = vim.loop.fs_stat(path)
  return stat ~= nil and stat.type == "directory"
end

---Strip trailing slashes: "/a/b/" -> "/a/b"; "/" -> "/".
---@param path string
---@return string
local function normalize(path)
  path = path:gsub("/+$", "")
  if path == "" then
    path = "/"
  end
  return path
end

---Run `jj sparse list` in dir, trailing whitespace stripped (like bash's
---command substitution); nil on failure (not a repo, jj missing, ...).
---@param dir string
---@return string|nil sparse pattern list
local function jj_sparse_list(dir)
  local out = vim.system({ "jj", "sparse", "list" }, { cwd = dir, text = true }):wait()
  if out.code ~= 0 then
    return nil
  end
  return (out.stdout or ""):gsub("%s+$", "")
end

---True iff dir is a pj-adopted jj root (pj's is_root, verbatim algo):
---ws/ or shared/ present, .jj/repo a real dir, and the root's default
---workspace narrowed (sparse list != ".").
---@param dir string normalized candidate
---@return boolean
local function is_root(dir)
  if not (is_dir(dir .. "/ws") or is_dir(dir .. "/shared")) then
    return false
  end
  if not is_dir(dir .. "/.jj/repo") then
    return false
  end
  local sparse = jj_sparse_list(dir)
  return sparse ~= nil and sparse ~= "."
end

---Walk up from start_dir to the first directory that is a pj-adopted jj root
---(see is_root). Colocated workspaces have only a .jj pointer file without the
---adopted layout, so those are skipped and the walk continues upward.
---@param start_dir string
---@return string|nil root
function M.find_root(start_dir)
  local dir = normalize(start_dir)
  while true do
    if is_root(dir) then
      return dir
    end
    local parent = vim.fs.dirname(dir)
    if parent == dir then
      return nil
    end
    dir = parent
  end
end

---Parse one `jj workspace list` output line.
---Line shape: "name: path changeid commitid (empty) (no description set)".
---`(empty)` present => clean; absent => dirty. Lines without ":" are skipped.
---@param line string
---@return table|nil ws { name, dirty }
local function parse_line(line)
  local name = line:match("^([^:]+):")
  if name == nil then
    return nil
  end
  name = name:gsub("%s+$", ""):gsub("%s*%(current%)$", "")
  if name == "" then
    return nil
  end
  return { name = name, dirty = not line:find("(empty)", 1, true) }
end

---True iff ref_dir is inside root/ws/name (strictly below it, exact boundaries).
---@param root string normalized root
---@param ws_dir string normalized workspace dir
---@param ref_dir string normalized reference dir
---@return boolean
local function is_inside(ref_dir, ws_dir)
  return ref_dir == ws_dir or ref_dir:sub(1, #ws_dir + 1) == ws_dir .. "/"
end

---List workspaces of an adopted root, sorted by name, `default` excluded.
---`current` marks the workspace containing ref_dir (default: nvim cwd).
---Returns nil when `jj workspace list` fails (not a repo, jj missing, ...).
---@param root string
---@param ref_dir string|nil
---@return table|nil workspaces { { name, dirty, current } }
function M.list_workspaces(root, ref_dir)
  local out = vim.system({ "jj", "workspace", "list" }, { cwd = root, text = true }):wait()
  if out.code ~= 0 then
    return nil
  end
  ref_dir = normalize(ref_dir or vim.loop.cwd())
  root = normalize(root)
  local wss = {}
  for line in out.stdout:gmatch("[^\r\n]+") do
    local ws = parse_line(line)
    if ws ~= nil and ws.name ~= "default" then
      ws.current = is_inside(ref_dir, root .. "/ws/" .. ws.name)
      wss[#wss + 1] = ws
    end
  end
  table.sort(wss, function(a, b)
    return a.name < b.name
  end)
  return wss
end

---Resolve the workspace name for a path inside root/ws/<name> (the
---workspace dir itself included). Returns nil for any other path: root itself,
---root/ws, root/shared/..., or anything outside root.
---@param root string normalized repo root
---@param path string|nil buffer file path
---@return string|nil name
function M.current_ws(root, path)
  if path == nil then
    return nil
  end
  local prefix = normalize(root) .. "/ws/"
  if path:sub(1, #prefix) ~= prefix then
    return nil
  end
  local rest = path:sub(#prefix + 1)
  if rest == "" then
    return nil
  end
  local name = rest:match("^[^/]+")
  return name ~= nil and name ~= "" and name or nil
end

return M
