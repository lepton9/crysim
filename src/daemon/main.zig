const std = @import("std");
const server = @import("server.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    const addr = try std.Io.net.Ip4Address.parse("127.0.0.1", 5555);

    const s = try server.Server.init(io, gpa, .{.ip4 = addr});
    defer s.deinit();

    var futAccept = std.Io.async(io, server.Server.startAccept, .{s});
    var futCore = std.Io.async(io, server.Server.coreLoop, .{s});
    _ = try futAccept.await(io);
    _ = try futCore.await(io);
    s.stop();
}

