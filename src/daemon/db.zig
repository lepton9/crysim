const std = @import("std");
const zqlite = @import("zqlite");
const protocol = @import("crysim").protocol;

pub const Db = struct {
    gpa: std.mem.Allocator,
    conn: zqlite.Conn,

    pub const User = struct {
        id: i64,
        username: []u8,
        password_hash: []u8,
        role: protocol.Role,
    };

    pub const Balance = struct {
        asset: []u8,
        amount_minor: i64,
    };

    pub const Position = struct {
        qty_minor: i64,
        cost_basis_usd_cents: i64,
    };

    pub const TradeSide = enum { buy, sell };
    pub const Trade = struct {
        id: i64,
        ts_ms: i64,
        side: TradeSide,
        asset: []u8,
        qty_minor: i64,
        price_usd_cents: i64,
        usd_gross_cents: i64,
        fee_usd_cents: i64,
        usd_net_cents: i64,
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

    pub fn transaction(self: *Db) !void {
        try self.conn.transaction();
    }

    pub fn commit(self: *Db) !void {
        try self.conn.commit();
    }

    pub fn rollback(self: *Db) void {
        self.conn.rollback();
    }

    /// Insert a new user to the database.
    pub fn insertUser(
        self: *Db,
        role: protocol.Role,
        username: []const u8,
        password_hash: []const u8,
        now_ms: i64,
    ) !i64 {
        try self.conn.exec(
            "insert into users (username, role, password_hash, created_at_ms) values (?1, ?2, ?3, ?4)",
            .{ username, @tagName(role), password_hash, now_ms },
        );
        return self.conn.lastInsertedRowId();
    }

    /// Insert a new user to the database.
    ///
    /// Add some initial starting balance for the user.
    pub fn insertUserWithInitialCredit(
        self: *Db,
        role: protocol.Role,
        username: []const u8,
        password_hash: []const u8,
        now_ms: i64,
        starting_usd_cents: i64,
    ) !i64 {
        try self.transaction();
        errdefer self.rollback();

        const user_id = try self.insertUser(role, username, password_hash, now_ms);

        // Initialize USD balance and record a cashflow so PnL can be computed.
        try self.conn.exec(
            "insert into balances (user_id, asset, amount_minor) values (?1, 'USD', ?2)",
            .{ user_id, starting_usd_cents },
        );
        try self.conn.exec(
            "insert into cashflows (user_id, ts_ms, asset, amount_minor, kind) values (?1, ?2, 'USD', ?3, 'initial')",
            .{ user_id, now_ms, starting_usd_cents },
        );

        try self.commit();
        return user_id;
    }

    /// Update the user password.
    pub fn updateUserPasswordHash(
        self: *Db,
        user_id: i64,
        password_hash: []const u8,
    ) !void {
        try self.conn.exec(
            "update users set password_hash = ?2 where id = ?1",
            .{ user_id, password_hash },
        );
    }

    /// Fetch and allocate user from the database based on the username.
    pub fn getUserOwned(self: *Db, gpa: std.mem.Allocator, username: []const u8) !?User {
        const row = try self.conn.row(
            "select id, username, password_hash, role from users where username = ?1 limit 1",
            .{username},
        ) orelse return null;

        defer row.deinit();

        const id = row.int(0);
        const un_txt = row.text(1);
        const pw_txt = row.text(2);
        const role_txt = row.text(3);
        const role = std.meta.stringToEnum(protocol.Role, role_txt) orelse
            return error.InvalidRole;

        return .{
            .id = id,
            .username = try gpa.dupe(u8, un_txt),
            .password_hash = try gpa.dupe(u8, pw_txt),
            .role = role,
        };
    }

    /// Return the amount of decimals are tracked for the selected asset.
    pub fn getAssetDecimals(self: *Db, asset: []const u8) !?u8 {
        const row = try self.conn.row(
            "select decimals from assets where symbol = ?1 limit 1",
            .{asset},
        ) orelse return null;
        defer row.deinit();
        const d64 = row.int(0);
        if (d64 < 0 or d64 > 255) return error.InvalidDecimals;
        return @intCast(d64);
    }

    /// Fetch the asset balance.
    pub fn getBalance(self: *Db, user_id: i64, asset: []const u8) !i64 {
        const row = try self.conn.row(
            "select amount_minor from balances where user_id = ?1 and asset = ?2 limit 1",
            .{ user_id, asset },
        ) orelse return 0;
        defer row.deinit();
        return row.int(0);
    }

    /// Set the new balance for the asset.
    pub fn setBalance(self: *Db, user_id: i64, asset: []const u8, amount_minor: i64) !void {
        try self.conn.exec(
            "insert into balances (user_id, asset, amount_minor) values (?1, ?2, ?3) " ++
                "on conflict(user_id, asset) do update set amount_minor = excluded.amount_minor",
            .{ user_id, asset, amount_minor },
        );
    }

    /// Fetch all the balances the user has.
    pub fn listBalancesOwned(self: *Db, alloc: std.mem.Allocator, user_id: i64) ![]Balance {
        var rows = try self.conn.rows(
            "select asset, amount_minor from balances where user_id = ?1 order by asset asc",
            .{user_id},
        );
        defer rows.deinit();

        var out: std.ArrayList(Balance) = .empty;
        errdefer {
            for (out.items) |b| alloc.free(b.asset);
            out.deinit(alloc);
        }

        while (rows.next()) |r| {
            const asset_txt = r.text(0);
            const amt = r.int(1);
            try out.append(alloc, .{
                .asset = try alloc.dupe(u8, asset_txt),
                .amount_minor = amt,
            });
        }
        return try out.toOwnedSlice(alloc);
    }

    /// Get the current position for the asset.
    pub fn getPosition(self: *Db, user_id: i64, asset: []const u8) !?Position {
        const row = try self.conn.row(
            "select qty_minor, cost_basis_usd_cents from positions where user_id = ?1 and asset = ?2 limit 1",
            .{ user_id, asset },
        ) orelse return null;
        defer row.deinit();

        return .{
            .qty_minor = row.int(0),
            .cost_basis_usd_cents = row.int(1),
        };
    }

    /// Set the current position for the asset.
    pub fn setPosition(
        self: *Db,
        user_id: i64,
        asset: []const u8,
        qty_minor: i64,
        cost_basis_usd_cents: i64,
    ) !void {
        try self.conn.exec(
            "insert into positions (user_id, asset, qty_minor, cost_basis_usd_cents) values (?1, ?2, ?3, ?4) " ++
                "on conflict(user_id, asset) do update set qty_minor = excluded.qty_minor, cost_basis_usd_cents = excluded.cost_basis_usd_cents",
            .{ user_id, asset, qty_minor, cost_basis_usd_cents },
        );
    }

    /// Insert a new trade into the database.
    pub fn insertTrade(
        self: *Db,
        user_id: i64,
        ts_ms: i64,
        side: TradeSide,
        asset: []const u8,
        qty_minor: i64,
        price_usd_cents: i64,
        usd_gross_cents: i64,
        fee_usd_cents: i64,
        usd_net_cents: i64,
    ) !i64 {
        try self.conn.exec(
            "insert into trades (user_id, ts_ms, side, asset, qty_minor, price_usd_cents, usd_gross_cents, fee_usd_cents, usd_net_cents) " ++
                "values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
            .{
                user_id,
                ts_ms,
                @tagName(side),
                asset,
                qty_minor,
                price_usd_cents,
                usd_gross_cents,
                fee_usd_cents,
                usd_net_cents,
            },
        );
        return self.conn.lastInsertedRowId();
    }

    /// List all the trades the user has made.
    pub fn listTradesOwned(
        self: *Db,
        alloc: std.mem.Allocator,
        user_id: i64,
        asset_opt: ?[]const u8,
        limit: u32,
        offset: u32,
    ) ![]Trade {
        const has_asset = asset_opt != null;
        const sql = if (has_asset)
            "select id, ts_ms, side, asset, qty_minor, price_usd_cents, usd_gross_cents, fee_usd_cents, usd_net_cents " ++
                "from trades where user_id = ?1 and asset = ?2 order by ts_ms desc limit ?3 offset ?4"
        else
            "select id, ts_ms, side, asset, qty_minor, price_usd_cents, usd_gross_cents, fee_usd_cents, usd_net_cents " ++
                "from trades where user_id = ?1 order by ts_ms desc limit ?2 offset ?3";

        var rows = if (has_asset)
            try self.conn.rows(sql, .{
                user_id,
                asset_opt.?,
                @as(i64, @intCast(limit)),
                @as(i64, @intCast(offset)),
            })
        else
            try self.conn.rows(sql, .{
                user_id,
                @as(i64, @intCast(limit)),
                @as(i64, @intCast(offset)),
            });
        defer rows.deinit();

        var out: std.ArrayList(Trade) = .empty;
        errdefer {
            for (out.items) |t| alloc.free(t.asset);
            out.deinit(alloc);
        }

        while (rows.next()) |r| {
            const side_txt = r.text(2);
            const side = std.meta.stringToEnum(TradeSide, side_txt) orelse
                return error.InvalidTradeSide;
            try out.append(alloc, .{
                .id = r.int(0),
                .ts_ms = r.int(1),
                .side = side,
                .asset = try alloc.dupe(u8, r.text(3)),
                .qty_minor = r.int(4),
                .price_usd_cents = r.int(5),
                .usd_gross_cents = r.int(6),
                .fee_usd_cents = r.int(7),
                .usd_net_cents = r.int(8),
            });
        }

        return try out.toOwnedSlice(alloc);
    }

    /// Sum up all the cashflows the user has made.
    pub fn sumUsdCashflows(self: *Db, user_id: i64) !i64 {
        const row = try self.conn.row(
            "select coalesce(sum(amount_minor), 0) from cashflows where user_id = ?1 and asset = 'USD'",
            .{user_id},
        ) orelse return 0;
        defer row.deinit();
        return row.int(0);
    }

    /// Sum up all the trades the user has made.
    pub fn sumTradeFeesUsd(self: *Db, user_id: i64) !i64 {
        const row = try self.conn.row(
            "select coalesce(sum(fee_usd_cents), 0) from trades where user_id = ?1",
            .{user_id},
        ) orelse return 0;
        defer row.deinit();
        return row.int(0);
    }
};
