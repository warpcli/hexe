# Hexe Isolation Guide

Complete guide to process, resource, and filesystem isolation in Hexe using [voidbox](https://github.com/bresilla/voidbox).

## Overview

Hexe uses **voidbox** for Linux sandboxing with three types of isolation:

1. **Process Isolation** - Namespaces (user, PID, mount, network, UTS, IPC)
2. **Resource Isolation** - Cgroups (CPU, memory, process limits)
3. **Filesystem Isolation** - Bind mounts, overlays, private /tmp

## Isolation Profiles

### `none` (Default)
**No isolation** - Normal operation with full system access.

- ❌ No namespaces
- ❌ No resource limits
- ❌ No filesystem restrictions
- ✅ Full access to all processes, files, network

**Use case**: Trusted code, normal shell work

---

### `minimal`
**Light isolation** - Basic privilege separation.

**Process:**
- ✅ User namespace (different UID/GID mapping)

**Filesystem:**
- ✅ Private `/tmp` (isolated from other panes)

**Use case**: Basic privilege separation, semi-trusted tools

**What you'll see:**
```bash
ls /tmp          # Your private /tmp
touch /tmp/test  # Won't appear in other panes
```

---

### `default`
**Standard isolation** - Process visibility control.

**Process:**
- ✅ User namespace
- ✅ PID namespace (can't see other processes)

**Filesystem:**
- ✅ Private `/tmp`
- ✅ Bind mounts: `/bin`, `/usr`, `/lib`, `/lib64`, `/nix`, `/pkg`, `/opt`
- ✅ Your `/home/<user>` directory (read-write)

**Use case**: Running tools that shouldn't see other processes

**What you'll see:**
```bash
ps aux           # Only shows processes in this pane!
ls /home         # Only your user directory
ls /             # System dirs + your home + tmp
```

---

### `balanced`
**Process + mount isolation** - Separate filesystem view.

**Process:**
- ✅ User namespace
- ✅ PID namespace
- ✅ Mount namespace (separate mount table)

**Filesystem:**
- ✅ Private `/tmp`
- ✅ Bind mounts: `/bin`, `/usr`, `/lib`, `/lib64`, `/nix`, `/pkg`, `/opt`
- ✅ Your `/home/<user>` directory (read-write)
- ✅ Separate mount table (mounts don't leak to host)

**Use case**: Isolated environment for development/testing

---

### `sandbox` (Recommended for untrusted code)
**Full isolation WITH network** - Secure but functional.

**Process:**
- ✅ User namespace
- ✅ PID namespace
- ✅ Mount namespace
- ❌ Network namespace (network allowed!)
- ✅ UTS namespace (isolated hostname)
- ✅ IPC namespace (isolated shared memory)

**Filesystem:**
- ✅ Private `/tmp`
- ✅ Bind mounts: `/bin`, `/usr`, `/lib`, `/lib64`, `/nix`, `/pkg`, `/opt`
- ✅ Your `/home/<user>` directory (read-write)

**Resources** (if configured):
- ✅ Memory limit (e.g., 512M)
- ✅ CPU limit (e.g., 0.5 cores)
- ✅ Process limit (e.g., 100 PIDs)

**Use case**: Run untrusted code that needs internet (downloading packages, API calls)

**What you'll see:**
```bash
ps aux                # Only this pane's processes
curl example.com      # Network works!
ls /                  # Only: bin, usr, lib, nix, pkg, opt, home/<you>, tmp
touch /tmp/test       # Private tmp
hostname              # Different hostname
```

---

### `full`
**Maximum isolation** - Minimal access, no network.

**Process:**
- ✅ User namespace
- ✅ PID namespace
- ✅ Mount namespace
- ✅ **Network namespace (NO NETWORK!)**
- ✅ UTS namespace
- ✅ IPC namespace
- ✅ Cgroup namespace

**Filesystem:**
- ✅ Private `/tmp`
- ✅ Bind mounts: `/bin`, `/usr`, `/lib`, `/lib64` **ONLY**
- ❌ NO `/nix`, `/pkg`, `/opt`
- ❌ NO `/home`

**Resources** (if configured):
- ✅ Memory limit
- ✅ CPU limit
- ✅ Process limit

**Use case**: Maximum security for highly untrusted code

**What you'll see:**
```bash
ps aux                # Only this pane's processes
ping 8.8.8.8          # Network unreachable!
ls /                  # Only: bin, usr, lib, lib64, tmp
ls /home              # No such directory
curl example.com      # Fails - no network
```

---

## Usage

### 1. Command-line (Ad-hoc floats)

```bash
# Spawn isolated float with sandbox profile
hexe mux float --command "zsh" --isolation=sandbox

# Full isolation (no network, minimal filesystem)
hexe mux float --command "zsh" --isolation=full

# With size and title
hexe mux float --command "zsh" \
  --isolation=sandbox \
  --title="Isolated Shell" \
  --size "80,60,0,0"

# Run untrusted script
hexe mux float --command "bash /tmp/untrusted.sh" --isolation=full
```

### 2. Configuration (Per-float in init.lua)

Configure isolation for specific floats in your `~/.config/hexe/init.lua`:

```lua
hx.ses.layout.define({
  name = "default",
  floats = {
    {
      key = "0",
      enabled = true,
      title = "sandbox",
      isolation = {
        profile = "sandbox",  -- Isolation profile
        memory = "512M",      -- Memory limit
        pids = 100,           -- Max processes
        cpu = "50000 100000", -- 0.5 CPU cores
      },
    },
  },
})
```

**Isolation fields:**
- `profile`: Profile name (none, minimal, default, balanced, sandbox, full)
- `memory`: Memory limit (e.g., "1G", "512M", "256M")
- `cpu`: CPU quota as "period max" (e.g., "100000 100000" = 1 core, "50000 100000" = 0.5 cores)
- `pids`: Maximum number of processes (e.g., 100, 1000)

---

## Resource Limits (Cgroups)

Control CPU, memory, and process limits:

### Memory Limit

```bash
# 512MB limit
hexe mux float --command "zsh" --isolation=sandbox  # Uses config

# In Lua config:
isolation = {
  profile = "sandbox",
  memory = "512M",  -- Killed if exceeded
}
```

**Test it:**
```bash
# This will be killed when it exceeds 512M
python3 -c "a = 'x' * (1024**3)"  # Try to allocate 1GB
```

### CPU Limit

```bash
# 0.5 cores max
isolation = {
  profile = "sandbox",
  cpu = "50000 100000",  -- 50% of one core
}
```

**Format:** `period max`
- `"100000 100000"` = 1 full core
- `"50000 100000"` = 0.5 cores
- `"200000 100000"` = 2 cores

### Process Limit

```bash
# Max 100 processes
isolation = {
  profile = "sandbox",
  pids = 100,
}
```

**Test it:**
```bash
# This will fail after 100 forks
:(){ :|:& };:  # Fork bomb (safely contained!)
```

---

## Filesystem Isolation Details

### Bind Mounts (Read-only vs Read-write)

**Read-only mounts** (safe, can't modify):
- `/bin`, `/usr`, `/lib`, `/lib64` - System binaries
- `/nix`, `/pkg`, `/opt` - Package managers (not in `full`)

**Read-write mounts** (you can modify):
- `/home/<youruser>` - Your home directory (not in `full`)
- `/tmp` - Private tmpfs (always isolated)

### What's Hidden?

In isolation modes, these are **not visible**:

- `/root` - Root home directory
- `/home/<otheruser>` - Other users' home directories
- `/proc` - Only shows your processes (PID namespace)
- `/sys` - System information (filtered)
- `/dev` - Some devices hidden

### Private /tmp

Every isolated pane gets its own `/tmp`:

```bash
# Pane 1:
touch /tmp/secret.txt
ls /tmp              # Shows secret.txt

# Pane 2 (isolated):
ls /tmp              # Empty! Can't see Pane 1's files
```

---

## Examples

### Example 1: Isolated Development Environment

```bash
hexe mux float --command "zsh" \
  --isolation=sandbox \
  --title="Dev Sandbox"

# Inside:
npm install   # Network works, downloads packages
ls /tmp       # Private temp directory
ps aux        # Only sees npm processes
```

### Example 2: Running Untrusted Code

```bash
# Full isolation - no network, minimal filesystem
hexe mux float --command "python3 /tmp/untrusted.py" \
  --isolation=full

# The script:
# - Can't see your /home
# - Can't access network
# - Can't see other processes
# - Limited to 512M RAM (if configured)
# - Can't fork bomb (PID limit)
```

### Example 3: Build Environment

```lua
-- In init.lua
{
  key = "b",
  title = "builder",
  command = "/usr/bin/make",
  isolation = {
    profile = "balanced",
    memory = "2G",
    cpu = "200000 100000",  -- 2 cores
    pids = 500,
  },
}
```

Press `Ctrl+Alt+B` to open isolated build environment.

---

## Security Considerations

### What Isolation Provides

✅ **Process containment** - Can't see/kill other processes
✅ **Resource limits** - Can't exhaust system memory/CPU
✅ **Filesystem restriction** - Can't access other users' data
✅ **Network isolation** (full profile) - Can't make network connections

### What Isolation Does NOT Provide

❌ **Kernel exploits** - Still shares kernel with host
❌ **Side-channel attacks** - Spectre/Meltdown not mitigated
❌ **Complete security** - Not a VM or hardware virtualization

**For maximum security**: Use VMs, containers with kernel isolation, or dedicated hardware.

---

## Troubleshooting

### Permission Denied Errors

```
[pty-child] Voidbox isolation failed: error.PermissionDenied
```

**Cause**: User namespaces disabled or insufficient permissions.

**Fix**:
```bash
# Check if user namespaces are enabled
sysctl kernel.unprivileged_userns_clone

# Enable (requires root)
sudo sysctl -w kernel.unprivileged_userns_clone=1
```

### Can't See My Files

**Issue**: `/home` is empty in isolated shell.

**Cause**: Using `full` profile which doesn't mount `/home`.

**Fix**: Use `sandbox`, `balanced`, or `default` profile instead.

### Network Not Working

**Issue**: `ping`, `curl` fail with "network unreachable".

**Cause**: Using `full` profile which blocks network.

**Fix**: Use `sandbox` profile for network access with isolation.

### Commands Not Found

**Issue**: `ls`, `cat`, etc. not found.

**Cause**: `/bin` not mounted (shouldn't happen with provided profiles).

**Fix**: Check profile includes `/bin` bind mount, or use `default`/`sandbox` profile.

---

## Advanced Configuration

### Custom Filesystem Actions

For advanced users, voidbox supports custom filesystem actions via environment variables (future feature) or direct voidbox configuration.

### Overlay Filesystems

Future enhancement: Use overlayfs for ephemeral root filesystem where changes don't persist between sessions.

### Network Isolation with Custom Routes

Future enhancement: Custom network namespaces with virtual interfaces for controlled internet access.

---

## Comparison with Docker/Podman

| Feature | Hexe Isolation | Docker/Podman |
|---------|---------------|---------------|
| **Startup Time** | <10ms | ~100-500ms |
| **Overhead** | Minimal | Container runtime |
| **Filesystem** | Bind mounts | Image layers |
| **Process Isolation** | PID namespace | Full container |
| **Network** | Optional | Virtual networks |
| **Use Case** | Fast task isolation | Full application containers |

**When to use Hexe**: Quick isolation for shell tasks, scripts, development.
**When to use Docker**: Deploying applications, reproducible environments, complex networking.

---

## See Also

- [Voidbox Documentation](https://github.com/bresilla/voidbox) - Underlying sandboxing library
- [Linux Namespaces](https://man7.org/linux/man-pages/man7/namespaces.7.html) - Kernel isolation primitives
- [Cgroups v2](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html) - Resource limits
