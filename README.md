# Hexa

A terminal multiplexer where the UI is disposable and your shells are not.

Crash the mux, restart it, reattach — your terminals keep running exactly where you left them.

---

## How it works

Hexa splits into three cooperating processes:

- **`hexe mux`** — the UI (tabs, splits, floats, keybindings, status bar). Safe to kill and restart.
- **`hexe ses`** — a persistent registry that tracks sessions, panes, and layouts.
- **`hexe pod`** — one per pane. Owns the PTY, holds the shell, buffers output even while detached.

See [architecture](docs/architecture.md) for the full picture.

---

## Docs

| Topic | Description |
|---|---|
| [Architecture](docs/architecture.md) | How mux, ses, and pod fit together |
| [Sessions](docs/sessions.md) | Detach, reattach, layouts, pane adoption |
| [Floats](docs/floats.md) | Overlay panes — per-directory, persistent, isolated |
| [Float attributes](docs/float_attributes.md) | Detailed flag reference for float behavior |
| [Keybindings](docs/keybindings.md) | Binding system, actions, conditions, gestures |
| [Status bar & prompt](docs/statusbar.md) | Segments, animations, conditions |
| [Isolation](docs/isolation.md) | Linux namespace + cgroup sandboxing for panes |
| [Instances](docs/instances.md) | Running multiple independent stacks side by side |
| [Config](docs/config.md) | Full config reference |
| [CLI](docs/cli.md) | All commands and flags |
| [Sprites](docs/sprite.md) | Pokemon sprite overlays |

---

## Quick start

**Build** (requires Zig):

```sh
zig build -Doptimize=ReleaseFast
```

**Run:**

```sh
hexe mux new
```

**Detach** (default: `Alt+Shift+D` release), then reattach:

```sh
hexe mux attach <session-name-or-prefix>
hexe ses list   # to find sessions
```

**Config** lives at `~/.config/hexe/init.lua`. See [config](docs/config.md).

---

## History

Started as bash and Python hacks wrapped around tmux. Absolutely cursed code. Shell scripts spawning tmux sessions, Python daemons talking to tmux through send-keys, config files that were basically more shell scripts. It was wild. But it worked, and it was the workflow I wanted.

Rewrote it properly in Rust on top of tmux-rs, got far, learned a lot about terminal internals. But that crate is mostly unsafe and you're still building on top of tmux's architecture rather than escaping it.

Then Ghostty came out. Saw what Mitchell was doing with Zig and decided to start from scratch. Zero regrets. Zig is a joy, Ghostty's VT implementation is solid, and the architecture finally matches what I actually wanted to build.

---

## Credits

- [Zig](https://ziglang.org)
- [ghostty-vt](https://github.com/ghostty-org/ghostty) — terminal emulation
- [libvaxis](https://github.com/rockorager/libvaxis) — TUI rendering
- [libxev](https://github.com/mitchellh/libxev) — event loop
- [voidbox](https://github.com/bresilla/voidbox) — process isolation
- [krabby](https://github.com/yannjor/krabby) — Pokemon sprites
