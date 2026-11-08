const dvui = @import("dvui");

pub const emoji_family = "Noto Emoji";
const embedded_fonts = [_]dvui.Font.Source{
    .{ .family = dvui.Font.array("HarmonyOS Sans SC"), .bytes = @embedFile("harmonyos-sans-sc") },
    .{ .family = dvui.Font.array(emoji_family), .bytes = @embedFile("noto-emoji") },
};

pub fn apply(win: *dvui.Window) void {
    var theme = win.theme;
    theme.name = "Matterlog";
    theme.embedded_fonts = &embedded_fonts;
    const body_font = dvui.Font.find(.{
        .family = "HarmonyOS Sans SC",
        .size = 11,
        .line_height_factor = 1.3,
    });
    theme.font_body = body_font;
    theme.font_heading = body_font.withSize(13);
    theme.font_title = body_font.withSize(16);
    theme.text = .fromHex(if (theme.dark) "#e5edf7" else "#223047");
    theme.fill = .fromHex(if (theme.dark) "#1b2431" else "#ffffff");
    theme.border = .fromHex(if (theme.dark) "#435166" else "#d6dde7");
    theme.focus = .fromHex(if (theme.dark) "#8ab4ff" else "#2f6fed");
    theme.window = .{ .fill = .fromHex(if (theme.dark) "#141b25" else "#f5f7fb") };
    theme.control = .{
        .fill = .fromHex(if (theme.dark) "#283445" else "#edf1f6"),
        .fill_hover = .fromHex(if (theme.dark) "#34445b" else "#e2eaf5"),
        .fill_press = .fromHex(if (theme.dark) "#405572" else "#d5e1f2"),
    };
    theme.highlight = .{
        .fill = .fromHex("#2f6fed"),
        .fill_hover = .fromHex("#245dce"),
        .fill_press = .fromHex("#1d4eae"),
        .text = .white,
    };
    theme.app1 = .{
        .fill = .fromHex(if (theme.dark) "#214231" else "#e4f3e8"),
        .fill_hover = .fromHex(if (theme.dark) "#2a513b" else "#d6eadc"),
        .fill_press = .fromHex(if (theme.dark) "#345f45" else "#c5dfcd"),
        .text = .fromHex(if (theme.dark) "#a4dfb9" else "#28613a"),
        .border = .fromHex(if (theme.dark) "#47775a" else "#8fbd9b"),
    };
    win.themeSet(theme);
}

pub fn mutedText() dvui.Color {
    return .fromHex(if (dvui.themeGet().dark) "#a9b8cc" else "#58677b");
}
