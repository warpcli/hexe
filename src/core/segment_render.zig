const std = @import("std");
const style = @import("style.zig");
const segment = @import("segments/context.zig");

pub const BUILTIN_MARKER_PREFIX = "__hexe_builtin:";

pub fn builtinNameFromMarker(s: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, s, BUILTIN_MARKER_PREFIX)) return null;
    const name = std.mem.trim(u8, s[BUILTIN_MARKER_PREFIX.len..], " \t\r\n");
    if (name.len == 0) return null;
    return name;
}

pub fn mergeStyle(base: style.Style, override: style.Style) style.Style {
    var out = base;
    if (override.fg != .none) out.fg = override.fg;
    if (override.bg != .none) out.bg = override.bg;
    if (override.bold) out.bold = true;
    if (override.italic) out.italic = true;
    if (override.underline) out.underline = true;
    if (override.dim) out.dim = true;
    return out;
}

pub fn resolveSegmentStyle(default_style: style.Style, segment_style: style.Style) style.Style {
    if (segment_style.isEmpty()) return default_style;
    return mergeStyle(default_style, segment_style);
}

pub fn forEachFormattedRun(
    comptime State: type,
    state: *State,
    format: []const u8,
    output: []const u8,
    output_segs: ?[]const segment.Segment,
    base_style: style.Style,
    comptime resolve_builtin: fn (*State, []const u8) ?[]const segment.Segment,
    comptime emit_run: fn (*State, []const u8, style.Style) anyerror!void,
) anyerror!void {
    var i: usize = 0;
    while (i < format.len) {
        if (i + 7 <= format.len and std.mem.eql(u8, format[i..][0..7], "$output")) {
            if (output_segs) |segs| {
                for (segs) |seg_out| {
                    const seg_style = resolveSegmentStyle(base_style, seg_out.style);
                    if (builtinNameFromMarker(seg_out.text)) |builtin_name| {
                        if (resolve_builtin(state, builtin_name)) |built_segs| {
                            for (built_segs) |built| {
                                const built_style = resolveSegmentStyle(seg_style, built.style);
                                try emit_run(state, built.text, built_style);
                            }
                        }
                    } else {
                        try emit_run(state, seg_out.text, seg_style);
                    }
                }
            } else {
                try emit_run(state, output, base_style);
            }
            i += 7;
            continue;
        }

        const len = std.unicode.utf8ByteSequenceLength(format[i]) catch 1;
        const end = @min(i + len, format.len);
        try emit_run(state, format[i..end], base_style);
        i = end;
    }
}
