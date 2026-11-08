const std = @import("std");
const dvui = @import("dvui");
const theme = @import("theme.zig");

/// Non-interactive, clipped single-line text for task names and button labels.
pub fn label(src: std.builtin.SourceLocation, text: []const u8, opts: dvui.Options) void {
    var layout: dvui.TextLayoutWidget = undefined;
    layout.init(src, .{ .break_lines = false, .focused = false, .process_events_in_deinit = false }, opts.override(.{
        .min_size_content = .height(opts.fontGet().textHeight()),
        .max_size_content = .{ .w = 0, .h = opts.fontGet().textHeight() },
    }));
    defer layout.deinit();
    addText(&layout, text, opts.strip());
}

/// Runs reference the original UTF-8 bytes: wrapping and font fallback must
/// never insert separators into selections, clipboard contents or saved text.
pub fn addText(layout: *dvui.TextLayoutWidget, text: []const u8, opts: dvui.Options) void {
    const primary = opts.font orelse layout.data().options.fontGet();
    const fallback = primary.withFamily(theme.emoji_family);
    var iter = (std.unicode.Utf8View.initUnchecked(text)).iterator();
    var start: usize = 0;
    var previous: ?struct { fallback: bool, cjk: bool } = null;
    while (true) {
        const offset = iter.i;
        const codepoint = iter.nextCodepoint() orelse break;
        const use_fallback = codepoint >= 0x80 and !hasGlyph(primary, codepoint) and hasGlyph(fallback, codepoint);
        const cjk = isCjk(codepoint);
        if (previous) |prev| {
            if (prev.fallback != use_fallback or prev.cjk != cjk) {
                layout.addText(text[start..offset], opts.override(.{ .font = if (prev.fallback) fallback else primary }));
                start = offset;
            }
        }
        previous = .{ .fallback = use_fallback, .cjk = cjk };
    }
    if (previous) |prev| layout.addText(text[start..], opts.override(.{ .font = if (prev.fallback) fallback else primary }));
}

pub fn hasGlyph(font: dvui.Font, codepoint: u21) bool {
    const cache = dvui.fontCacheGet(font) catch return false;
    return dvui.c.FT_Get_Char_Index(cache.face, codepoint) != 0;
}

// A CJK run has no ASCII spaces for DVUI to backtrack to. This prevents a
// numbered Chinese paragraph from wrapping immediately after its "7. " prefix.
fn isCjk(cp: u21) bool {
    return (cp >= 0x2e80 and cp <= 0x9fff) or
        (cp >= 0xac00 and cp <= 0xd7af) or
        (cp >= 0xf900 and cp <= 0xfaff) or
        (cp >= 0xff00 and cp <= 0xffef) or
        (cp >= 0x20000 and cp <= 0x323af);
}
