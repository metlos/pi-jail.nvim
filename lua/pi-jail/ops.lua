-- pi-jail.ops: synchronous pj process operations.
--
-- pj commands must run with cwd = adopted repo root. Both success and
-- failure are surfaced to the caller as a plain result table; notifications
-- are the caller's job. Failure stderr is passed through verbatim.

local config = require("pi-jail.config")

local M = {}

---Run the configured pj executable with args, synchronously, cwd=root.
---@param args string[] arguments after the executable
---@param root string repo root used as process cwd
---@return table result { ok = boolean, stdout = string, stderr = string, code = number }
function M.run_pj(args, root)
  local argv = { config.get().pj }
  for _, a in ipairs(args) do
    argv[#argv + 1] = a
  end
  local out = vim.system(argv, { cwd = root, text = true }):wait()
  return {
    ok = out.code == 0,
    stdout = out.stdout or "",
    stderr = out.stderr or "",
    code = out.code,
  }
end

return M
