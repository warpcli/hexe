const core = @import("core");

const BindKey = core.Config.BindKey;
const BindKeyKind = core.Config.BindKeyKind;

/// Encode a key + modifiers into legacy byte sequences for pane input.
/// Returns encoded length or null if output buffer is too small.
pub fn encodeLegacyKey(out: []u8, mods: u8, key: BindKey, use_application_arrows: bool) ?usize {
    var n: usize = 0;

    switch (@as(BindKeyKind, key)) {
        .space => {
            if ((mods & 2) != 0) {
                if (out.len < 1) return null;
                out[n] = 0x00;
                n += 1;
            } else {
                if ((mods & 1) != 0) {
                    if (out.len < n + 1) return null;
                    out[n] = 0x1b;
                    n += 1;
                }
                if (out.len < n + 1) return null;
                out[n] = ' ';
                n += 1;
            }
        },
        .char => {
            var ch: u8 = key.char;
            if ((mods & 4) != 0 and ch == 0x09) {
                if (out.len < n + 3) return null;
                out[n] = 0x1b;
                n += 1;
                out[n] = '[';
                n += 1;
                out[n] = 'Z';
                n += 1;
            } else {
                if ((mods & 4) != 0 and ch >= 'a' and ch <= 'z') ch = ch - 'a' + 'A';
                if ((mods & 2) != 0) {
                    if (ch >= 'a' and ch <= 'z') ch = ch - 'a' + 1;
                    if (ch >= 'A' and ch <= 'Z') ch = ch - 'A' + 1;
                }
                if ((mods & 1) != 0) {
                    if (out.len < n + 1) return null;
                    out[n] = 0x1b;
                    n += 1;
                }
                if (out.len < n + 1) return null;
                out[n] = ch;
                n += 1;
            }
        },
        .up, .down, .left, .right => {
            const dir_char: u8 = switch (@as(BindKeyKind, key)) {
                .up => 'A',
                .down => 'B',
                .right => 'C',
                .left => 'D',
                else => unreachable,
            };

            if (out.len < n + 2) return null;
            out[n] = 0x1b;
            n += 1;

            if (mods == 0 and use_application_arrows) {
                out[n] = 'O';
                n += 1;
                if (out.len < n + 1) return null;
                out[n] = dir_char;
                n += 1;
            } else {
                out[n] = '[';
                n += 1;

                if (mods != 0) {
                    var csi_mod: u8 = 1;
                    if ((mods & 4) != 0) csi_mod |= 1; // shift
                    if ((mods & 1) != 0) csi_mod |= 2; // alt
                    if ((mods & 2) != 0) csi_mod |= 4; // ctrl

                    if (out.len < n + 3) return null;
                    out[n] = '1';
                    n += 1;
                    out[n] = ';';
                    n += 1;
                    out[n] = '0' + csi_mod;
                    n += 1;
                }

                if (out.len < n + 1) return null;
                out[n] = dir_char;
                n += 1;
            }
        },
    }

    return n;
}
