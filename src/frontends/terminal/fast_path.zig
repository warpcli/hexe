// Tiny dependency-light helper for deciding whether a key event should
// bypass ghostty's full key encoder and be forwarded as raw UTF-8 / C0
// control bytes. Split out from keybinds.zig so unit tests don't need to
// pull in the rest of the terminal frontend.

const std = @import("std");
const core = @import("core");
const log = std.log.scoped(.terminal_fast_path);

const BindKey = core.Config.BindKey;
const BindKeyKind = core.Config.BindKeyKind;

/// Compute raw bytes to forward directly to a pane for "text-producing"
/// keys. Writes into `out` and returns the number of bytes written, or
/// `null` if the caller should fall back to `key_translate.encodeKey`.
///
/// Two fast paths are covered:
///   - Plain Ctrl+letter → canonical C0 control byte (e.g. Ctrl+C = 0x03).
///   - Plain or Alt-ed text keys (.char/.space with text_codepoint and no
///     Ctrl/Super) → raw UTF-8, optionally prefixed with ESC for Alt.
///
/// Rejecting space from this fast path was the root cause of the
/// "space key does not work in some CLI apps" bug: ghostty's encoder was
/// producing `CSI 32 u` under a pane's kitty-keyboard report_all flags,
/// while letters bypassed the encoder entirely and arrived as raw bytes.
/// Including `.space` here restores consistent encoding for all printable
/// characters.
pub fn fastPathBytes(out: []u8, mods: u8, key: BindKey, text_codepoint: ?u21) ?usize {
    // Ctrl+letter canonicalization.
    if (mods == 2 and @as(BindKeyKind, key) == .char) {
        const ch = key.char;
        if ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z')) {
            if (out.len < 1) return null;
            const lc = std.ascii.toLower(ch);
            out[0] = (lc - 'a') + 1;
            return 1;
        }
    }

    const key_kind = @as(BindKeyKind, key);
    if (key_kind != .char and key_kind != .space) return null;
    const cp = text_codepoint orelse return null;
    if ((mods & 2) != 0 or (mods & 8) != 0) return null; // Ctrl/Super → encoder

    var n: usize = 0;
    if ((mods & 1) != 0) {
        if (n >= out.len) return null;
        out[n] = 0x1b;
        n += 1;
    }
    const written = std.unicode.utf8Encode(cp, out[n..]) catch |err| {
        log.debug("failed to encode fast-path key codepoint {d}: {}", .{ cp, err });
        return null;
    };
    n += written;
    return if (n > 0) n else null;
}
