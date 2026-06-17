const std = @import("std");

/// A small reusable cache keyed by strings.
/// - If `V` has a `deinit` method, it will be called when entries are removed.
pub fn OwnedStringCache(comptime V: type) type {
    return struct {
        io: std.Io,
        allocator: std.mem.Allocator,
        map: std.StringHashMapUnmanaged(Entry) = .{},
        ttl_ms: i64,
        max_entries: usize,
        prune_per_set: usize,

        const Self = @This();

        const Entry = struct {
            value: V,
            written_at_ms: i64,
            accessed_at_ms: i64,
        };

        fn isContainerType(comptime T: type) bool {
            return switch (@typeInfo(T)) {
                .@"struct", .@"enum", .@"union", .@"opaque" => true,
                else => false,
            };
        }

        fn valueDeinit(allocator: std.mem.Allocator, v: *V) void {
            if (!comptime isContainerType(V)) return;
            if (!@hasDecl(V, "deinit")) return;
            const info = @typeInfo(@TypeOf(V.deinit)).@"fn";
            comptime switch (info.params.len) {
                1 => v.deinit(),
                2 => v.deinit(allocator),
                else => @compileError(
                    "Cache value deinit must be deinit(self) or deinit(self, allocator)",
                ),
            };
        }

        pub const Options = struct {
            /// <= 0 means no TTL expiration.
            ttl_ms: i64 = 0,
            /// 0 means unbounded.
            max_entries: usize = 0,
            /// How many expired entries to prune on each `set`.
            prune_per_set: usize = 1,
        };

        pub fn init(io: std.Io, allocator: std.mem.Allocator, opts: Options) Self {
            return .{
                .io = io,
                .allocator = allocator,
                .ttl_ms = opts.ttl_ms,
                .max_entries = opts.max_entries,
                .prune_per_set = opts.prune_per_set,
            };
        }

        pub fn deinit(self: *Self) void {
            var it = self.map.iterator();
            while (it.next()) |e| {
                self.allocator.free(e.key_ptr.*);
                valueDeinit(self.allocator, &e.value_ptr.value);
            }
            self.map.deinit(self.allocator);
        }

        pub fn count(self: *const Self) usize {
            return self.map.size;
        }

        fn nowMs(self: *const Self) i64 {
            return std.Io.Clock.real.now(self.io).toMilliseconds();
        }

        fn isExpired(self: *const Self, now_ms: i64, e: *const Entry) bool {
            if (self.ttl_ms <= 0) return false;
            const age = now_ms - e.written_at_ms;
            return age >= self.ttl_ms;
        }

        fn removeOwned(self: *Self, key: []const u8) void {
            var kv = self.map.fetchRemove(key) orelse return;
            self.allocator.free(kv.key);
            valueDeinit(self.allocator, &kv.value.value);
        }

        /// Return a pointer to the value if present and not expired.
        ///
        /// If the entry is expired, it is removed.
        pub fn getPtr(self: *Self, key: []const u8) ?*V {
            return self.getPtrAt(key, self.nowMs());
        }

        fn getPtrAt(self: *Self, key: []const u8, now_ms: i64) ?*V {
            const e = self.map.getPtr(key) orelse return null;
            if (self.isExpired(now_ms, e)) {
                self.removeOwned(key);
                return null;
            }
            e.accessed_at_ms = now_ms;
            return &e.value;
        }

        /// Insert or update an entry.
        pub fn set(self: *Self, key: []const u8, value: V) !void {
            return self.setAt(key, value, self.nowMs());
        }

        fn setAt(self: *Self, key: []const u8, value: V, now_ms: i64) !void {
            if (self.map.getPtr(key)) |e| {
                valueDeinit(self.allocator, &e.value);
                e.* = .{ .value = value, .written_at_ms = now_ms, .accessed_at_ms = now_ms };
                return;
            }

            const gop = try self.map.getOrPut(self.allocator, key);
            if (gop.found_existing) {
                valueDeinit(self.allocator, &gop.value_ptr.value);
            } else gop.key_ptr.* = try self.allocator.dupe(u8, key);

            gop.value_ptr.* = .{
                .value = value,
                .written_at_ms = now_ms,
                .accessed_at_ms = now_ms,
            };

            if (self.prune_per_set > 0) self.pruneExpiredAt(now_ms, self.prune_per_set);
            self.evictToMax(now_ms);
        }

        /// Remove up to `budget` expired entries.
        pub fn pruneExpired(self: *Self, budget: usize) void {
            self.pruneExpiredAt(self.nowMs(), budget);
        }

        fn pruneExpiredAt(self: *Self, now_ms: i64, budget: usize) void {
            if (budget == 0 or self.ttl_ms <= 0) return;
            var removed: usize = 0;
            while (removed < budget) : (removed += 1) {
                var victim: ?[]const u8 = null;
                var it = self.map.iterator();
                while (it.next()) |e| {
                    if (self.isExpired(now_ms, e.value_ptr)) {
                        victim = e.key_ptr.*;
                        break;
                    }
                }
                if (victim == null) return;
                self.removeOwned(victim.?);
            }
        }

        fn evictToMax(self: *Self, now_ms: i64) void {
            if (self.max_entries == 0) return;
            while (self.map.size > self.max_entries) {
                if (!self.evictOneLru(now_ms)) break;
            }
        }

        fn evictOneLru(self: *Self, now_ms: i64) bool {
            _ = now_ms;
            var victim: ?[]const u8 = null;
            var best_ts: i64 = std.math.maxInt(i64);

            var it = self.map.iterator();
            while (it.next()) |e| {
                const ts = e.value_ptr.accessed_at_ms;
                if (ts < best_ts) {
                    best_ts = ts;
                    victim = e.key_ptr.*;
                }
            }

            if (victim == null) return false;
            self.removeOwned(victim.?);
            return true;
        }
    };
}

test "OwnedStringCache TTL + LRU" {
    const t = std.testing;

    var c = OwnedStringCache(i32).init(t.allocator, t.io, .{
        .ttl_ms = 5,
        .max_entries = 2,
        .prune_per_set = 0,
    });
    defer c.deinit();

    try c.setAt("a", 1, 0);
    try c.setAt("b", 2, 0);
    try t.expectEqual(@as(usize, 2), c.count());
    try t.expectEqual(@as(i32, 1), c.getPtrAt("a", 0).?.*);

    _ = c.getPtrAt("a", 1);
    try c.setAt("c", 3, 1);
    try t.expectEqual(@as(usize, 2), c.count());
    try t.expect(c.getPtrAt("a", 1) != null);
    try t.expect(c.getPtrAt("b", 1) == null);
    try t.expectEqual(@as(i32, 3), c.getPtrAt("c", 1).?.*);

    try t.expect(c.getPtrAt("a", 10) == null);
}
