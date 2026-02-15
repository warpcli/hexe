# Voidbox Integration

Hexa integrates [voidbox](https://github.com/bresilla/voidbox) (v0.0.3) for process sandboxing and isolation.

## Overview

Voidbox provides Linux namespace/cgroup/filesystem isolation for running contained processes. In Hexa, it's available to:

- **POD module** - Isolate PTY processes per-pane
- **SES module** - Manage sandboxed sessions

## Availability

The `voidbox` module is imported in:
- `src/modules/pod/` - Access via `const voidbox = @import("voidbox");`
- `src/modules/ses/` - Access via `const voidbox = @import("voidbox");`

## Quick Start

### 1. Launch Isolated Shell

```zig
const voidbox = @import("voidbox");

var config = voidbox.default_shell_config();
config.isolation.user = true;
config.isolation.pid = true;

const outcome = try voidbox.launch_shell(allocator, &config);
```

### 2. Launch Custom Command

```zig
var jail = voidbox.JailConfig{
    .allocator = allocator,
    .rootfs = "/",
    .command = "/bin/bash",
    .args = &[_][]const u8{ "-c", "echo hello" },
    .isolation = .{
        .user = true,
        .pid = true,
        .mount = false,
        .net = false,
    },
};

try voidbox.validate(&jail);
const outcome = try voidbox.launch(allocator, &jail);
```

### 3. Spawn Non-Blocking

```zig
var config = voidbox.default_shell_config();
try voidbox.with_profile(&config, .default);

const session = try voidbox.spawn(allocator, &config);
// Do other work...
const outcome = try voidbox.wait(&session);
```

## Integration Profiles

Voidbox provides preset isolation profiles:

- **`.minimal`** - Basic isolation (user namespace only)
- **`.default`** - Balanced isolation (user + pid + mount)
- **`.full_isolation`** - Maximum isolation (all namespaces)

```zig
try voidbox.with_profile(&config, .full_isolation);
```

## Configuration Options

### Isolation Options

```zig
.isolation = .{
    .user = true,    // User namespace
    .pid = true,     // PID namespace
    .mount = true,   // Mount namespace
    .net = true,     // Network namespace
    .uts = true,     // UTS namespace (hostname)
    .ipc = true,     // IPC namespace
    .cgroup = true,  // Cgroup namespace
}
```

### Resource Limits

```zig
.resources = .{
    .memory_limit_mb = 512,   // Max RAM
    .pids_limit = 100,        // Max processes
    .cpu_shares = 1024,       // CPU weight
}
```

### Security Options

```zig
.security = .{
    .drop_all_caps = true,
    .keep_caps = &[_]u32{ CAP_NET_BIND_SERVICE },
    .seccomp_profile = null,
}
```

## Host Compatibility Check

Before using voidbox features, check host capabilities:

```zig
const report = try voidbox.check_host(allocator);
if (!report.user_ns_available) {
    return error.UserNamespacesNotSupported;
}
```

## Use Cases in Hexa

### POD: Sandboxed Panes

```zig
// In pod/main.zig
pub fn spawnSandboxedPane(allocator: std.mem.Allocator, command: []const u8) !void {
    const voidbox = @import("voidbox");

    var config = voidbox.default_shell_config();
    config.command = command;
    config.isolation.user = true;
    config.isolation.pid = true;
    config.resources.memory_limit_mb = 1024;

    const session = try voidbox.spawn(allocator, &config);
    // Wire session to PTY...
}
```

### SES: Isolated Sessions

```zig
// In ses/state.zig
pub fn createIsolatedSession(allocator: std.mem.Allocator) !void {
    const voidbox = @import("voidbox");

    var config = voidbox.default_shell_config();
    try voidbox.with_profile(&config, .default);

    // Launch session daemon in isolated environment
    const outcome = try voidbox.launch_shell(allocator, &config);
}
```

## Build Configuration

Voidbox is configured in:
- **build.zig.zon** - Git dependency on tag `0.0.3`
- **build.zig** - Module imports for POD and SES

To update version:
```bash
zig fetch --save git+https://github.com/bresilla/voidbox#<new-version>
```

## Examples

See `/doc/code/hexa/examples/voidbox_integration.zig` for complete examples.

## Requirements

- **Linux host** - voidbox requires Linux kernel namespaces
- **Zig 0.15.x** - Compatible with Hexa's Zig version
- **Kernel features** - User namespaces, PID namespaces (check with `check_host()`)

## References

- [Voidbox GitHub](https://github.com/bresilla/voidbox)
- [Voidbox API Documentation](https://github.com/bresilla/voidbox/blob/0.0.3/README.md)
