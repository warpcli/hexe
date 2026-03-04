const std = @import("std");
const worker = @import("worker_runtime.zig");

test "worker runtime enforces bounded queue" {
    var rt = worker.WorkerRuntime.init(std.testing.allocator, .{
        .worker_count = 1,
        .max_jobs = 1,
        .max_results = 8,
    });
    defer rt.deinit();

    const req: worker.JobRequest = .{
        .generation = 1,
        .key_hash = 11,
        .payload = .{ .status_command = .{ .command = "printf one" } },
    };

    _ = try rt.enqueue(req);
    try std.testing.expectError(error.QueueFull, rt.enqueue(req));
}

test "worker runtime processes queued job and drains results" {
    var rt = worker.WorkerRuntime.init(std.testing.allocator, .{
        .worker_count = 1,
        .max_jobs = 16,
        .max_results = 16,
    });
    try rt.start();
    defer rt.deinit();

    const req: worker.JobRequest = .{
        .generation = 7,
        .key_hash = 0xBEEF,
        .payload = .{ .status_command = .{ .command = "printf hello" } },
    };

    const job_id = try rt.enqueue(req);
    var results: std.ArrayList(worker.Result) = .empty;
    defer results.deinit(std.testing.allocator);

    var tries: usize = 0;
    while (tries < 200 and results.items.len == 0) : (tries += 1) {
        std.Thread.sleep(2 * std.time.ns_per_ms);
        rt.drainResults(&results);
    }

    try std.testing.expect(results.items.len > 0);
    try std.testing.expectEqual(job_id, results.items[0].job_id);
    try std.testing.expectEqual(@as(u64, 7), results.items[0].generation);
}

test "inflight tracker dedupes and rejects stale completion" {
    var tracker = worker.InflightTracker.init(std.testing.allocator);
    defer tracker.deinit();

    try std.testing.expect(tracker.tryStart(42, .{ .job_id = 100, .generation = 3 }));
    try std.testing.expect(!tracker.tryStart(42, .{ .job_id = 101, .generation = 3 }));

    const stale: worker.Result = .{
        .job_id = 999,
        .kind = .status_when,
        .generation = 3,
        .key_hash = 42,
        .submitted_ms = 0,
        .completed_ms = 0,
        .duration_ns = 0,
        .status = .ok,
        .payload = .{ .status_when = .{ .matched = false } },
    };
    try std.testing.expect(!tracker.clearIfCurrent(42, stale));
    try std.testing.expect(tracker.contains(42));

    const current: worker.Result = .{
        .job_id = 100,
        .kind = .status_when,
        .generation = 3,
        .key_hash = 42,
        .submitted_ms = 0,
        .completed_ms = 0,
        .duration_ns = 0,
        .status = .ok,
        .payload = .{ .status_when = .{ .matched = true } },
    };
    try std.testing.expect(tracker.clearIfCurrent(42, current));
    try std.testing.expect(!tracker.contains(42));
}
