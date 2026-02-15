# POD Pane Isolation (Voidbox)

Hexa POD uses **voidbox** for comprehensive pane isolation with namespaces, cgroups, and security features.

## Configuration

POD isolation is configured via environment variables:

### Isolation Profiles

```bash
# Set isolation profile (default: "default")
export HEXE_VOIDBOX_PROFILE=balanced

# Available profiles:
# - none:     No isolation
# - minimal:  User namespace only
# - default:  User + PID namespaces
# - balanced: User + PID + Mount namespaces
# - full:     All namespaces (user/pid/mount/net/uts/ipc/cgroup)
```

### Resource Limits (Cgroups v2)

```bash
# Memory limit (supports K/M/G suffixes)
export HEXE_CGROUP_MEM_MAX=1G

# Maximum number of processes
export HEXE_CGROUP_PIDS_MAX=512

# CPU quota (format: "quota period" in microseconds)
export HEXE_CGROUP_CPU_MAX="50000 100000"  # 50% CPU
```

## Isolation Profiles

### `none` - No Isolation
```bash
export HEXE_VOIDBOX_PROFILE=none
```
- No namespaces
- No resource limits
- Processes run with full system access
- Use for: trusted development, debugging

### `minimal` - User Namespace Only
```bash
export HEXE_VOIDBOX_PROFILE=minimal
```
- **User namespace**: UID/GID remapping (root inside namespace)
- Lightweight isolation
- Use for: basic privilege separation

### `default` - User + PID (Default)
```bash
export HEXE_VOIDBOX_PROFILE=default
# or simply don't set HEXE_VOIDBOX_PROFILE
```
- **User namespace**: UID/GID isolation
- **PID namespace**: Process isolation (can't see other processes)
- Use for: general development, moderate security

### `balanced` - User + PID + Mount
```bash
export HEXE_VOIDBOX_PROFILE=balanced
```
- **User namespace**: UID/GID isolation
- **PID namespace**: Process isolation
- **Mount namespace**: Filesystem isolation (fresh /tmp)
- Use for: untrusted code, build environments

### `full` - Complete Isolation
```bash
export HEXE_VOIDBOX_PROFILE=full
```
- **User namespace**: UID/GID isolation
- **PID namespace**: Process isolation
- **Mount namespace**: Filesystem isolation
- **Network namespace**: Network isolation (no network access)
- **UTS namespace**: Hostname isolation
- **IPC namespace**: IPC isolation
- **Cgroup namespace**: Cgroup isolation
- Use for: maximum security, containers

## Examples

### Basic Usage
```bash
# Start hexe with default isolation
hexe mux
```

### Resource-Limited Builds
```bash
# Limit resources for compilation
export HEXE_VOIDBOX_PROFILE=balanced
export HEXE_CGROUP_MEM_MAX=4G
export HEXE_CGROUP_CPU_MAX="200000 100000"  # 2 cores
export HEXE_CGROUP_PIDS_MAX=1000
hexe mux
```

### Untrusted Code Execution
```bash
# Maximum isolation for running untrusted scripts
export HEXE_VOIDBOX_PROFILE=full
export HEXE_CGROUP_MEM_MAX=512M
export HEXE_CGROUP_PIDS_MAX=100
hexe mux
```

### Development (No Isolation)
```bash
# Disable isolation for debugging
export HEXE_VOIDBOX_PROFILE=none
hexe mux
```

## Features

### Namespaces

- **User (CLONE_NEWUSER)**: Maps UID/GID to root inside namespace
- **PID (CLONE_NEWPID)**: Isolated process tree, PID 1 inside namespace
- **Mount (CLONE_NEWNS)**: Isolated mounts, fresh /tmp (128MB tmpfs)
- **Network (CLONE_NEWNET)**: No network access (loopback only)
- **UTS (CLONE_NEWUTS)**: Isolated hostname
- **IPC (CLONE_NEWIPC)**: Isolated IPC resources (message queues, semaphores)
- **Cgroup (CLONE_NEWCGROUP)**: Isolated cgroup view

### Security

- **no_new_privs**: Prevents privilege escalation (always enabled)
- Future: Capability dropping, seccomp filters

### Cgroups v2

- **memory.max**: Hard memory limit
- **pids.max**: Maximum process count
- **cpu.max**: CPU quota (quota/period microseconds)

## Implementation

Voidbox isolation is applied in two phases:

### Child Process (After Fork, Before Exec)
1. **Enter namespaces** - `unshare()` syscalls for requested namespaces
2. **Setup user namespace** - UID/GID mappings
3. **Setup mount namespace** - Fresh /tmp, private mounts
4. **Security restrictions** - `prctl(PR_SET_NO_NEW_PRIVS)`

### Parent Process (After Fork)
1. **Apply cgroups** - Write limits to cgroup files
2. **Move process** - Add child PID to cgroup.procs

See `src/core/isolation_voidbox.zig` for implementation details.

## Troubleshooting

### "Voidbox isolation failed" in logs
- Check kernel support: `zgrep NAMESPACES /proc/config.gz`
- User namespaces: `sysctl kernel.unprivileged_userns_clone`
- Try lower profile: `export HEXE_VOIDBOX_PROFILE=minimal`

### Cgroups not working
- Verify cgroup v2: `mount | grep cgroup2`
- Check delegation: `cat /sys/fs/cgroup/cgroup.controllers`
- Some limits may require root or cgroup delegation

### Network issues with `full` profile
- Network namespace isolates network completely
- Use `balanced` if you need network access
- Or manually configure veth pairs (advanced)

## Future Enhancements

- Per-pane profiles via Lua config
- Custom rootfs/container support
- Bind mounts and filesystem actions
- Seccomp filter support
- Capability management

## References

- Implementation: `src/core/isolation_voidbox.zig`
- PTY Integration: `src/core/pty.zig`
- Voidbox: https://github.com/bresilla/voidbox
