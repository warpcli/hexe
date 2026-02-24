# Session manager

Drop a `.hexe.lua` file in a project root to define tabs, splits, floats, and startup commands. Launch it with `hexe ses open .`.

---

## Quick start

Create `.hexe.lua` in your project directory:

```lua
return {
  name = "myproject",
  root = ".",

  tabs = {
    {
      name = "editor",
      split = {
        dir = "horizontal",
        { cmd = "nvim", size = 70 },
        { size = 30 },
      },
    },
    {
      name = "server",
      split = { cmd = "npm run dev" },
    },
    {
      name = "shell",
    },
  },

  floats = {
    { key = "g", cmd = "lazygit", width = 90, height = 90 },
  },
}
```

Then open it:

```sh
hexe ses open .
```

---

## Config resolution

`hexe ses open <target>` finds the config based on the target argument:

| Target | Resolution |
|---|---|
| `.` | `.hexe.lua` in current directory |
| `/path/to/dir` | `.hexe.lua` inside that directory |
| `/path/to/file.lua` | Use the file directly |
| `myproject` | `~/.local/share/hexe/sessions/myproject.lua` |

Named configs live in:

```
~/.local/share/hexe/sessions/
```

---

## Selective tab launch

Append `:<tab>` to only open a specific tab from the config:

```sh
# Open only the "server" tab
hexe ses open myproject:server

# Works with directory targets too
hexe ses open .:editor
```

If the tab name doesn't match, a default tab is created instead.

---

## Config reference

### Top-level fields

| Field | Default | Description |
|---|---|---|
| `name` | — | Session name |
| `root` | config directory | Working directory for all panes |
| `on_start` | `{}` | Shell commands to run after session starts |
| `on_stop` | `{}` | Shell commands to run before teardown |
| `tabs` | `{}` | Tab definitions |
| `floats` | `{}` | Global float definitions |

### Tab definition

| Field | Default | Description |
|---|---|---|
| `name` | `tab-N` | Tab label |
| `split` | — | Split tree (omit for a single default shell pane) |
| `floats` | `{}` | Per-tab float definitions |

### Split tree

A split tree is either a **leaf pane** or a **split node**.

Leaf pane:

```lua
{ cmd = "nvim", cwd = "src" }
```

| Field | Default | Description |
|---|---|---|
| `cmd` | — | Command to run (omit for default shell) |
| `cwd` | root | Working directory, relative to `root` |

Split node:

```lua
{
  dir = "horizontal",
  { cmd = "nvim", size = 70 },
  { size = 30 },
}
```

| Field | Default | Description |
|---|---|---|
| `dir` | required | `"horizontal"` or `"vertical"` |
| children | required | Array of child panes/splits (1-based) |

Each child can have an optional `size` field (percentage). Unspecified sizes split the remaining space equally.

### Float definition

| Field | Default | Description |
|---|---|---|
| `key` | — | Toggle key character |
| `cmd` | — | Command to run |
| `width` | `80` | Width as percentage of terminal |
| `height` | `80` | Height as percentage of terminal |
| `pos_x` | `50` | Horizontal position (center %) |
| `pos_y` | `50` | Vertical position (center %) |
| `title` | — | Border title |
| `global` | `false` | Available across all tabs |

---

## Nested splits

Splits can nest arbitrarily. Children are numbered array elements:

```lua
split = {
  dir = "horizontal",
  { size = 50, cmd = "nvim" },
  {
    size = 50,
    dir = "vertical",
    { cmd = "npm run dev" },
    { cmd = "npm test" },
  },
}
```

This creates a horizontal split: nvim on the left (50%), and a vertical split on the right with two panes.

Three-way equal split:

```lua
split = {
  dir = "horizontal",
  { cmd = "nvim" },
  {},
  {},
}
```

Without `size`, each child gets an equal share.

---

## Startup hooks

Run shell commands when the session starts:

```lua
return {
  name = "myproject",
  root = "~/projects/myapp",

  on_start = {
    "docker compose up -d",
    "redis-server --daemonize yes",
  },

  tabs = { ... },
}
```

Hooks are fire-and-forget — they run in the background and don't block session creation.

---

## Freezing a session

Snapshot a live session as a `.hexe.lua` config:

```sh
hexe ses freeze > .hexe.lua
```

Run this from inside a hexe pane. It captures the current tab layout, split structure, and pane working directories, then outputs valid Lua to stdout.

The frozen config can be reopened:

```sh
hexe ses open .
```

---

## CLI reference

```sh
hexe ses open <target>[:<tab>] [--debug] [--logfile <path>]
```
Open a session from a `.hexe.lua` config.

```sh
hexe ses freeze
```
Snapshot current session as `.hexe.lua` to stdout.

---

## Examples

### Full-stack project

```lua
return {
  name = "webapp",
  root = "~/projects/webapp",

  on_start = {
    "docker compose up -d",
  },

  tabs = {
    {
      name = "code",
      split = {
        dir = "horizontal",
        { cmd = "nvim", size = 65 },
        {
          size = 35,
          dir = "vertical",
          { cmd = "npm run dev" },
          {},
        },
      },
    },
    {
      name = "db",
      split = { cmd = "pgcli" },
    },
    {
      name = "shell",
    },
  },

  floats = {
    { key = "g", cmd = "lazygit", width = 90, height = 90 },
    { key = "d", cmd = "lazydocker", width = 80, height = 80 },
  },
}
```

### Simple note-taking

```lua
return {
  name = "notes",
  root = "~/notes",
  tabs = {
    { name = "edit", split = { cmd = "nvim ." } },
    { name = "shell" },
  },
}
```
