const std = @import("std");

pub const SessionSplitDir = enum {
    horizontal,
    vertical,
};

pub const SessionPaneKind = enum {
    split,
    float,
};

pub const SessionLayoutNode = union(enum) {
    pane: [32]u8,
    split: Split,

    pub const Split = struct {
        dir: SessionSplitDir,
        ratio: f32,
        first: *SessionLayoutNode,
        second: *SessionLayoutNode,
    };

    pub fn deinit(self: *SessionLayoutNode, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .pane => {},
            .split => |*split| {
                split.first.deinit(allocator);
                allocator.destroy(split.first);
                split.second.deinit(allocator);
                allocator.destroy(split.second);
            },
        }
    }

    pub fn clone(self: *const SessionLayoutNode, allocator: std.mem.Allocator) !*SessionLayoutNode {
        const node = try allocator.create(SessionLayoutNode);
        errdefer allocator.destroy(node);

        switch (self.*) {
            .pane => |uuid| node.* = .{ .pane = uuid },
            .split => |split| {
                const first = try split.first.clone(allocator);
                errdefer {
                    first.deinit(allocator);
                    allocator.destroy(first);
                }
                const second = try split.second.clone(allocator);
                errdefer {
                    second.deinit(allocator);
                    allocator.destroy(second);
                }
                node.* = .{
                    .split = .{
                        .dir = split.dir,
                        .ratio = split.ratio,
                        .first = first,
                        .second = second,
                    },
                };
            },
        }

        return node;
    }
};

pub const SessionTab = struct {
    uuid: [32]u8,
    name: []u8,
    root: ?*SessionLayoutNode = null,
    focused_pane_uuid: ?[32]u8 = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *SessionTab) void {
        if (self.root) |root| {
            root.deinit(self.allocator);
            self.allocator.destroy(root);
        }
        self.allocator.free(self.name);
    }

    pub fn clone(self: *const SessionTab, allocator: std.mem.Allocator) !SessionTab {
        return .{
            .uuid = self.uuid,
            .name = try allocator.dupe(u8, self.name),
            .root = if (self.root) |root| try root.clone(allocator) else null,
            .focused_pane_uuid = self.focused_pane_uuid,
            .allocator = allocator,
        };
    }
};

pub const SessionPane = struct {
    uuid: [32]u8,
    kind: SessionPaneKind,
    parent_tab: ?usize = null,
    sticky: bool = false,
    is_pwd: bool = false,
    float_key: u8 = 0,
};

pub const SessionFloat = struct {
    pane_uuid: [32]u8,
    parent_tab: ?usize = null,
    visible: bool = true,
    tab_visible: u64 = 0,
    sticky: bool = false,
    is_pwd: bool = false,
    float_key: u8 = 0,
    width_pct: u8 = 60,
    height_pct: u8 = 60,
    pos_x_pct: u8 = 50,
    pos_y_pct: u8 = 50,
    pad_x: u8 = 1,
    pad_y: u8 = 0,
};

pub const SessionSnapshot = struct {
    allocator: std.mem.Allocator,
    uuid: [32]u8,
    session_name: []u8,
    tab_counter: usize,
    active_tab: usize,
    active_float_uuid: ?[32]u8 = null,
    focused_pane_uuid: ?[32]u8 = null,
    tabs: std.ArrayList(SessionTab),
    panes: std.AutoHashMap([32]u8, SessionPane),
    floats: std.ArrayList(SessionFloat),

    pub fn initMinimal(allocator: std.mem.Allocator, uuid: [32]u8, session_name: []const u8) !SessionSnapshot {
        return .{
            .allocator = allocator,
            .uuid = uuid,
            .session_name = try allocator.dupe(u8, session_name),
            .tab_counter = 0,
            .active_tab = 0,
            .tabs = .empty,
            .panes = std.AutoHashMap([32]u8, SessionPane).init(allocator),
            .floats = .empty,
        };
    }

    pub fn deinit(self: *SessionSnapshot) void {
        for (self.tabs.items) |*tab| tab.deinit();
        self.tabs.deinit(self.allocator);
        self.panes.deinit();
        self.floats.deinit(self.allocator);
        self.allocator.free(self.session_name);
    }

    pub fn clone(self: *const SessionSnapshot, allocator: std.mem.Allocator) !SessionSnapshot {
        var tabs: std.ArrayList(SessionTab) = .empty;
        errdefer {
            for (tabs.items) |*tab| tab.deinit();
            tabs.deinit(allocator);
        }
        for (self.tabs.items) |tab| {
            try tabs.append(allocator, try tab.clone(allocator));
        }

        var panes = std.AutoHashMap([32]u8, SessionPane).init(allocator);
        errdefer panes.deinit();
        var pane_iter = self.panes.iterator();
        while (pane_iter.next()) |entry| {
            try panes.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        var floats: std.ArrayList(SessionFloat) = .empty;
        errdefer floats.deinit(allocator);
        try floats.appendSlice(allocator, self.floats.items);

        return .{
            .allocator = allocator,
            .uuid = self.uuid,
            .session_name = try allocator.dupe(u8, self.session_name),
            .tab_counter = self.tab_counter,
            .active_tab = self.active_tab,
            .active_float_uuid = self.active_float_uuid,
            .focused_pane_uuid = self.focused_pane_uuid,
            .tabs = tabs,
            .panes = panes,
            .floats = floats,
        };
    }

    pub fn fromMuxJson(allocator: std.mem.Allocator, mux_state_json: []const u8) !SessionSnapshot {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, mux_state_json, .{});
        defer parsed.deinit();

        const root = switch (parsed.value) {
            .object => |obj| obj,
            else => return error.InvalidStateJson,
        };

        const uuid_str = stringField(root, "uuid") orelse return error.InvalidStateJson;
        const session_name = stringField(root, "session_name") orelse return error.InvalidStateJson;
        const tabs_val = root.get("tabs") orelse return error.InvalidStateJson;
        const floats_val = root.get("floats") orelse return error.InvalidStateJson;

        var snapshot = try SessionSnapshot.initMinimal(allocator, try parseUuid(uuid_str), session_name);
        errdefer snapshot.deinit();

        snapshot.tab_counter = intField(root, "tab_counter") orelse 0;
        snapshot.active_tab = intField(root, "active_tab") orelse 0;

        const tabs = switch (tabs_val) {
            .array => |arr| arr,
            else => return error.InvalidStateJson,
        };
        const floats = switch (floats_val) {
            .array => |arr| arr,
            else => return error.InvalidStateJson,
        };

        for (tabs.items, 0..) |tab_val, tab_idx| {
            const tab_obj = switch (tab_val) {
                .object => |obj| obj,
                else => return error.InvalidStateJson,
            };

            var id_to_uuid = std.AutoHashMap(u16, [32]u8).init(allocator);
            defer id_to_uuid.deinit();

            const splits_val = tab_obj.get("splits") orelse return error.InvalidStateJson;
            const splits = switch (splits_val) {
                .array => |arr| arr,
                else => return error.InvalidStateJson,
            };
            for (splits.items) |split_val| {
                const split_obj = switch (split_val) {
                    .object => |obj| obj,
                    else => return error.InvalidStateJson,
                };

                const pane_uuid = try parseUuid(stringField(split_obj, "uuid") orelse return error.InvalidStateJson);
                const split_id: u16 = @intCast(intField(split_obj, "id") orelse return error.InvalidStateJson);
                try id_to_uuid.put(split_id, pane_uuid);
                try snapshot.panes.put(pane_uuid, .{
                    .uuid = pane_uuid,
                    .kind = .split,
                    .parent_tab = tab_idx,
                });
            }

            const tab_uuid = try parseUuid(stringField(tab_obj, "uuid") orelse return error.InvalidStateJson);
            var tab = SessionTab{
                .uuid = tab_uuid,
                .name = try allocator.dupe(u8, stringField(tab_obj, "name") orelse return error.InvalidStateJson),
                .allocator = allocator,
            };
            errdefer tab.deinit();

            if (intField(tab_obj, "focused_split_id")) |focused_split_id| {
                tab.focused_pane_uuid = id_to_uuid.get(@intCast(focused_split_id));
            }

            if (tab_obj.get("tree")) |tree_val| {
                if (tree_val != .null) {
                    tab.root = try parseLayoutNode(allocator, tree_val, &id_to_uuid);
                }
            }

            try snapshot.tabs.append(allocator, tab);
        }

        for (floats.items, 0..) |float_val, float_idx| {
            const float_obj = switch (float_val) {
                .object => |obj| obj,
                else => return error.InvalidStateJson,
            };

            const pane_uuid = try parseUuid(stringField(float_obj, "uuid") orelse return error.InvalidStateJson);
            const parent_tab_int = intField(float_obj, "parent_tab");
            const float_state = SessionFloat{
                .pane_uuid = pane_uuid,
                .parent_tab = if (parent_tab_int) |idx| @intCast(idx) else null,
                .visible = boolField(float_obj, "visible") orelse true,
                .tab_visible = if (intField(float_obj, "tab_visible")) |mask| @intCast(mask) else 0,
                .sticky = boolField(float_obj, "sticky") orelse false,
                .is_pwd = boolField(float_obj, "is_pwd") orelse false,
                .float_key = if (intField(float_obj, "float_key")) |key| @intCast(key) else 0,
                .width_pct = if (intField(float_obj, "float_width_pct")) |v| @intCast(v) else 60,
                .height_pct = if (intField(float_obj, "float_height_pct")) |v| @intCast(v) else 60,
                .pos_x_pct = if (intField(float_obj, "float_pos_x_pct")) |v| @intCast(v) else 50,
                .pos_y_pct = if (intField(float_obj, "float_pos_y_pct")) |v| @intCast(v) else 50,
                .pad_x = if (intField(float_obj, "float_pad_x")) |v| @intCast(v) else 1,
                .pad_y = if (intField(float_obj, "float_pad_y")) |v| @intCast(v) else 0,
            };

            try snapshot.floats.append(allocator, float_state);
            try snapshot.panes.put(pane_uuid, .{
                .uuid = pane_uuid,
                .kind = .float,
                .parent_tab = float_state.parent_tab,
                .sticky = float_state.sticky,
                .is_pwd = float_state.is_pwd,
                .float_key = float_state.float_key,
            });

            if (intField(root, "active_floating")) |active_float_idx| {
                if (@as(usize, @intCast(active_float_idx)) == float_idx) {
                    snapshot.active_float_uuid = pane_uuid;
                }
            }
        }

        if (snapshot.active_tab >= snapshot.tabs.items.len and snapshot.tabs.items.len > 0) {
            snapshot.active_tab = 0;
        }

        if (snapshot.active_float_uuid) |active_float_uuid| {
            snapshot.focused_pane_uuid = active_float_uuid;
        } else if (snapshot.tabs.items.len > 0) {
            snapshot.focused_pane_uuid = snapshot.tabs.items[snapshot.active_tab].focused_pane_uuid;
        }

        return snapshot;
    }
};

fn parseLayoutNode(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    id_to_uuid: *const std.AutoHashMap(u16, [32]u8),
) !*SessionLayoutNode {
    const obj = switch (value) {
        .object => |obj| obj,
        else => return error.InvalidStateJson,
    };

    const node_type = stringField(obj, "type") orelse return error.InvalidStateJson;
    const node = try allocator.create(SessionLayoutNode);
    errdefer allocator.destroy(node);

    if (std.mem.eql(u8, node_type, "pane")) {
        const pane_id: u16 = @intCast(intField(obj, "id") orelse return error.InvalidStateJson);
        const pane_uuid = id_to_uuid.get(pane_id) orelse return error.InvalidStateJson;
        node.* = .{ .pane = pane_uuid };
        return node;
    }

    if (std.mem.eql(u8, node_type, "split")) {
        const dir_str = stringField(obj, "dir") orelse return error.InvalidStateJson;
        const first_val = obj.get("first") orelse return error.InvalidStateJson;
        const second_val = obj.get("second") orelse return error.InvalidStateJson;
        const first = try parseLayoutNode(allocator, first_val, id_to_uuid);
        errdefer {
            first.deinit(allocator);
            allocator.destroy(first);
        }
        const second = try parseLayoutNode(allocator, second_val, id_to_uuid);
        errdefer {
            second.deinit(allocator);
            allocator.destroy(second);
        }

        node.* = .{
            .split = .{
                .dir = if (std.mem.eql(u8, dir_str, "horizontal")) .horizontal else .vertical,
                .ratio = floatField(obj, "ratio") orelse 0.5,
                .first = first,
                .second = second,
            },
        };
        return node;
    }

    return error.InvalidStateJson;
}

fn parseUuid(value: []const u8) ![32]u8 {
    if (value.len != 32) return error.InvalidStateJson;
    var out: [32]u8 = undefined;
    @memcpy(&out, value[0..32]);
    return out;
}

fn stringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn intField(obj: std.json.ObjectMap, key: []const u8) ?usize {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        else => null,
    };
}

fn floatField(obj: std.json.ObjectMap, key: []const u8) ?f32 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .float => |f| @floatCast(f),
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}

fn boolField(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .bool => |b| b,
        else => null,
    };
}
