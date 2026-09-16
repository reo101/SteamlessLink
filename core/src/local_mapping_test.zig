const std = @import("std");
const triton = @import("triton.zig");

fn put16(report: []u8, offset: usize, value: i16) void {
    std.mem.writeInt(i16, report[offset..][0..2], value, .little);
}
fn buttons(report: []u8, value: u32) void {
    std.mem.writeInt(u32, report[2..6], value, .little);
}
fn axis(packet: []const u8, offset: usize) i16 {
    return std.mem.readInt(i16, packet[offset..][0..2], .little);
}

test "default local mapping is byte identical for all Triton report types" {
    for ([_]u8{ 0x42, 0x45, 0x47 }) |id| {
        var report = [_]u8{0} ** 46;
        report[0] = id;
        buttons(&report, 0xffffffff);
        for ([_]usize{ 6, 10, 14, 40 }) |offset| put16(&report, offset, 32767);
        for ([_]usize{ 8, 12, 16, 42 }) |offset| put16(&report, offset, -32768);
        var baseline: [20]u8 = undefined;
        var local: [20]u8 = undefined;
        try triton.mapTritonToXbox360(&report, &baseline);
        try triton.mapTritonToLocalXbox360(&report, &local, .{});
        try std.testing.expectEqualSlices(u8, &baseline, &local);
    }
}

test "rear grips add mappings without suppressing physical buttons" {
    var report = [_]u8{0} ** 18;
    report[0] = 0x45;
    const options = triton.LocalOptions{ .grips = .{ 0x1000, 0x2000, 0x4000, 0x8000 } };
    var packet: [20]u8 = undefined;
    for ([_]u32{ 0x20000, 0x40000, 0x80, 0x100 }, options.grips) |grip, mapped| {
        buttons(&report, grip | triton.Buttons.L);
        try triton.mapTritonToLocalXbox360(&report, &packet, options);
        try std.testing.expectEqual(mapped | 0x100, std.mem.readInt(u32, packet[0..4], .little));
    }
    buttons(&report, 0);
    try triton.mapTritonToLocalXbox360(&report, &packet, options);
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, packet[0..4], .little));
}

test "pad replacement requires contact and restores the physical stick on release" {
    for ([_]u8{ 0x42, 0x45, 0x47 }) |id| {
        var report = [_]u8{0} ** 46;
        report[0] = id;
        put16(&report, 14, 123);
        put16(&report, 16, -456);
        const offset: usize = if (id == 0x47) 26 else 24;
        put16(&report, offset, 30000);
        put16(&report, offset + 2, -20000);
        var packet: [20]u8 = undefined;
        const options = triton.LocalOptions{ .right_pad_stick = true };
        buttons(&report, 0x200000);
        try triton.mapTritonToLocalXbox360(&report, &packet, options);
        try std.testing.expectEqual(@as(i16, 30000), axis(&packet, 10));
        try std.testing.expectEqual(@as(i16, -20000), axis(&packet, 12));
        buttons(&report, 0);
        try triton.mapTritonToLocalXbox360(&report, &packet, options);
        try std.testing.expectEqual(@as(i16, 123), axis(&packet, 10));
        try std.testing.expectEqual(@as(i16, -456), axis(&packet, 12));
    }
}

test "touch gyro uses rate scale, clamps safely and ignores absent fields" {
    var report = [_]u8{0} ** 46;
    report[0] = 0x45;
    buttons(&report, 0x200000);
    put16(&report, 40, 900);
    put16(&report, 42, -1800);
    var packet: [20]u8 = undefined;
    const options = triton.LocalOptions{ .touch_gyro = true, .gyro_full_scale_dps = 180 };
    try triton.mapTritonToLocalXbox360(&report, &packet, options);
    try std.testing.expectEqual(@as(i16, 20000), axis(&packet, 10));
    try std.testing.expectEqual(@as(i16, 10000), axis(&packet, 12));
    put16(&report, 40, -32768);
    put16(&report, 42, -32768);
    try triton.mapTritonToLocalXbox360(&report, &packet, options);
    try std.testing.expectEqual(@as(i16, 32767), axis(&packet, 10));
    try std.testing.expectEqual(@as(i16, -32768), axis(&packet, 12));
    try triton.mapTritonToLocalXbox360(report[0..18], &packet, options);
    try std.testing.expectEqual(@as(i16, 0), axis(&packet, 10));
    buttons(&report, 0);
    try triton.mapTritonToLocalXbox360(&report, &packet, options);
    try std.testing.expectEqual(@as(i16, 0), axis(&packet, 10));
}

test "local mapping rejects invalid configuration and buffers" {
    var report = [_]u8{0} ** 18;
    report[0] = 0x45;
    var packet: [20]u8 = undefined;
    try std.testing.expectError(error.InvalidMappingOptions, triton.mapTritonToLocalXbox360(&report, &packet, .{ .gyro_full_scale_dps = 0 }));
    try std.testing.expectError(error.InvalidMappingOptions, triton.mapTritonToLocalXbox360(&report, &packet, .{ .grips = .{ 0x80000000, 0, 0, 0 } }));
    try std.testing.expectError(error.OutputBufferTooSmall, triton.mapTritonToLocalXbox360(&report, packet[0..19], .{}));
    try std.testing.expectError(error.ReportTooShort, triton.mapTritonToLocalXbox360(report[0..17], &packet, .{}));
}
