const std = @import("std");

const protocol = @import("crysim").protocol;
const amounts = @import("crysim").amounts;
const db_mod = @import("db.zig");
const prices = @import("prices.zig");

const Db = db_mod.Db;

pub const Error = error{
    InvalidParams,
    InvalidAsset,
    PriceUnavailable,
    InsufficientFunds,
    AmountTooSmall,
    DbError,
    OutOfMemory,
};

pub const Config = struct {
    buy_fee_bps: i64 = 25,
    sell_fee_bps: i64 = 35,
};

pub const TradingService = struct {
    io: std.Io,
    db: *Db,

    price_provider: prices.PriceProvider,
    venue: ExecutionVenue,

    pub fn init(
        io: std.Io,
        db: *Db,
        price_provider: prices.PriceProvider,
        venue: ExecutionVenue,
    ) TradingService {
        return .{
            .io = io,
            .db = db,
            .price_provider = price_provider,
            .venue = venue,
        };
    }

    pub fn deinit(self: *TradingService) void {
        self.venue.deinit();
        self.price_provider.deinit();
    }

    fn requireTradableAsset(self: *TradingService, asset: []const u8) Error!u8 {
        const d_opt = self.db.getAssetDecimals(asset) catch return error.DbError;
        const d = d_opt orelse return error.InvalidAsset;
        if (std.mem.eql(u8, asset, "USD")) return error.InvalidAsset;
        return d;
    }

    /// Fetch the current asset price.
    pub fn price(
        self: *TradingService,
        gpa: std.mem.Allocator,
        params: protocol.PriceParams,
    ) Error!protocol.PriceResult {
        const asset = try gpa.dupe(u8, params.asset);
        _ = try self.requireTradableAsset(asset);
        const spot_price = self.price_provider.getSpot(asset) catch return error.PriceUnavailable;

        const price_usd = try amounts.formatUsdFromCents(gpa, spot_price.price_usd_cents);
        return .{ .asset = asset, .price_usd = price_usd, .ts_ms = spot_price.ts_ms };
    }

    /// Buy some amount of the given asset.
    pub fn buy(
        self: *TradingService,
        gpa: std.mem.Allocator,
        params: protocol.BuyParams,
        user_id: i64,
    ) Error!protocol.TradeResult {
        const asset = try gpa.dupe(u8, params.asset);
        const usd_gross_cents = amounts.parseUsdToCents(params.usd) catch
            return error.InvalidParams;

        const decimals = try self.requireTradableAsset(asset);

        const order: ExecutionVenue.OrderRequest = .{
            .side = .buy,
            .asset = asset,
            .asset_decimals = decimals,
            .size = .{ .quote_usd_cents = usd_gross_cents },
        };

        const exec = try self.venue.placeOrder(order);

        self.db.transaction() catch return error.DbError;
        errdefer self.db.rollback();

        const usd_bal = self.db.getBalance(user_id, "USD") catch return error.DbError;
        if (usd_bal < exec.usd_gross_cents) return error.InsufficientFunds;
        self.db.setBalance(user_id, "USD", usd_bal - exec.usd_gross_cents) catch
            return error.DbError;

        const asset_bal = self.db.getBalance(user_id, exec.asset) catch
            return error.DbError;
        self.db.setBalance(user_id, exec.asset, asset_bal + exec.qty_minor) catch
            return error.DbError;

        const pos_opt = self.db.getPosition(user_id, exec.asset) catch return error.DbError;
        if (pos_opt) |pos| {
            const new_qty = pos.qty_minor + exec.qty_minor;
            const new_basis = pos.cost_basis_usd_cents + exec.usd_net_cents;
            self.db.setPosition(user_id, exec.asset, new_qty, new_basis) catch
                return error.DbError;
        } else {
            self.db.setPosition(user_id, exec.asset, exec.qty_minor, exec.usd_net_cents) catch
                return error.DbError;
        }

        const ts_ms: i64 = std.Io.Clock.real.now(self.io).toMilliseconds();
        const trade_id = self.db.insertTrade(
            user_id,
            ts_ms,
            exec.side,
            exec.asset,
            exec.qty_minor,
            exec.price_usd_cents,
            exec.usd_gross_cents,
            exec.fee_usd_cents,
            exec.usd_net_cents,
        ) catch return error.DbError;

        self.db.commit() catch return error.DbError;

        return .{
            .id = trade_id,
            .ts_ms = ts_ms,
            .side = "buy",
            .asset = exec.asset,
            .qty = try amounts.formatFixedFromMinor(gpa, exec.qty_minor, decimals, true),
            .price_usd = try amounts.formatUsdFromCents(gpa, exec.price_usd_cents),
            .usd_gross = try amounts.formatUsdFromCents(gpa, exec.usd_gross_cents),
            .fee_usd = try amounts.formatUsdFromCents(gpa, exec.fee_usd_cents),
            .usd_net = try amounts.formatUsdFromCents(gpa, exec.usd_net_cents),
        };
    }

    /// Sell some amount of the given asset.
    pub fn sell(
        self: *TradingService,
        gpa: std.mem.Allocator,
        params: protocol.SellParams,
        user_id: i64,
    ) Error!protocol.TradeResult {
        const asset = try gpa.dupe(u8, params.asset);
        const decimals = try self.requireTradableAsset(asset);
        const qty_minor = amounts.parseFixedToMinor(params.qty, decimals) catch
            return error.InvalidParams;

        const order: ExecutionVenue.OrderRequest = .{
            .side = .sell,
            .asset = asset,
            .asset_decimals = decimals,
            .size = .{ .base_minor = qty_minor },
        };

        const exec = try self.venue.placeOrder(order);

        self.db.transaction() catch return error.DbError;
        errdefer self.db.rollback();

        const asset_bal = self.db.getBalance(user_id, exec.asset) catch return error.DbError;
        if (asset_bal < exec.qty_minor) return error.InsufficientFunds;
        self.db.setBalance(user_id, exec.asset, asset_bal - exec.qty_minor) catch
            return error.DbError;

        const usd_bal = self.db.getBalance(user_id, "USD") catch return error.DbError;
        self.db.setBalance(user_id, "USD", usd_bal + exec.usd_net_cents) catch
            return error.DbError;

        // Reduce cost basis proportionally (weighted average).
        if (self.db.getPosition(user_id, exec.asset) catch return error.DbError) |pos| {
            if (pos.qty_minor <= 0) return error.DbError;
            const remaining_qty: i64 = pos.qty_minor - exec.qty_minor;
            const remaining_basis: i64 = if (remaining_qty <= 0) 0 else blk: {
                const basis: i128 = @as(i128, pos.cost_basis_usd_cents) * @as(i128, remaining_qty);
                const rb: i128 = @divTrunc(basis, @as(i128, pos.qty_minor));
                break :blk @intCast(rb);
            };
            self.db.setPosition(user_id, exec.asset, @max(remaining_qty, 0), remaining_basis) catch
                return error.DbError;
        }

        const ts_ms: i64 = std.Io.Clock.real.now(self.io).toMilliseconds();
        const trade_id = self.db.insertTrade(
            user_id,
            ts_ms,
            exec.side,
            exec.asset,
            exec.qty_minor,
            exec.price_usd_cents,
            exec.usd_gross_cents,
            exec.fee_usd_cents,
            exec.usd_net_cents,
        ) catch return error.DbError;

        self.db.commit() catch return error.DbError;

        return .{
            .id = trade_id,
            .ts_ms = ts_ms,
            .side = "sell",
            .asset = exec.asset,
            .qty = try amounts.formatFixedFromMinor(gpa, exec.qty_minor, decimals, true),
            .price_usd = try amounts.formatUsdFromCents(gpa, exec.price_usd_cents),
            .usd_gross = try amounts.formatUsdFromCents(gpa, exec.usd_gross_cents),
            .fee_usd = try amounts.formatUsdFromCents(gpa, exec.fee_usd_cents),
            .usd_net = try amounts.formatUsdFromCents(gpa, exec.usd_net_cents),
        };
    }

    /// Get the trade history of the given asset or all if not given.
    pub fn tradeHistory(
        self: *TradingService,
        gpa: std.mem.Allocator,
        params: protocol.TradeHistoryParams,
        user_id: i64,
    ) Error!struct { trades: []const protocol.TradeRow } {
        if (params.asset) |a| {
            _ = self.db.getAssetDecimals(a) catch return error.DbError;
        }

        const limit: u32 = params.limit orelse 50;
        const offset: u32 = params.offset orelse 0;

        const trades = self.db.listTradesOwned(gpa, user_id, params.asset, limit, offset) catch
            return error.DbError;
        var out: std.ArrayList(protocol.TradeRow) = .empty;
        errdefer out.deinit(gpa);
        try out.ensureTotalCapacity(gpa, trades.len);
        for (trades) |t| {
            const d_opt = self.db.getAssetDecimals(t.asset) catch return error.DbError;
            const d = d_opt orelse return error.InvalidAsset;
            out.appendAssumeCapacity(.{
                .id = t.id,
                .ts_ms = t.ts_ms,
                .side = @tagName(t.side),
                .asset = t.asset,
                .qty = try amounts.formatFixedFromMinor(gpa, t.qty_minor, d, true),
                .price_usd = try amounts.formatUsdFromCents(gpa, t.price_usd_cents),
                .usd_gross = try amounts.formatUsdFromCents(gpa, t.usd_gross_cents),
                .fee_usd = try amounts.formatUsdFromCents(gpa, t.fee_usd_cents),
                .usd_net = try amounts.formatUsdFromCents(gpa, t.usd_net_cents),
            });
        }

        return .{ .trades = try out.toOwnedSlice(gpa) };
    }

    /// Return the current state.
    pub fn state(
        self: *TradingService,
        gpa: std.mem.Allocator,
        user_id: i64,
    ) Error!protocol.StateResult {
        const balances = self.db.listBalancesOwned(gpa, user_id) catch return error.DbError;
        const net_deposits = self.db.sumUsdCashflows(user_id) catch return error.DbError;
        const fees_paid = self.db.sumTradeFeesUsd(user_id) catch return error.DbError;

        var equity_i128: i128 = 0;

        var proto_balances: std.ArrayList(protocol.BalanceRow) = .empty;
        errdefer proto_balances.deinit(gpa);
        try proto_balances.ensureTotalCapacity(gpa, balances.len);

        var assets_out: std.ArrayList(protocol.AssetState) = .empty;
        errdefer assets_out.deinit(gpa);

        for (balances) |b| {
            if (std.mem.eql(u8, b.asset, "USD")) {
                equity_i128 += @as(i128, b.amount_minor);
                proto_balances.appendAssumeCapacity(.{
                    .asset = b.asset,
                    .amount = try amounts.formatUsdFromCents(gpa, b.amount_minor),
                });
                continue;
            }

            const d_opt = self.db.getAssetDecimals(b.asset) catch return error.DbError;
            const d = d_opt orelse return error.InvalidAsset;
            const spot_price = self.price_provider.getSpot(b.asset) catch
                return error.PriceUnavailable;

            proto_balances.appendAssumeCapacity(.{
                .asset = b.asset,
                .amount = try amounts.formatFixedFromMinor(gpa, b.amount_minor, d, true),
            });

            const denom: i128 = amounts.pow10(i128, d) catch return error.InvalidAsset;
            const mv_i128: i128 = @divTrunc(
                @as(i128, b.amount_minor) * @as(i128, spot_price.price_usd_cents),
                denom,
            );
            const market_value: i64 = blk: {
                if (mv_i128 > std.math.maxInt(i64)) break :blk std.math.maxInt(i64);
                break :blk @intCast(mv_i128);
            };
            equity_i128 += mv_i128;

            var basis: i64 = 0;
            if (self.db.getPosition(user_id, b.asset) catch return error.DbError) |pos| {
                basis = pos.cost_basis_usd_cents;
            }

            try assets_out.append(gpa, .{
                .asset = b.asset,
                .qty = try amounts.formatFixedFromMinor(gpa, b.amount_minor, d, true),
                .cost_basis_usd = try amounts.formatUsdFromCents(gpa, basis),
                .spot_price_usd = try amounts.formatUsdFromCents(gpa, spot_price.price_usd_cents),
                .market_value_usd = try amounts.formatUsdFromCents(gpa, market_value),
                .unrealized_pnl_usd = try amounts.formatUsdFromCents(gpa, market_value - basis),
            });
        }

        const equity: i64 = blk: {
            if (equity_i128 > std.math.maxInt(i64)) break :blk std.math.maxInt(i64);
            break :blk @intCast(equity_i128);
        };
        const pnl: i64 = equity - net_deposits;

        return .{
            .balances = try proto_balances.toOwnedSlice(gpa),
            .equity_usd = try amounts.formatUsdFromCents(gpa, equity),
            .net_deposits_usd = try amounts.formatUsdFromCents(gpa, net_deposits),
            .pnl_usd = try amounts.formatUsdFromCents(gpa, pnl),
            .fees_paid_usd = try amounts.formatUsdFromCents(gpa, fees_paid),
            .assets = try assets_out.toOwnedSlice(gpa),
        };
    }
};

pub const ExecutionVenue = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        deinit: *const fn (ctx: *anyopaque) void,
        placeOrder: *const fn (ctx: *anyopaque, order: OrderRequest) Error!ExecutionReport,
    };

    pub const OrderSize = union(enum) {
        /// Spend this many USD cents. Used for buying.
        quote_usd_cents: i64,
        /// Trade this many asset minor units. Used for sells.
        base_minor: i64,
    };

    pub const OrderRequest = struct {
        side: Db.TradeSide,
        asset: []const u8,
        asset_decimals: u8,
        size: OrderSize,
    };

    pub const ExecutionReport = struct {
        ts_ms: i64,
        side: Db.TradeSide,
        asset: []const u8,
        qty_minor: i64,
        price_usd_cents: i64,
        usd_gross_cents: i64,
        fee_usd_cents: i64,
        usd_net_cents: i64,

        /// Optional venue order id (for real exchange integrations).
        venue_order_id: ?[]const u8 = null,
    };

    pub fn placeOrder(self: *ExecutionVenue, order: OrderRequest) Error!ExecutionReport {
        return self.vtable.placeOrder(self.ctx, order);
    }

    pub fn deinit(self: *ExecutionVenue) void {
        self.vtable.deinit(self.ctx);
    }
};

pub const SimVenue = struct {
    gpa: std.mem.Allocator,
    price_provider: prices.PriceProvider, // Borrowed
    cfg: Config,

    pub fn init(
        gpa: std.mem.Allocator,
        price_provider: prices.PriceProvider,
        cfg: Config,
    ) SimVenue {
        return .{ .gpa = gpa, .price_provider = price_provider, .cfg = cfg };
    }

    pub fn create(
        gpa: std.mem.Allocator,
        price_provider: prices.PriceProvider,
        cfg: Config,
    ) !ExecutionVenue {
        const self = try gpa.create(SimVenue);
        self.* = SimVenue.init(gpa, price_provider, cfg);
        return self.venue();
    }

    pub fn venue(self: *SimVenue) ExecutionVenue {
        return .{ .ctx = self, .vtable = &vtable };
    }

    fn place(
        ctx: *anyopaque,
        order: ExecutionVenue.OrderRequest,
    ) Error!ExecutionVenue.ExecutionReport {
        const self: *SimVenue = @ptrCast(@alignCast(ctx));

        if (order.asset.len == 0) return error.InvalidAsset;
        if (order.asset_decimals > 30) return error.InvalidAsset;

        const spot_price = self.price_provider.getSpot(order.asset) catch
            return error.PriceUnavailable;
        if (spot_price.price_usd_cents <= 0) return error.PriceUnavailable;

        switch (order.side) {
            .buy => {
                const usd_gross_cents = switch (order.size) {
                    .quote_usd_cents => |v| v,
                    .base_minor => return error.InvalidParams,
                };
                if (usd_gross_cents <= 0) return error.AmountTooSmall;

                const fee: i64 = @intCast(@divTrunc(
                    @as(i128, usd_gross_cents) * @as(i128, self.cfg.buy_fee_bps),
                    10_000,
                ));
                const usd_net: i64 = usd_gross_cents - fee;
                if (usd_net <= 0) return error.AmountTooSmall;

                const denom = amounts.pow10(i128, order.asset_decimals) catch
                    return error.InvalidAsset;
                const qty: i128 = @divTrunc(
                    @as(i128, usd_net) * denom,
                    @as(i128, spot_price.price_usd_cents),
                );
                if (qty <= 0 or qty > std.math.maxInt(i64))
                    return error.AmountTooSmall;

                return .{
                    .ts_ms = spot_price.ts_ms,
                    .side = .buy,
                    .asset = order.asset,
                    .qty_minor = @intCast(qty),
                    .price_usd_cents = spot_price.price_usd_cents,
                    .usd_gross_cents = usd_gross_cents,
                    .fee_usd_cents = fee,
                    .usd_net_cents = usd_net,
                };
            },
            .sell => {
                const qty_minor = switch (order.size) {
                    .base_minor => |v| v,
                    .quote_usd_cents => return error.InvalidParams,
                };
                if (qty_minor <= 0) return error.AmountTooSmall;

                const denom = amounts.pow10(i128, order.asset_decimals) catch
                    return error.InvalidAsset;

                const usd_gross: i64 = blk: {
                    const usd_gross: i128 = @divTrunc(
                        @as(i128, qty_minor) * @as(i128, spot_price.price_usd_cents),
                        denom,
                    );
                    if (usd_gross <= 0 or usd_gross > std.math.maxInt(i64))
                        return error.AmountTooSmall;
                    break :blk @intCast(usd_gross);
                };

                const fee: i64 = @intCast(@divTrunc(
                    @as(i128, usd_gross) * @as(i128, self.cfg.sell_fee_bps),
                    10_000,
                ));
                const usd_net: i64 = usd_gross - fee;
                if (usd_net <= 0) return error.AmountTooSmall;

                return .{
                    .ts_ms = spot_price.ts_ms,
                    .side = .sell,
                    .asset = order.asset,
                    .qty_minor = qty_minor,
                    .price_usd_cents = spot_price.price_usd_cents,
                    .usd_gross_cents = usd_gross,
                    .fee_usd_cents = fee,
                    .usd_net_cents = usd_net,
                };
            },
        }
    }

    fn vDeinit(ctx: *anyopaque) void {
        const self: *SimVenue = @ptrCast(@alignCast(ctx));
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    const vtable: ExecutionVenue.VTable = .{
        .deinit = vDeinit,
        .placeOrder = place,
    };
};
