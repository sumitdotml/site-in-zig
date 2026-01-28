const std = @import("std");
const scanner = @import("scanner.zig");
const frontmatter = @import("frontmatter.zig");
const markdown = @import("markdown.zig");
const footnotes = @import("footnotes.zig");
const template = @import("template.zig");
const assets = @import("assets.zig");
const site = @import("site.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Parse command line arguments
    var content_dir: []const u8 = "content";
    var output_dir: []const u8 = "dist";
    var template_dir: []const u8 = "templates";
    var static_dir: []const u8 = "static";

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--content") and i + 1 < args.len) {
            content_dir = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--output") and i + 1 < args.len) {
            output_dir = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--templates") and i + 1 < args.len) {
            template_dir = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--static") and i + 1 < args.len) {
            static_dir = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
            printHelp();
            return;
        }
    }

    std.debug.print("Zig Static Site Generator\n", .{});
    std.debug.print("=========================\n\n", .{});
    std.debug.print("Content directory: {s}\n", .{content_dir});
    std.debug.print("Output directory: {s}\n", .{output_dir});
    std.debug.print("Template directory: {s}\n", .{template_dir});
    std.debug.print("Static directory: {s}\n\n", .{static_dir});

    // Build the site
    try site.build(allocator, .{
        .content_dir = content_dir,
        .output_dir = output_dir,
        .template_dir = template_dir,
        .static_dir = static_dir,
    });

    std.debug.print("\nSite generated successfully!\n", .{});
}

fn printHelp() void {
    std.debug.print(
        \\Zig Static Site Generator
        \\
        \\Usage: zig-ssg [options]
        \\
        \\Options:
        \\  --content <dir>    Content directory (default: content)
        \\  --output <dir>     Output directory (default: dist)
        \\  --templates <dir>  Template directory (default: templates)
        \\  --static <dir>     Static files directory (default: static)
        \\  --help, -h         Show this help message
        \\
    , .{});
}

test "main imports" {
    _ = scanner;
    _ = frontmatter;
    _ = markdown;
    _ = footnotes;
    _ = template;
    _ = assets;
    _ = site;
}
