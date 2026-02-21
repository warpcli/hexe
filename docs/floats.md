# Floats

Floats are overlay panes that appear on top of your splits. They are toggled with a keybinding and can be configured with rich behavior around persistence, scope, and lifecycle.

---

## Defining floats

Floats are defined under `floats` in your session layout:

```lua
hx.ses.layout.define({
  name = "default",
  floats = {
    {
      key     = "g",
      command = "lazygit",
      title   = "git",
      attributes = { per_cwd = true, sticky = true, global = true },
      width_percent  = 90,
      height_percent = 90,
    },
    {
      key     = "f",
      command = "fzf",
      attributes = { per_cwd = true, sticky = true, global = true },
    },
    {
      key        = "t",
      attributes = { global = false, destroy = true },
      width_percent  = 40,
      height_percent = 30,
      pos_x = 100,
      pos_y = 0,
    },
  },
})
```

And toggled via keybindings:

```lua
{ on = "press", mods = { hx.mod.alt }, key = "g",
  when = "focus:any",
  action = { type = hx.action.float_toggle, float = "g" } },
```

---

## Sizing and position

| Field | Default | Description |
|---|---|---|
| `width_percent` | 60 | Width as % of terminal (10–100) |
| `height_percent` | 60 | Height as % of terminal (10–100) |
| `pos_x` | 50 | Horizontal anchor (0=left, 50=center, 100=right) |
| `pos_y` | 50 | Vertical anchor (0=top, 50=center, 100=bottom) |
| `padding_x` | 1 | Left/right inner padding |
| `padding_y` | 0 | Top/bottom inner padding |

---

## Attributes

Attributes control behavior. They are set under `attributes = { ... }`:

### `per_cwd`

One float instance per working directory.

- Toggle `Alt+g` in `/repo/a` → opens the `/repo/a` lazygit
- Toggle `Alt+g` in `/repo/b` → opens the `/repo/b` lazygit (separate instance)
- Go back to `/repo/a` → shows the `/repo/a` instance again

Useful for project-scoped tools: `lazygit`, `nvim`, REPLs, file browsers.

### `sticky`

The float survives mux restarts.

- Pod is kept alive in a half-attached state when mux detaches or exits
- New mux automatically reclaims it on reattach
- Combine with `per_cwd` for directory-specific persistent floats

### `global`

Controls tab scope.

- `global = true` (recommended with `per_cwd`): Float is visible across all tabs. Visibility is tracked per-tab via a bitmask.
- `global = false` (default): Float is bound to the tab it was created on. Closing that tab destroys it.

### `exclusive`

When shown, this float hides all other floats on the current tab.

Useful for modal-style overlays where you want a single focused tool.

### `destroy`

The float process is killed when the float is hidden.

- Meaningful only for tab-bound, non-`per_cwd` floats
- Useful for fire-and-forget tools or one-shot dialogs

### `isolated`

The float runs inside a sandboxed pod (Linux namespaces + cgroups).

See [isolation](isolation.md) for profiles and resource limits.

---

## Border style

Each float can have custom border characters and colors:

```lua
style = {
  top_left     = "╭",
  top_right    = "╮",
  bottom_left  = "╰",
  bottom_right = "╯",
  horizontal   = "─",
  vertical     = "│",
},
color = {
  active  = 2,   -- palette index when focused
  passive = 8,   -- palette index when unfocused
},
```

### Border title

Embed a title or status module in the border:

```lua
style = {
  position = "topcenter",   -- topleft | topcenter | topright | bottomleft | bottomcenter | bottomright
  module   = "time",        -- any built-in segment name
  outputs  = {
    { style = "bg:0 fg:1",   format = "[" },
    { style = "bg:237 fg:250", format = " $output " },
    { style = "bg:0 fg:1",   format = "]" },
  },
},
```

---

## Global defaults

Set defaults for all floats in your mux config. Per-float values override these:

```lua
hx.mux.float.set_defaults({
  width_percent  = 65,
  height_percent = 65,
  color = { active = 2, passive = 237 },
  attributes = { global = true },
})
```

---

## Ad-hoc floats (CLI)

Spawn a one-off float from the command line:

```sh
hexe mux float --command "btop" --title "monitor" --size "80,70,0,0"
hexe mux float --command "zsh" --isolation sandbox
hexe mux float --command "bash /tmp/script.sh" --result-file /tmp/result
```

Options:

| Flag | Description |
|---|---|
| `--command` | Command to run |
| `--title` | Border title |
| `--cwd` | Working directory |
| `--size WxH,X,Y` | Size and position |
| `--focus` | Focus the float on open |
| `--isolation <profile>` | Isolation profile |
| `--key <key>` | Exit key (sent on dismiss) |
| `--result-file <path>` | Write float output here on close |
| `--pass-env` | Pass current env to float |
| `--extra-env K=V` | Add extra env vars |

---

## Moving floats

You can nudge a float's position with a keybinding:

```lua
{ on = "press", mods = { hx.mod.alt, hx.mod.shift }, key = "up",
  action = { type = hx.action.float_nudge, dir = "up" } },
```

---

## Full attribute reference

See [float_attributes.md](float_attributes.md) for detailed notes on each attribute and edge cases.
