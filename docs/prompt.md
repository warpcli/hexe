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
    lua = "return ctx.env.SSH_CONNECTION and '//' or nil",
    outputs = {
      { style = "bg:237 fg:15", format = " $output " },
    },
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

## Segment Model

Each prompt side is an array of segment definitions.

```lua
{
  name     = "directory",       -- built-in segment name
  priority = 50,                 -- lower = kept longer when width is tight
  command  = "echo hello",      -- optional shell command output
  lua      = "return 'hello'",  -- optional Lua output (preferred)
  when     = { ... },            -- optional condition
  outputs  = {
    { style = "bg:1 fg:0", format = " $output " },
  },
}
```

Notes:

- `lua` and `command` are mutually practical choices; use one output source.
- `outputs` is required for visible rendering.
- `$output` is replaced with the segment output.

## Output Execution Paths

### `lua = "..."` (in-process)

Lua output runs inside Hexe (no shell subprocess). The chunk must `return` a value.

Return behavior:

- `string` -> used as output
- `number` -> converted to text
- `boolean true` -> rendered as `"true"`
- `nil` / `false` / other types -> treated as empty (segment hidden)

### `command = "..."` (shell subprocess)

Runs via `/bin/bash -c` in parallel with other command segments. Stdout is trimmed and used as output on exit code `0`.

## Conditions (`when`)

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

Fast env-gated segment:

```lua
{
  name = "ssh",
  priority = 30,
  when = { env = "SSH_CONNECTION" },
  command = "echo //",
  outputs = {
    { style = "bg:237 fg:15", format = " $output" },
  },
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
