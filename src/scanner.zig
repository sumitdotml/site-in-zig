const std = @import("std");
const frontmatter = @import("frontmatter.zig");

pub const ContentFile = struct {
    path: []const u8,
    relative_path: []const u8,
    slug: []const u8,
    content_type: ContentType,
    frontmatter: frontmatter.Frontmatter,
    raw_content: []const u8,

    pub fn deinit(self: *ContentFile, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.relative_path);
        allocator.free(self.slug);
        allocator.free(self.raw_content);
        self.frontmatter.deinit(allocator);
    }
};

pub const ContentType = enum {
    blog,
    page,
};

pub const Scanner = struct {
    allocator: std.mem.Allocator,
    content_dir: []const u8,
    files: std.ArrayList(ContentFile),

    pub fn init(allocator: std.mem.Allocator, content_dir: []const u8) Scanner {
        return .{
            .allocator = allocator,
            .content_dir = content_dir,
            .files = .{},
        };
    }

    pub fn deinit(self: *Scanner) void {
        for (self.files.items) |*file| {
            file.deinit(self.allocator);
        }
        self.files.deinit(self.allocator);
    }

    pub fn scan(self: *Scanner) !void {
        const blog_dir = try std.fs.path.join(self.allocator, &.{ self.content_dir, "blog" });
        defer self.allocator.free(blog_dir);
        try self.scanDirectory(blog_dir, .blog);

        const pages_dir = try std.fs.path.join(self.allocator, &.{ self.content_dir, "pages" });
        defer self.allocator.free(pages_dir);
        try self.scanDirectory(pages_dir, .page);

        // Sort blog posts by date, newest first
        std.mem.sort(ContentFile, self.files.items, {}, struct {
            fn lessThan(_: void, a: ContentFile, b: ContentFile) bool {
                if (a.content_type == .blog and b.content_type == .blog) {
                    const a_date = a.frontmatter.pub_date orelse "";
                    const b_date = b.frontmatter.pub_date orelse "";
                    return std.mem.order(u8, a_date, b_date) == .gt;
                }
                return false;
            }
        }.lessThan);
    }

    fn scanDirectory(self: *Scanner, dir_path: []const u8, content_type: ContentType) !void {
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) {
                std.debug.print("Warning: Directory not found: {s}\n", .{dir_path});
                return;
            }
            return err;
        };
        defer dir.close();

        var walker = dir.iterate();
        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;

            const name = entry.name;
            if (!std.mem.endsWith(u8, name, ".md")) continue;

            const full_path = try std.fs.path.join(self.allocator, &.{ dir_path, name });
            errdefer self.allocator.free(full_path);

            const type_prefix = if (content_type == .blog) "blog" else "pages";
            const relative_path = try std.fs.path.join(self.allocator, &.{ type_prefix, name });
            errdefer self.allocator.free(relative_path);

            const slug = try self.allocator.dupe(u8, name[0 .. name.len - 3]);
            errdefer self.allocator.free(slug);

            const file = try std.fs.cwd().openFile(full_path, .{});
            defer file.close();
            const raw_content = try file.readToEndAlloc(self.allocator, 1024 * 1024);
            errdefer self.allocator.free(raw_content);

            const fm = try frontmatter.parse(self.allocator, raw_content);

            try self.files.append(self.allocator, .{
                .path = full_path,
                .relative_path = relative_path,
                .slug = slug,
                .content_type = content_type,
                .frontmatter = fm.frontmatter,
                .raw_content = raw_content,
            });

            std.debug.print("  Found: {s} ({s})\n", .{ relative_path, fm.frontmatter.title orelse "untitled" });
        }
    }
};

test "scanner basic" {
    const allocator = std.testing.allocator;
    var s = Scanner.init(allocator, "content");
    defer s.deinit();
}
