# Configuration

Hexa is configured in Lua.

---

## File locations

Hexa reads config from (in order):

1. `$XDG_CONFIG_HOME/hexe/init.lua`
2. `~/.config/hexe/init.lua` (default if XDG not set)
3. `./.hexe.lua` (optional local override in current directory)

State is stored under:

- `~/.local/state/hexe/` (or `$XDG_STATE_HOME/hexe/`)

---

## Basic structure

```lua
local hx = require("hexe")

-- session layouts (tabs, splits, floats)
hx.ses.layout.define({ ... })

-- mux config (tabs, status bar, floats, keybinds, etc.)
hx.mux.set({ ... })

-- shell prompt config
hx.shp.set({ ... })
```

---

## Mux config reference

```lua
hx.mux.set({
  -- Confirmation dialogs
  confirm_on_exit   = false,
  confirm_on_detach = false,
  confirm_on_disown = false,
  confirm_on_close  = false,

  -- Selection
  selection_color          = 240,  -- palette index
  selection_override_mods  = { hx.mod.alt, hx.mod.ctrl },

  -- Splits
  splits = {
    color = { active = 1, passive = 237 },
    style = {
      vertical   = "│",
      horizontal = "─",
      cross      = "┼",
      top_t      = "┬",
      bottom_t   = "┴",
      left_t     = "├",
      right_t    = "┤",
    },
  },

  -- Tabs
  tabs = {
    key_new    = "t",
    key_next   = "n",
    key_prev   = "p",
    key_close  = "x",
    key_detach = "d",
    status = {
      enabled = true,
      left    = { ... },  -- segment arrays
      center  = { ... },
      right   = { ... },
    },
  },

  -- Notifications
  notifications = {
    mux  = { fg = 0, bg = 3, bold = true, padding_x = 1, padding_y = 0,
              offset = 1, alignment = "center", duration_ms = 3000 },
    pane = { fg = 0, bg = 3, bold = true, padding_x = 1, padding_y = 0,
              offset = 1, alignment = "center", duration_ms = 3000 },
  },

  -- Float defaults
  float_width_percent  = 60,
  float_height_percent = 60,
  float_padding_x      = 1,
  float_padding_y      = 0,
  float_color          = { active = 1, passive = 237 },
  float_default_attributes = {
    exclusive = false,
    per_cwd   = false,
    sticky    = false,
    global    = false,
    destroy   = false,
    isolated  = false,
  },
  float_style_default = {
    top_left     = "╭",
    top_right    = "╮",
    bottom_left  = "╰",
    bottom_right = "╯",
    horizontal   = "─",
    vertical     = "│",
  },

  -- Input
  input = {
    timing = {
      tap_ms  = 200,
      hold_ms = 600,
    },
    binds = { ... },  -- see keybindings.md
  },
})
```

---

## Session layout reference

```lua
hx.ses.layout.define({
  name    = "default",
  enabled = true,

  tabs = {
    {
      name    = "main",
      enabled = true,
      root    = {
        -- single pane:
        cwd     = "~/projects",
        command = nil,           -- nil = default shell

        -- OR a split:
        dir    = "h",            -- "h" or "v"
        ratio  = 0.65,           -- 0.0 – 1.0
        first  = { cwd = "~" },
        second = { cwd = "~" },
      },
    },
  },

  floats = {
    {
      key            = "g",
      enabled        = true,
      command        = "lazygit",
      title          = "git",
      width_percent  = 90,
      height_percent = 90,
      pos_x          = 50,
      pos_y          = 50,
      padding_x      = 1,
      padding_y      = 0,
      color          = { active = 2, passive = 237 },
      style          = { ... },       -- border characters
      attributes     = {
        per_cwd   = true,
        sticky    = true,
        global    = true,
        exclusive = false,
        destroy   = false,
        isolated  = false,
      },
      isolation = {
        profile = "sandbox",
        memory  = "512M",
        cpu     = "50000 100000",
        pids    = 100,
      },
    },
  },
})
```

---

## Shell prompt reference

```lua
hx.shp.set({
  prompt = {
    left  = { ... },   -- segment arrays, see statusbar.md
    right = { ... },
  },
})
```

---

## Environment variables

| Variable | Description |
|---|---|
| `HEXE_INSTANCE` | Named instance (see [instances](instances.md)) |
| `HEXE_TEST_ONLY` | Set by `--test-only`; signals test isolation |
| `HEXE_CONDITION_TIMEOUT` | Bash condition eval timeout (ms, default 100, range 10–5000) |

---

## Validate config

```sh
hexe config validate
```

Parses and validates your config without starting any daemon.
