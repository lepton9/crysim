const std = @import("std");
const zcli = @import("zcli");
const options = @import("build_options");

const crysim = @import("crysim");
const protocol = crysim.protocol;

const Method = protocol.Method;

const DATA_PATH = ".local/share/crysim";

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
    .{ .name = "whoami", .desc = "Show current session", .action = cmdWhoAmI },
    .{ .name = "state", .desc = "Get current state", .action = cmdState },
};

const Ctx = struct {
    init: std.process.Init,
    cli: *zcli.Cli,
};

/// Handle the parsed CLI and call the command function.
pub fn handleCli(init: std.process.Init) !void {
    const gpa = init.gpa;
    const cli = try zcli.parseInit(init, &spec);
    defer cli.deinit(gpa);
    var ctx: Ctx = .{ .init = init, .cli = cli };
    if (cli.cmd) |c| {
        const f = c.exec orelse return;
        try f(&ctx);
    }
}

fn getConnectOptions(ctx: *const Ctx) protocol.Options {
    var opts: protocol.Options = .{};
    if (ctx.cli.findOption("host")) |o| {
        opts.host = o.value.?.string;
    }
    if (ctx.cli.findOption("port")) |o| {
        if (std.math.cast(u16, o.value.?.int)) |p|
            opts.port = p;
    }
    return opts;
}

fn tokenFilePath(ctx: *const Ctx, gpa: std.mem.Allocator) ![]u8 {
    const home = ctx.init.environ_map.get("HOME") orelse return error.NoHome;
    return std.fmt.allocPrint(gpa, "{s}/{s}/token", .{ home, DATA_PATH });
}

/// Load the session token from the saved file.
fn loadToken(ctx: *const Ctx, gpa: std.mem.Allocator) !?[]u8 {
    if (ctx.cli.findOption("token")) |o| {
        return try gpa.dupe(u8, o.value.?.string);
    }

    const path = try tokenFilePath(ctx, gpa);
    defer gpa.free(path);

    var file = std.Io.Dir.openFileAbsolute(ctx.init.io, path, .{
        .mode = .read_only,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(ctx.init.io);

    var rbuf: [4096]u8 = undefined;
    var r = std.Io.File.Reader.init(file, ctx.init.io, &rbuf);
    const line = (try r.interface.takeDelimiter('\n')) orelse return null;
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try gpa.dupe(u8, trimmed);
}

/// Save the session token to a file.
fn saveToken(ctx: *const Ctx, token: []const u8) !void {
    const home = ctx.init.environ_map.get("HOME") orelse return error.NoHome;

    var home_dir = try std.Io.Dir.openDirAbsolute(ctx.init.io, home, .{});
    defer home_dir.close(ctx.init.io);

    try home_dir.createDirPath(ctx.init.io, DATA_PATH);
    var cdir = try home_dir.openDir(ctx.init.io, DATA_PATH, .{});
    defer cdir.close(ctx.init.io);

    var file = try cdir.createFile(ctx.init.io, "token", .{ .truncate = true });
    defer file.close(ctx.init.io);

    var wbuf: [256]u8 = undefined;
    var w = std.Io.File.Writer.init(file, ctx.init.io, &wbuf);
    try w.interface.writeAll(token);
    try w.interface.writeAll("\n");
    try w.interface.flush();
}

fn printJson(value: anytype) void {
    std.debug.print("{f}\n", .{std.json.fmt(value, .{ .whitespace = .indent_2 })});
}

fn cmdHealth(ctxp: *anyopaque) anyerror!void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctxp));
    const resp = try protocol.request(
        ctx.init.io,
        ctx.init.gpa,
        getConnectOptions(ctx),
        .{ .id = 1, .method = Method.health },
    );
    defer resp.deinit();
    printJson(resp.value);
}

fn cmdLogin(ctxp: *anyopaque) anyerror!void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctxp));

    const user_pos = ctx.cli.findPositional("username") orelse return error.MissingField;
    const pass_pos = ctx.cli.findPositional("password") orelse return error.MissingField;

    const resp = try protocol.request(
        ctx.init.io,
        ctx.init.gpa,
        getConnectOptions(ctx),
        .{
            .id = 1,
            .method = Method.login,
            .params = .{ .username = user_pos.value, .password = pass_pos.value },
        },
    );
    defer resp.deinit();

    if (!resp.value.ok) {
        printJson(resp.value);
        return;
    }

    const result_val = resp.value.result orelse {
        printJson(resp.value);
        return;
    };
    const LoginResult = struct { token: []const u8, role: []const u8, expires_at_ms: i64 };
    const parsed = try std.json.parseFromValue(
        LoginResult,
        ctx.init.gpa,
        result_val,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    try saveToken(ctx, parsed.value.token);
    printJson(resp.value);
}

fn cmdLogout(ctxp: *anyopaque) anyerror!void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctxp));
    const token = (try loadToken(ctx, ctx.init.gpa)) orelse return error.NotLoggedIn;
    defer ctx.init.gpa.free(token);

    const resp = try protocol.request(
        ctx.init.io,
        ctx.init.gpa,
        getConnectOptions(ctx),
        .{ .id = 1, .token = token, .method = Method.logout },
    );
    defer resp.deinit();
    printJson(resp.value);
}

fn cmdWhoAmI(ctxp: *anyopaque) anyerror!void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctxp));
    const token = (try loadToken(ctx, ctx.init.gpa)) orelse return error.NotLoggedIn;
    defer ctx.init.gpa.free(token);

    const resp = try protocol.request(
        ctx.init.io,
        ctx.init.gpa,
        getConnectOptions(ctx),
        .{ .id = 1, .token = token, .method = Method.whoami },
    );
    defer resp.deinit();
    printJson(resp.value);
}

fn cmdState(ctxp: *anyopaque) anyerror!void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctxp));
    const token = (try loadToken(ctx, ctx.init.gpa)) orelse return error.NotLoggedIn;
    defer ctx.init.gpa.free(token);

    const resp = try protocol.request(
        ctx.init.io,
        ctx.init.gpa,
        getConnectOptions(ctx),
        .{ .id = 1, .token = token, .method = Method.state },
    );
    defer resp.deinit();
    printJson(resp.value);
}
