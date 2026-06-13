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

    const User = struct {
        password: []const u8,
        role: protocol.Role,
    };

    const Session = struct {
        username: []const u8,
        role: protocol.Role,
        expires_at: std.Io.Clock.Timestamp,
    };

    const RequestError = enum {
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
        try self.users.put(self.gpa, "admin", .{ .password = "admin", .role = .admin });
        try self.users.put(self.gpa, "viewer", .{ .password = "viewer", .role = .viewer });
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

    pub fn stop(self: *Server) void {
        if (self.running.swap(false, .seq_cst)) {
            self.server.socket.close(self.io);
            self.conn_group.cancel(self.io);
            self.log("Stopping..", .{});
        }
    }

    pub fn coreLoop(self: *Server) std.Io.Cancelable!void {
        while (self.running.load(.seq_cst)) {
            try std.Io.sleep(self.io, std.Io.Duration.fromSeconds(1), .boot);
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

    fn nowBoot(self: *Server) std.Io.Timestamp {
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
    fn sendErr(w: *std.Io.Writer, id: u64, code: RequestError, message: []const u8) void {
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

    /// Get the session matching the token or cleanup if expired.
    fn requireSession(self: *Server, token: ?[]const u8) ?Session {
        const t = token orelse return null;
        const sess = self.sessions.get(t) orelse return null;
        if (sess.expires_at.compare(.lte, nowBoot(self).withClock(.boot))) {
            // Cleanup of expired token
            if (self.sessions.fetchRemove(t)) |kv| {
                self.gpa.free(kv.key);
                self.gpa.free(kv.value.username);
            }
            return null;
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

    fn authenticate(self: *Server, req: protocol.Request) !?Session {
        if (!protocol.requireAuth(req.method)) return null;
        const sess = self.requireSession(req.token) orelse return error.Unauthorized;
        return sess;
    }

    const LoginError = error{
        MissingParams,
        InvalidParams,
        InvalidCredentials,
        OutOfMemory,
    };

    /// Handle the login request and return the created token if succeeded.
    fn login(self: *Server, req: protocol.Request) LoginError!struct {
        token: []const u8,
        role: []const u8,
        expires_at_ms: i64,
    } {
        const params_val = req.params orelse return LoginError.MissingParams;
        const params_parsed = std.json.parseFromValue(
            protocol.LoginParams,
            self.gpa,
            params_val,
            .{},
        ) catch return LoginError.MissingParams;

        defer params_parsed.deinit();
        const params = params_parsed.value;

        const user = self.users.get(params.username) orelse
            return LoginError.InvalidCredentials;
        if (!std.mem.eql(u8, user.password, params.password))
            return LoginError.InvalidCredentials;

        var token_bytes: [32]u8 = undefined;
        var token_hex: [64]u8 = undefined;
        newTokenHex(self.io, &token_bytes, &token_hex);
        const token = try self.gpa.dupe(u8, token_hex[0..]);
        errdefer self.gpa.free(token);

        const username = try self.gpa.dupe(u8, params.username);
        errdefer self.gpa.free(username);

        const now_ts = nowBoot(self);
        const expires_at = now_ts.addDuration(std.Io.Duration.fromSeconds(12 * 60 * 60));
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

    fn logout(self: *Server, req: protocol.Request) error{NotLoggedIn}!void {
        const token = req.token orelse unreachable;
        const kv = self.sessions.fetchRemove(token) orelse return error.NotLoggedIn;
        self.gpa.free(kv.key);
        self.gpa.free(kv.value.username);
    }

    /// Handle the incoming request.
    fn dispatch(self: *Server, req: protocol.Request, w: *std.Io.Writer) void {
        self.log("({s}), id={d}", .{ @tagName(req.method), req.id });

        const sess = self.authenticate(req) catch {
            sendErr(w, req.id, .unauthorized, "missing/invalid token");
            return;
        };

        switch (req.method) {
            .health => {
                const uptime_ms: i64 = self.start_ts.durationTo(nowBoot(self)).toMilliseconds();
                return sendOk(w, req.id, .{ .uptime_ms = uptime_ms });
            },
            .login => {
                const res = self.login(req) catch |err| return switch (err) {
                    LoginError.MissingParams => {
                        sendErr(w, req.id, .bad_request, "missing params");
                    },
                    LoginError.InvalidParams => {
                        sendErr(w, req.id, .bad_request, "invalid params");
                    },
                    LoginError.InvalidCredentials => {
                        sendErr(w, req.id, .unauthorized, "invalid credentials");
                    },
                    LoginError.OutOfMemory => {
                        sendErr(w, req.id, .internal, "out of memory");
                        self.oom();
                    },
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
                return sendOk(w, req.id, .{ .balance = 0 });
            },
        }

        return sendErr(w, req.id, .not_found, "unknown method");
    }

    fn log(self: *Server, comptime fmt: []const u8, args: anytype) void {
        _ = self;
        std.log.info(fmt, args);
    }

    fn oom(self: *Server) noreturn {
        defer self.stop();
        std.log.err("Out of memory", .{});
        std.process.exit(1);
    }
};
