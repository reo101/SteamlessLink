//! Runtime log level for the daemons.
//!
//! `std.log` filters at comptime only, so a `--log-level` flag needs a global
//! level and a `logFn` that drops messages the comptime level admitted.
//! Executables install `logFn` through `std_options`.

const std = @import("std");

/// Set once during argument parsing, before worker threads start.
pub var level: std.log.Level = .info;

pub fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@backingInt(message_level) > @backingInt(level)) return;
    std.log.defaultLog(message_level, scope, format, args);
}

pub fn parseLevel(value: []const u8) ?std.log.Level {
    if (std.mem.eql(u8, value, "debug")) return .debug;
    if (std.mem.eql(u8, value, "info")) return .info;
    if (std.mem.eql(u8, value, "warning")) return .warn;
    if (std.mem.eql(u8, value, "error")) return .err;
    return null;
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

test "log level parsing maps CLI names" {
    try std.testing.expectEqual(std.log.Level.debug, parseLevel("debug").?);
    try std.testing.expectEqual(std.log.Level.warn, parseLevel("warning").?);
    try std.testing.expectEqual(std.log.Level.err, parseLevel("error").?);
    try std.testing.expectEqual(@as(?std.log.Level, null), parseLevel("bogus"));
}

test "hexHead formats at most 8 bytes" {
    var out: [23]u8 = undefined;
    const head = hexHead(&.{ 0x45, 0x01, 0xff, 0x00, 0x10, 0x20, 0x30, 0x40, 0x50 }, &out);
    try std.testing.expectEqualStrings("45 01 ff 00 10 20 30 40", head);
}
