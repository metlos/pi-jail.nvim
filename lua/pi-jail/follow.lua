-- pi-jail.follow: focusing a workspace terminal chdirs the CURRENT TAB into
-- that workspace, so cwd-bound sidebars (e.g. neo-tree) follow the terminal
-- you are looking at. Always tcd: each ws terminal owns its tab, so the
-- chdir must stay tab-local; the global cwd is never touched.

local terminal = require("pi-jail.terminal")

local M = {}

local GROUP = "pi-jail-follow"

---Chdir into the entry's workspace unless the cwd already matches.
local function follow_entry(entry)
  local ws_dir = entry.root .. "/" .. entry.ws
  if vim.fn.getcwd() ~= ws_dir then
    vim.cmd("tcd " .. vim.fn.fnameescape(ws_dir))
  end
end

---Register the BufEnter autocmd (idempotent: a cleared group, one autocmd).
function M.setup()
  vim.api.nvim_create_augroup(GROUP, { clear = true })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = GROUP,
    nested = true, -- re-fire DirChanged so cwd-bound plugins (neo-tree) see the chdir
    callback = function(args)
      local entry = terminal.entry_for_buf(args.buf)
      if entry ~= nil then
        follow_entry(entry)
      end
    end,
    desc = "pi-jail: focus a workspace terminal -> chdir into the workspace",
  })
end

return M
