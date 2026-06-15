const std = @import("std");
const server = @import("server.zig");
const crysim = @import("crysim");
const data = crysim.data;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    const addr = try std.Io.net.Ip4Address.parse("0.0.0.0", 5555);

    const db_path: []const u8 = blk: {
        if (init.environ_map.get("CRYSIM_DB_PATH")) |p|
            break :blk try gpa.dupe(u8, p);
        const path = try data.dataFilePath(io, gpa, init.environ_map, "daemon", "crysim.db");
        break :blk path orelse try gpa.dupe(u8, "crysim.db");
    };
    defer gpa.free(db_path);

    const s = try server.Server.init(io, gpa, .{ .ip4 = addr }, db_path);
    defer s.deinit();
    s.run();
}
