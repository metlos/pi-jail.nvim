# pi-jail.nvim

Neovim plugin for pi-jail repositories: jj repos adopted by `pctl`, where every workspace lives as a worktree under
`ws/` with shared state in `shared/`.

It gives you:

- `:Pj [ws]` — enter a workspace: change the cwd to `ws/<name>` and open the pi coding agent there in a persistent
  terminal (reused across invocations, one per workspace).
- `:Pj debug` — a jail shell (`pi debug`) for the workspace your buffer is in.
- `:Pj new` / `:Pj fill` / `:Pj drop` — thin, confirmed wrappers around the matching `pctl` commands.

## Requirements

- Neovim >= 0.9 (`vim.ui.select`/`vim.ui.input`, `vim.system`)
- `pctl` and `pi` on your `PATH` (or configured, see below)
- `jj` on your `PATH` (workspace listing)

## Setup

Lazy:

```lua
-- with lazy.nvim
{
  "<repo>/pi-jail.nvim",
  opts = {},
}
```

Or plain:

```lua
require("pi-jail").setup({})
```

## Commands

All commands resolve the repo root from the current working directory (walking up to the nearest `pctl`-adopted jj
repo). Outside a project they notify an error and do nothing.

| Command           | Action                                                             |
| ----------------- | ------------------------------------------------------------------ |
| `:Pj`             | Pick a workspace (`vim.ui.select`, dirty ones shown as `name *`)   |
| `:Pj ws [name]`   | Enter workspace `name` (picker when omitted)                       |
| `:Pj new [name]`  | `pctl new` — create a workspace (prompt for the name when omitted) |
| `:Pj drop [name]` | `pctl drop` with confirm; offers `--force` on unlanded work        |
| `:Pj fill [name]` | `pctl fill` for the buffer's workspace (picker fallback)           |
| `:Pj debug`       | Jail shell for the buffer's workspace (picker fallback)            |

Details:

- **Enter** (`:Pj`, `:Pj ws`): change the working directory into `ws/<name>` first, then open/reuse the workspace's
  agent terminal. `ws/<name>` is a normal terminal buffer; the agent keeps running while you edit in other splits.
- **Focus-follow**: focusing a workspace terminal's split chdirs back into that workspace (same scope as Enter), so a
  cwd-bound sidebar always reflects the workspace you are looking at. Focusing the dead-but-kept terminal of an exited
  agent still follows; focusing away from a terminal never changes the cwd.
- **New** creates the workspace only: no chdir, no agent start.
- **Drop** always confirms (`Drop ws/<name>?`). If `pctl drop` reports unlanded work, a second confirm offers `--force`.
  Success and failure are surfaced with `vim.notify` (failure shows pctl's stderr verbatim).

## Configuration

Defaults:

```lua
require("pi-jail").setup({
  pctl = "pctl", -- pctl executable (name on PATH, or an absolute path)
  pi = "pi", -- pi executable (name on PATH, or an absolute path)
  dir_change_scope = "cd", -- ":cd" (global) or ":tcd" (tab-local) when entering a ws
  terminal = {
    keep_on_exit = true, -- keep the split + buffer around after the agent exits
    size = 0.4, -- terminal column width as a fraction of &columns
  },
})
```

## Terminal layout

The first workspace terminal opens as a right-side vertical split sized by `terminal.size`. Every further terminal opens
below the bottom-most one, so all terminals stack in a single right-side column of that width instead of tiling side by
side. Closing a terminal's split and reopening it later rejoins the column.

## Plugin interop

`dir_change_scope = "cd"` (the default) makes cwd-following plugins follow along automatically: the `:cd` fires
`DirChanged global`, which e.g. a neo-tree sidebar with `bind_to_cwd = true` listens to — both when entering a workspace
and when focusing its terminal. Use `"tcd"` if you want other tabs to keep their cwd — then configure such plugins to
watch the tab scope instead (neo-tree: `cwd_target.sidebar = "tab"`).

## Development

```sh
bash tests/run.sh
```

Runs every `tests/test_*_spec.lua` in headless nvim. Specs are dependency-free Lua files; each exercises the module
against fakes (fake `pctl`/`pi` shell scripts, real `jj` scratch repos in `/tmp`).
