const std = @import("std");

pub const Context = struct {
    allocator: std.mem.Allocator,
    values: std.StringHashMap(Value),
    partials: std.StringHashMap([]const u8),

    pub const Value = union(enum) {
        string: []const u8,
        boolean: bool,
        list: []const Context,
    };

    pub fn init(allocator: std.mem.Allocator) Context {
        return .{
            .allocator = allocator,
            .values = std.StringHashMap(Value).init(allocator),
            .partials = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Context) void {
        self.values.deinit();
        self.partials.deinit();
    }

    pub fn set(self: *Context, key: []const u8, value: Value) !void {
        try self.values.put(key, value);
    }

    pub fn setString(self: *Context, key: []const u8, value: []const u8) !void {
        try self.values.put(key, .{ .string = value });
    }

    pub fn setBool(self: *Context, key: []const u8, value: bool) !void {
        try self.values.put(key, .{ .boolean = value });
    }

    pub fn setList(self: *Context, key: []const u8, value: []const Context) !void {
        try self.values.put(key, .{ .list = value });
    }

    pub fn setPartial(self: *Context, name: []const u8, content: []const u8) !void {
        try self.partials.put(name, content);
    }

    pub fn get(self: *const Context, key: []const u8) ?Value {
        return self.values.get(key);
    }

    pub fn getString(self: *const Context, key: []const u8) ?[]const u8 {
        if (self.values.get(key)) |val| {
            return switch (val) {
                .string => |s| s,
                else => null,
            };
        }
        return null;
    }

    pub fn getBool(self: *const Context, key: []const u8) bool {
        if (self.values.get(key)) |val| {
            return switch (val) {
                .boolean => |b| b,
                .string => |s| s.len > 0,
                else => true,
            };
        }
        return false;
    }

    pub fn getList(self: *const Context, key: []const u8) ?[]const Context {
        if (self.values.get(key)) |val| {
            return switch (val) {
                .list => |l| l,
                else => null,
            };
        }
        return null;
    }
};

pub fn renderTemplate(allocator: std.mem.Allocator, template_str: []const u8, context: *const Context) ![]const u8 {
    var result: std.ArrayList(u8) = .{};
    defer result.deinit(allocator);

    var i: usize = 0;
    while (i < template_str.len) {
        if (i + 1 < template_str.len and template_str[i] == '{' and template_str[i + 1] == '{') {
            var j = i + 2;

            // Triple braces {{{ for raw output
            const is_raw = j < template_str.len and template_str[j] == '{';
            if (is_raw) j += 1;

            const tag_start = j;

            while (j < template_str.len) {
                if (j + 1 < template_str.len and template_str[j] == '}' and template_str[j + 1] == '}') break;
                j += 1;
            }

            if (j < template_str.len) {
                const tag_end = j;
                const tag = std.mem.trim(u8, template_str[tag_start..tag_end], " \t");

                if (std.mem.startsWith(u8, tag, "#if ")) {
                    const var_name = std.mem.trim(u8, tag[4..], " \t");
                    const end_tag = "{{/if}}";

                    if (std.mem.indexOf(u8, template_str[j + 2 ..], end_tag)) |end_pos| {
                        const inner = template_str[j + 2 .. j + 2 + end_pos];
                        if (context.getBool(var_name)) {
                            const rendered = try renderTemplate(allocator, inner, context);
                            defer allocator.free(rendered);
                            try result.appendSlice(allocator, rendered);
                        }
                        i = j + 2 + end_pos + end_tag.len;
                        continue;
                    }
                } else if (std.mem.startsWith(u8, tag, "#each ")) {
                    const var_name = std.mem.trim(u8, tag[6..], " \t");
                    const end_tag = "{{/each}}";

                    if (std.mem.indexOf(u8, template_str[j + 2 ..], end_tag)) |end_pos| {
                        const inner = template_str[j + 2 .. j + 2 + end_pos];
                        if (context.getList(var_name)) |items| {
                            for (items) |item| {
                                const rendered = try renderTemplate(allocator, inner, &item);
                                defer allocator.free(rendered);
                                try result.appendSlice(allocator, rendered);
                            }
                        }
                        i = j + 2 + end_pos + end_tag.len;
                        continue;
                    }
                } else if (std.mem.startsWith(u8, tag, "> ")) {
                    const partial_name = std.mem.trim(u8, tag[2..], " \t");
                    if (context.partials.get(partial_name)) |partial_content| {
                        const rendered = try renderTemplate(allocator, partial_content, context);
                        defer allocator.free(rendered);
                        try result.appendSlice(allocator, rendered);
                    }
                    i = j + 2;
                    if (is_raw and i < template_str.len and template_str[i] == '}') i += 1;
                    continue;
                } else if (!std.mem.startsWith(u8, tag, "/") and !std.mem.startsWith(u8, tag, "#")) {
                    if (context.getString(tag)) |value| {
                        if (is_raw) {
                            try result.appendSlice(allocator, value);
                        } else {
                            const escaped = try escapeHtml(allocator, value);
                            defer allocator.free(escaped);
                            try result.appendSlice(allocator, escaped);
                        }
                    }
                    i = j + 2;
                    if (is_raw and i < template_str.len and template_str[i] == '}') i += 1;
                    continue;
                }

                i = j + 2;
                if (is_raw and i < template_str.len and template_str[i] == '}') i += 1;
                continue;
            }
        }

        try result.append(allocator, template_str[i]);
        i += 1;
    }

    return result.toOwnedSlice(allocator);
}

fn escapeHtml(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .{};
    defer result.deinit(allocator);

    for (text) |c| {
        switch (c) {
            '<' => try result.appendSlice(allocator, "&lt;"),
            '>' => try result.appendSlice(allocator, "&gt;"),
            '&' => try result.appendSlice(allocator, "&amp;"),
            '"' => try result.appendSlice(allocator, "&quot;"),
            '\'' => try result.appendSlice(allocator, "&#x27;"),
            else => try result.append(allocator, c),
        }
    }

    return result.toOwnedSlice(allocator);
}

pub fn loadTemplate(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, 1024 * 1024);
}

pub fn loadTemplates(allocator: std.mem.Allocator, template_dir: []const u8) !std.StringHashMap([]const u8) {
    var templates = std.StringHashMap([]const u8).init(allocator);
    errdefer templates.deinit();

    var dir = std.fs.cwd().openDir(template_dir, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("Warning: Template directory not found: {s}\n", .{template_dir});
            return templates;
        }
        return err;
    };
    defer dir.close();

    var walker = dir.iterate();
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".html")) continue;

        const full_path = try std.fs.path.join(allocator, &.{ template_dir, entry.name });
        defer allocator.free(full_path);

        const content = try loadTemplate(allocator, full_path);
        const name = try allocator.dupe(u8, entry.name[0 .. entry.name.len - 5]);
        try templates.put(name, content);
    }

    const partials_dir = try std.fs.path.join(allocator, &.{ template_dir, "partials" });
    defer allocator.free(partials_dir);

    var partials = std.fs.cwd().openDir(partials_dir, .{ .iterate = true }) catch {
        return templates;
    };
    defer partials.close();

    var partials_walker = partials.iterate();
    while (try partials_walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".html")) continue;

        const full_path = try std.fs.path.join(allocator, &.{ partials_dir, entry.name });
        defer allocator.free(full_path);

        const content = try loadTemplate(allocator, full_path);
        const name = try allocator.dupe(u8, entry.name[0 .. entry.name.len - 5]);
        try templates.put(name, content);
    }

    return templates;
}

test "render simple variable" {
    const allocator = std.testing.allocator;

    var ctx = Context.init(allocator);
    defer ctx.deinit();
    try ctx.setString("name", "World");

    const out = try renderTemplate(allocator, "Hello, {{name}}!", &ctx);
    defer allocator.free(out);

    try std.testing.expectEqualStrings("Hello, World!", out);
}

test "render conditional" {
    const allocator = std.testing.allocator;

    var ctx = Context.init(allocator);
    defer ctx.deinit();
    try ctx.setBool("show", true);

    const out = try renderTemplate(allocator, "{{#if show}}Visible{{/if}}", &ctx);
    defer allocator.free(out);

    try std.testing.expectEqualStrings("Visible", out);
}
