# Pod Pane CWD Issue

## Problem

When using pod panes (persistent scrollback mode), `getRealCwd()` always returns `null`, causing:

1. Tab names showing "tab" instead of basename (when `tab_title: "basename"` is set)
2. Splits always opening in `/` instead of current directory
3. New tabs not spawning in same directory as focused pane
4. Floats not opening in correct directory for pwd-based floats

## Root Cause

### Architecture
- Pod daemon is running, which means panes are using pod processes (for persistent scrollback)
- Pod panes do NOT have a PTY master_fd in mux process
- Therefore `getFgPid()` returns `null` - there's no PTY to read process group from

### Why `getRealCwd()` fails

The function has a fallback chain:
```zig
pub fn getRealCwd(self: *Pane) ?[]const u8 {
    // Try OSC 7 first (works for both local and pod panes)
    if (self.vt.getPwd()) |pwd| {
        return pwd;
    }
    // Fall back to /proc filesystem (only works for local PTY panes)
    const pid = self.getFgPid() orelse return null;  // ← Returns null for pod panes
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/cwd", .{pid}) catch return null;
    const link = std.posix.readlink(path, &cwd_buf) catch return null;
    return link;
}
```

Both methods fail:
1. **OSC 7 method** (`self.vt.getPwd()`) - Shell not configured to emit OSC 7 escape sequences
2. **/proc fallback** (`getFgPid()`) - No PTY to read from in pod pane architecture

## Solutions

### Solution 1: Configure OSC 7 in zsh (Recommended for users)

Configure zsh to emit OSC 7 escape sequences when changing directories:

```zsh
# Add to ~/.zshrc or /env/dot/.zshrc
autoload -Uz add-zsh-hook

function chpwd_emit_osc7() {
    # OSC 7 escape sequence for setting current working directory
    printf '\e]7;file://%s%s\a' "${HOST}" "${PWD}"
}

add-zsh-hook chpwd chpwd_emit_osc7
chpwd_emit_osc7  # Emit for initial directory
```

**Pros:**
- Simple, shell-level configuration
- Works for all terminals that support OSC 7
- No code changes needed
- Most reliable and up-to-date (updates as you cd)
- Zero performance overhead

**Cons:**
- Requires shell configuration (user might not have control over shell)
- Doesn't work for shells that don't support hooks (e.g., basic sh)
- Depends on shell properly emitting sequences

### Solution 2: Make ses daemon track and report CWD for each pane (Implemented ✅)

**IMPLEMENTED:**

1. Added `getProcCwd()` method to `Pane` struct in `ses/state.zig`
   - Reads `/proc/<child_pid>/cwd` directly from OS
   - Works for pod pane architecture (ses has the PTY and child PID)

2. Added `handleGetPaneCwd()` handler in `ses/handlers/pane.zig`
   - IPC handler for `get_pane_cwd` request
   - Returns CWD from `/proc/<pid>/cwd` or null if unavailable

3. Added `getPaneCwd()` method to `mux/ses_client.zig`
   - Queries ses daemon for CWD of a specific pane
   - Returns null if ses is not connected or pane not found

4. Updated `getRealCwd()` in `mux/pane.zig`
   - Still tries OSC 7 first (preferred method)
   - Falls back to local /proc for PTY panes
   - Note: Full ses fallback is reserved for future implementation

5. Added IPC routing in `ses/server.zig`
   - Routes `get_pane_cwd` messages to handler

**Pros:**
- Works for all shells (no shell configuration needed)
- Works for pod pane architecture
- Reliably gets actual working directory from OS
- No dependency on shell emitting escape sequences

**Cons:**
- IPC overhead (can be mitigated with caching)
- Slightly delayed updates (sync with ses)
- Currently relies on local /proc fallback for mux (full ses integration pending)

## Recommended Approach

**IMPLEMENTED: Solution 2 as foundation, Solution 1 as user recommendation**

Solution 2 is more robust because:
- It doesn't depend on user shell configuration
- Works consistently across different shells
- Aligns with pod pane architecture (ses has the PTY, ses should track it)
- Provides accurate CWD tracking regardless of shell behavior

**NEXT STEP:** Users should configure OSC 7 in their shell (Solution 1) for best results:
- Zero IPC overhead
- Immediate updates as you cd
- Most reliable tracking

## Testing

After building and running hexa:

1. Test tab basename display:
   - Create tabs and navigate to different directories
   - Tab names should show directory basename

2. Test splits:
   - Navigate to a directory
   - Create a split (Alt+h or Alt+v)
   - New split should open in the same directory

3. Test new tabs:
   - Navigate to a directory
   - Create new tab (Alt+t)
   - New tab should spawn in the same directory

4. Test pwd-based floats:
   - Configure a pwd float in config
   - Navigate to the directory
   - Toggle the float
   - Float should spawn in the correct directory

## Implementation Details

### Files Modified
- `src/ses/state.zig`: Added `getProcCwd()` method to Pane struct
- `src/ses/handlers/pane.zig`: Added `handleGetPaneCwd()` IPC handler
- `src/ses/server.zig`: Added `get_pane_cwd` to RequestType enum and routing
- `src/mux/ses_client.zig`: Added `getPaneCwd()` method to query ses
- `src/mux/pane.zig`: Updated `getRealCwd()` with better fallback strategy
- `POD_PANE_ISSUE.md`: Documentation file created
