const std = @import("std");
const protocol = @import("crysim").protocol;

pub const Server = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    listen_addr: std.Io.net.IpAddress,
    server: std.Io.net.Server = undefined,
    running: std.atomic.Value(bool) = .init(false),
    start_ts: std.Io.Timestamp,

    users: std.StringHashMapUnmanaged(User) = .{},
    sessions: std.StringHashMapUnmanaged(Session) = .{},

    conn_group: std.Io.Group = .init,

    const SESSION_LEN_S = 12 * 60 * 60;
    const CLEANUP_FREQUENCY_S = 5;

    const User = struct {
        username: []const u8,
        password: []const u8,
        role: protocol.Role,
    };

    const Session = struct {
        username: []const u8,
        role: protocol.Role,
        expires_at: std.Io.Clock.Timestamp,
    };

    const ErrorCode = enum {
        not_found,
        bad_request,
        internal,
        unauthorized,
    };

    pub fn init(io: std.Io, gpa: std.mem.Allocator, addr: std.Io.net.IpAddress) !*Server {
        const s = try gpa.create(Server);
        s.* = .{
            .io = io,
            .gpa = gpa,
            .listen_addr = addr,
            .server = try addr.listen(io, .{ .reuse_address = false }),
            .start_ts = std.Io.Clock.boot.now(io),
        };
        try s.initUsers();
        s.running.store(true, .seq_cst);
        return s;
    }

    fn initUsers(self: *Server) !void {
        // TODO: Dev defaults. Load from file
        _ = try self.putUser(.admin, "admin", "admin");
        _ = try self.putUser(.viewer, "viewer", "viewer");
    }

    pub fn deinit(self: *Server) void {
        self.running.store(false, .seq_cst);
        self.conn_group.cancel(self.io);
        _ = self.conn_group.await(self.io) catch {};

        var it = self.sessions.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.username);
        }
        self.sessions.deinit(self.gpa);
        self.users.deinit(self.gpa);
        self.server.deinit(self.io);
        self.gpa.destroy(self);
    }

    pub fn run(self: *Server) void {
        self.run_group.async(self.io, Server.startAccept, .{self});
        self.run_group.async(self.io, Server.coreLoop, .{self});
        self.run_group.async(self.io, Server.cleanupLoop, .{self});
        self.run_group.await(self.io) catch {};
    }

    pub fn stop(self: *Server) void {
        if (self.running.swap(false, .seq_cst)) {
            self.server.socket.close(self.io);
            self.conn_group.cancel(self.io);
            self.log("Stopping..", .{});
        }
    }

    pub fn coreLoop(self: *Server) std.Io.Cancelable!void {
        while (self.running.load(.seq_cst)) {
            try std.Io.sleep(self.io, .fromSeconds(1), .boot);
        }
    }

    /// Start accepting new connections in a loop.
    pub fn startAccept(self: *Server) std.Io.Cancelable!void {
        {
            const b = self.listen_addr.ip4.bytes;
            self.log(
                "Listening on {d}.{d}.{d}.{d}:{d}",
                .{ b[0], b[1], b[2], b[3], self.listen_addr.ip4.port },
            );
        }
        while (self.running.load(.seq_cst)) {
            const conn = self.server.accept(self.io) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => {
                    std.log.err("accept failed: {}", .{err});
                    self.stop();
                    return error.Canceled;
                },
            };
            self.conn_group.async(self.io, Server.handleConn, .{ self, conn });
        }
    }

    /// Cleanup expired sessions periodically.
    pub fn cleanupLoop(self: *Server) std.Io.Cancelable!void {
        while (self.running.load(.seq_cst)) {
            try std.Io.sleep(self.io, .fromSeconds(CLEANUP_FREQUENCY_S), .boot);
            self.cleanupExpiredSessions() catch |err| {
                self.logErr("Failed to cleanup ({s})", .{@errorName(err)});
            };
        }
    }

    fn nowBoot(self: *const Server) std.Io.Timestamp {
        return std.Io.Clock.boot.now(self.io);
    }

    /// Write ok response with the result content.
    fn sendOk(w: *std.Io.Writer, id: u64, result: anytype) void {
        const Out = struct {
            id: u64,
            ok: bool = true,
            result: @TypeOf(result),
        };
        std.json.Stringify.value(Out{ .id = id, .result = result }, .{}, w) catch return;
        w.writeAll("\n") catch return;
        w.flush() catch return;
    }

    /// Write error response with error message.
    fn sendErr(w: *std.Io.Writer, id: u64, code: ErrorCode, message: []const u8) void {
        const Out = struct {
            id: u64,
            ok: bool = false,
            @"error": protocol.Error,
        };
        std.json.Stringify.value(
            Out{ .id = id, .@"error" = .{ .code = @tagName(code), .message = message } },
            .{},
            w,
        ) catch return;
        w.writeAll("\n") catch return;
        w.flush() catch return;
    }

    fn newTokenHex(io: std.Io, buf: *[32]u8, out_hex: *[64]u8) void {
        std.Io.randomSecure(io, buf) catch std.Io.random(io, buf);
        out_hex.* = std.fmt.bytesToHex(buf.*, .lower);
    }

    /// Check if the session is expired.
    fn isExpired(self: *const Server, session: *const Session) bool {
        return (session.expires_at.compare(.lte, self.nowBoot().withClock(.boot)));
    }

    /// Get the session matching the token or cleanup if expired.
    fn requireSession(self: *Server, token: ?[]const u8) !Session {
        const t = token orelse return error.NotLoggedIn;
        const sess = self.sessions.get(t) orelse return error.InvalidSessionToken;
        if (self.isExpired(&sess)) {
            // Cleanup of expired token
            if (self.sessions.fetchRemove(t)) |kv| {
                self.gpa.free(kv.key);
                self.gpa.free(kv.value.username);
            }
            return error.TokenExpired;
        }
        return sess;
    }

    /// Handle new connection and parse the request.
    pub fn handleConn(self: *Server, conn: std.Io.net.Stream) std.Io.Cancelable!void {
        defer conn.close(self.io);

        var rbuf: [8192]u8 = undefined;
        var wbuf: [8192]u8 = undefined;
        var reader = std.Io.net.Stream.Reader.init(conn, self.io, &rbuf);
        var writer = std.Io.net.Stream.Writer.init(conn, self.io, &wbuf);

        while (self.running.load(.seq_cst)) {
            const line_opt = reader.interface.takeDelimiter('\n') catch |err| switch (err) {
                error.ReadFailed => return,
                error.StreamTooLong => {
                    sendErr(&writer.interface, 0, .bad_request, "request too long");
                    return;
                },
            };
            const line = line_opt orelse return;
            const trimmed = std.mem.trimEnd(u8, line, "\r");
            if (trimmed.len == 0) continue;

            var arena_alloc = std.heap.ArenaAllocator.init(self.gpa);
            defer arena_alloc.deinit();
            const arena = arena_alloc.allocator();

            const parsed = std.json.parseFromSlice(protocol.Request, arena, trimmed, .{
                .ignore_unknown_fields = true,
            }) catch {
                sendErr(&writer.interface, 0, .bad_request, "invalid JSON request");
                continue;
            };

            self.dispatch(parsed.value, &writer.interface);
        }
    }

    fn getUser(self: *Server, username: []const u8) ?*User {
        return self.users.getPtr(username);
    }

    /// Put a new user to the list of users.
    fn putUser(
        self: *Server,
        role: protocol.Role,
        username: []const u8,
        password: []const u8,
    ) error{ OutOfMemory, UserExists }!*User {
        const gop = try self.users.getOrPut(self.gpa, username);
        if (gop.found_existing) return error.UserExists;
        const un = try self.gpa.dupe(u8, username);
        gop.key_ptr.* = un;
        gop.value_ptr.* = .{
            .username = un,
            .password = try self.gpa.dupe(u8, password),
            .role = role,
        };
        return gop.value_ptr;
    }

    /// Get all the current sessions.
    fn getSessions(self: *Server) error{OutOfMemory}!std.ArrayList(*Session) {
        var sessions: std.ArrayList(*Session) = try .initCapacity(self.gpa, self.sessions.size);
        errdefer sessions.deinit(self.gpa);
        var it = self.sessions.valueIterator();
        while (it.next()) |s| sessions.appendAssumeCapacity(s);
        return sessions;
    }

    /// Clean up all the sessions that have expired.
    fn cleanupExpiredSessions(self: *Server) !void {
        var expired: std.ArrayList([]const u8) = .empty;
        defer expired.deinit(self.gpa);
        var it = self.sessions.iterator();
        while (it.next()) |e| {
            const session = e.value_ptr;
            if (!self.isExpired(session)) continue;
            try expired.append(self.gpa, e.key_ptr.*);
        }
        for (expired.items) |token| {
            const kv = self.sessions.fetchRemove(token) orelse continue;
            self.gpa.free(kv.key);
            self.gpa.free(kv.value.username);
        }
    }

    /// Revoke all the sessions for the user.
    fn revokeSessionsUsername(self: *Server, username: []const u8) !void {
        var expired: std.ArrayList([]const u8) = .empty;
        defer expired.deinit(self.gpa);
        var it = self.sessions.iterator();
        while (it.next()) |e| {
            if (!std.mem.eql(u8, e.value_ptr.username, username)) continue;
            try expired.append(self.gpa, e.key_ptr.*);
        }
        for (expired.items) |token| {
            const kv = self.sessions.fetchRemove(token) orelse continue;
            self.gpa.free(kv.key);
            self.gpa.free(kv.value.username);
        }
    }

    /// Revoke all the sessions.
    fn revokeSessionsAll(self: *Server) void {
        var it = self.sessions.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.username);
        }
        self.sessions.clearAndFree(self.gpa);
    }

    /// Check if the user is logged in and has enough rights.
    ///
    /// Skips check if the requested method does not require authentication.
    fn authenticate(self: *Server, req: protocol.Request) !?Session {
        const required_rights = protocol.requiredRights(req.method);
        if (!required_rights.auth) return null;
        const sess = try self.requireSession(req.token);
        if (!protocol.hasEnoughRights(required_rights, sess.role))
            return error.NotEnoughRights;
        return sess;
    }

    const RequestError = error{
        MissingParams,
        InvalidParams,
        InvalidCredentials,
        InvalidRole,
        InvalidPassword,
        UserExists,
        OutOfMemory,
    };

    /// Parse the params from the request.
    fn parseParams(
        T: type,
        gpa: std.mem.Allocator,
        req: protocol.Request,
    ) RequestError!std.json.Parsed(T) {
        const params_val = req.params orelse return RequestError.MissingParams;
        return std.json.parseFromValue(T, gpa, params_val, .{}) catch
            return RequestError.InvalidParams;
    }

    /// Handle the login request and return the created token if succeeded.
    fn login(self: *Server, req: protocol.Request) RequestError!protocol.LoginResult {
        const params_parsed = try parseParams(protocol.LoginParams, self.gpa, req);
        defer params_parsed.deinit();
        const params = params_parsed.value;

        const user = self.getUser(params.username) orelse
            return RequestError.InvalidCredentials;
        if (!std.mem.eql(u8, user.password, params.password))
            return RequestError.InvalidCredentials;

        var token_bytes: [32]u8 = undefined;
        var token_hex: [64]u8 = undefined;
        newTokenHex(self.io, &token_bytes, &token_hex);
        const token = try self.gpa.dupe(u8, token_hex[0..]);
        errdefer self.gpa.free(token);

        const username = try self.gpa.dupe(u8, params.username);
        errdefer self.gpa.free(username);

        const now_ts = nowBoot(self);
        const expires_at = now_ts.addDuration(std.Io.Duration.fromSeconds(SESSION_LEN_S));
        self.revokeSessionsUsername(username) catch {};
        try self.sessions.put(self.gpa, token, .{
            .username = username,
            .role = user.role,
            .expires_at = expires_at.withClock(.boot),
        });
        return .{
            .token = token,
            .role = @tagName(user.role),
            .expires_at_ms = expires_at.toMilliseconds(),
        };
    }

    /// Log the user out.
    fn logout(self: *Server, req: protocol.Request) error{NotLoggedIn}!void {
        const token = req.token orelse unreachable;
        const kv = self.sessions.fetchRemove(token) orelse return error.NotLoggedIn;
        self.gpa.free(kv.key);
        self.gpa.free(kv.value.username);
    }

    fn validatePassword(password: []const u8) ![]const u8 {
        const trimmed = std.mem.trim(u8, password, " \t\n\r");
        if (trimmed.len == 0) return RequestError.InvalidPassword;
        return trimmed;
    }

    /// Create a new user.
    ///
    /// Checks that the creator has admin rights.
    fn createUser(self: *Server, req: protocol.Request) RequestError!*User {
        const params_parsed = try parseParams(protocol.CreateUserParams, self.gpa, req);
        defer params_parsed.deinit();
        const params = params_parsed.value;

        if (self.getUser(params.username)) |_| return RequestError.UserExists;
        const role = std.meta.stringToEnum(protocol.Role, params.role) orelse
            return RequestError.InvalidRole;
        const pw = try validatePassword(params.password);

        return try self.putUser(role, params.username, pw);
    }

    /// Handle the incoming request.
    fn dispatch(self: *Server, req: protocol.Request, w: *std.Io.Writer) void {
        const sess = self.authenticate(req) catch |err| {
            self.logErr(
                "({s}), id={d}, error={s}",
                .{ @tagName(req.method), req.id, @errorName(err) },
            );
            return switch (err) {
                error.NotLoggedIn => sendErr(w, req.id, .unauthorized, "not logged in"),
                error.InvalidSessionToken => sendErr(w, req.id, .unauthorized, "invalid token"),
                error.TokenExpired => sendErr(w, req.id, .unauthorized, "sessiong token expired"),
                error.NotEnoughRights => sendErr(w, req.id, .unauthorized, "not enough rights"),
                else => unreachable,
            };
        };

        if (sess) |s| {
            self.log(
                "({s}), id={d}, username={s}, role={s}",
                .{ @tagName(req.method), req.id, s.username, @tagName(s.role) },
            );
        } else self.log("({s}), id={d}", .{ @tagName(req.method), req.id });

        switch (req.method) {
            .health => {
                const uptime_ms: i64 = self.start_ts.durationTo(nowBoot(self)).toMilliseconds();
                return sendOk(w, req.id, .{ .uptime_ms = uptime_ms });
            },
            .login => {
                const res = self.login(req) catch |err| return switch (err) {
                    RequestError.MissingParams => {
                        sendErr(w, req.id, .bad_request, "missing params");
                    },
                    RequestError.InvalidParams => {
                        sendErr(w, req.id, .bad_request, "invalid params");
                    },
                    RequestError.InvalidCredentials => {
                        sendErr(w, req.id, .unauthorized, "invalid credentials");
                    },
                    RequestError.OutOfMemory => {
                        sendErr(w, req.id, .internal, "out of memory");
                        self.oom();
                    },
                    else => unreachable,
                };
                self.log(
                    "Logged in user id={d}, role={s}, expires={d}",
                    .{ req.id, res.role, res.expires_at_ms },
                );
                return sendOk(w, req.id, res);
            },
            .logout => {
                self.logout(req) catch |err| {
                    std.debug.assert(err == error.NotLoggedIn);
                    return sendErr(w, req.id, .unauthorized, "not logged in");
                };
                return sendOk(w, req.id, .{ .message = "Logged out" });
            },
            .whoami => {
                const session = sess orelse unreachable;
                return sendOk(w, req.id, .{
                    .username = session.username,
                    .role = @tagName(session.role),
                    .expires_at_ms = session.expires_at.raw.toMilliseconds(),
                });
            },
            .state => {
                const session = sess orelse unreachable;
                _ = session;
                // TODO:
                return sendOk(w, req.id, .{ .balance = 0 });
            },
            .create_user => {
                const user = self.createUser(req) catch |err| return switch (err) {
                    RequestError.MissingParams => {
                        sendErr(w, req.id, .bad_request, "missing params");
                    },
                    RequestError.InvalidParams => {
                        sendErr(w, req.id, .bad_request, "invalid params");
                    },
                    RequestError.UserExists => {
                        sendErr(w, req.id, .unauthorized, "user exists with the username");
                    },
                    RequestError.InvalidRole => {
                        sendErr(w, req.id, .unauthorized, "invalid role");
                    },
                    RequestError.InvalidPassword => {
                        sendErr(w, req.id, .unauthorized, "invalid password given");
                    },
                    RequestError.OutOfMemory => {
                        sendErr(w, req.id, .internal, "out of memory");
                        self.oom();
                    },
                    else => unreachable,
                };
                return sendOk(w, req.id, .{
                    .message = "User created",
                    .username = user.username,
                    .role = @tagName(user.role),
                });
            },
            .session_list => {
                var sessions = self.getSessions() catch self.oom();
                defer sessions.deinit(self.gpa);
                // TODO:
                return sendOk(w, req.id, .{
                    .sessions = sessions,
                });
            },
            },
        }

        return sendErr(w, req.id, .not_found, "unknown method");
    }

    fn log(self: *Server, comptime fmt: []const u8, args: anytype) void {
        _ = self;
        std.log.info(fmt, args);
    }

    fn logErr(self: *Server, comptime fmt: []const u8, args: anytype) void {
        _ = self;
        std.log.err(fmt, args);
    }

    fn oom(self: *Server) noreturn {
        defer self.stop();
        std.log.err("Out of memory", .{});
        std.process.exit(1);
    }
};
