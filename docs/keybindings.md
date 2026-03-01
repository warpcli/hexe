# Keybindings

Keybindings are defined with `hx.mux.keymap.set({...})` in your config.

---

## Basic structure

```lua
local hx = require("hexe")

hx.mux.keymap.set({
  { key = { hx.key.ctrl, hx.key.alt, hx.key.q }, action = { type = hx.action.mux_quit } },
  { key = { hx.key.ctrl, hx.key.alt, hx.key.t }, action = { type = hx.action.tab_new } },
})
```

---

## `key`

The `key` field is a single array containing modifiers and the key, all using `hx.key.*`:

```lua
key = { hx.key.ctrl, hx.key.alt, hx.key.q }
key = { hx.key.ctrl, hx.key.alt, hx.key.shift, hx.key.p }
key = { hx.key.ctrl, hx.key.alt, hx.key.up }
key = { hx.key.ctrl, hx.key.alt, hx.key["1"] }   -- number keys
key = { hx.key.ctrl, hx.key.alt, hx.key.dot }
key = { hx.key.ctrl, hx.key.alt, hx.key.comma }
```

**Modifiers:**
- `hx.key.ctrl`
- `hx.key.alt`
- `hx.key.shift`
- `hx.key.super`

**Named keys:**
- Letters: `hx.key.a` … `hx.key.z`
- Numbers: `hx.key["0"]` … `hx.key["9"]`
- Arrows: `hx.key.up`, `hx.key.down`, `hx.key.left`, `hx.key.right`
- Punctuation: `hx.key.dot`, `hx.key.comma`, `hx.key.space`, etc.

---

## `action`

Actions trigger mux operations. All available types:

| Action | Description |
|---|---|
| `hx.action.mux_quit` | Exit the mux |
| `hx.action.mux_detach` | Detach from session (leave running) |
| `hx.action.pane_disown` | Orphan current pane |
| `hx.action.pane_adopt` | Adopt an orphaned pane |
| `hx.action.pane_close` | Close current float or split pane |
| `hx.action.pane_select_mode` | Enter pane select/swap mode |
| `hx.action.split_h` | Split horizontally |
| `hx.action.split_v` | Split vertically |
| `hx.action.split_resize` | Resize split (requires `dir`) |
| `hx.action.tab_new` | New tab |
| `hx.action.tab_next` | Next tab |
| `hx.action.tab_prev` | Previous tab |
| `hx.action.tab_close` | Close current tab |
| `hx.action.float_toggle` | Toggle named float (requires `float`) |
| `hx.action.float_nudge` | Move float (requires `dir`) |
| `hx.action.focus_move` | Move focus (requires `dir`) |
| `hx.action.clipboard_copy` | Copy selection to clipboard |
| `hx.action.clipboard_request` | Paste from clipboard |
| `hx.action.system_notify` | Send a system notification |
| `hx.action.sprite_toggle` | Toggle Pokemon sprite overlay |

**Actions that take parameters:**

```lua
{ key = { ... }, action = { type = hx.action.float_toggle, float = "1" } }
{ key = { ... }, action = { type = hx.action.focus_move,   dir = "left" } }
{ key = { ... }, action = { type = hx.action.split_resize, dir = "up" } }
{ key = { ... }, action = { type = hx.action.float_nudge,  dir = "down" } }
```

---

## `mode`

Controls what happens to the key after the bind fires:

| Mode | Description |
|---|---|
| `hx.mode.act_and_consume` | Run action, swallow the key (default) |
| `hx.mode.act_and_passthrough` | Run action AND forward key to pane |
| `hx.mode.passthrough_only` | Forward key to pane, no action |

```lua
-- default: key is consumed
{ key = { hx.key.ctrl, hx.key.alt, hx.key.t }, action = { type = hx.action.tab_new } }

-- passthrough: forward to pane, no action
{ key = { hx.key.ctrl, hx.key.alt, hx.key.up }, mode = hx.mode.passthrough_only,
  when = { any = { "fg:nvim", "fg:vim" } } }

-- both: run action and also send key into pane
{ key = { ... }, mode = hx.mode.act_and_passthrough, action = { type = hx.action.sprite_toggle } }
```

Keys without any binding always pass through unchanged.

---

## `when`

Optional condition that must be true for the bind to fire.

**String shorthand** (single token):

```lua
when = "focus_split"
when = "focus_float"
```

**Table form** — `any` (OR) or `all` (AND):

```lua
when = { any = { "fg:nvim", "fg:vim" } }
when = { all = { "focus_split", "fg:nvim" } }
```

**Shell/script conditions:**

```lua
when = { bash = "[[ -n $SSH_CONNECTION ]]" }
when = { lua  = function(ctx) return ctx.last_status ~= 0 end }
when = { env  = "MY_VAR" }       -- set and non-empty
when = { env_not = "MY_VAR" }    -- not set or empty
```

**Available tokens:**

| Token | Meaning |
|---|---|
| `focus_split` | Focused pane is a split |
| `focus_float` | Focused pane is a float |
| `fg:nvim` | Foreground process matches `nvim` |
| `fg:vim` | Foreground process matches `vim` |
| `float_sticky` | Current float has sticky attribute |
| `float_exclusive` | Current float has exclusive attribute |
| `float_per_cwd` | Current float has per_cwd attribute |
| `float_global` | Current float has global attribute |
| `float_isolated` | Current float has isolated attribute |
| `float_destroyable` | Current float has destroy attribute |
| `process_running` | A process is running in focused pane |
| `alt_screen` | Terminal is in alt-screen mode |
| `has_selection` | Active text selection |
| `adhoc_float` | An ad-hoc float is open |
| `named_float` | A named float is open |
| `tabs_gt1` | More than one tab open |

---

## Common patterns

### Nvim passthrough

Pass `Ctrl+Alt+Arrow` through to nvim/vim, otherwise move focus:

```lua
-- passthrough first (evaluated before the fallback)
{ key = { hx.key.ctrl, hx.key.alt, hx.key.up },    when = { any = {"fg:nvim","fg:vim"} }, mode = hx.mode.passthrough_only },
{ key = { hx.key.ctrl, hx.key.alt, hx.key.down },  when = { any = {"fg:nvim","fg:vim"} }, mode = hx.mode.passthrough_only },
{ key = { hx.key.ctrl, hx.key.alt, hx.key.left },  when = { any = {"fg:nvim","fg:vim"} }, mode = hx.mode.passthrough_only },
{ key = { hx.key.ctrl, hx.key.alt, hx.key.right }, when = { any = {"fg:nvim","fg:vim"} }, mode = hx.mode.passthrough_only },

-- fallback: move mux focus
{ key = { hx.key.ctrl, hx.key.alt, hx.key.up },    action = { type = hx.action.focus_move, dir = "up" } },
{ key = { hx.key.ctrl, hx.key.alt, hx.key.down },  action = { type = hx.action.focus_move, dir = "down" } },
{ key = { hx.key.ctrl, hx.key.alt, hx.key.left },  action = { type = hx.action.focus_move, dir = "left" } },
{ key = { hx.key.ctrl, hx.key.alt, hx.key.right }, action = { type = hx.action.focus_move, dir = "right" } },
```

Binds are evaluated in order — first match wins.

### Context-sensitive split/float

```lua
-- split only when a split is focused
{ key = { hx.key.ctrl, hx.key.alt, hx.key.h }, when = "focus_split", action = { type = hx.action.split_h } },
{ key = { hx.key.ctrl, hx.key.alt, hx.key.v }, when = "focus_split", action = { type = hx.action.split_v } },
```

### Float toggles

```lua
{ key = { hx.key.ctrl, hx.key.alt, hx.key["1"] }, action = { type = hx.action.float_toggle, float = "1" } },
{ key = { hx.key.ctrl, hx.key.alt, hx.key["2"] }, action = { type = hx.action.float_toggle, float = "2" } },
{ key = { hx.key.ctrl, hx.key.alt, hx.key["0"] }, action = { type = hx.action.float_toggle, float = "p" } },
```

The `float` value must match the `key` field of a float defined in your layout.

---

## Terminal support

Hexa enables the kitty keyboard protocol on startup. Terminals that support it send structured key events (including modifiers on arrows, etc.). Terminals that don't fall back to legacy escape sequences — most binds still work.

**Key forwarding for passthrough modes** translates to legacy sequences:
- Arrow keys with mods → `ESC [ 1 ; <mod> A/B/C/D`
- Ctrl+letter → control character (0x01–0x1A)
- Alt+key → ESC prefix
- Shift+Tab → `ESC [ Z`

---

## Conditions in status bar and prompt

`when` is also used in status bar segments and shell prompt segments. See [statusbar](statusbar.md) for the full token list available in those contexts.
