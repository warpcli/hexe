# Float attributes

This document describes float *attributes* under `floats[].attributes` in your mux config (`init.lua`).

Each float definition can declare a set of boolean attributes:

```json
{
  "key": "f",
  "command": "btop",
  "attributes": {
    "exclusive": true,
    "global": true,
    "per_cwd": false,
    "sticky": false,
    "destroy": false
  }
}
```

The first float entry (the one with no `key`) can also provide *default attributes*.
Those defaults are applied to every keyed float unless that float overrides the value.

## exclusive

When `exclusive` is true, showing this float will hide all other floats on the current tab.

Notes:
- This is currently one-way: hidden floats stay hidden until you toggle them back on.

Use cases:
- A "main tool" float (like `btop`) where you want a clean focus mode.
- A distraction-free scratch terminal.

## per_cwd

When `per_cwd` is true, the float is "one instance per working directory".

What this means in practice:
- If you open the float in `/repo/a`, it creates (or reuses) the `/repo/a` instance.
- If you open the same key in `/repo/b`, it creates (or reuses) a different instance.

Use cases:
- Project-scoped tools: `lazygit`, `opencode`, `nvim`, a repo-specific shell.
- Anything where you want separate state per project.

## sticky

When `sticky` is true, ses will preserve the float across mux restarts.

Use cases:
- A long-running monitor (e.g. `btop`) that you want to keep around.
- A background REPL.

## global

Controls whether the float is global (not tab-bound) or tab-bound.

- `global: true` means the float is not owned by a single tab.
  Visibility is tracked per-tab.
- `global: false` means the float is tab-bound (owned by the current tab).
  Closing that tab will also close the float.

Default:
- `global` defaults to `false` (tab-bound) unless you set it to `true`.

Use cases:
- Global: tools you want available on multiple tabs.
- Tab-bound: scratch tools that should die with the tab.

## destroy

When `destroy` is true, hiding the float should kill the underlying process.

Notes:
- This is generally not meaningful together with `per_cwd`.
- It is often not what you want together with `sticky`.

Use cases:
- Fire-and-forget tools.
- A float that runs a command and you never want it to keep state.
