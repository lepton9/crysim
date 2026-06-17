const std = @import("std");
const amounts = @import("crysim").amounts;
const cache_mod = @import("crysim").cache;

pub const SpotPrice = struct {
    price_usd_cents: i64,
    ts_ms: i64,
};

pub const PriceProvider = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        getSpot: *const fn (ctx: *anyopaque, asset: []const u8) anyerror!SpotPrice,
        deinit: *const fn (ctx: *anyopaque) void,
    };

    /// Get the spot price of the asset.
    pub fn getSpot(self: *PriceProvider, asset: []const u8) !SpotPrice {
        return self.vtable.getSpot(self.ctx, asset);
    }

    pub fn deinit(self: *PriceProvider) void {
        self.vtable.deinit(self.ctx);
    }
};

pub const CoinbasePriceProvider = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    client: std.http.Client,

    cache: cache_mod.OwnedStringCache(SpotPrice),

    const base_url = "https://api.coinbase.com/v2";

    fn init(io: std.Io, gpa: std.mem.Allocator) CoinbasePriceProvider {
        return .{
            .io = io,
            .gpa = gpa,
            .client = .{ .allocator = gpa, .io = io },
            .cache = undefined,
        };
    }

    pub fn deinit(self: *CoinbasePriceProvider) void {
        self.cache.deinit();
        self.client.deinit();
    }

    pub fn create(io: std.Io, gpa: std.mem.Allocator) !PriceProvider {
        const self = try gpa.create(CoinbasePriceProvider);
        self.* = CoinbasePriceProvider.init(io, gpa);
        self.cache = cache_mod.OwnedStringCache(SpotPrice).init(self.io, gpa, .{
            .ttl_ms = 10_000,
            .max_entries = 16,
            .prune_per_set = 2,
        });
        return self.provider();
    }

    pub fn provider(self: *CoinbasePriceProvider) PriceProvider {
        return .{ .ctx = self, .vtable = &coinbase_vtable };
    }

    fn nowMs(self: *const CoinbasePriceProvider) i64 {
        return std.Io.Clock.real.now(self.io).toMilliseconds();
    }

    fn getCached(self: *CoinbasePriceProvider, asset: []const u8) ?SpotPrice {
        const sp = self.cache.getPtr(asset) orelse return null;
        return sp.*;
    }

    fn putCache(self: *CoinbasePriceProvider, asset: []const u8, spot_price: SpotPrice) !void {
        try self.cache.set(asset, spot_price);
    }

    fn getSpotInner(self: *CoinbasePriceProvider, asset: []const u8) !SpotPrice {
        if (self.getCached(asset)) |spot_price| return spot_price;

        var url_buf: [128]u8 = undefined;
        const url = try std.fmt.bufPrint(
            &url_buf,
            "{s}/prices/{s}-USD/spot",
            .{ CoinbasePriceProvider.base_url, asset },
        );

        var body_list = std.ArrayList(u8).empty;
        var aw: std.Io.Writer.Allocating = .fromArrayList(self.gpa, &body_list);
        defer aw.deinit();

        const res = try self.client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .headers = .{ .accept_encoding = .{ .override = "identity" } },
            .response_writer = &aw.writer,
        });
        if (res.status.class() != .success) return error.BadStatus;

        body_list = aw.toArrayList();
        defer body_list.deinit(self.gpa);

        const CoinbaseResponse = struct {
            data: struct {
                amount: []const u8,
            },
        };

        const parsed = try std.json.parseFromSlice(
            CoinbaseResponse,
            self.gpa,
            body_list.items,
            .{ .ignore_unknown_fields = true },
        );
        defer parsed.deinit();

        const price_cents = try amounts.parseUsdToCents(parsed.value.data.amount);
        const spot_price: SpotPrice = .{ .price_usd_cents = price_cents, .ts_ms = self.nowMs() };
        try self.putCache(asset, spot_price);
        return spot_price;
    }

    fn vGetSpot(ctx: *anyopaque, asset: []const u8) anyerror!SpotPrice {
        const self: *CoinbasePriceProvider = @ptrCast(@alignCast(ctx));
        return self.getSpotInner(asset);
    }

    fn vDeinit(ctx: *anyopaque) void {
        const self: *CoinbasePriceProvider = @ptrCast(@alignCast(ctx));
        const gpa = self.gpa;
        self.deinit();
        gpa.destroy(self);
    }

    const coinbase_vtable: PriceProvider.VTable = .{
        .getSpot = vGetSpot,
        .deinit = vDeinit,
    };
};
