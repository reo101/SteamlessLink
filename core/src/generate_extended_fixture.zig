//! Emit the real descriptors and mapper output for the Linux integration test.
const std = @import("std");
const extended = @import("extended_gamepad.zig");
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.InvalidArgument;
    var report = [_]u8{0} ** 46;
    report[0] = 0x45;
    var neutral: [extended.PACKET_SIZE]u8 = undefined;
    try extended.mapTritonToInput(&report, &neutral);
    // A, four paddles, both touch contacts.
    std.mem.writeInt(u32, report[2..6], 0x02260181, .little);
    std.mem.writeInt(i16, report[18..20], -1000, .little);
    std.mem.writeInt(i16, report[20..22], 2000, .little);
    std.mem.writeInt(u16, report[22..24], 1234, .little);
    std.mem.writeInt(i16, report[24..26], 3000, .little);
    std.mem.writeInt(i16, report[26..28], -4000, .little);
    std.mem.writeInt(u16, report[28..30], 2345, .little);
    std.mem.writeInt(i16, report[34..36], 16384, .little);
    std.mem.writeInt(i16, report[42..44], -32768, .little);
    var active: [extended.PACKET_SIZE]u8 = undefined;
    try extended.mapTritonToInput(&report, &active);
    const json = try std.json.Stringify.valueAlloc(init.arena.allocator(), .{
        .names = extended.NAMES,
        .descriptors = extended.DESCRIPTORS,
        .sizes = extended.REPORT_SIZES,
        .devices = extended.REPORT_DEVICES,
        .active = active,
        .neutral = neutral,
    }, .{ .emit_strings_as_arrays = true });
    const file = try std.Io.Dir.cwd().createFile(init.io, args[1], .{});
    defer file.close(init.io);
    try file.writeStreamingAll(init.io, json);
}
