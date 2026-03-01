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

## Segment Schema (Lua-first)

```lua
{
  name     = "tabs",
  priority = 50,
  -- value segment (text or styled blocks)
  value = function(ctx)
    return {
      { text = " ", style = "bg:237 fg:250" },
      { text = os.date("%H:%M:%S"), style = "bold bg:237 fg:250" },
      { text = " ", style = "bg:237 fg:250" },
    }
  end,

  -- builtin segment (descriptor)
  builtin = function(ctx)
    return { name = "session", style = "bg:1 fg:0", prefix = " ", suffix = " " }
  end,

  -- optional click behavior
  button = {
    on_left_click = "hexe record toggle --scope pod --out /tmp/pod.cast",
    on_right_click = "hexe record stop --scope pod --out /tmp/pod.cast",
    active_when = "test \"$(hexe record status --scope pod 2>/dev/null)\" = 1",
    left_style = "bg:2 fg:0",
    middle_style = "bg:3 fg:0",
    right_style = "bg:1 fg:0",
    inverse_on_hover = true,
  },

  -- optional structured progress behavior
  progress = {
    every_ms = 1000,
    show_when = function(ctx) return ctx.jobs > 0 end,
    value = function(ctx) return tostring(ctx.jobs) end,
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

Kind is inferred from fields (`value`, `builtin`, `button`, `progress`); you do not need to set a `kind` field.

Unlike prompt, statusbar is not builtin-allowlisted: statusbar can use `value`, `builtin`, `button`, and `progress` segment kinds and full statusbar builtins (including `spinner`).

`on_click`, `on_right_click`, and `on_middle_click` run shell commands on statusbar clicks.

Clickable segments are treated as buttons and automatically render with reverse colors while hovered.

If `button.active_when` is set and returns success, the button stays reversed while active; on hover it flips back (opposite visual) to indicate a deactivate click.

Button click-state behavior:

- First click (left/middle/right) sets a clicked state for that button.
- Clicked state style can be set per button via `left_style`, `middle_style`, and `right_style` (or top-level aliases `button_left_style`, `button_middle_style`, `button_right_style`).
- When hovered while clicked, style is inverted if `inverse_on_hover = true`.
- Clicking the same button again unclicks (toggle off).
- If already clicked with one button, clicking a different button unclicks (does not switch to the other clicked state).

When using Lua config helpers, `hx.record.status({ scope = "pod" })` now returns a table like `{ active = true|false, scope = "pod", pid = ..., out = "...", started_ms = ... }`.

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
when = { lua  = function(ctx) return ctx.shell_running and not ctx.alt_screen end }
```

`when.lua` is evaluated with a statusbar `ctx` table.

`when.lua` must be a callback (`lua = function(ctx) ... end`). String-chunk form is no longer supported.

`ctx.pane(0)` returns the current focused pane state (same table as `ctx`).

Available fields in `ctx`:

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

Common pane fields include `focus_split`, `focus_float`, `process_name`, and `process_running`.

Condition evaluation is cached internally:

- Lua conditions: short TTL (fast re-use)
- Bash conditions: longer TTL and timeout guard

You can adjust bash condition timeout via `HEXE_CONDITION_TIMEOUT` (ms, clamped to safe range).

## Value/Builtin Output Model

`value` return behavior:

- `string` -> rendered text
- `number` -> rendered text
- `boolean true` -> `"true"`
- `nil` / `false` / unsupported types -> empty output

Example:

```lua
{
  name = "virt",
  value = function(_)
    local p = io.popen("systemd-detect-virt 2>/dev/null")
    if not p then return nil end
    local v = (p:read("*a") or ""):match("^%s*(.-)%s*$")
    p:close()
    if v == "" or v == "none" then return nil end
    if v == "lxc" then
      return { { text = " >> ", style = "bg:5 fg:0" } }
    end
    return { { text = " :: ", style = "bg:5 fg:0" } }
  end,
}
```

Builtin descriptor behavior:

- `name` selects a builtin segment renderer.
- `style` applies to descriptor-added prefix/suffix.
- `prefix`/`suffix` wrap the builtin output.
- For spinner builtin descriptors, optional fields `kind`, `width`, `step`/`step_ms`, `hold`/`hold_frames`, `colors`, `bg`, and `placeholder` are supported.
- Descriptor style is authoritative when provided (it does not merge with builtin segment style).

Convenience constructor:

```lua
builtin = function(_)
  return hexe.segment.builtin.git_status({
    style = "bg:1 fg:0",
    suffix = " ",
  })
end
```

Use `hexe.segment.builtin` (or `hx.segment.builtin`). The typo alias `hexe.segment.buildin` has been removed.

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
