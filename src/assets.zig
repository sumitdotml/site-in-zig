const std = @import("std");

/// Copy all files from source directory to destination directory
pub fn copyDirectory(allocator: std.mem.Allocator, src_dir: []const u8, dest_dir: []const u8) !void {
    var source = std.fs.cwd().openDir(src_dir, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("Warning: Source directory not found: {s}\n", .{src_dir});
            return;
        }
        return err;
    };
    defer source.close();

    // Create destination directory if it doesn't exist
    std.fs.cwd().makePath(dest_dir) catch {};

    var walker = source.walk(allocator) catch return;
    defer walker.deinit();

    while (try walker.next()) |entry| {
        const relative_path = entry.path;
        const dest_path = try std.fs.path.join(allocator, &.{ dest_dir, relative_path });
        defer allocator.free(dest_path);

        switch (entry.kind) {
            .directory => {
                std.fs.cwd().makePath(dest_path) catch {};
            },
            .file => {
                const src_path = try std.fs.path.join(allocator, &.{ src_dir, relative_path });
                defer allocator.free(src_path);

                try copyFile(src_path, dest_path);
            },
            else => {},
        }
    }
}

/// Copy a single file
pub fn copyFile(src_path: []const u8, dest_path: []const u8) !void {
    // Ensure destination directory exists
    if (std.fs.path.dirname(dest_path)) |dir| {
        std.fs.cwd().makePath(dir) catch {};
    }

    // Open source file
    const src_file = try std.fs.cwd().openFile(src_path, .{});
    defer src_file.close();

    // Create destination file
    const dest_file = std.fs.cwd().createFile(dest_path, .{}) catch |err| {
        std.debug.print("Error creating file {s}: {}\n", .{ dest_path, err });
        return err;
    };
    defer dest_file.close();

    // Copy content
    var buf: [8192]u8 = undefined;
    while (true) {
        const bytes_read = try src_file.read(&buf);
        if (bytes_read == 0) break;
        _ = try dest_file.write(buf[0..bytes_read]);
    }
}

/// Process image references in markdown/HTML content and copy images
pub fn processImages(allocator: std.mem.Allocator, content: []const u8, content_dir: []const u8, output_dir: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .{};
    defer result.deinit(allocator);

    var i: usize = 0;
    while (i < content.len) {
        // Look for image markdown: ![alt](path)
        if (i + 1 < content.len and content[i] == '!' and content[i + 1] == '[') {
            if (std.mem.indexOf(u8, content[i..], "](")) |bracket_end| {
                if (std.mem.indexOf(u8, content[i + bracket_end + 2 ..], ")")) |paren_end| {
                    const img_src = content[i + bracket_end + 2 .. i + bracket_end + 2 + paren_end];

                    // Check if it's a local image (not http/https)
                    if (!std.mem.startsWith(u8, img_src, "http://") and !std.mem.startsWith(u8, img_src, "https://")) {
                        // Convert relative path to absolute and copy
                        const new_path = try processImagePath(allocator, img_src, content_dir, output_dir);
                        defer allocator.free(new_path);

                        // Write the modified image reference
                        try result.appendSlice(allocator, content[i .. i + bracket_end + 2]);
                        try result.appendSlice(allocator, new_path);
                        try result.append(allocator, ')');
                        i += bracket_end + 3 + paren_end;
                        continue;
                    }
                }
            }
        }

        // Look for HTML img tags: src="path"
        if (std.mem.startsWith(u8, content[i..], "src=\"")) {
            const src_start = i + 5;
            if (std.mem.indexOf(u8, content[src_start..], "\"")) |end| {
                const img_src = content[src_start .. src_start + end];

                if (!std.mem.startsWith(u8, img_src, "http://") and !std.mem.startsWith(u8, img_src, "https://")) {
                    const new_path = try processImagePath(allocator, img_src, content_dir, output_dir);
                    defer allocator.free(new_path);

                    try result.appendSlice(allocator, "src=\"");
                    try result.appendSlice(allocator, new_path);
                    try result.append(allocator, '"');
                    i = src_start + end + 1;
                    continue;
                }
            }
        }

        try result.append(allocator, content[i]);
        i += 1;
    }

    return result.toOwnedSlice(allocator);
}

fn processImagePath(allocator: std.mem.Allocator, img_src: []const u8, content_dir: []const u8, output_dir: []const u8) ![]const u8 {
    // Handle relative paths like ../../assets/image.png
    var normalized = img_src;

    // Remove leading ../ components and resolve relative to content_dir
    while (std.mem.startsWith(u8, normalized, "../")) {
        normalized = normalized[3..];
    }

    // Get just the filename for the output
    const filename = std.fs.path.basename(normalized);

    // Create assets directory in output
    const assets_dest = try std.fs.path.join(allocator, &.{ output_dir, "assets" });
    defer allocator.free(assets_dest);
    std.fs.cwd().makePath(assets_dest) catch {};

    // Try to find and copy the source image
    // Look in common locations relative to content_dir
    const possible_sources = [_][]const u8{
        try std.fs.path.join(allocator, &.{ std.fs.path.dirname(content_dir) orelse ".", normalized }),
        try std.fs.path.join(allocator, &.{ content_dir, "..", normalized }),
        try std.fs.path.join(allocator, &.{ content_dir, "..", "assets", filename }),
    };
    defer {
        for (possible_sources) |src| allocator.free(src);
    }

    const dest_path = try std.fs.path.join(allocator, &.{ assets_dest, filename });
    defer allocator.free(dest_path);

    for (possible_sources) |src| {
        copyFile(src, dest_path) catch continue;
        break;
    }

    // Return the new path for the HTML
    return std.fmt.allocPrint(allocator, "/assets/{s}", .{filename});
}

/// Ensure output directory exists and is empty
pub fn prepareOutputDir(output_dir: []const u8) !void {
    // Try to delete existing directory
    std.fs.cwd().deleteTree(output_dir) catch {};

    // Create fresh directory
    try std.fs.cwd().makePath(output_dir);
}

/// Write content to a file in the output directory
pub fn writeOutput(allocator: std.mem.Allocator, output_dir: []const u8, path: []const u8, content: []const u8) !void {
    const full_path = try std.fs.path.join(allocator, &.{ output_dir, path });
    defer allocator.free(full_path);

    // Ensure parent directory exists
    if (std.fs.path.dirname(full_path)) |dir| {
        std.fs.cwd().makePath(dir) catch {};
    }

    const file = try std.fs.cwd().createFile(full_path, .{});
    defer file.close();

    try file.writeAll(content);
}

test "copy file" {
    // This test would require a temp directory setup
}
