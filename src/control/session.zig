const std = @import("std");
const protocol = @import("protocol.zig");

const Method = protocol.Method;

/// Client-side session state shared across requests.
pub const ClientSession = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    options: protocol.Options,
    next_id: u64 = 1,

    token: ?[]u8 = null,
    token_store: ?TokenStore = null,

    pub const TokenStore = struct {
        ctx: *anyopaque,
        load: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator) anyerror!?[]u8,
        save: *const fn (ctx: *anyopaque, token: []const u8) anyerror!void,
    };

    pub fn init(
        io: std.Io,
        gpa: std.mem.Allocator,
        options: protocol.Options,
    ) ClientSession {
        return .{ .io = io, .gpa = gpa, .options = options };
    }

    pub fn initWithTokenStore(
        io: std.Io,
        gpa: std.mem.Allocator,
        options: protocol.Options,
        token_store: TokenStore,
    ) ClientSession {
        var s = ClientSession.init(io, gpa, options);
        s.token_store = token_store;
        return s;
    }

    pub fn deinit(self: *ClientSession) void {
        if (self.token) |t| self.gpa.free(t);
        self.token = null;
    }

    /// Set the current session token.
    pub fn setToken(self: *ClientSession, token: []const u8) !void {
        if (self.token) |t| self.gpa.free(t);
        self.token = try self.gpa.dupe(u8, token);
    }

    /// Load the session token from disk or memory if loaded.
    fn loadToken(self: *ClientSession) !?[]const u8 {
        if (self.token) |t| return t;
        const store = self.token_store orelse return null;
        const t = (try store.load(store.ctx, self.gpa)) orelse return null;
        self.token = t;
        return t;
    }

    /// Load the token or return error if not found.
    fn requireToken(self: *ClientSession) ![]const u8 {
        return (try self.loadToken()) orelse error.NotLoggedIn;
    }

    /// Save the session token.
    pub fn saveToken(self: *ClientSession, token: []const u8) !void {
        const store = self.token_store orelse return error.NoTokenStore;
        try store.save(store.ctx, token);
        try self.setToken(token);
    }

    /// Increment the request ID.
    fn nextId(self: *ClientSession) !u64 {
        if (self.next_id == std.math.maxInt(u64)) return error.RequestIdOverflow;
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    /// Make a request.
    pub fn request(self: *ClientSession, method: Method) !std.json.Parsed(protocol.Response) {
        const required_rights = protocol.requiredRights(method);
        const token: ?[]const u8 = if (required_rights.auth)
            try self.requireToken()
        else
            null;
        return protocol.request(self.io, self.gpa, self.options, protocol.Request{
            .id = try self.nextId(),
            .token = token,
            .method = method,
        });
    }

    /// Make a request with params.
    pub fn requestParams(
        self: *ClientSession,
        method: Method,
        params: anytype,
    ) !std.json.Parsed(protocol.Response) {
        const required_rights = protocol.requiredRights(method);
        const token: ?[]const u8 = if (required_rights.auth)
            try self.requireToken()
        else
            null;

        return protocol.request(self.io, self.gpa, self.options, .{
            .id = try self.nextId(),
            .token = token,
            .method = method,
            .params = params,
        });
    }
};
