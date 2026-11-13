const std = @import("std");
const dvui = @import("dvui");
const theme = @import("theme.zig");

/// Non-interactive, ellipsized single-line text for task names and button labels.
pub fn label(src: std.builtin.SourceLocation, text: []const u8, opts: dvui.Options) void {
    var layout: dvui.TextLayoutWidget = undefined;
    layout.init(src, .{ .break_lines = false, .focused = false, .process_events_in_deinit = false }, opts.override(.{
        .min_size_content = .height(opts.fontGet().textHeight()),
        .max_size_content = .{ .w = 0, .h = opts.fontGet().textHeight() },
    }));
    defer layout.deinit();
    const visible = fitLabel(text, opts.fontGet(), layout.data().contentRect().w);
    addText(&layout, visible, opts.strip());
}

/// Returns frame-local display text. Stored titles and accessibility labels
/// retain the original string; fitting uses the same font runs as rendering.
pub fn fitLabel(text: []const u8, font: dvui.Font, width: f32) []const u8 {
    var runs = TextRuns.init(text, font);
    var full_width: f32 = 0;
    while (runs.next()) |run| full_width += run.font.textSize(run.text).w;
    if (full_width <= width) return text;

    const ellipsis = "…";
    const ellipsis_width = font.textSize(ellipsis).w;
    if (width < ellipsis_width) return "";
    var remaining = width - ellipsis_width;
    var end: usize = 0;
    runs = TextRuns.init(text, font);
    while (runs.next()) |run| {
        var count: usize = 0;
        const size = run.font.textSizeEx(run.text, .{ .max_width = remaining, .end_idx = &count });
        end += count;
        remaining = @max(0, remaining - size.w);
        if (count < run.text.len) break;
    }
    return std.fmt.allocPrint(dvui.currentWindow().arena(), "{s}{s}", .{ text[0..end], ellipsis }) catch ellipsis;
}

/// Runs reference the original UTF-8 bytes: wrapping and font fallback must
/// never insert separators into selections, clipboard contents or saved text.
pub fn addText(layout: *dvui.TextLayoutWidget, text: []const u8, opts: dvui.Options) void {
    const primary = opts.font orelse layout.data().options.fontGet();
    var runs = TextRuns.init(text, primary);
    while (runs.next()) |run| {
        layout.addText(run.text, opts.override(.{ .font = run.font }));
    }
}

const TextRuns = struct {
    text: []const u8,
    primary: dvui.Font,
    fallback: dvui.Font,
    offset: usize = 0,

    const Kind = struct { fallback: bool, cjk: bool };
    const Run = struct { text: []const u8, font: dvui.Font };

    fn init(text: []const u8, primary: dvui.Font) TextRuns {
        return .{ .text = text, .primary = primary, .fallback = primary.withFamily(theme.emoji_family) };
    }

    fn kind(self: TextRuns, cp: u21) Kind {
        return .{
            .fallback = cp >= 0x80 and !hasGlyph(self.primary, cp) and hasGlyph(self.fallback, cp),
            .cjk = isCjk(cp),
        };
    }

    fn next(self: *TextRuns) ?Run {
        const start = self.offset;
        var iter = (std.unicode.Utf8View.initUnchecked(self.text[start..])).iterator();
        const first = self.kind(iter.nextCodepoint() orelse return null);
        while (true) {
            const end = iter.i;
            const cp = iter.nextCodepoint() orelse break;
            const current = self.kind(cp);
            if (first.fallback != current.fallback or first.cjk != current.cjk) {
                self.offset = start + end;
                return .{ .text = self.text[start..self.offset], .font = if (first.fallback) self.fallback else self.primary };
            }
        }
        self.offset = self.text.len;
        return .{ .text = self.text[start..], .font = if (first.fallback) self.fallback else self.primary };
    }
};

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
