# Float attributes

Detailed reference for float behavior flags under `floats[].attributes`.

For the full float guide (sizing, borders, layout, CLI) see [floats.md](floats.md).

---

## Setting attributes

```lua
hx.ses.layout.define({
  floats = {
    {
      key     = "f",
      command = "btop",
      attributes = {
        exclusive = true,
        global    = true,
        per_cwd   = false,
        sticky    = false,
        destroy   = false,
        isolated  = false,
      },
    },
  },
})
```

The first float entry (no `key`) can provide default attributes for all floats. Defaults are additive — they can turn attributes on but not force them off for keyed floats.

---

## `exclusive`

When shown, this float hides all other floats on the current tab.

- The hidden floats stay hidden until you toggle them back individually
- Useful for modal-style focus (e.g. `btop` monitor, distraction-free scratch terminal)

## `per_cwd`

One float instance per working directory.

- Toggle the key in `/repo/a` → creates or reuses the `/repo/a` instance
- Toggle the same key in `/repo/b` → different instance, separate state
- Navigate back to `/repo/a` → same instance resumes where you left off

Use for project-scoped tools: `lazygit`, `nvim`, `opencode`, language REPLs.

## `sticky`

The float survives mux exits and restarts.

- On detach or mux exit, ses keeps the pod alive in a half-attached state
- A new mux automatically reclaims it on reattach
- Matched by directory + key combination

Does not combine meaningfully with `destroy` (a sticky float that destroys itself on hide loses all persistence benefit).

## `global`

Controls tab ownership.

- `global = true`: Float is not owned by any tab. Visibility is tracked per-tab via a bitmask. Toggling from any tab shows/hides it on that tab.
- `global = false` (default): Float is bound to the tab it was created in. Closing that tab destroys the float.

`per_cwd` floats are always treated as global regardless of this setting.

## `destroy`

The float process is killed when the float is hidden.

- Only meaningful for tab-bound, non-`per_cwd` floats
- Use for fire-and-forget commands or single-run dialogs
- Combining with `sticky` or `per_cwd` has no effect (those modes require persistence)

## `isolated`

The float runs inside a sandboxed pod.

- Uses Linux namespaces (user, PID, mount) and optionally cgroups
- Configure the isolation level and resource limits via `isolation = { profile = "...", ... }`

See [isolation.md](isolation.md) for profiles and limits.
