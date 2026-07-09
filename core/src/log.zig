const std = @import("std");

pub const LogLevel = enum(u8) {
    debug = 0,
    info = 1,
    warning = 2,
    err = 3,

    pub fn parse(value: []const u8) ?LogLevel {
        if (std.mem.eql(u8, value, "debug")) return .debug;
        if (std.mem.eql(u8, value, "info")) return .info;
        if (std.mem.eql(u8, value, "warning")) return .warning;
        if (std.mem.eql(u8, value, "error")) return .err;
        return null;
    }

    pub fn label(level: LogLevel) []const u8 {
        return switch (level) {
            .debug => "DEBUG",
            .info => "INFO",
            .warning => "WARNING",
            .err => "ERROR",
        };
    }
};

pub fn log(min_level: LogLevel, level: LogLevel, comptime format: []const u8, args: anytype) void {
    if (@intFromEnum(level) < @intFromEnum(min_level)) return;
    std.debug.print("{s} " ++ format ++ "\n", .{level.label()} ++ args);
}

pub fn hexHead(data: []const u8, out: *[23]u8) []const u8 {
    const hex = "0123456789abcdef";
    const count = @min(data.len, 8);
    var index: usize = 0;
    for (data[0..count], 0..) |byte, i| {
        if (i > 0) {
            out[index] = ' ';
            index += 1;
        }
        out[index] = hex[byte >> 4];
        out[index + 1] = hex[byte & 0x0f];
        index += 2;
    }
    return out[0..index];
}

test "log level parsing" {
    try std.testing.expectEqual(LogLevel.debug, LogLevel.parse("debug").?);
    try std.testing.expectEqual(LogLevel.err, LogLevel.parse("error").?);
    try std.testing.expectEqual(@as(?LogLevel, null), LogLevel.parse("bogus"));
}

test "hexHead formats at most 8 bytes" {
    var out: [23]u8 = undefined;
    const head = hexHead(&.{ 0x45, 0x01, 0xff, 0x00, 0x10, 0x20, 0x30, 0x40, 0x50 }, &out);
    try std.testing.expectEqualStrings("45 01 ff 00 10 20 30 40", head);
}
