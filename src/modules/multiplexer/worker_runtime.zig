const std = @import("std");

pub const JobKind = enum {
    status_when,
    status_command,
    pane_metadata,
};

pub const Job = struct {
    id: u64,
    kind: JobKind,
    generation: u64,
    key_hash: u64,
    submitted_ms: i64,
    payload: ?[]u8,
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

        for (self.jobs.items) |job| {
            if (job.payload) |buf| self.allocator.free(buf);
        }

        self.jobs.deinit(self.allocator);
        self.results.deinit(self.allocator);
        self.workers.deinit(self.allocator);
    }

    pub fn enqueue(self: *WorkerRuntime, kind: JobKind, generation: u64, key_hash: u64, payload: ?[]const u8) !u64 {
        var owned_payload: ?[]u8 = null;
        if (payload) |bytes| {
            owned_payload = try self.allocator.dupe(u8, bytes);
        }
        errdefer if (owned_payload) |buf| self.allocator.free(buf);

        self.lock.lock();
        defer self.lock.unlock();

        if (self.jobs.items.len >= self.config.max_jobs) {
            return error.QueueFull;
        }

        const id = self.next_job_id;
        self.next_job_id += 1;

        try self.jobs.append(self.allocator, .{
            .id = id,
            .kind = kind,
            .generation = generation,
            .key_hash = key_hash,
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

            if (job.payload) |buf| {
                self.allocator.free(buf);
            }

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
            });
            self.lock.unlock();
        }
    }
};
