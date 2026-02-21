# Status bar & prompt

Hexa has a unified segment system used in two places:

- **Mux status bar** (`mux.tabs.status`) — shown in the tab bar at the top
- **Shell prompt** (`shp.prompt`) — rendered by `hexe shp` in your shell

Both use the same segment format. The only difference is which condition providers are available.

---

## Status bar

Configure under `mux.tabs.status` in your mux config:

```lua
hx.mux.set({
  tabs = {
    status = {
      enabled = true,
      left   = { ... },
      center = { ... },
      right  = { ... },
    },
  },
})
```

Each of `left`, `center`, `right` is an array of segment definitions.

---

## Shell prompt

Configure under `shp.prompt`:

```lua
hx.shp.set({
  prompt = {
    left  = { ... },
    right = { ... },
  },
})
```

Initialize in your shell:

```sh
# bash
eval "$(hexe shp init bash)"

# zsh
eval "$(hexe shp init zsh)"

# fish
hexe shp init fish | source
```

---

## Segment format

```lua
{
  name     = "git_branch",       -- built-in or custom segment name
  priority = 50,                 -- 1–255, lower = hidden last when space is tight
  command  = nil,                -- custom command (overrides built-in)
  when     = { ... },            -- optional condition (see below)
  outputs  = {
    { style = "bg:1 fg:0 bold", format = " $output " },
  },
}
```

### `outputs`

Each output is a `{ style, format }` pair. `$output` is replaced with the segment's value.

**Style syntax:** space-separated tokens
- `bg:<n>` — background palette index or `bg:r,g,b` for RGB
- `fg:<n>` — foreground palette index or `fg:r,g,b` for RGB
- `bold`, `italic`, `underline`, `blink`, `reverse`, `strikethrough`

**Format** is a string with `$output` as a placeholder. Can include static text.

### `priority`

When the terminal is too narrow to show all segments, lower-priority segments are dropped first. Default is 50.

---

## Built-in segments

### Universal (statusbar + prompt)

| Name | Description |
|---|---|
| `directory` | Current working directory |
| `git_branch` | Git branch name |
| `git_status` | Git staged/unstaged/untracked counts |
| `character` | Shell prompt character (e.g., `❯`) |
| `time` | Current time |
| `status` | Last exit status code |
| `sudo` | Shows if sudo credentials are cached |
| `jobs` | Number of background jobs |
| `duration` | Duration of last command |
| `pod_name` | Name of the current pod |
| `hostname` | Hostname |
| `username` | Current user |
| `uptime` | System uptime |
| `battery` | Battery level |
| `last_command` | Name of last command |

### Statusbar-only

| Name | Description |
|---|---|
| `tabs` | Tab list with active indicator |
| `cpu` | CPU usage |
| `memory` | Memory usage |
| `netspeed` | Network throughput |
| `running_anim` | Running indicator (animated) |
| `running_anim/knight_rider` | Knight Rider animation |

### Animation params (query string syntax)

```lua
name = "running_anim/knight_rider?width=10&step=30&hold=20"
```

| Param | Default | Description |
|---|---|---|
| `width` | 8 | Width of animation in cells |
| `step` | 75 | Frame duration in ms |
| `hold` | 9 | Frames held at each end |
| `trail` | 6 | Trail length |

### Spinner (loading indicator)

Shown while a segment's command is running:

```lua
spinner = {
  kind        = "knight_rider",
  width       = 8,
  step_ms     = 75,
  hold_frames = 9,
  trail_len   = 6,
  colors      = { 1, 3, 5 },
},
```

### Custom commands

Run any shell command as a segment:

```lua
{
  name    = "my_thing",
  command = "cat /proc/loadavg | awk '{print $1}'",
  outputs = {
    { style = "bg:237 fg:3", format = "  $output " },
  },
}
```

The command output is used as `$output`.

---

## Conditions (`when`)

### In the statusbar

```lua
when = {
  hexe = { "process_running", "not_alt_screen" },
}
```

Available `hexe` tokens:

**Shell state:**
- `process_running` / `not_process_running`
- `alt_screen` / `not_alt_screen`
- `jobs_nonzero`
- `has_last_cmd`
- `last_status_nonzero`

**Mux state:**
- `focus_float` / `focus_split`
- `adhoc_float` / `named_float`
- `float_destroyable`, `float_exclusive`, `float_sticky`, `float_per_cwd`, `float_global`, `float_isolated`
- `tabs_gt1` / `tabs_eq1`

Bash or Lua conditions also work (rate-limited):

```lua
when = { bash = "[[ $TERM_PROGRAM == 'ghostty' ]]" }
when = { lua  = "return ctx.last_status ~= 0" }
```

Lua `ctx` in statusbar:
- `ctx.shell_running`, `ctx.alt_screen`, `ctx.jobs`
- `ctx.last_status`, `ctx.last_command`, `ctx.cwd`
- `ctx.now_ms`

### In the prompt

```lua
when = { bash = "[[ -n $SSH_CONNECTION ]]" }
when = { lua  = "return (ctx.exit_status or 0) ~= 0" }
```

Lua `ctx` in prompt:
- `ctx.cwd`, `ctx.exit_status`, `ctx.cmd_duration_ms`, `ctx.jobs`, `ctx.terminal_width`

---

## Tabs segment

The tab list segment has additional styling:

```lua
{
  name = "tabs",
  active_style   = "bg:1 fg:0 bold",
  inactive_style = "bg:237 fg:8",
  separator      = "│",
  separator_style = "bg:0 fg:237",
  tab_title      = "basename",   -- "name" or "basename"
  left_arrow     = "",
  right_arrow    = "",
},
```

---

## Notifications

Transient text notifications appear in the status bar area (not in a segment).

Configure under `mux.notifications`:

```lua
hx.mux.set({
  notifications = {
    mux = {
      fg          = 0,
      bg          = 3,
      bold        = true,
      padding_x   = 1,
      padding_y   = 0,
      offset      = 1,
      alignment   = "center",   -- left | center | right
      duration_ms = 3000,
    },
    pane = {
      -- same fields, offset is from bottom of pane
    },
  },
})
```

Send a notification from the CLI:

```sh
hexe mux notify "Build complete"
hexe mux notify --broadcast "Deploying..."
```
