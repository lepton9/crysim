const std = @import("std");

pub const Method = enum {
    health,
    login,
    whoami,
    state,
};

pub fn requireAuth(method: Method) bool {
    return switch (method) {
        .health => false,
        .login => false,
        .whoami => true,
        .state => true,
    };
}

// JSON request sent from clients to the daemon.
// Framing: one JSON object per line (newline-delimited).
pub const Request = struct {
    id: u64,
    token: ?[]const u8 = null,
    method: Method,
    params: ?std.json.Value = null,
};

pub const Error = struct {
    code: []const u8,
    message: []const u8,
};

pub const Response = struct {
    id: u64,
    ok: bool,
    result: ?std.json.Value = null,
    @"error": ?Error = null,
};

pub const Role = enum {
    viewer,
    trader,
    admin,
};

pub const LoginParams = struct {
    username: []const u8,
    password: []const u8,
};

pub const Options = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 5555,
};

/// Make a TCP request to the server with the payload.
/// The returned JSON must be freed by the caller.
pub fn request(
    io: std.Io,
    gpa: std.mem.Allocator,
    options: Options,
    req: anytype,
) !std.json.Parsed(Response) {
    const ip4 = try std.Io.net.Ip4Address.parse(options.host, options.port);
    var ip: std.Io.net.IpAddress = .{ .ip4 = ip4 };

    var stream = try ip.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var rbuf: [8192]u8 = undefined;
    var wbuf: [8192]u8 = undefined;
    var reader = std.Io.net.Stream.Reader.init(stream, io, &rbuf);
    var writer = std.Io.net.Stream.Writer.init(stream, io, &wbuf);

    try std.json.Stringify.value(req, .{}, &writer.interface);
    try writer.interface.writeAll("\n");
    try writer.interface.flush();

    const line = (try reader.interface.takeDelimiter('\n')) orelse return error.EndOfStream;
    const trimmed = std.mem.trimEnd(u8, line, "\r");

    return try std.json.parseFromSlice(Response, gpa, trimmed, .{
        .ignore_unknown_fields = true,
    });
}
