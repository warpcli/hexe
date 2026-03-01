# Shell Prompt (`shp`) Infrastructure

This document covers how Hexe prompt rendering works end-to-end, including Lua execution, conditions, config layering, and module behavior.

## Quick Start

Enable prompt hooks in your shell:

```sh
# bash
eval "$(hexe shp init bash)"

# zsh
eval "$(hexe shp init zsh)"

# fish
hexe shp init fish | source
```

Define segments in `~/.config/hexe/init.lua`:

```lua
local hx = require("hexe")

hx.shp.prompt.left({
  {
    name = "ssh",
    priority = 50,
    value = function(ctx)
      if not ctx.env.SSH_CONNECTION then
        return nil
      end
      return { { text = " //", style = "bg:237 fg:15" } }
    end,
  },
})
```

## Config Sources and Precedence

Prompt loading order:

1. Global config: `~/.config/hexe/init.lua`
2. Optional local override: `./.hexe.lua`

For SHP, local `./.hexe.lua` can override prompt arrays via table form:

```lua
return {
  shp = {
    prompt = {
      left = { ... },
      right = { ... },
    },
  },
}
```

## Segment Model (Lua-first)

Each prompt side is an array of segment definitions.

```lua
{
  name     = "directory",       -- built-in segment name
  priority = 50,                 -- lower = kept longer when width is tight

  -- value segment
  value = function(ctx)
    return { { text = " hello ", style = "bg:1 fg:0" } }
  end,

  -- or builtin segment descriptor
  builtin = function(ctx)
    return { name = "directory", style = "bg:237 fg:15", suffix = " " }
  end,

  -- optional click behavior
  button = {
    on_left_click = "hexe record toggle --scope pod --out /tmp/pod.cast",
    on_right_click = "hexe record stop --scope pod --out /tmp/pod.cast",
    active_when = "test \"$(hexe record status --scope pod 2>/dev/null)\" = 1",
    inverse_on_hover = true,
  },

  -- optional progress behavior
  progress = {
    every_ms = 1000,
    show_when = function(ctx) return (ctx.jobs or 0) > 0 end,
    value = function(ctx) return tostring(ctx.jobs or 0) end,
  },
}
```

Notes:

- Kind is inferred from fields (`value`, `builtin`, `button`, `progress`); no `kind` field is required.
- `outputs` is not used in the Lua-first prompt model.

## Output Execution Paths

### `value = ...` (in-process)

`value` runs inside Hexe and must return a value.

Return behavior:

- `string` -> used as output
- `number` -> converted to text
- `boolean true` -> rendered as `"true"`
- `nil` / `false` / other types -> treated as empty (segment hidden)

### `builtin = ...` (descriptor)

`builtin` returns a descriptor table:

- `name` (required): builtin segment name (for example `git_branch`, `git_status`, `directory`)
- `style`: descriptor style override
- `prefix` / `suffix`: wrapper text around builtin output

Style behavior:

- If descriptor `style` is provided, it is authoritative for rendered builtin text.
- This is useful when you want fixed colors (for example black-on-red git segments).

## Conditions (`when`) [legacy parser path]

The current Lua-first prompt model typically encodes visibility directly in `value`/`builtin` functions (return `nil` to hide). Older table-style parser paths still support `when` fields.

Prompt supports these condition forms:

```lua
when = { env = "SSH_CONNECTION" }
when = { env_not = "INSIDE_CONTAINER" }
when = { bash = "[[ -n $SSH_CONNECTION ]]" }
when = { lua = "return (ctx.exit_status or 0) ~= 0" }
when = { all = { "token_a", "token_b" } }
when = { any = { "token_a", { lua = "return true" } } }
```

`when.lua` must return boolean.

## Lua Context (`ctx`)

Prompt Lua (`lua` field and `when.lua`) gets a global `ctx` table:

- `ctx.cwd`
- `ctx.home`
- `ctx.exit_status`
- `ctx.cmd_duration_ms`
- `ctx.jobs`
- `ctx.terminal_width`
- `ctx.now_ms`
- `ctx.env` (environment map: `ctx.env.NAME`)

Example:

```lua
lua = [[
  if (ctx.exit_status or 0) ~= 0 then
    return "ERR"
  end
  return nil
]]
```

## Lua Safety Modes

Hexe Lua runtime has two modes:

- Safe mode (default): no `io`, no `os`, restricted `require`
- Unsafe mode: enable with `HEXE_UNRESTRICTED_CONFIG=1`

Unsafe mode enables `io`, `os`, and package loading from config paths.

### `require()` behavior

Safe mode:

- only `require("hexe")` is allowed

Unsafe mode package search paths:

- `${XDG_CONFIG_HOME}/hexe/lua/?.lua`
- `${XDG_CONFIG_HOME}/hexe/lua/?/init.lua`

If `XDG_CONFIG_HOME` is unset, `~/.config/hexe` is used.

Native C modules are disabled (`package.cpath = ""`).

## Width and Priority Behavior

Prompt rendering uses width budgeting per side:

- left prompt budget: half terminal width
- right prompt budget: half terminal width

If segments exceed budget, higher priority numbers are hidden first. Lower numbers stay visible longer.

## Built-in Prompt Segments

Common built-ins used in prompt:

- `directory`
- `git_branch`
- `git_status`
- `status`
- `sudo`
- `jobs`
- `duration`
- `pod_name`
- `hostname`
- `username`
- `character`

## Practical Patterns

Pure Lua segment:

```lua
{
  name = "virt",
  priority = 40,
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

Builtin descriptor segment:

```lua
{
  name = "git_status",
  priority = 5,
  builtin = function(_)
    return { name = "git_status", style = "bg:1 fg:0", suffix = " " }
  end,
}
```

## Troubleshooting

- Lua segment not rendering:
  - check return value (must resolve to supported output type)
  - check for runtime errors in config
- if using `io`/`os`, ensure `HEXE_UNRESTRICTED_CONFIG=1`
- `require("my_module")` fails:
  - verify module exists under `~/.config/hexe/lua/...`
  - verify unsafe mode is enabled
- Segment disappears unexpectedly:
  - check `priority` and terminal width budget
  - check `when` conditions
