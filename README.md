# pi-jail.nvim

Neovim plugin for pi-jail repositories: jj repos adopted by `pj`, where every workspace lives as a worktree under
`ws/` with shared state in `shared/`.

It gives you:

- `:Pj [ws]` — enter a workspace: opens it in its own named tab (label `ws/<name>`) with the pi coding agent in a
  persistent terminal inside it (reused across invocations, one per workspace). Closing the tab keeps the agent alive;
  a later `:Pj open` re-attaches it in a fresh tab.
- `:Pj new` / `:Pj fill` / `:Pj drop` — thin, confirmed wrappers around the matching `pj` commands.

## Requirements

- Neovim >= 0.9 (`vim.ui.select`/`vim.ui.input`, `vim.system`)
- `pj` on your `PATH` (or configured, see below)
- `jj` on your `PATH` (workspace listing)

## Setup

Lazy:

```lua
-- with lazy.nvim
{
  "metlos/pi-jail.nvim",
  opts = {},
}
```

Or plain:

```lua
require("pi-jail").setup({})
```

## Commands

All commands resolve the repo root from the current working directory (walking up to the nearest `pj`-adopted jj
repo). Outside a project they notify an error and do nothing.

Workspace arguments use the `ws/<name>` form, matching `pj`'s shell completion (`:Pj open ws/mytask`). Unlike `pj`
itself, the plugin does not accept the bare `name` form — anything else is rejected with an error notification before
anything runs.

| Command              | Action                                                                                      |
| -------------------- | ------------------------------------------------------------------------------------------- |
| `:Pj`                | Pick a workspace (`vim.ui.select`, dirty ones as `ws/name *`, open ones as `ws/name [tab]`) |
| `:Pj open [ws/name]` | Enter workspace `ws/name` (picker when omitted)                                             |
| `:Pj new [ws/name]`  | `pj new` — create the workspace and open its tab (prompt for the id when omitted)           |
| `:Pj drop [ws/name]` | `pj drop` with confirm; offers `--force` on unlanded work                                   |
| `:Pj fill [ws/name]` | `pj fill` for the buffer's workspace (picker fallback)                                      |

Details:

- **Enter** (`:Pj`, `:Pj open`): open (or switch to) the workspace's own tab — labeled `ws/<name>` — and open/reuse
  its agent terminal (`pj open`) there. No global `cd` happens: each workspace tab carries its own tab-local cwd
  (`tcd` into `ws/<name>`), so every other tab keeps its cwd. Focusing a workspace terminal (also across tab
  switches) tcd's that tab into the workspace, so cwd-bound sidebars follow the terminal you are looking at.
  Focusing the dead-but-kept terminal of an exited agent still follows; focusing away from a terminal never changes
  the cwd.
- **New** creates the workspace, then opens its tab (prompts for the id when omitted).
- **Drop** always confirms (`Drop ws/<name>?`). If `pj drop` reports unlanded work, a second confirm offers `--force`.
  Success and failure are surfaced with `vim.notify` (failure shows pj's stderr verbatim).

## Configuration

Defaults:

```lua
require("pi-jail").setup({
  pj = "pj", -- pj executable (name on PATH, or an absolute path)
  terminal = {
    keep_on_exit = true, -- keep the split + buffer around after the agent exits
    size = 0.4, -- terminal column width as a fraction of &columns
  },
})
```

## Terminal layout

Each workspace terminal lives in its own tab as a right-side vertical split sized by `terminal.size`. Re-entering a
workspace whose terminal split was closed re-splits the same buffer in its tab.

## Tabline

At setup the plugin installs a minimal tabline showing workspace names — but only when `vim.o.tabline` is empty. A
tabline plugin takes over that option instead, so every workspace tab also sets the tab-local variables `t:tabname`
(lualine's convention) and `t:name` (bufferline's rename convention) to the workspace id, next to our own
`t:pi_jail_name`.

Support matrix:

- **lualine** — works out of the box: its `tabs` component reads `t:tabname`, so jail tabs are labeled `ws/<name>`.
- **tabby** — auto-integrated when installed: names are pushed into its `tabby.feature.tab_name` module.
- **bufferline** — not automatic in `mode = "tabs"`: its tab labels come from the active buffer, not `t:name`. Use
  `name_formatter` reading `t:pi_jail_name`:

```lua
require("bufferline").setup({
  options = {
    mode = "tabs",
    name_formatter = function(opts)
      local ok, name = pcall(vim.api.nvim_tabpage_get_var, opts.tabnr, "pi_jail_name")
      return ok and name or nil
    end,
  },
})
```

(Without the pcall, non-jail tabs would error bufferline into its fallback label; returning `nil` keeps their default
name.)

## Plugin interop

Entering a workspace no longer fires a global `:cd`: the chdir is tab-local (`tcd`), and `DirChanged` fires with tab
scope. Cwd-following plugins should watch the tab scope instead — for neo-tree, `cwd_target.sidebar = "tab"` — so a
per-tab sidebar follows the workspace whose tab you are in, both on entering a workspace and on focusing its terminal.

## Development

```sh
bash tests/run.sh
```

Runs every `tests/test_*_spec.lua` in headless nvim. Specs are dependency-free Lua files; each exercises the module
against fakes (fake `pj` shell scripts, real `jj` scratch repos in `/tmp`).
