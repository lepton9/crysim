const std = @import("std");

const db_mod = @import("db.zig");
const prices = @import("prices.zig");
const trading = @import("trading.zig");

const Db = db_mod.Db;

const SIM_BUY_FEE_BPS: i64 = 25; // 0.25%
const SIM_SELL_FEE_BPS: i64 = 35; // 0.35%

pub const TradingBackend = enum {
    sim,
    exchange,
};

pub fn createTradingService(
    io: std.Io,
    gpa: std.mem.Allocator,
    db: *Db,
    backend: TradingBackend,
) !trading.TradingService {
    return switch (backend) {
        .sim => blk: {
            var price_provider = try prices.CoinbasePriceProvider.create(io, gpa);
            errdefer price_provider.deinit();

            var venue = try trading.SimVenue.create(gpa, price_provider, .{
                .buy_fee_bps = SIM_BUY_FEE_BPS,
                .sell_fee_bps = SIM_SELL_FEE_BPS,
            });
            errdefer venue.deinit();

            break :blk trading.TradingService.init(io, db, price_provider, venue);
        },
        .exchange => @panic("TODO: exchange trading"),
    };
}
