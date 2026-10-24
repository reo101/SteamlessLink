const std = @import("std");
const c = @import("c");

pub fn readFd(fd: c_int, out: []u8) !usize {
    while (true) {
        const rc = c.read(fd, out.ptr, out.len);
        switch (std.c.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .BADF => return error.BadFileDescriptor,
            else => return error.ReadFailed,
        }
    }
}

pub fn writeAllFd(fd: c_int, data: []const u8) !void {
    var offset: usize = 0;
    while (offset < data.len) {
        const rc = c.write(fd, data[offset..].ptr, data.len - offset);
        switch (std.c.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return error.WriteFailed;
                offset += @intCast(rc);
            },
            .INTR => continue,
            .PIPE, .CONNRESET => return error.ConnectionClosed,
            .BADF => return error.BadFileDescriptor,
            else => return error.WriteFailed,
        }
    }
}

pub fn closeFd(fd: c_int) void {
    _ = c.close(fd);
}
