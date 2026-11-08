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
    theme.app1 = .{
        .fill = .fromHex("#e4f3e8"),
        .fill_hover = .fromHex("#d6eadc"),
        .fill_press = .fromHex("#c5dfcd"),
        .text = .fromHex("#28613a"),
        .border = .fromHex("#8fbd9b"),
    };
    win.themeSet(theme);
}
