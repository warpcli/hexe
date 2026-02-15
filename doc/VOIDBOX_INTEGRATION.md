# Voidbox Integration

Hexa includes [voidbox](https://github.com/bresilla/voidbox) (v0.0.3) as a dependency for future sandboxing capabilities.

## Current Status

✅ **Available**: Voidbox is built and available as a module import
✅ **Accessible**: POD and SES modules can import and use voidbox
⚠️ **Not Integrated**: POD pane isolation currently uses Hexa's built-in isolation system
🔮 **Future**: Full voidbox integration planned for comprehensive sandboxing

## Current POD Isolation

Hexa POD currently provides built-in isolation via `src/core/isolation.zig`:

### Features
- **Landlock** - Filesystem access control (default)
- **User namespaces** - UID/GID mapping (optional)
- **Mount namespaces** - Isolated /tmp (optional)
- **Cgroups v2** - Resource limits (CPU, memory, PIDs)

### Configuration

```bash
# Enable Landlock filesystem isolation
export HEXE_POD_ISOLATE=1

# Enable user + mount namespaces
export HEXE_POD_ISOLATE_USERNS=1

# Set resource limits
export HEXE_CGROUP_PIDS_MAX=512
export HEXE_CGROUP_MEM_MAX=1G
export HEXE_CGROUP_CPU_MAX="50000 100000"  # 50% CPU

# Start hexe with isolation
hexe mux
```

## Manual Voidbox Usage

While not integrated into POD spawning yet, you can use voidbox directly in Zig code:

###  Basic Example

```zig
const std = @import("std");
const voidbox = @import("voidbox");

pub fn runIsolated(allocator: std.mem.Allocator) !void {
    const config = voidbox.JailConfig{
        .name = "my-jail",
        .rootfs_path = "/",
        .cmd = &[_][]const u8{ "/bin/sh", "-c", "echo hello" },
        .isolation = .{
            .user = true,
            .pid = true,
            .mount = true,
            .net = false,
            .uts = false,
            .ipc = false,
            .cgroup = false,
        },
        .resources = .{
            .mem = "512M",
            .pids = "100",
            .cpu = null,
        },
        .security = .{
            .no_new_privs = true,
            .cap_drop = "",
            .cap_add = "",
        },
    };

    // Validate config
    try voidbox.validate(&config, allocator);

    // Spawn jail
    const session = try voidbox.spawn(&config, allocator);
    defer voidbox.cleanup_session(&session, allocator);

    // Wait for completion
    const outcome = try voidbox.wait(&session, allocator);
    std.debug.print("Exit code: {}\n", .{outcome.exit_code});
}
```

### Advanced: Custom Jail

```zig
const config = voidbox.JailConfig{
    .name = "secure-shell",
    .rootfs_path = "/custom/rootfs",  // Chroot to custom root
    .cmd = &[_][]const u8{ "/bin/bash" },

    .isolation = .{
        .user = true,
        .pid = true,
        .mount = true,
        .net = true,   // Isolated network
        .uts = true,   // Isolated hostname
        .ipc = true,   // Isolated IPC
        .cgroup = true,
    },

    .resources = .{
        .mem = "1G",
        .pids = "500",
        .cpu = "100000",  // CPU quota
    },

    .security = .{
        .no_new_privs = true,
        .seccomp_mode = .strict,  // Enable seccomp
        .cap_drop = "ALL",        // Drop all capabilities
        .cap_add = "NET_BIND_SERVICE",  // Keep only specific caps
    },

    .fs_actions = &[_]voidbox.FsAction{
        .{ .bind_mount = .{ .source = "/dev", .target = "/dev" } },
        .{ .tmpfs = .{ .target = "/tmp", .size = "64M" } },
    },
};
```

## Future Integration Plans

### Phase 1: Optional Voidbox POD Spawning
```bash
# Enable voidbox for POD isolation (planned)
export HEXE_POD_VOIDBOX=1
export HEXE_POD_VOIDBOX_PROFILE=balanced  # none, minimal, balanced, full
```

### Phase 2: Per-Pane Isolation Policies
```lua
-- In init.lua (planned API)
hexe.ses.layout.define({
  floats = {
    {
      key = "1",
      command = "/usr/bin/firefox",
      isolation = {
        profile = "full",  -- Complete isolation
        resources = { memory = "2G", pids = 1000 },
        network = "isolated",  -- Private network namespace
      },
    },
  },
})
```

### Phase 3: Rootfs/Container Support
```lua
-- Use custom rootfs (planned)
hexe.ses.layout.define({
  floats = {
    {
      key = "c",
      command = "/bin/bash",
      isolation = {
        rootfs = "/containers/ubuntu-22.04",
        filesystem = {
          bind_mounts = {
            { source = "$HOME/code", target = "/workspace" },
          },
        },
      },
    },
  },
})
```

## Use Cases

### 1. **Untrusted Code Execution**
Spawn a pane with full isolation for running untrusted scripts:
```bash
HEXE_POD_ISOLATE=1 HEXE_POD_ISOLATE_USERNS=1 hexe mux
# Then run untrusted code in a pane
```

### 2. **Resource-Limited Builds**
Prevent builds from consuming all system resources:
```bash
export HEXE_CGROUP_MEM_MAX=4G
export HEXE_CGROUP_CPU_MAX="200000 100000"  # 2 cores max
hexe mux
```

### 3. **Development Containers**
(Future) Each pane as an isolated container with custom rootfs.

## Development Guide

Want to integrate voidbox further? Here's where to start:

### Files to Modify
- `src/core/isolation.zig` - Current isolation implementation
- `src/core/pty.zig` - PTY spawning (line 733 in pod/main.zig)
- `src/modules/pod/main.zig` - POD initialization

### Integration Pattern
```zig
// In src/modules/pod/main.zig

const voidbox = @import("voidbox");

// Check if voidbox isolation is requested
const use_voidbox = posix.getenv("HEXE_POD_VOIDBOX") != null;

if (use_voidbox) {
    // Option 1: Spawn with voidbox, attach PTY after
    // Challenge: voidbox controls spawn, hard to inject PTY

    // Option 2: Manual namespace setup inspired by voidbox
    // Use voidbox config structures but do spawn ourselves

    // Option 3: Extend core.Pty to support voidbox config
    // Clean separation of concerns
}
```

### API Compatibility Note

Voidbox 0.0.3 API differs from initial assumptions:

```zig
// Actual voidbox API:
voidbox.JailConfig{
    .name = "jail-name",
    .rootfs_path = "/",
    .cmd = &[_][]const u8{ "/bin/sh" },  // Array, not single string
    .resources = .{ .mem = "512M" },     // String format
}

// NOT:
voidbox.JailConfig{
    .allocator = allocator,  // ❌ Doesn't exist
    .command = "/bin/sh",    // ❌ Wrong field name
}
```

## Build Configuration

Voidbox is configured in:
- **build.zig.zon** - Git dependency `git+https://github.com/bresilla/voidbox#0.0.3`
- **build.zig** - Module imports for POD, SES, and CORE

To verify voidbox is available:
```bash
zig build
# Should compile without errors
```

## References

- [Voidbox GitHub](https://github.com/bresilla/voidbox)
- [Voidbox Tag 0.0.3](https://github.com/bresilla/voidbox/tree/0.0.3)
- [Current Hexa Isolation](../src/core/isolation.zig)
- [Integration Examples](../examples/voidbox_integration.zig)
