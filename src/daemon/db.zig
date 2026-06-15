const std = @import("std");
const zqlite = @import("zqlite");
const protocol = @import("crysim").protocol;

pub const Db = struct {
    gpa: std.mem.Allocator,
    conn: zqlite.Conn,

    pub const User = struct {
        username: []u8,
        password_hash: []u8,
        role: protocol.Role,
    };

    pub fn init(gpa: std.mem.Allocator, path: []const u8) !Db {
        const flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode;
        var conn = try zqlite.open(@ptrCast(path.ptr), flags);
        errdefer conn.close();

        try conn.busyTimeout(5000);

        var db: Db = .{ .gpa = gpa, .conn = conn };
        try db.ensureSchema();
        return db;
    }

    pub fn deinit(self: *Db) void {
        self.conn.close();
    }

    fn ensureSchema(self: *Db) !void {
        const schema = @embedFile("db/schema.sql");
        try self.conn.execNoArgs(schema);
    }

    pub fn insertUser(
        self: *Db,
        role: protocol.Role,
        username: []const u8,
        password_hash: []const u8,
        now_ms: i64,
    ) !void {
        try self.conn.exec(
            "insert into users (username, role, password_hash, created_at_ms) values (?1, ?2, ?3, ?4)",
            .{ username, @tagName(role), password_hash, now_ms },
        );
    }

    pub fn updateUserPasswordHash(
        self: *Db,
        username: []const u8,
        password_hash: []const u8,
    ) !void {
        try self.conn.exec(
            "update users set password_hash = ?2 where username = ?1",
            .{ username, password_hash },
        );
    }

    pub fn getUserOwned(self: *Db, gpa: std.mem.Allocator, username: []const u8) !?User {
        if (try self.conn.row(
            "select username, password_hash, role from users where username = ?1 limit 1",
            .{username},
        )) |row| {
            defer row.deinit();

            const un_txt = row.text(0);
            const pw_txt = row.text(1);
            const role_txt = row.text(2);
            const role = std.meta.stringToEnum(protocol.Role, role_txt) orelse
                return error.InvalidRole;

            return .{
                .username = try gpa.dupe(u8, un_txt),
                .password_hash = try gpa.dupe(u8, pw_txt),
                .role = role,
            };
        }
        return null;
    }
};
