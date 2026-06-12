const std = @import("std");
const cli = @import("cli.zig");

pub fn main(init: std.process.Init) void {
    cli.handleCli(init) catch |err| {
        std.log.err("{}", .{err});
    };
}

