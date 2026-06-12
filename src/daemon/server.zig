const std = @import("std");


pub const Server = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    listen_addr: std.Io.net.IpAddress,
    server: std.Io.net.Server = undefined,
    connections: std.ArrayListUnmanaged(std.Io.net.Stream) = .empty,
    running: std.atomic.Value(bool) = .init(false),

    pub fn init(io: std.Io, gpa: std.mem.Allocator, addr: std.Io.net.IpAddress) !*Server {
        const s = try gpa.create(Server);
        s.* = .{
            .io = io,
            .gpa = gpa,
            .listen_addr = addr,
            .server = try addr.listen(io, .{.reuse_address = true}),
        };
        s.running.store(true, .seq_cst);
        return s;
    }

    pub fn deinit(self: *Server) void {
        self.server.deinit(self.io);
        self.gpa.destroy(self);
    }

    pub fn stop(self: *Server) void {
        self.running.store(false, .seq_cst);
    }

    pub fn coreLoop(self: *Server) !void {
        while (self.running.load(.seq_cst)) {
            std.log.info("main", .{});
        }
    }

    /// Start accepting new connections in a loop.
    pub fn startAccept(self: *Server) !void {
        while (self.running.load(.seq_cst)) {
            const conn = try self.server.accept(self.io);
            try self.connections.append(self.gpa, conn);
            std.log.info("accepted: {s}", .{conn.socket.address.ip4.bytes});
        }
    }
};

