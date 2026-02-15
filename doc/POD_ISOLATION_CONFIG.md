# POD Isolation Configuration (Lua API)

Configure voidbox POD isolation directly in your `init.lua` config file.

## Basic Usage

```lua
-- In ~/.config/hexe/init.lua

hexe.ses.isolation.set({
  profile = "balanced",
  memory = "1G",
  pids = 512,
  cpu = "50000 100000",
})
```

## API Reference

### `hexe.ses.isolation.set(config)`

Configure global POD isolation settings for all panes.

**Parameters:**
- `config` (table) - Isolation configuration

**Config Fields:**

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `profile` | string | `"default"` | Isolation profile: `"none"`, `"minimal"`, `"default"`, `"balanced"`, `"full"` |
| `memory` | string | `nil` | Memory limit (e.g., `"512M"`, `"1G"`, `"2G"`) |
| `cpu` | string | `nil` | CPU quota `"quota period"` in microseconds |
| `pids` | number/string | `nil` | Maximum number of processes |

## Isolation Profiles

### `none` - No Isolation
```lua
hexe.ses.isolation.set({ profile = "none" })
```
- No namespaces or resource limits
- Full system access
- **Use for:** Debugging, trusted development

### `minimal` - User Namespace Only
```lua
hexe.ses.isolation.set({ profile = "minimal" })
```
- **Namespaces:** User
- **Use for:** Basic privilege separation

### `default` - User + PID (Recommended)
```lua
hexe.ses.isolation.set({ profile = "default" })
```
- **Namespaces:** User + PID
- **Use for:** General development, moderate security

### `balanced` - User + PID + Mount
```lua
hexe.ses.isolation.set({
  profile = "balanced",
  memory = "2G",
  pids = 1000,
})
```
- **Namespaces:** User + PID + Mount
- Fresh `/tmp` (128MB tmpfs)
- **Use for:** Untrusted code, build environments

### `full` - Complete Isolation
```lua
hexe.ses.isolation.set({
  profile = "full",
  memory = "512M",
  pids = 100,
  cpu = "100000 100000",  -- 1 core max
})
```
- **Namespaces:** User + PID + Mount + Network + UTS + IPC + Cgroup
- No network access (loopback only)
- **Use for:** Maximum security, containers

## Examples

### Development Workstation
```lua
-- Moderate isolation with generous resources
hexe.ses.isolation.set({
  profile = "default",
  memory = "4G",
  pids = 2000,
})
```

### Build Server
```lua
-- Prevent builds from consuming all resources
hexe.ses.isolation.set({
  profile = "balanced",
  memory = "8G",
  cpu = "400000 100000",  -- 4 cores
  pids = 5000,
})
```

### Untrusted Code Execution
```lua
-- Maximum isolation with tight limits
hexe.ses.isolation.set({
  profile = "full",
  memory = "512M",
  cpu = "50000 100000",  -- 0.5 cores
  pids = 50,
})
```

### No Isolation (Development)
```lua
-- Disable all isolation for debugging
hexe.ses.isolation.set({ profile = "none" })
```

## Resource Limit Formats

### Memory
```lua
memory = "512M"  -- 512 megabytes
memory = "1G"    -- 1 gigabyte
memory = "2048M" -- 2 gigabytes
```

### CPU Quota
Format: `"quota period"` (both in microseconds)

```lua
cpu = "50000 100000"   -- 50% of 1 core
cpu = "100000 100000"  -- 100% of 1 core (1 full core)
cpu = "200000 100000"  -- 200% (2 full cores)
```

### PIDs
```lua
pids = 100    -- number
pids = "500"  -- string
pids = 1000   -- number
```

## Environment Variable Override

Lua config settings can be overridden by environment variables:

```bash
# Override profile
export HEXE_VOIDBOX_PROFILE=full

# Override resource limits
export HEXE_CGROUP_MEM_MAX=2G
export HEXE_CGROUP_PIDS_MAX=1000
export HEXE_CGROUP_CPU_MAX="100000 100000"

hexe mux
```

**Priority:** Environment variables > Lua config > Built-in defaults

## Complete Example

```lua
-- ~/.config/hexe/init.lua

-- POD Isolation
hexe.ses.isolation.set({
  profile = "balanced",
  memory = "2G",
  pids = 1000,
  cpu = "200000 100000",  -- 2 cores
})

-- SES Layouts
hexe.ses.layout.define({
  name = "default",
  enabled = true,
  floats = {
    {
      key = "1",
      title = "editor",
      command = "/usr/bin/nvim",
      attributes = { per_cwd = true },
    },
    {
      key = "2",
      title = "browser",
      command = "/usr/bin/firefox",
      attributes = { per_cwd = false },
    },
  },
})
```

## Troubleshooting

### Isolation Not Working?

1. **Check kernel support:**
   ```bash
   # Check namespaces
   zgrep NAMESPACES /proc/config.gz

   # Check user namespaces
   sysctl kernel.unprivileged_userns_clone
   ```

2. **Verify config loading:**
   ```lua
   -- Add debug output
   print("Setting isolation profile: balanced")
   hexe.ses.isolation.set({ profile = "balanced" })
   ```

3. **Check logs:**
   ```bash
   # POD logs
   tail -f /tmp/hexe/dev/log/pod-*.log
   ```

### Cgroups Not Applying?

- Verify cgroup v2: `mount | grep cgroup2`
- Check delegation: `cat /sys/fs/cgroup/cgroup.controllers`
- Some limits may require root or systemd delegation

### Network Issues with `full` Profile?

- Network namespace isolates network completely
- Use `balanced` if you need network access
- Or configure veth pairs (advanced)

## See Also

- [POD_ISOLATION.md](POD_ISOLATION.md) - Environment variable configuration
- [VOIDBOX_INTEGRATION.md](VOIDBOX_INTEGRATION.md) - Voidbox internals
- [src/core/isolation_voidbox.zig](../src/core/isolation_voidbox.zig) - Implementation
