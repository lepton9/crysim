const std = @import("std");

const DATA_DIR = ".local/share/crysim";

pub fn dataDir(
    io: std.Io,
    gpa: std.mem.Allocator,
    env: *std.process.Environ.Map,
    sub_dir: []const u8,
) !?[]u8 {
    if (env.get("HOME")) |home| {
        var home_dir = try std.Io.Dir.openDirAbsolute(io, home, .{});
        defer home_dir.close(io);

        const rel = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ DATA_DIR, sub_dir });
        defer gpa.free(rel);
        try home_dir.createDirPath(io, rel);

        return try std.Io.Dir.path.join(gpa, &.{ home, DATA_DIR, sub_dir });
    }

    return null;
}

/// Returns an absolute data file path under the given subdir, creating parent dir if needed.
pub fn dataFilePath(
    io: std.Io,
    gpa: std.mem.Allocator,
    env: *std.process.Environ.Map,
    dir_path: []const u8,
    file_name: []const u8,
) !?[]u8 {
    const dir = (try dataDir(io, gpa, env, dir_path)) orelse return null;
    defer gpa.free(dir);
    return try std.Io.Dir.path.join(gpa, &.{ dir, file_name });
}
