# Isolation

Hexe can run a pane/float command in a more isolated environment.

The design goal is **rootless** isolation that is practical on real systems:

- Filesystem sandboxing via **Landlock** (allowlist-based)
- Resource containment via **cgroup v2** when delegated (best-effort)
- Optional user+mount namespaces for experimentation (off by default)

## How To Use

### Ad-hoc floats

Spawn an isolated float:

```sh
hexe mux float --command "bash" --isolated
```

Notes:

- `--isolated` defaults to `false`.
- The flag works by injecting `HEXE_POD_ISOLATE=1` into the spawned command's environment.

### Named floats (mux.json)

You can set a per-float attribute:

```json
{
  "key": "g",
  "command": "lazygit",
  "attributes": {
    "global": true,
    "isolated": true
  }
}
```

Defaults:

- `floats[].attributes.isolated` defaults to `false`.

## What "Isolated" Does

### Filesystem (Landlock)

When isolation is enabled, the exec'd program is restricted to an allowlist.
This is intended to keep common interactive tools working while preventing
unintended access outside typical runtime/user/work directories.

Allowed (typical):

- Read/execute: `/bin`, `/usr`, `/lib`, `/lib64`, `/etc`, `/proc`, `/run`
- Traverse: `/` plus common parents like `/home` and `/var`
- Read/write: `$HOME`, current working directory (if set), `/tmp`, `/var/tmp`
- Writable device nodes needed by shells/tools: `/dev/null`, `/dev/tty`, `/dev/pts`, `/dev/ptmx`, `/dev/zero`, `/dev/random`, `/dev/urandom`

Enforcement happens in the PTY child right before `exec`.

### Cgroups (best-effort)

If the environment has a delegated **cgroup v2** subtree, the child process is
moved into a per-pane cgroup and limits are applied.

If cgroups are not available or not delegated, this step is skipped.

Environment overrides:

- `HEXE_CGROUP_PIDS_MAX` (default: `512`)
- `HEXE_CGROUP_MEM_MAX` (e.g. `1073741824` or `max`)
- `HEXE_CGROUP_CPU_MAX` (e.g. `50000 100000`)

## Optional Namespaces

User+mount namespaces are **off by default**.

Reason: unprivileged user namespaces are not reliably available everywhere and
partial failures can lead to an unmapped uid (showing up as `nobody`) which
breaks normal shell behavior.

To experiment:

```sh
HEXE_POD_ISOLATE_USERNS=1 hexe mux float --command "bash" --isolated
```
