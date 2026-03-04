const std = @import("std");

pub const JobKind = enum {
    status_when,
    status_command,
    pane_metadata,
};

pub const StatusWhenJob = struct {
    script: []const u8,
    shell_running: bool,
    alt_screen: bool,
    timeout_ms: u32,
    last_command: ?[]const u8,
    cwd: ?[]const u8,

    pub fn deinit(self: *StatusWhenJob, allocator: std.mem.Allocator) void {
        allocator.free(self.script);
        if (self.last_command) |v| allocator.free(v);
        if (self.cwd) |v| allocator.free(v);
    }
};

pub const StatusCommandJob = struct {
    command: []const u8,

    pub fn deinit(self: *StatusCommandJob, allocator: std.mem.Allocator) void {
        allocator.free(self.command);
    }
};

pub const PaneMetadataField = enum {
    cwd,
    process,
};

pub const PaneMetadataJob = struct {
    pane_uuid: [32]u8,
    field: PaneMetadataField,
    pid: i32,
};

pub const JobPayload = union(JobKind) {
    status_when: StatusWhenJob,
    status_command: StatusCommandJob,
    pane_metadata: PaneMetadataJob,

    pub fn deinit(self: *JobPayload, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .status_when => |*v| v.deinit(allocator),
            .status_command => |*v| v.deinit(allocator),
            .pane_metadata => {},
        }
    }

    pub fn clone(self: JobPayload, allocator: std.mem.Allocator) !JobPayload {
        return switch (self) {
            .status_when => |v| blk: {
                const script = try allocator.dupe(u8, v.script);
                errdefer allocator.free(script);

                const last_command = if (v.last_command) |cmd| try allocator.dupe(u8, cmd) else null;
                errdefer if (last_command) |cmd| allocator.free(cmd);

                const cwd = if (v.cwd) |cwd_v| try allocator.dupe(u8, cwd_v) else null;
                errdefer if (cwd) |cwd_v| allocator.free(cwd_v);

                break :blk .{ .status_when = .{
                    .script = script,
                    .shell_running = v.shell_running,
                    .alt_screen = v.alt_screen,
                    .timeout_ms = v.timeout_ms,
                    .last_command = last_command,
                    .cwd = cwd,
                } };
            },
            .status_command => |v| .{ .status_command = .{ .command = try allocator.dupe(u8, v.command) } },
            .pane_metadata => |v| .{ .pane_metadata = v },
        };
    }
};

pub const JobRequest = struct {
    generation: u64,
    key_hash: u64,
    payload: JobPayload,
};

pub const Job = struct {
    id: u64,
    kind: JobKind,
    generation: u64,
    key_hash: u64,
    submitted_ms: i64,
    payload: JobPayload,
};

pub const ResultStatus = enum {
    ok,
    dropped,
};

pub const Result = struct {
    job_id: u64,
    kind: JobKind,
    generation: u64,
    key_hash: u64,
    submitted_ms: i64,
    completed_ms: i64,
    duration_ns: u64,
    status: ResultStatus,
    payload: ResultPayload,
};

pub const ResultPayload = union(JobKind) {
    status_when: StatusWhenResult,
    status_command: StatusCommandResult,
    pane_metadata: PaneMetadataResult,
};

pub const StatusWhenResult = struct {
    matched: bool,
};

pub const StatusCommandResult = struct {
    ok: bool,
    output_len: u16,
    output: [512]u8,
};

pub const PaneMetadataResult = struct {
    ok: bool,
    pane_uuid: [32]u8,
    field: PaneMetadataField,
    pid: i32,
    value_len: u16,
    value: [512]u8,
};

pub const Config = struct {
    worker_count: usize = 2,
    max_jobs: usize = 256,
    max_results: usize = 256,
};

pub const WorkerRuntime = struct {
    allocator: std.mem.Allocator,
    config: Config,

    lock: std.Thread.Mutex = .{},
    cv_jobs: std.Thread.Condition = .{},
    shutdown_requested: bool = false,

    next_job_id: u64 = 1,
    jobs: std.ArrayList(Job) = .empty,
    results: std.ArrayList(Result) = .empty,
    workers: std.ArrayList(std.Thread) = .empty,

    pub fn init(allocator: std.mem.Allocator, config: Config) WorkerRuntime {
        return .{
            .allocator = allocator,
            .config = .{
                .worker_count = if (config.worker_count == 0) 1 else config.worker_count,
                .max_jobs = if (config.max_jobs == 0) 1 else config.max_jobs,
                .max_results = if (config.max_results == 0) 1 else config.max_results,
            },
        };
    }

    pub fn start(self: *WorkerRuntime) !void {
        try self.workers.ensureTotalCapacity(self.allocator, self.config.worker_count);

        var i: usize = 0;
        while (i < self.config.worker_count) : (i += 1) {
            const thread = try std.Thread.spawn(.{}, workerMain, .{self});
            self.workers.appendAssumeCapacity(thread);
        }
    }

    pub fn deinit(self: *WorkerRuntime) void {
        self.lock.lock();
        self.shutdown_requested = true;
        self.cv_jobs.broadcast();
        self.lock.unlock();

        for (self.workers.items) |t| t.join();

        for (self.jobs.items) |*job| {
            job.payload.deinit(self.allocator);
        }

        self.jobs.deinit(self.allocator);
        self.results.deinit(self.allocator);
        self.workers.deinit(self.allocator);
    }

    pub fn enqueue(self: *WorkerRuntime, request: JobRequest) !u64 {
        const owned_payload = try request.payload.clone(self.allocator);
        errdefer {
            var cleanup_payload = owned_payload;
            cleanup_payload.deinit(self.allocator);
        }

        self.lock.lock();
        defer self.lock.unlock();

        if (self.jobs.items.len >= self.config.max_jobs) {
            return error.QueueFull;
        }

        const id = self.next_job_id;
        self.next_job_id += 1;

        const payload_kind: JobKind = std.meta.activeTag(request.payload);

        try self.jobs.append(self.allocator, .{
            .id = id,
            .kind = payload_kind,
            .generation = request.generation,
            .key_hash = request.key_hash,
            .submitted_ms = std.time.milliTimestamp(),
            .payload = owned_payload,
        });
        self.cv_jobs.signal();
        return id;
    }

    pub fn drainResults(self: *WorkerRuntime, out: *std.ArrayList(Result)) void {
        self.lock.lock();
        defer self.lock.unlock();

        if (self.results.items.len == 0) return;

        out.ensureUnusedCapacity(self.allocator, self.results.items.len) catch return;
        for (self.results.items) |result| {
            out.appendAssumeCapacity(result);
        }
        self.results.clearRetainingCapacity();
    }

    fn pushResult(self: *WorkerRuntime, result: Result) void {
        if (self.results.items.len >= self.config.max_results) {
            _ = self.results.orderedRemove(0);
        }
        self.results.append(self.allocator, result) catch {};
    }

    fn workerMain(self: *WorkerRuntime) void {
        while (true) {
            self.lock.lock();
            while (self.jobs.items.len == 0 and !self.shutdown_requested) {
                self.cv_jobs.wait(&self.lock);
            }

            if (self.shutdown_requested and self.jobs.items.len == 0) {
                self.lock.unlock();
                break;
            }

            const job = self.jobs.orderedRemove(0);
            self.lock.unlock();

            const started_ns: u64 = @intCast(std.time.nanoTimestamp());
            const result_payload = runJob(job.payload);

            var payload_cleanup = job.payload;
            payload_cleanup.deinit(self.allocator);

            const ended_ns: u64 = @intCast(std.time.nanoTimestamp());
            const duration_ns = ended_ns - started_ns;

            self.lock.lock();
            self.pushResult(.{
                .job_id = job.id,
                .kind = job.kind,
                .generation = job.generation,
                .key_hash = job.key_hash,
                .submitted_ms = job.submitted_ms,
                .completed_ms = std.time.milliTimestamp(),
                .duration_ns = duration_ns,
                .status = .ok,
                .payload = result_payload,
            });
            self.lock.unlock();
        }
    }
};

fn runJob(payload: JobPayload) ResultPayload {
    return switch (payload) {
        .status_when => |job| .{ .status_when = .{ .matched = runStatusWhen(job) } },
        .status_command => |job| .{ .status_command = runStatusCommand(job) },
        .pane_metadata => |job| .{ .pane_metadata = runPaneMetadata(job) },
    };
}

fn runStatusWhen(job: StatusWhenJob) bool {
    var env_map = std.process.EnvMap.init(std.heap.page_allocator);
    defer env_map.deinit();

    env_map.put("HEXE_STATUS_PROCESS_RUNNING", if (job.shell_running) "1" else "0") catch {};
    env_map.put("HEXE_STATUS_ALT_SCREEN", if (job.alt_screen) "1" else "0") catch {};
    if (job.last_command) |cmd| env_map.put("HEXE_STATUS_LAST_CMD", cmd) catch {};
    if (job.cwd) |cwd| env_map.put("HEXE_STATUS_CWD", cwd) catch {};

    var child = std.process.Child.init(&.{ "/bin/bash", "-c", job.script }, std.heap.page_allocator);
    child.env_map = &env_map;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    child.spawn() catch return false;

    const start_ms = std.time.milliTimestamp();
    while (std.time.milliTimestamp() - start_ms < job.timeout_ms) {
        const wait_res = std.posix.waitpid(child.id, std.posix.W.NOHANG);
        if (wait_res.pid == child.id) {
            child.id = undefined;
            return std.posix.W.IFEXITED(wait_res.status) and std.posix.W.EXITSTATUS(wait_res.status) == 0;
        }
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }

    _ = child.kill() catch {};
    return false;
}

fn runStatusCommand(job: StatusCommandJob) StatusCommandResult {
    var out: StatusCommandResult = .{ .ok = false, .output_len = 0, .output = undefined };

    const result = std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &.{ "/bin/sh", "-c", job.command },
    }) catch return out;
    defer std.heap.page_allocator.free(result.stdout);
    defer std.heap.page_allocator.free(result.stderr);

    var len = result.stdout.len;
    while (len > 0 and (result.stdout[len - 1] == '\n' or result.stdout[len - 1] == '\r')) {
        len -= 1;
    }
    const copy_len = @min(len, out.output.len);
    @memcpy(out.output[0..copy_len], result.stdout[0..copy_len]);
    out.output_len = @intCast(copy_len);
    out.ok = true;
    return out;
}

fn runPaneMetadata(job: PaneMetadataJob) PaneMetadataResult {
    var out: PaneMetadataResult = .{
        .ok = false,
        .pane_uuid = job.pane_uuid,
        .field = job.field,
        .pid = job.pid,
        .value_len = 0,
        .value = undefined,
    };

    var path_buf: [64]u8 = undefined;
    switch (job.field) {
        .process => {
            const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/comm", .{job.pid}) catch return out;
            const file = std.fs.openFileAbsolute(path, .{}) catch return out;
            defer file.close();

            const len = file.read(&out.value) catch return out;
            if (len == 0) return out;
            const end = if (out.value[len - 1] == '\n') len - 1 else len;
            out.value_len = @intCast(end);
            out.ok = true;
        },
        .cwd => {
            const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/cwd", .{job.pid}) catch return out;
            const link = std.posix.readlink(path, &out.value) catch return out;
            out.value_len = @intCast(link.len);
            out.ok = true;
        },
    }

    return out;
}
