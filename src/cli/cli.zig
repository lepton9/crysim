const std = @import("std");
const zcli = @import("zcli");
const options = @import("build_options");

const crysim = @import("crysim");
const protocol = crysim.protocol;
const session = crysim.session;
const data = crysim.data;

const Method = protocol.Method;

const spec: zcli.CliApp = .{
    .config = .{
        .name = options.program_name,
        .auto_help = true,
        .auto_version = true,
        .help_max_width = 80,
        .exclusive_group_mode = .combined,
    },
    .commands = commands,
    .options = &[_]zcli.Opt{
        .{
            .long_name = "host",
            .desc = "Daemon host",
            .arg = .{ .name = "host", .default = "127.0.0.1", .type = .Text },
        },
        .{
            .long_name = "port",
            .desc = "Daemon port",
            .arg = .{ .name = "port", .default = "5555", .type = .Int },
        },
        .{
            .long_name = "token",
            .desc = "Session token (overrides token file)",
            .arg = .{ .name = "token", .type = .Text },
        },
        .{ .long_name = "version", .short_name = "v", .desc = "Print version" },
        .{ .long_name = "help", .short_name = "h", .desc = "Print help" },
    },
    .positionals = &[_]zcli.PosArg{},
};

const commands = &[_]zcli.Cmd{
    .{ .name = "health", .desc = "Check daemon health", .action = cmdHealth },
    .{ .name = "login", .desc = "Login and store token", .positionals = &[_]zcli.PosArg{
        .{ .name = "username", .desc = "Username", .required = true },
        .{ .name = "password", .desc = "Password", .required = true },
    }, .action = cmdLogin },
    .{ .name = "logout", .desc = "Logout from the session", .action = cmdLogout },
    .{
        .name = "changepw",
        .desc = "Change password",
        .action = cmdChangePassword,
        .positionals = &[_]zcli.PosArg{
            .{ .name = "old", .desc = "Old password", .required = true },
            .{ .name = "new", .desc = "New password", .required = true },
        },
    },
    .{ .name = "whoami", .desc = "Show current session", .action = cmdWhoAmI },
    .{ .name = "state", .desc = "Get current state", .action = cmdState },
    .{
        .name = "createuser",
        .desc = "Create a new user",
        .positionals = &[_]zcli.PosArg{
            .{ .name = "role", .desc = "Role", .required = true },
            .{ .name = "username", .desc = "Username", .required = true },
            .{ .name = "password", .desc = "Password", .required = true },
        },
        .action = cmdCreateUser,
    },
    .{ .name = "sessionlist", .desc = "List all the active sessions", .action = cmdSessionList },
    .{ .name = "shutdown", .desc = "Shutdown the server", .action = cmdShutdown },
};

const Ctx = struct {
    init: std.process.Init,
    cli: *zcli.Cli,
    sess: *session.ClientSession,
};

const CliTokenStore = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    env: *std.process.Environ.Map,
    token: ?[]const u8 = null,

    fn tokenFilePath(self: *const CliTokenStore, gpa: std.mem.Allocator) ![]u8 {
        return (try data.dataFilePath(self.io, gpa, self.env, "client", "token")) orelse
            return error.NoHome;
    }

    fn load(ctxp: *anyopaque, gpa: std.mem.Allocator) anyerror!?[]u8 {
        const self: *CliTokenStore = @ptrCast(@alignCast(ctxp));

        if (self.token) |token| return try gpa.dupe(u8, token);

        const path = try self.tokenFilePath(gpa);
        defer gpa.free(path);

        var file = std.Io.Dir.openFileAbsolute(self.io, path, .{
            .mode = .read_only,
        }) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer file.close(self.io);

        var rbuf: [4096]u8 = undefined;
        var r = std.Io.File.Reader.init(file, self.io, &rbuf);
        const line = (try r.interface.takeDelimiter('\n')) orelse return null;
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) return null;
        return try gpa.dupe(u8, trimmed);
    }

    fn save(ctxp: *anyopaque, token: []const u8) anyerror!void {
        const self: *CliTokenStore = @ptrCast(@alignCast(ctxp));

        const path = try self.tokenFilePath(self.gpa);
        defer self.gpa.free(path);

        var file = try std.Io.Dir.createFileAbsolute(self.io, path, .{ .truncate = true });
        defer file.close(self.io);

        var wbuf: [256]u8 = undefined;
        var w = std.Io.File.Writer.init(file, self.io, &wbuf);
        try w.interface.writeAll(token);
        try w.interface.writeAll("\n");
        try w.interface.flush();
    }
};

/// Handle the parsed CLI and call the command function.
pub fn handleCli(init: std.process.Init) !void {
    const gpa = init.gpa;
    const cli = try zcli.parseInit(init, &spec);
    defer cli.deinit(gpa);

    var store = CliTokenStore{
        .io = init.io,
        .gpa = init.gpa,
        .env = init.environ_map,
        .token = if (cli.findOption("token")) |t| t.value.?.string else null,
    };
    const token_store: session.ClientSession.TokenStore = .{
        .ctx = &store,
        .load = CliTokenStore.load,
        .save = CliTokenStore.save,
    };

    var sess = session.ClientSession.initWithTokenStore(
        init.io,
        init.gpa,
        getConnectOptions(cli),
        token_store,
    );
    defer sess.deinit();

    var ctx: Ctx = .{ .init = init, .cli = cli, .sess = &sess };
    if (cli.cmd) |c| {
        const f = c.exec orelse return;
        try f(&ctx);
    }
}

fn getConnectOptions(cli: *const zcli.Cli) protocol.Options {
    var opts: protocol.Options = .{};
    if (cli.findOption("host")) |o| {
        opts.host = o.value.?.string;
    }
    if (cli.findOption("port")) |o| {
        if (std.math.cast(u16, o.value.?.int)) |p|
            opts.port = p;
    }
    return opts;
}

fn printJson(value: anytype) void {
    std.debug.print("{f}\n", .{std.json.fmt(value, .{ .whitespace = .indent_2 })});
}

fn cmdHealth(ctxp: *anyopaque) anyerror!void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctxp));
    const resp = try ctx.sess.request(.health);
    defer resp.deinit();
    printJson(resp.value);
}

fn cmdLogin(ctxp: *anyopaque) anyerror!void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctxp));

    const user_pos = ctx.cli.findPositional("username") orelse unreachable;
    const pass_pos = ctx.cli.findPositional("password") orelse unreachable;

    const resp = try ctx.sess.requestParams(.login, protocol.LoginParams{
        .username = user_pos.value,
        .password = pass_pos.value,
    });
    defer resp.deinit();

    const result = blk: {
        const result_val = resp.value.result;
        if (resp.value.ok) if (result_val) |r| break :blk r;
        printJson(resp.value);
        return;
    };

    const parsed = try std.json.parseFromValue(
        protocol.LoginResult,
        ctx.init.gpa,
        result,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    try ctx.sess.saveToken(parsed.value.token);
    printJson(resp.value);
}

fn cmdLogout(ctxp: *anyopaque) anyerror!void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctxp));
    const resp = try ctx.sess.request(.logout);
    defer resp.deinit();
    printJson(resp.value);
}

fn cmdCreateUser(ctxp: *anyopaque) anyerror!void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctxp));

    const user_role = ctx.cli.findPositional("role") orelse unreachable;
    const user_pos = ctx.cli.findPositional("username") orelse unreachable;
    const pass_pos = ctx.cli.findPositional("password") orelse unreachable;

    const resp = try ctx.sess.requestParams(.create_user, protocol.CreateUserParams{
        .role = user_role.value,
        .username = user_pos.value,
        .password = pass_pos.value,
    });
    defer resp.deinit();

    const result = blk: {
        const result_val = resp.value.result;
        if (resp.value.ok) if (result_val) |r| break :blk r;
        printJson(resp.value);
        return;
    };

    const parsed = try std.json.parseFromValue(
        protocol.CreateUserResult,
        ctx.init.gpa,
        result,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    printJson(resp.value);
}

fn cmdChangePassword(ctxp: *anyopaque) anyerror!void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctxp));
    const old = ctx.cli.findPositional("old") orelse unreachable;
    const new = ctx.cli.findPositional("new") orelse unreachable;
    const resp = try ctx.sess.requestParams(.change_password, .{
        .old = old.value,
        .new = new.value,
    });
    defer resp.deinit();
    printJson(resp.value);
}

fn cmdSessionList(ctxp: *anyopaque) anyerror!void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctxp));
    const resp = try ctx.sess.request(.session_list);
    defer resp.deinit();
    printJson(resp.value);
}

fn cmdShutdown(ctxp: *anyopaque) anyerror!void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctxp));
    const resp = try ctx.sess.request(.shutdown);
    defer resp.deinit();
    printJson(resp.value);
}

fn cmdWhoAmI(ctxp: *anyopaque) anyerror!void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctxp));
    const resp = try ctx.sess.request(.whoami);
    defer resp.deinit();
    printJson(resp.value);
}

fn cmdState(ctxp: *anyopaque) anyerror!void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctxp));
    const resp = try ctx.sess.request(.state);
    defer resp.deinit();
    printJson(resp.value);
}
