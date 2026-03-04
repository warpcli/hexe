const std = @import("std");
const worker = @import("worker_runtime.zig");

test "stress: async status and metadata jobs complete under load" {
    var rt = worker.WorkerRuntime.init(std.testing.allocator, .{
        .worker_count = 2,
        .max_jobs = 512,
        .max_results = 512,
    });
    try rt.start();
    defer rt.deinit();

    const total_jobs: usize = 80;
    var submitted: usize = 0;
    while (submitted < total_jobs) : (submitted += 1) {
        if ((submitted % 2) == 0) {
            const req: worker.JobRequest = .{
                .generation = submitted,
                .key_hash = submitted,
                .payload = .{ .status_command = .{ .command = "printf ok" } },
            };
            _ = try rt.enqueue(req);
        } else {
            const req: worker.JobRequest = .{
                .generation = submitted,
                .key_hash = submitted,
                .payload = .{ .pane_metadata = .{
                    .pane_uuid = [_]u8{0} ** 32,
                    .field = .process,
                    .pid = -1,
                } },
            };
            _ = try rt.enqueue(req);
        }
    }

    var completed: usize = 0;
    var spins: usize = 0;
    var drained: std.ArrayList(worker.Result) = .empty;
    defer drained.deinit(std.testing.allocator);

    while (completed < total_jobs and spins < 400) : (spins += 1) {
        std.Thread.sleep(2 * std.time.ns_per_ms);
        rt.drainResults(&drained);
        completed += drained.items.len;
        drained.clearRetainingCapacity();
    }

    try std.testing.expectEqual(total_jobs, completed);
}

test "stress: stale metadata completions are rejected by inflight tracker" {
    var tracker = worker.InflightTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const key: worker.InflightKey = 0xABCD;
    try std.testing.expect(tracker.tryStart(key, .{ .job_id = 1000, .generation = 10 }));

    var stale_count: usize = 0;
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const stale: worker.Result = .{
            .job_id = @as(u64, 900) + i,
            .kind = .pane_metadata,
            .generation = @as(u64, 9),
            .key_hash = key,
            .submitted_ms = 0,
            .completed_ms = 0,
            .duration_ns = 0,
            .status = .ok,
            .payload = .{ .pane_metadata = .{
                .ok = true,
                .pane_uuid = [_]u8{0} ** 32,
                .field = .process,
                .pid = 1,
                .value_len = 0,
                .value = undefined,
            } },
        };
        if (!tracker.clearIfCurrent(key, stale)) stale_count += 1;
    }

    try std.testing.expectEqual(@as(usize, 50), stale_count);
    try std.testing.expect(tracker.contains(key));

    const current: worker.Result = .{
        .job_id = 1000,
        .kind = .pane_metadata,
        .generation = 10,
        .key_hash = key,
        .submitted_ms = 0,
        .completed_ms = 0,
        .duration_ns = 0,
        .status = .ok,
        .payload = .{ .pane_metadata = .{
            .ok = true,
            .pane_uuid = [_]u8{0} ** 32,
            .field = .cwd,
            .pid = 1,
            .value_len = 0,
            .value = undefined,
        } },
    };
    try std.testing.expect(tracker.clearIfCurrent(key, current));
    try std.testing.expect(!tracker.contains(key));
}
