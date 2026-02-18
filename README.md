# Hexe

A terminal multiplexer, session manager, and shell prompt renderer jammed into one.

Hexe is built around a flipped architecture: the UI is disposable, your shells are not.
Crash the UI, restart it, reattach, keep going.

---

## What you get

- A fast terminal multiplexer (`hexe mux`) with tabs, splits, floats, popups, and notifications.
- A session daemon (`hexe ses`) that tracks sessions, panes, and layouts.
- Per-pane pods (`hexe pod`) that own PTYs, keep processes alive, and buffer output.
- A prompt renderer (`hexe shp`) that can power your shell prompt and mux status bar.

---

## Architecture (the cool part)

Traditional multiplexers often tie UI and process ownership together.
If the UI dies at the wrong time, you lose state or your PTYs get stuck.

Hexe splits responsibilities on purpose:

- `hexe mux` (UI)
  - Rendering, tabs/splits layout, keybinds, mouse handling
  - Runs Ghostty VT state per pane
  - Safe to restart

- `hexe pod` (one per pane)
  - Owns the PTY master file descriptor
  - Spawns/holds the shell process
  - Continuously drains PTY output so processes do not block
  - Buffers scrollback so detach/reattach does not lose history

- `hexe ses` (registry)
  - Knows what panes exist and where their pods are
  - Stores detached session layouts
  - Periodically persists state so a daemon crash is survivable

This is the foundation for:

- Persistent scrollback
- Surviving mux crashes
- Detach/reattach without killing your shell processes

---

## Features

### Multiplexer (mux)

- Tabs
- Splits
- Floating panes (see dedicated section below)
- Pane adoption
  - Adopt an orphaned pane into the current mux
  - Swap panes or destroy the current pane during adopt
- Detach and reattach sessions
- Notifications and popup UI
  - Confirm dialogs
  - Picker/choose dialogs
  - Pane-level and mux-level notifications

### Keybindings

Keybindings are configured in Lua under `mux.input.binds`.

See `docs/keybindings.md`.

### Floats

Floats are overlay panes that appear on top of your splits. They are toggled via `Alt+<key>` bindings and support several powerful behaviors.

#### Float Settings

Each float can be configured with these settings:

| Setting | Default | Description |
|---------|---------|-------------|
| `key` | required | Keybinding (e.g., `f` for `Alt+f`) |
| `command` | shell | Command to run (null = default shell) |
| `pwd` | false | Each directory gets its own instance |
| `sticky` | false | Survives mux restarts |
| `special` | true | Global float (false = tab-bound) |
| `destroy` | false | Kill float when hidden |
| `alone` | false | Hide all other floats when shown |

#### pwd: Directory-Specific Floats

When `pwd: true`, each directory gets its own independent instance of the float.

- Toggle `Alt+f` in `/home/user/project-a` → opens float A
- Toggle `Alt+f` in `/home/user/project-b` → opens float B (different instance)
- Go back to `/home/user/project-a` and toggle → shows float A again

This is useful for tools like fzf, file browsers, or any context where you want per-directory state.

#### sticky: Persistent Floats

When `sticky: true`, the float survives mux restarts.

- You open a sticky float in `/home/user/project`
- You exit the mux (or it crashes)
- You start a new mux in the same directory
- The float is automatically restored with its full state

Sticky floats are matched by directory + key combination. The session daemon keeps them alive in a half-attached state until a new mux reclaims them.

Combine with `pwd: true` for directory-specific persistent floats.

#### special: Global vs Tab-Bound

- `special: true` (default): Float is global, visible across all tabs. Uses a per-tab visibility bitmask.
- `special: false`: Float is bound to the tab it was created on. Only visible on that tab.

Note: `pwd` floats are always global regardless of this setting.

#### destroy: Auto-Cleanup

When `destroy: true`, the float is killed when hidden instead of just becoming invisible.

- Only applies to tab-bound floats (`special: false`, `pwd: false`)
- Useful for one-shot commands or dialogs
- Pwd and special floats ignore this setting (they need persistence)

#### alone: Modal Mode

When `alone: true`, showing this float automatically hides all other floats on the current tab.

Useful for creating modal-like overlays that demand focus.

#### Sizing and Position

Floats support percentage-based layout:

| Setting | Default | Description |
|---------|---------|-------------|
| `width` | 60 | Width as % of terminal (10-100) |
| `height` | 60 | Height as % of terminal (10-100) |
| `pos_x` | 50 | Horizontal position (0=left, 50=center, 100=right) |
| `pos_y` | 50 | Vertical position (0=top, 50=center, 100=bottom) |
| `padding_x` | 1 | Left/right padding inside border |
| `padding_y` | 0 | Top/bottom padding inside border |

#### Border Style

Each float can have custom border characters and colors:

```json
{
  "style": {
    "top_left": "╭",
    "top_right": "╮",
    "bottom_left": "╰",
    "bottom_right": "╯",
    "horizontal": "─",
    "vertical": "│"
  },
  "color": {
    "active": 2,
    "passive": 8
  }
}
```

You can also embed a status module in the border:

```json
{
  "style": {
    "position": "topcenter",
    "module": "time"
  }
}
```

Positions: `topleft`, `topcenter`, `topright`, `bottomleft`, `bottomcenter`, `bottomright`

#### Example Configuration

```json
{
  "floats": [
    {
      "key": "f",
      "command": "fzf",
      "pwd": true,
      "sticky": true,
      "width": 80,
      "height": 70
    },
    {
      "key": "g",
      "command": "lazygit",
      "pwd": true,
      "sticky": true,
      "width": 90,
      "height": 90
    },
    {
      "key": "t",
      "special": false,
      "destroy": true,
      "width": 40,
      "height": 30,
      "pos_x": 100,
      "pos_y": 0
    },
    {
      "key": "h",
      "command": "hexe-help",
      "alone": true,
      "width": 70,
      "height": 50
    }
  ]
}
```

This gives you:

- `Alt+f`: fzf with per-directory instances that persist across restarts
- `Alt+g`: lazygit with per-directory instances that persist across restarts
- `Alt+t`: A tab-local scratch terminal in the top-right that dies when hidden
- `Alt+h`: A help overlay that hides everything else when shown

#### Float Defaults

The first entry in `floats` without a `key` field sets defaults for all floats:

```json
{
  "floats": [
    {
      "width": 60,
      "height": 60,
      "padding_x": 1,
      "padding_y": 0,
      "color": { "active": 2, "passive": 8 }
    },
    { "key": "f", "command": "fzf", "pwd": true },
    { "key": "g", "command": "lazygit", "pwd": true }
  ]
}
```

### Persistent scrollback

Hexe keeps scrollback even across detach/reattach.

How:

- Pods continuously record PTY output into a ring buffer.
- On reattach, mux reconnects to the pod and replays backlog.
- Ghostty VT rebuilds the terminal history from the replayed stream.

Result: detach, do work, reattach, and your output is still there.

### Clipboard and OSC

Hexe runs a VT inside mux, which means control sequences like OSC are not automatically visible to the host terminal.

Hexe forwards important OSC sequences to the host terminal, including:

- OSC 52 clipboard
- OSC 4 / 10-19 / 104 / 110-119 color palette sequences (pywal-friendly)
- OSC 0/1/2 title/icon
- OSC 7 cwd URL

Color queries:

- If an app inside a pane asks the terminal for colors (OSC color queries), Hexe forwards the query to the host terminal and routes the reply back into the correct pane.

### Colors (pywal-friendly)

Hexe preserves 256-color palette indices (SGR 38;5 / 48;5).
This matters because tools like pywal update the host terminal palette and then expect applications to keep using palette indices.

If you use scripts that emit OSC 4/10/11 etc (pywal and friends), Hexe forwards those sequences so the host terminal palette updates live.

### Shell prompt renderer (shp)

Hexe includes a prompt renderer you can use for bash, zsh, and fish.

- Left and right prompt rendering
- Segment system (git, directory, time, cpu, memory, battery, jobs, duration, etc.)
- Used by the mux status bar too

---

## Getting started

### Build

Hexe is a Zig project.

Always build with ReleaseFast:

- zig build -Doptimize=ReleaseFast

### Run

Start the session daemon:

- hexe ses daemon

Start a mux:

- hexe mux new

Detach (keeps panes alive), then reattach:

- hexe mux attach <session-uuid-or-prefix>

List what is available to attach:

- hexe mux list

---

## Configuration

Config is read from:

- `$XDG_CONFIG_HOME/hexe/init.lua` (if `XDG_CONFIG_HOME` is set)
- `~/.config/hexe/init.lua` (default)
- `./.hexe.lua` (optional local override in current directory)

State is stored under XDG state home (by default):

- ~/.local/state/hexe/

---

## Project status

This is a new project and it moves fast.

- Backwards compatibility is not a goal.
- The architecture is intentionally aggressive.
- If something feels like it should be simpler, it probably should be.

---

## History (or: How We Got Here)

This thing has been in the making for a few years now, but always as a stupid personal project that I kept coming back to.

It started as bash and Python hacks wrapped around tmux. Absolutely cursed code. Shell scripts spawning tmux sessions, Python daemons talking to tmux through tmux send-keys, config files that were basically just more shell scripts. It was crazy. But it worked, and it was amazing - I could finally have the workflow I wanted.

At some point I decided to write a real version. Picked Rust, found the tmux-rs crate. Great experience, learned a lot about terminal internals, got pretty far with it. But that crate is basically all unsafe rust - you're still fundamentally building on top of tmux's architecture, not escaping it.

Then Ghostty came out and I saw what Mitchell was doing with Zig for terminal emulation. Said ok, full rewrite and rebuilt everything from scratch. Zero regrets. Zig is a joy to work with, Ghostty's VT implementation is rock solid, and I finally got to build the architecture I actually wanted instead of fighting someone else's.

Also - real talk - having AI assistants that can help convert concepts between languages has been a game changer. Half of the tricky bits in here started as: here is how this worked in Rust, how do I do it idiomatically in Zig?

---

## Credits

- Zig
- ghostty-vt (terminal emulation)

---

## Notes

- Clipboard: OSC 52 is forwarded to the host terminal. Hexe also attempts to set the system clipboard via wl-copy (Wayland) or xclip/xsel (X11) when available.
- Hyperlinks (OSC 8): full hyperlink rendering requires renderer-level support because Hexe renders from cells rather than passing through the raw byte stream.
