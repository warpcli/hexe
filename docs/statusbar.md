# Mux Status Bar (`mux.tabs.status`)

This page documents the mux status bar system.

For shell prompt details, see `docs/prompt.md`.

## Configure Status Bar

```lua
local hx = require("hexe")

hx.mux.config.setup({
  tabs = {
    status = {
      enabled = true,
    },
  },
})

hx.mux.tabs.add_segment("left", {
  name = "session",
  outputs = {
    { style = "bg:237 fg:15", format = " $output " },
  },
})
```

You can also provide arrays with `left`, `center`, `right` using your preferred config style.

## Segment Schema

```lua
{
  name     = "tabs",
  priority = 50,
  command  = "echo hello",      -- optional shell command output
  lua      = "return 'hello'",  -- optional Lua output (in-process)
  on_click = "hexe pod record --name mypod --out /tmp/mypod.cast",
  on_right_click = "hexe mux notify \"clicked\"",
  on_middle_click = "hexe pod gc --dry-run",

  -- optional sugar section
  button = {
    on_click = "hexe pod record --name mypod --out /tmp/mypod.cast",
    on_right_click = "pkill -f 'hexe pod record --name mypod'",
    active_when = "pgrep -f -- 'hexe pod record --name mypod' >/dev/null",
  },
  when     = { ... },
  outputs  = {
    { style = "bg:1 fg:0", format = " $output " },
  },

  -- tabs-only styling fields:
  active_style    = "bg:1 fg:0",
  inactive_style  = "bg:237 fg:250",
  separator       = " | ",
  separator_style = "fg:7",
  tab_title       = "basename", -- or "name"
  left_arrow      = "",
  right_arrow     = "",

  -- optional spinner object (module-level animation):
  spinner = {
    kind = "knight_rider",
    width = 8,
    step_ms = 75,
    hold_frames = 9,
    trail_len = 6,
    colors = { 1, 3, 5 },
  },
}
```

`on_click`, `on_right_click`, and `on_middle_click` run shell commands on statusbar clicks.

Clickable segments are treated as buttons and automatically render with reverse colors while hovered.

If `button.active_when` is set and returns success, the button stays reversed while active; on hover it flips back (opposite visual) to indicate a deactivate click.

## Built-in Status Segments

Common built-ins used by the status bar:

- `tabs`
- `session`
- `directory`
- `git_branch`
- `git_status`
- `jobs`
- `duration`
- `status`
- `sudo`
- `pod_name`
- `hostname`
- `username`
- `time`
- `cpu`
- `memory`
- `netspeed`
- `battery`
- `uptime`
- `last_command`
- `running_anim` (and named variants)
- `randomdo`
- `spinner`

## Conditions (`when`) in Status Bar

Status bar supports token and script conditions.

### Token conditions

```lua
when = { all = { "process_running", "not_alt_screen" } }
when = { any = { "focus_float", "tabs_gt1" } }
```

Common tokens:

- shell state: `process_running`, `not_process_running`, `alt_screen`, `not_alt_screen`, `jobs_nonzero`, `has_last_cmd`, `last_status_nonzero`
- focus state: `focus_float`, `focus_split`
- float attributes: `float_destroyable`, `float_exclusive`, `float_sticky`, `float_per_cwd`, `float_global`, `float_isolated`, `adhoc_float`, `named_float`
- tabs: `tabs_gt1`, `tabs_eq1`

### Script conditions

```lua
when = { bash = "[[ $HEXE_STATUS_ALT_SCREEN -eq 0 ]]" }
when = { lua  = "return ctx.shell_running and not ctx.alt_screen" }
```

`when.lua` is evaluated with a statusbar `ctx` table:

- `ctx.shell_running`
- `ctx.alt_screen`
- `ctx.jobs`
- `ctx.last_status`
- `ctx.exit_status`
- `ctx.last_command`
- `ctx.cwd`
- `ctx.home`
- `ctx.cmd_duration_ms`
- `ctx.terminal_width`
- `ctx.now_ms`
- `ctx.env`

Condition evaluation is cached internally:

- Lua conditions: short TTL (fast re-use)
- Bash conditions: longer TTL and timeout guard

You can adjust bash condition timeout via `HEXE_CONDITION_TIMEOUT` (ms, clamped to safe range).

## Lua Output in Statusbar Segments

Statusbar now supports the same output model as prompt segments:

- `lua = "return ..."` (in-process Lua)
- `command = "..."` (shell subprocess)

`lua` output return behavior:

- `string` -> rendered text
- `number` -> rendered text
- `boolean true` -> `"true"`
- `nil` / `false` / unsupported types -> empty output

Example:

```lua
{
  name = "virt",
  lua = [[
    local p = io.popen("systemd-detect-virt 2>/dev/null")
    if not p then return nil end
    local v = (p:read("*a") or ""):match("^%s*(.-)%s*$")
    p:close()
    if v == "" or v == "none" then return nil end
    return v == "lxc" and " >> " or " :: "
  ]],
  outputs = {
    { style = "bg:5 fg:0", format = "$output" },
  },
}
```

## Width and Priority

Status bar layout is three-zone:

- left
- center (usually `tabs`, truly centered)
- right

Left and right modules are width-budgeted and priority-sorted.

- lower `priority` value means it survives longer when space is tight
- center tabs are rendered after side zones and can visually win overlaps

## Tabs Styling Example

```lua
{
  name = "tabs",
  active_style = "bg:1 fg:0 bold",
  inactive_style = "bg:237 fg:8",
  separator = "│",
  separator_style = "fg:7",
  tab_title = "basename",
  left_arrow = "",
  right_arrow = "",
  outputs = {
    { style = "", format = "$output" },
  },
}
```

## Notification Layer (not a segment)

Status-area notifications are configured separately from segment lists:

```lua
hx.mux.config.setup({
  notifications = {
    mux = {
      fg = 0,
      bg = 3,
      bold = true,
      padding_x = 1,
      padding_y = 0,
      offset = 1,
      alignment = "center",
      duration_ms = 3000,
    },
  },
})
```

Send with CLI:

```sh
hexe mux notify "Build complete"
hexe mux notify --broadcast "Deploying..."
```
