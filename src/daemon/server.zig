const std = @import("std");
const argon2 = std.crypto.pwhash.argon2;
const protocol = @import("crysim").protocol;
const db = @import("db.zig");
const prices = @import("prices.zig");
const trading = @import("trading.zig");
const wiring = @import("wiring.zig");

const Db = db.Db;

pub const Server = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    listen_addr: std.Io.net.IpAddress,
    server: std.Io.net.Server = undefined,
    running: std.atomic.Value(bool) = .init(false),
    start_ts: std.Io.Timestamp,

    db: Db,
    trading_service: trading.TradingService = undefined,

    users: std.StringHashMapUnmanaged(Db.User) = .{},
    sessions: std.StringHashMapUnmanaged(Session) = .{},

    /// Group for the server loops.
    run_group: std.Io.Group = .init,
    /// Group for handling user requests.
    conn_group: std.Io.Group = .init,

    const SESSION_LEN_S = 12 * 60 * 60;
    const CLEANUP_FREQUENCY_S = 60;

    const STARTING_USD_CENTS: i64 = 1_000_000; // $10,000.00

    const Session = struct {
        user_id: i64,
        username: []const u8,
        role: protocol.Role,
        expires_at: std.Io.Clock.Timestamp,
    };

    const ErrorCode = enum {
        not_found,
        bad_request,
        internal,
        unauthorized,
        forbidden,
        conflict,
    };

    pub fn init(
        io: std.Io,
        gpa: std.mem.Allocator,
        addr: std.Io.net.IpAddress,
        db_path: []const u8,
    ) !*Server {
        const s = try gpa.create(Server);
        errdefer gpa.destroy(s);
        s.* = .{
            .io = io,
            .gpa = gpa,
            .listen_addr = addr,
            .server = try addr.listen(io, .{ .reuse_address = true }),
            .start_ts = std.Io.Clock.boot.now(io),
            .db = try db.Db.init(gpa, db_path),
            .trading_service = try wiring.createTradingService(io, gpa, &s.db, .sim),
        };
        errdefer s.db.deinit();
        s.running.store(true, .seq_cst);

        s.initDevEnv();

        return s;
    }

    pub fn deinit(self: *Server) void {
        self.running.store(false, .seq_cst);

        var it = self.sessions.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.username);
        }
        self.sessions.deinit(self.gpa);

        var uit = self.users.iterator();
        while (uit.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.password_hash);
        }
        self.users.deinit(self.gpa);

        self.trading_service.deinit();
        self.db.deinit();
        self.server.deinit(self.io);
        self.gpa.destroy(self);
    }

    /// TODO: only for testing
    fn initDevEnv(self: *Server) void {
        _ = self.createUserInner("admin", "admin", "admin") catch {};
        _ = self.createUserInner("trader", "trader", "trader") catch {};
        _ = self.createUserInner("viewer", "viewer", "viewer") catch {};
    }

    pub fn run(self: *Server) void {
        self.run_group.async(self.io, Server.startAccept, .{self});
        self.run_group.async(self.io, Server.coreLoop, .{self});
        self.run_group.async(self.io, Server.cleanupLoop, .{self});

        while (self.running.load(.seq_cst)) {
            std.Io.sleep(self.io, .fromMilliseconds(200), .boot) catch {};
        }

        self.run_group.cancel(self.io);
        _ = self.run_group.await(self.io) catch {};

        self.conn_group.cancel(self.io);
        _ = self.conn_group.await(self.io) catch {};
    }

    pub fn stop(self: *Server) void {
        if (self.running.swap(false, .seq_cst)) {
            self.log("Stopping the server..", .{});
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
                    if (!self.running.load(.seq_cst)) return;
                    std.log.err("accept failed: {}", .{err});
                    return;
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

            self.dispatch(arena, parsed.value, &writer.interface);
        }
    }

    /// Fetch a user from the in-memory cache or lazily load from SQLite.
    fn getUser(self: *Server, username: []const u8) error{ OutOfMemory, DbError }!?*Db.User {
        if (self.users.getPtr(username)) |u| return u;

        const owned_opt = self.db.getUserOwned(self.gpa, username) catch |err| {
            self.logErr("DB get user failed: {s}", .{@errorName(err)});
            return error.DbError;
        };
        const owned = owned_opt orelse return null;
        errdefer {
            self.gpa.free(owned.username);
            self.gpa.free(owned.password_hash);
        }

        const inserted = self.putUserOwned(
            owned.role,
            owned.id,
            owned.username,
            owned.password_hash,
        ) catch |err| switch (err) {
            error.UserExists => return self.users.getPtr(username),
            error.OutOfMemory => return error.OutOfMemory,
        };
        return inserted;
    }

    /// Put a new user to the list of users.
    fn putUser(
        self: *Server,
        role: protocol.Role,
        user_id: i64,
        username: []const u8,
        password: []const u8,
    ) error{ OutOfMemory, UserExists }!*Db.User {
        const gop = try self.users.getOrPut(self.gpa, username);
        if (gop.found_existing) return error.UserExists;
        const un = try self.gpa.dupe(u8, username);
        gop.key_ptr.* = un;
        gop.value_ptr.* = .{
            .id = user_id,
            .username = un,
            .password_hash = try self.gpa.dupe(u8, password),
            .role = role,
        };
        return gop.value_ptr;
    }

    /// Put a new user to the list of users, taking ownership of the buffers.
    fn putUserOwned(
        self: *Server,
        role: protocol.Role,
        user_id: i64,
        username: []u8,
        password_hash: []u8,
    ) error{ OutOfMemory, UserExists }!*Db.User {
        const gop = try self.users.getOrPut(self.gpa, username);
        if (gop.found_existing) return error.UserExists;
        gop.key_ptr.* = username;
        gop.value_ptr.* = .{
            .id = user_id,
            .username = username,
            .password_hash = password_hash,
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
        UserDoesNotExist,
        UserExists,
        DbError,
        OutOfMemory,
    };

    /// Parse the params from the request.
    fn parseParams(
        comptime T: type,
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

        const user = self.getUser(params.username) catch |err| switch (err) {
            error.OutOfMemory => return RequestError.OutOfMemory,
            error.DbError => return RequestError.DbError,
        } orelse return RequestError.InvalidCredentials;

        const ok = try self.verifyPassword(user.password_hash, params.password);
        if (!ok) return RequestError.InvalidCredentials;

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
            .user_id = user.id,
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

    /// Change the password of the user making the request.
    fn changePassword(
        self: *Server,
        req: protocol.Request,
        session: *const Session,
    ) RequestError!void {
        const params_parsed = try parseParams(
            struct { old: []const u8, new: []const u8 },
            self.gpa,
            req,
        );
        defer params_parsed.deinit();
        const params = params_parsed.value;

        const user = try self.getUser(session.username) orelse
            return RequestError.UserDoesNotExist;

        const ok = try self.verifyPassword(user.password_hash, params.old);
        if (!ok) return RequestError.InvalidPassword;

        const new = try validatePassword(params.new);
        const new_hash = try self.hashPassword(new);
        errdefer self.gpa.free(new_hash);

        self.db.updateUserPasswordHash(session.user_id, new_hash) catch
            return RequestError.DbError;
        self.gpa.free(user.password_hash);
        user.password_hash = new_hash;
    }

    fn validatePassword(password: []const u8) ![]const u8 {
        const trimmed = std.mem.trim(u8, password, " \t\n\r");
        if (trimmed.len == 0) return RequestError.InvalidPassword;
        return trimmed;
    }

    /// Create and allocate hash for the given password.
    fn hashPassword(self: *Server, password: []const u8) RequestError![]u8 {
        var buf: [256]u8 = undefined;
        const hashed = argon2.strHash(password, .{
            .allocator = self.gpa,
            .params = argon2.Params.owasp_2id,
            .mode = .argon2id,
            .encoding = .phc,
        }, &buf, self.io) catch |err| switch (err) {
            error.OutOfMemory => return RequestError.OutOfMemory,
            else => {
                self.logErr("password hash failed: {s}", .{@errorName(err)});
                return RequestError.DbError;
            },
        };
        return self.gpa.dupe(u8, hashed) catch return RequestError.OutOfMemory;
    }

    /// Check the password against the given hash.
    fn verifyPassword(
        self: *Server,
        stored_hash: []const u8,
        password: []const u8,
    ) RequestError!bool {
        argon2.strVerify(
            stored_hash,
            password,
            .{ .allocator = self.gpa },
            self.io,
        ) catch |err| switch (err) {
            error.PasswordVerificationFailed => return false,
            error.InvalidEncoding => return false,
            error.OutOfMemory => return RequestError.OutOfMemory,
            else => {
                self.logErr("password verify failed: {s}", .{@errorName(err)});
                return RequestError.DbError;
            },
        };
        return true;
    }

    /// Handle create user request.
    fn createUser(self: *Server, req: protocol.Request) RequestError!*Db.User {
        const params_parsed = try parseParams(protocol.CreateUserParams, self.gpa, req);
        defer params_parsed.deinit();
        const params = params_parsed.value;
        return self.createUserInner(params.role, params.username, params.password);
    }

    /// Create a new user.
    ///
    /// Checks that the creator has admin rights.
    fn createUserInner(
        self: *Server,
        role_str: []const u8,
        username: []const u8,
        password: []const u8,
    ) RequestError!*Db.User {
        if (self.getUser(username) catch |err| switch (err) {
            error.OutOfMemory => return RequestError.OutOfMemory,
            error.DbError => return RequestError.DbError,
        }) |_| return RequestError.UserExists;
        const role = std.meta.stringToEnum(protocol.Role, role_str) orelse
            return RequestError.InvalidRole;
        const pw = try validatePassword(password);

        const pw_hash = try self.hashPassword(pw);
        errdefer self.gpa.free(pw_hash);

        const now_ms: i64 = std.Io.Clock.real.now(self.io).toMilliseconds();
        const user_id = self.db.insertUserWithInitialCredit(
            role,
            username,
            pw_hash,
            now_ms,
            STARTING_USD_CENTS,
        ) catch |err| {
            if (err == error.ConstraintUnique) return RequestError.UserExists;
            self.logErr("DB insert user failed: {s}", .{@errorName(err)});
            return RequestError.DbError;
        };

        const username_alloc = try self.gpa.dupe(u8, username);
        errdefer self.gpa.free(username_alloc);

        return self.putUserOwned(role, user_id, username_alloc, pw_hash) catch |err| switch (err) {
            error.UserExists => return RequestError.UserExists,
            error.OutOfMemory => return RequestError.OutOfMemory,
        };
    }

    /// Handle the incoming request.
    fn dispatch(self: *Server, alloc: std.mem.Allocator, req: protocol.Request, w: *std.Io.Writer) void {
        const sess = self.authenticate(req) catch |err| {
            self.logErr(
                "({s}), id={d}, error={s}",
                .{ @tagName(req.method), req.id, @errorName(err) },
            );
            return switch (err) {
                error.NotLoggedIn => sendErr(w, req.id, .unauthorized, "not logged in"),
                error.InvalidSessionToken => sendErr(w, req.id, .unauthorized, "invalid token"),
                error.TokenExpired => sendErr(w, req.id, .unauthorized, "session token expired"),
                error.NotEnoughRights => sendErr(w, req.id, .forbidden, "not enough rights"),
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
                const res = self.login(req) catch |err| {
                    return self.respondRequestError(w, req.id, err);
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
            .change_password => {
                const session = sess orelse unreachable;
                self.changePassword(req, &session) catch |err| {
                    return self.respondRequestError(w, req.id, err);
                };

                return sendOk(w, req.id, .{ .message = "Password changed" });
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
                const res = self.trading_service.state(alloc, session.user_id) catch |err| {
                    return self.respondTradingError(w, req.id, err);
                };
                return sendOk(w, req.id, res);
            },
            .price => {
                const params_parsed = parseParams(protocol.PriceParams, alloc, req) catch |err|
                    return self.respondRequestError(w, req.id, err);
                defer params_parsed.deinit();

                const res = self.trading_service.price(alloc, params_parsed.value) catch |err| {
                    return self.respondTradingError(w, req.id, err);
                };
                return sendOk(w, req.id, res);
            },
            .buy => {
                const session = sess orelse unreachable;
                const params_parsed = parseParams(protocol.BuyParams, alloc, req) catch |err|
                    return self.respondRequestError(w, req.id, err);
                defer params_parsed.deinit();

                const res = self.trading_service.buy(
                    alloc,
                    params_parsed.value,
                    session.user_id,
                ) catch |err| return self.respondTradingError(w, req.id, err);
                return sendOk(w, req.id, res);
            },
            .sell => {
                const session = sess orelse unreachable;
                const params_parsed = parseParams(protocol.SellParams, alloc, req) catch |err|
                    return self.respondRequestError(w, req.id, err);
                defer params_parsed.deinit();

                const res = self.trading_service.sell(
                    alloc,
                    params_parsed.value,
                    session.user_id,
                ) catch |err| return self.respondTradingError(w, req.id, err);
                return sendOk(w, req.id, res);
            },
            .trade_history => {
                const session = sess orelse unreachable;
                const params_parsed = blk: {
                    if (req.params == null) break :blk null;
                    break :blk parseParams(protocol.TradeHistoryParams, alloc, req) catch |err|
                        return self.respondRequestError(w, req.id, err);
                };
                defer if (params_parsed) |p| p.deinit();

                const res = self.trading_service.tradeHistory(
                    alloc,
                    if (params_parsed) |p| p.value else .{},
                    session.user_id,
                ) catch |err| return self.respondTradingError(w, req.id, err);
                return sendOk(w, req.id, res);
            },
            .create_user => {
                const user = self.createUser(req) catch |err| {
                    return self.respondRequestError(w, req.id, err);
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
            .shutdown => {
                defer self.stop();
                sendOk(w, req.id, .{ .message = "Shutting down" });
            },
        }

        return sendErr(w, req.id, .not_found, "unknown method");
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

    fn respondRequestError(self: *Server, w: *std.Io.Writer, id: u64, err: RequestError) void {
        switch (err) {
            RequestError.MissingParams => sendErr(w, id, .bad_request, "missing params"),
            RequestError.InvalidParams => sendErr(w, id, .bad_request, "invalid params"),
            RequestError.InvalidCredentials => sendErr(w, id, .unauthorized, "invalid credentials"),
            RequestError.InvalidRole => sendErr(w, id, .unauthorized, "invalid role"),
            RequestError.InvalidPassword => sendErr(w, id, .unauthorized, "invalid password"),
            RequestError.UserDoesNotExist => sendErr(w, id, .internal, "user does not exist"),
            RequestError.UserExists => sendErr(w, id, .conflict, "user exists with the username"),
            RequestError.DbError => sendErr(w, id, .internal, "db error"),
            RequestError.OutOfMemory => {
                sendErr(w, id, .internal, "out of memory");
                self.oom();
            },
        }
    }

    fn respondTradingError(self: *Server, w: *std.Io.Writer, id: u64, err: trading.Error) void {
        switch (err) {
            error.InvalidParams => sendErr(w, id, .bad_request, "invalid params"),
            error.InvalidAsset => sendErr(w, id, .bad_request, "invalid asset"),
            error.AmountTooSmall => sendErr(w, id, .bad_request, "amount too small"),
            error.InsufficientFunds => sendErr(w, id, .unauthorized, "insufficient funds"),
            error.PriceUnavailable => sendErr(w, id, .internal, "price unavailable"),
            error.DbError => sendErr(w, id, .internal, "db error"),
            error.OutOfMemory => {
                sendErr(w, id, .internal, "out of memory");
                self.oom();
            },
        }
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
