# Keybindings

Hexe mux keybindings are defined in your Lua config under `mux.input.binds`.

This system is designed to:
- keep every bind explicit (no implicit defaults)
- allow context-sensitive behavior (split vs float focus)
- support advanced gestures (press/release/repeat/hold/double-tap)
- work across many terminals via progressive enhancement

## File locations

Hexe reads its config from:
- `$XDG_CONFIG_HOME/hexe/init.lua`
- or `~/.config/hexe/init.lua`
- optional local override: `./.hexe.lua`

Main config should return a Lua table containing the `mux` section.

## Basic schema

```lua
local hx = require("hexe")

return {
  mux = {
    input = {
      timing = {
        hold_ms = 350,
        tap_ms = 200,
      },
      binds = {
        {
          on = "press",
          mods = { hx.mod.alt },
          key = "q",
          when = { all = { "focus:any" } },
          action = { type = hx.action.mux_quit },
        },
      },
    },
  },
}
```

### `mods`

`mods` is an array of modifier values:
- `hx.mod.alt`
- `hx.mod.ctrl`
- `hx.mod.shift`
- `hx.mod.super`

### `key`

Supported key values:
- single characters like `"q"`, `"1"`, `"."`
- named keys: `"up"`, `"down"`, `"left"`, `"right"`, `"space"`

### `when` (conditions)

`when` filters when a bind can fire.

- string shorthand: `when = "focus:any"`
- table form: `when = { all = { "focus:split", "fg:nvim" } }`
- script form: `when = { bash = "[[ -n $SSH_CONNECTION ]]" }` or `when = { lua = "return true" }`

### `mode`

The `mode` field controls what happens when a keybind matches:

- **`act_and_consume`** (default): Execute the action and consume the key (key is NOT sent to pane)
- **`act_and_passthrough`**: Execute the action AND forward the key to the pane
- **`passthrough_only`**: Don't execute any action, just forward the key to the pane

Example use cases:

```lua
-- Default: Alt+T creates tab, key is consumed
{
  on = "press",
  mods = { hx.mod.alt },
  key = "t",
  action = { type = hx.action.tab_new },
  -- mode = "act_and_consume" is implicit
}

-- Execute action AND send key to pane (e.g., for logging/notifications)
{
  on = "press",
  mods = { hx.mod.ctrl },
  key = "s",
  mode = "act_and_passthrough",
  action = { type = hx.action.keycast_toggle },
}

-- Passthrough only: useful for conditional forwarding
-- When in nvim, forward Ctrl+W to pane (let nvim handle it)
{
  on = "press",
  mods = { hx.mod.ctrl },
  key = "w",
  mode = "passthrough_only",
  when = { all = { "fg:nvim" } },
}
```

**Important**: Keys without ANY keybinding pass through to panes unchanged. You only need `passthrough_only` when you want to explicitly forward a key in specific contexts while consuming it in others.

### `action`

Actions are dispatchers that trigger mux operations.

Supported action types:
- `mux_quit` - quit the mux session
- `mux_detach` - detach from session (leave running)
- `pane_disown` - disown current pane (orphan it)
- `pane_adopt` - adopt orphaned panes
- `pane_close` - close current float or split pane
- `pane_select_mode` - enter pane select mode
- `keycast_toggle` - toggle keycast overlay
- `split_h` - split horizontally
- `split_v` - split vertically
- `split_resize` - resize split (requires `dir`)
- `tab_new` - create new tab
- `tab_next` - switch to next tab
- `tab_prev` - switch to previous tab
- `tab_close` - close current tab
- `float_toggle` - toggle named float (requires `float`)
- `float_nudge` - move float position (requires `dir`)
- `focus_move` - move focus (requires `dir`)

Action parameters:
- `float_toggle`: `{ type = hx.action.float_toggle, float = "p" }`
- `focus_move`: `{ type = hx.action.focus_move, dir = "left" }`
- `split_resize`: `{ type = hx.action.split_resize, dir = "left" }`
- `float_nudge`: `{ type = hx.action.float_nudge, dir = "up" }`

## Advanced gestures

These features are enabled by the kitty keyboard protocol when the terminal supports it.

### `on: press`

Runs when the key is pressed.

```lua
{ on = "press", mods = { hx.mod.alt }, key = "t", when = { all = { "focus:any" } }, action = { type = hx.action.tab_new } }
```

### `on: repeat`

Runs while the key is held and repeat events are generated.

Notes:
- If there is no `repeat` binding for the key, repeat events are NOT forwarded (to prevent accidental repeated actions).
- Useful for repeating navigation actions.

```lua
{ on = "repeat", mods = { hx.mod.alt }, key = "left", when = { all = { "focus:any" } }, action = { type = hx.action.focus_move, dir = "left" } }
```

### `on: release`

Runs when the key is released.

Notes:
- Requires a terminal that supports kitty keyboard protocol event types.
- Release events are mux-only; they are not forwarded into panes.

```lua
{ on = "release", mods = { hx.mod.alt, hx.mod.shift }, key = "d", when = { all = { "focus:any" } }, action = { type = hx.action.mux_detach } }
```

### `on: hold`

Runs once after the key has been held for a given duration.

Configuration:
- per-bind: `hold_ms`
- default: `input.timing.hold_ms`

Notes:
- Implemented as a mux timer.
- A key release cancels a pending hold.

```lua
{ on = "hold", mods = { hx.mod.alt }, key = "q", hold_ms = 600, when = { all = { "focus:any" } }, action = { type = hx.action.mux_quit } }
```

### `double_tap`

`double_tap` is not currently supported in bind parsing. Use `on = "press" | "release" | "repeat" | "hold"`.

## Context-sensitive use cases

### Same key, different action depending on focus

```lua
{ mods = { hx.mod.alt }, key = "x", on = "press", when = { all = { "focus:float" } }, action = { type = hx.action.pane_close } }
{ mods = { hx.mod.alt }, key = "x", on = "press", when = { all = { "focus:split" } }, action = { type = hx.action.tab_close } }
```

### Float toggles

Named floats are configured under `floats[]` (command, size, style, attributes), and are triggered via binds:

```lua
{ mods = { hx.mod.alt }, key = "p", on = "press", when = { all = { "focus:any" } }, action = { type = hx.action.float_toggle, float = "p" } }
```

### Disable binds in specific apps (Neovim integration)

If you want Hexe to handle `Alt+Arrow` everywhere except inside Neovim (so Neovim can use the same keys), add an exclude filter:

```lua
{ mods = { hx.mod.alt }, key = "left", on = "press", when = { all = { "focus:any", "not_fg:nvim" } }, action = { type = hx.action.focus_move, dir = "left" } }
```

Then Neovim can call `hexe mux focus left|right|up|down` when it needs to move between mux panes.

### Passthrough keys to specific programs

Forward Ctrl+W to pane only when running vim/nvim (otherwise mux handles it):

```lua
-- In vim: let vim handle Ctrl+W (window commands)
{
  on = "press",
  mods = { hx.mod.ctrl },
  key = "w",
  mode = "passthrough_only",
  when = { all = { "fg:nvim" } },
}

-- Outside vim: close pane
{
  on = "press",
  mods = { hx.mod.ctrl },
  key = "w",
  when = { all = { "not_fg:nvim" } },
  action = { type = hx.action.pane_close },
}
```

## Float Title Styling

Float titles are rendered by the float border renderer. The float title text comes from the float definition (`floats[].title`).

The optional `style.title` section controls where and how that title string is rendered:

```lua
style = {
  title = {
    position = "topcenter",
    outputs = {
      { style = "bg:0 fg:1", format = "[" },
      { style = "bg:237 fg:250", format = " $output " },
      { style = "bg:0 fg:1", format = "]" },
    },
  },
}
```

## Terminal support and fallback behavior

Hexe uses progressive enhancement:

- On mux start, Hexe enables kitty keyboard protocol (`CSI > ... u`).
- Terminals that support it will send CSI-u key events, including repeat/release if requested.
- Terminals that don't support it ignore the enable sequence and keep sending legacy escape sequences.

### Key forwarding behavior

**Keys without bindings**: Pass through raw to the pane unchanged. This preserves all escape sequences (Shift+Tab, F-keys, etc.).

**Keys with bindings**:
- `act_and_consume`: Key is consumed, not sent to pane
- `act_and_passthrough`: Action runs, key is translated and sent to pane
- `passthrough_only`: Key is translated and sent to pane (no action)

For passthrough modes, keys are translated to legacy sequences:
- Shift+Tab becomes `ESC [ Z` (backtab)
- Ctrl+Space becomes NUL (0x00)
- Arrow keys with mods become `ESC [ 1 ; <mod> A/B/C/D`
- Ctrl+letter becomes control character (0x01-0x1A)
- Alt+key gets ESC prefix

Practical implications:
- Your binds work in many terminals (legacy parsing fallback).
- Release detection is best-effort and only active when the terminal reports release events.
- Keys you don't bind pass through unchanged, preserving complex sequences.

## Conditional `when` (Prompt + Status Modules)

Hexe supports conditional rendering for:

- `shp.prompt` modules (shell prompt)
- `mux.tabs.status` modules (mux status bar)

The condition is configured via a `when = { ... }` table.

Important:
- `when` must be a table (no string form)
- conditions are ANDed: if multiple providers are present, all must pass

### Prompt Modules (`shp.prompt`)

Supported providers:
- `bash`: run a bash condition (exit code 0 = show)
- `lua`: run a Lua chunk that returns a boolean

Example:

```lua
{
  name = "ssh",
  command = "echo //",
  when = {
    bash = "[[ -n $SSH_CONNECTION ]]",
  },
  outputs = {
    { style = "bg:237 italic fg:15", format = " $output" },
  },
}
```

For `lua`, the chunk must `return true/false`. A `ctx` table is provided:
- `ctx.cwd`
- `ctx.exit_status`
- `ctx.cmd_duration_ms`
- `ctx.jobs`
- `ctx.terminal_width`

Example:

```lua
when = {
  lua = "return (ctx.exit_status or 0) ~= 0",
}
```

### Status Bar Modules (`mux.tabs.status`)

Supported providers:
- `hexe`: a list of built-in mux predicates (ANDed)
- `bash`: run a bash condition (rate-limited)
- `lua`: run a Lua chunk that returns a boolean (rate-limited)

Example:

```lua
{
  name = "running_anim/knight_rider?width=10&step=30&hold=20",
  when = {
    hexe = { "process_running", "not_alt_screen" },
  },
  outputs = {
    { format = " $output" },
  },
}
```

`hexe.shp` tokens available:
- `process_running`
- `not_process_running`
- `alt_screen`
- `not_alt_screen`
- `jobs_nonzero`
- `has_last_cmd`
- `last_status_nonzero`

`hexe.mux` tokens available:
- `focus_float`
- `focus_split`
- `adhoc_float`
- `named_float`
- `float_destroyable`
- `float_exclusive`
- `float_sticky`
- `float_per_cwd`
- `float_global`
- `float_isolated`
- `tabs_gt1`
- `tabs_eq1`

For statusbar `lua`, `ctx` includes:
- `ctx.shell_running`
- `ctx.alt_screen`
- `ctx.jobs`
- `ctx.last_status`
- `ctx.last_command`
- `ctx.cwd`
- `ctx.now_ms`
