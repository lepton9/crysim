const std = @import("std");

pub const Method = enum {
    health,
    login,
    logout,
    whoami,
    state,
    create_user,
    session_list,
};

pub const Rights = struct {
    auth: bool,
    role: ?Role = null,
};

pub fn requiredRights(method: Method) Rights {
    return switch (method) {
        .health => .{ .auth = false },
        .login => .{ .auth = false },
        .logout => .{ .auth = true },
        .whoami => .{ .auth = true },
        .state => .{ .auth = true },
        .create_user => .{ .auth = true, .role = .admin },
        .session_list => .{ .auth = true, .role = .admin },
    };
}

pub fn hasEnoughRights(rights: Rights, role: Role) bool {
    const needed = rights.role orelse return true;
    return switch (needed) {
        .viewer => role == .admin or role == .trader or role == .viewer,
        .trader => role == .admin or role == .trader,
        .admin => role == .admin,
    };
}

// JSON request sent from clients to the daemon.
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

pub const CreateUserParams = struct {
    role: []const u8,
    username: []const u8,
    password: []const u8,
};

pub const LoginParams = struct {
    username: []const u8,
    password: []const u8,
};

pub const LoginResult = struct { token: []const u8, role: []const u8, expires_at_ms: i64 };
pub const CreateUserResult = struct { username: []const u8, role: Role };

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
