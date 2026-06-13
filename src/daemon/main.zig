const std = @import("std");
const server = @import("server.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    const addr = try std.Io.net.Ip4Address.parse("0.0.0.0", 5555);

    const s = try server.Server.init(io, gpa, .{ .ip4 = addr });
    defer {
        s.stop();
        s.deinit();
    }

    var g: std.Io.Group = .init;
    g.async(io, server.Server.startAccept, .{s});
    g.async(io, server.Server.coreLoop, .{s});
    try g.await(io);
}
