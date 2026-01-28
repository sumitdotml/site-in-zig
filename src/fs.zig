const std = @import("std");

pub fn copyDirectory(allocator: std.mem.Allocator, src_dir: []const u8, dest_dir: []const u8) !void {
    var source = std.fs.cwd().openDir(src_dir, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("Warning: Source directory not found: {s}\n", .{src_dir});
            return;
        }
        return err;
    };
    defer source.close();

    std.fs.cwd().makePath(dest_dir) catch {};

    var walker = source.walk(allocator) catch return;
    defer walker.deinit();

    while (try walker.next()) |entry| {
        const relative_path = entry.path;
        const dest_path = try std.fs.path.join(allocator, &.{ dest_dir, relative_path });
        defer allocator.free(dest_path);

        switch (entry.kind) {
            .directory => std.fs.cwd().makePath(dest_path) catch {},
            .file => {
                const src_path = try std.fs.path.join(allocator, &.{ src_dir, relative_path });
                defer allocator.free(src_path);
                try copyFile(src_path, dest_path);
            },
            else => {},
        }
    }
}

pub fn copyFile(src_path: []const u8, dest_path: []const u8) !void {
    if (std.fs.path.dirname(dest_path)) |dir| {
        std.fs.cwd().makePath(dir) catch {};
    }

    const src_file = try std.fs.cwd().openFile(src_path, .{});
    defer src_file.close();

    const dest_file = std.fs.cwd().createFile(dest_path, .{}) catch |err| {
        std.debug.print("Error creating file {s}: {}\n", .{ dest_path, err });
        return err;
    };
    defer dest_file.close();

    var buf: [8192]u8 = undefined;
    while (true) {
        const bytes_read = try src_file.read(&buf);
        if (bytes_read == 0) break;
        _ = try dest_file.write(buf[0..bytes_read]);
    }
}

pub fn prepareOutputDir(output_dir: []const u8) !void {
    std.fs.cwd().deleteTree(output_dir) catch {};
    try std.fs.cwd().makePath(output_dir);
}

pub fn writeOutput(allocator: std.mem.Allocator, output_dir: []const u8, path: []const u8, content: []const u8) !void {
    const full_path = try std.fs.path.join(allocator, &.{ output_dir, path });
    defer allocator.free(full_path);

    if (std.fs.path.dirname(full_path)) |dir| {
        std.fs.cwd().makePath(dir) catch {};
    }

    const file = try std.fs.cwd().createFile(full_path, .{});
    defer file.close();
    try file.writeAll(content);
}
