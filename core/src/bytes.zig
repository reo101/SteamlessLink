const std = @import("std");

pub fn readU16Le(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}

pub fn readU32Le(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

pub fn readU64Le(bytes: []const u8, offset: usize) u64 {
    return std.mem.readInt(u64, bytes[offset..][0..8], .little);
}

pub fn writeU16Le(bytes: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[offset..][0..2], value, .little);
}

pub fn writeU32Le(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
}

test "little-endian round trip" {
    var buf: [8]u8 = undefined;
    writeU32Le(&buf, 0, 0xdeadbeef);
    writeU16Le(&buf, 4, 0x1303);
    try std.testing.expectEqual(@as(u32, 0xdeadbeef), readU32Le(&buf, 0));
    try std.testing.expectEqual(@as(u16, 0x1303), readU16Le(&buf, 4));
}
