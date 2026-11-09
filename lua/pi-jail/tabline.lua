-- pi-jail.tabline: tabline rendering for jail tabs. Tabs carrying
-- t:pi_jail_name show that name; other tabs fall back to their first
-- window's buffer name (nvim-default style). The current tab is wrapped in
-- "> N label <"; labels join with a single space.
-- vim.o.tabline cannot hold a Lua function, so setup() installs the
-- %{v:lua...} expression string instead.

local M = {}

local EXPRESSION = "%{v:lua.require('pi-jail.tabline').render()}"

---Label text for one tabpage: t:pi_jail_name if set, else the first
---window's buffer name, else "[No Name]". Never errors.
local function tab_label(tab)
  local okv, name = pcall(vim.api.nvim_tabpage_get_var, tab, "pi_jail_name")
  if okv and name ~= nil and name ~= "" then
    return name
  end
  local okw, wins = pcall(vim.api.nvim_tabpage_list_wins, tab)
  if okw and wins[1] ~= nil and vim.api.nvim_win_is_valid(wins[1]) then
    local buf = vim.api.nvim_win_get_buf(wins[1])
    local bufname = vim.fn.bufname(buf)
    if bufname ~= "" then
      return vim.fn.fnamemodify(bufname, ":t")
    end
  end
  return "[No Name]"
end

---Full tabline string for every tabpage, in order.
function M.render()
  local current = vim.api.nvim_get_current_tabpage()
  local labels = {}
  for i, tab in ipairs(vim.api.nvim_list_tabpages()) do
    if vim.api.nvim_tabpage_is_valid(tab) then
      local label = i .. " " .. tab_label(tab) .. " "
      if tab == current then
        labels[#labels + 1] = "> " .. label .. "<"
      else
        labels[#labels + 1] = label
      end
    end
  end
  return table.concat(labels, " ")
end

---Install the tabline expression if no tabline is set; idempotent, never
---overwrites a non-empty option.
function M.setup()
  if vim.o.tabline == "" then
    vim.o.tabline = EXPRESSION
  end
end

return M
