const std = @import("std");
const zcli = @import("zcli");
const options = @import("build_options");

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
        .{ .long_name = "version", .short_name = "v", .desc = "Print version" },
        .{ .long_name = "help", .short_name = "h", .desc = "Print help" },
    },
    .positionals = &[_]zcli.PosArg{},
};

const commands = &[_]zcli.Cmd{};

const Ctx = struct {
    init: std.process.Init,
};

pub fn handleCli(init: std.process.Init) !void {
    const gpa = init.gpa;
    const cli = try zcli.parseInit(init, &spec);
    defer cli.deinit(gpa);
    var ctx: Ctx = .{.init = init};
    if (cli.cmd) |c| {
        const f = c.exec orelse return;
        try f(&ctx);
    }
}

