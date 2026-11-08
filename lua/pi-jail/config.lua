-- pi-jail.config: plugin configuration with defaults and merge-on-setup semantics.

local M = {}

local defaults = {
  pj = "pj",
  -- "cd" (global, so cwd-bound plugins like a neo-tree sidebar follow along)
  -- or "tcd" (tab-local, so other tabs keep their cwd).
  dir_change_scope = "cd",
  terminal = {
    keep_on_exit = true,
    size = 0.4,
  },
}

M.config = vim.deepcopy(defaults)

local function is_table(v)
  return type(v) == "table"
end

local function merge_into(target, src)
  for k, v in pairs(src) do
    if is_table(v) and is_table(target[k]) then
      merge_into(target[k], v)
    else
      target[k] = v
    end
  end
end

---Merge opts over current config (defaults initially). Nested tables merge
---recursively. Later setup calls merge over the previous state.
---@param opts table|nil
function M.setup(opts)
  if opts == nil then
    return
  end
  merge_into(M.config, opts)
end

---Return the resolved config table (live reference; do not mutate).
---@return table
function M.get()
  return M.config
end

return M
