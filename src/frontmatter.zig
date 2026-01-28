const std = @import("std");

pub const Frontmatter = struct {
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    pub_date: ?[]const u8 = null,
    updated_date: ?[]const u8 = null,
    date_label: ?[]const u8 = null,
    breadcrumb_title: ?[]const u8 = null,
    image: ?[]const u8 = null,
    draft: bool = false,

    // Store raw key-value pairs for custom fields
    custom: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) Frontmatter {
        return .{
            .custom = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Frontmatter, allocator: std.mem.Allocator) void {
        if (self.title) |t| allocator.free(t);
        if (self.description) |d| allocator.free(d);
        if (self.pub_date) |p| allocator.free(p);
        if (self.updated_date) |u| allocator.free(u);
        if (self.date_label) |l| allocator.free(l);
        if (self.breadcrumb_title) |b| allocator.free(b);
        if (self.image) |i| allocator.free(i);

        var iter = self.custom.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.custom.deinit();
    }
};

pub const ParseResult = struct {
    frontmatter: Frontmatter,
    body_start: usize,
};

/// Parse TOML-like frontmatter from markdown content
/// Format:
/// ---
/// title = "My Title"
/// description = "My Description"
/// pubDate = 2025-10-30
/// ---
pub fn parse(allocator: std.mem.Allocator, content: []const u8) !ParseResult {
    var fm = Frontmatter.init(allocator);
    errdefer fm.deinit(allocator);

    // Check for frontmatter delimiter
    if (!std.mem.startsWith(u8, content, "---")) {
        return .{
            .frontmatter = fm,
            .body_start = 0,
        };
    }

    // Find the ending delimiter
    const start = 3; // Skip first "---"
    var end: usize = start;

    // Skip whitespace/newline after opening ---
    while (end < content.len and (content[end] == '\n' or content[end] == '\r')) {
        end += 1;
    }

    const body_search_start = end;

    // Find closing ---
    if (std.mem.indexOf(u8, content[body_search_start..], "\n---")) |close_pos| {
        end = body_search_start + close_pos;
    } else {
        // No closing delimiter found
        return .{
            .frontmatter = fm,
            .body_start = 0,
        };
    }

    const frontmatter_text = content[body_search_start..end];

    // Parse each line
    var lines = std.mem.splitSequence(u8, frontmatter_text, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        // Parse key = value or key: value
        if (parseKeyValue(trimmed)) |kv| {
            const key = kv.key;
            const value = try allocator.dupe(u8, kv.value);
            errdefer allocator.free(value);

            if (std.mem.eql(u8, key, "title")) {
                fm.title = value;
            } else if (std.mem.eql(u8, key, "description")) {
                fm.description = value;
            } else if (std.mem.eql(u8, key, "pubDate") or std.mem.eql(u8, key, "date")) {
                fm.pub_date = value;
            } else if (std.mem.eql(u8, key, "updatedDate")) {
                fm.updated_date = value;
            } else if (std.mem.eql(u8, key, "breadcrumbTitle")) {
                fm.breadcrumb_title = value;
            } else if (std.mem.eql(u8, key, "image")) {
                fm.image = value;
            } else if (std.mem.eql(u8, key, "draft")) {
                fm.draft = std.mem.eql(u8, value, "true");
                allocator.free(value);
            } else if (std.mem.startsWith(u8, key, "dateLabels.")) {
                // Handle nested dateLabels
                if (std.mem.eql(u8, key, "dateLabels.published") or std.mem.eql(u8, key, "dateLabels.page")) {
                    fm.date_label = value;
                } else {
                    allocator.free(value);
                }
            } else {
                // Store as custom field
                const key_copy = try allocator.dupe(u8, key);
                try fm.custom.put(key_copy, value);
            }
        }
    }

    // Find where the body starts (after closing --- and newline)
    var body_start = end + 4; // Skip "\n---"
    while (body_start < content.len and (content[body_start] == '\n' or content[body_start] == '\r')) {
        body_start += 1;
    }

    return .{
        .frontmatter = fm,
        .body_start = body_start,
    };
}

const KeyValue = struct {
    key: []const u8,
    value: []const u8,
};

fn parseKeyValue(line: []const u8) ?KeyValue {
    // Try TOML-style: key = "value" or key = value
    if (std.mem.indexOf(u8, line, " = ")) |eq_pos| {
        const key = std.mem.trim(u8, line[0..eq_pos], " \t");
        var value = std.mem.trim(u8, line[eq_pos + 3 ..], " \t");

        // Remove quotes if present
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
            value = value[1 .. value.len - 1];
        }

        return .{ .key = key, .value = value };
    }

    // Try YAML-style: key: value (for backwards compat during migration)
    if (std.mem.indexOf(u8, line, ": ")) |colon_pos| {
        const key = std.mem.trim(u8, line[0..colon_pos], " \t");
        var value = std.mem.trim(u8, line[colon_pos + 2 ..], " \t");

        // Remove quotes if present
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
            value = value[1 .. value.len - 1];
        }

        return .{ .key = key, .value = value };
    }

    // Try: key=value (no spaces)
    if (std.mem.indexOf(u8, line, "=")) |eq_pos| {
        const key = std.mem.trim(u8, line[0..eq_pos], " \t");
        var value = std.mem.trim(u8, line[eq_pos + 1 ..], " \t");

        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
            value = value[1 .. value.len - 1];
        }

        return .{ .key = key, .value = value };
    }

    return null;
}

/// Get the body content (everything after frontmatter)
pub fn getBody(content: []const u8, body_start: usize) []const u8 {
    if (body_start >= content.len) return "";
    return content[body_start..];
}

test "parse frontmatter" {
    const allocator = std.testing.allocator;

    const content =
        \\---
        \\title = "Test Post"
        \\description = "A test description"
        \\pubDate = 2025-10-30
        \\---
        \\
        \\This is the body content.
    ;

    var result = try parse(allocator, content);
    defer result.frontmatter.deinit(allocator);

    try std.testing.expectEqualStrings("Test Post", result.frontmatter.title.?);
    try std.testing.expectEqualStrings("A test description", result.frontmatter.description.?);
    try std.testing.expectEqualStrings("2025-10-30", result.frontmatter.pub_date.?);

    const body = getBody(content, result.body_start);
    try std.testing.expect(std.mem.indexOf(u8, body, "This is the body content.") != null);
}

test "parse yaml-style frontmatter" {
    const allocator = std.testing.allocator;

    const content =
        \\---
        \\title: "Test Post"
        \\description: A test description
        \\---
        \\
        \\Body here.
    ;

    var result = try parse(allocator, content);
    defer result.frontmatter.deinit(allocator);

    try std.testing.expectEqualStrings("Test Post", result.frontmatter.title.?);
    try std.testing.expectEqualStrings("A test description", result.frontmatter.description.?);
}
