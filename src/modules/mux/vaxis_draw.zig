const Renderer = @import("render_core.zig").Renderer;
const Color = @import("render_types.zig").Color;
const Cell = @import("render_types.zig").Cell;

pub fn putChar(renderer: *Renderer, x: u16, y: u16, cp: u21, fg: ?Color, bg: ?Color, bold: bool) void {
    var cell: Cell = .{ .char = cp, .bold = bold };
    if (fg) |c| cell.fg = c;
    if (bg) |c| cell.bg = c;
    renderer.setCell(x, y, cell);
}
