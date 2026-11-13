pub const default_percent: u16 = 100;
pub const min_percent: u16 = 80;
pub const max_percent: u16 = 150;
pub const step: u16 = 10;

pub fn restore(value: i64) u16 {
    return if (value >= min_percent and value <= max_percent) @intCast(value) else default_percent;
}

pub fn scale(percent: u16) f32 {
    return @as(f32, @floatFromInt(percent)) / 100;
}
