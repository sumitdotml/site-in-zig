const std = @import("std");

pub const Footnote = struct {
    id: []const u8,
    content: []const u8,
};

pub const FootnoteResult = struct {
    html: []const u8,
    footnotes: []Footnote,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *FootnoteResult) void {
        self.allocator.free(self.html);
        for (self.footnotes) |note| {
            self.allocator.free(note.id);
            self.allocator.free(note.content);
        }
        self.allocator.free(self.footnotes);
    }
};

pub fn process(allocator: std.mem.Allocator, content: []const u8) !FootnoteResult {
    var footnote_list: std.ArrayList(Footnote) = .{};
    defer footnote_list.deinit(allocator);

    const remaining_content = try collectDefinitions(allocator, content, &footnote_list);
    defer allocator.free(remaining_content);

    const html = try processReferences(allocator, remaining_content);
    errdefer allocator.free(html);

    return .{
        .html = html,
        .footnotes = try allocator.dupe(Footnote, footnote_list.items),
        .allocator = allocator,
    };
}

pub fn processReferences(allocator: std.mem.Allocator, content: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .{};
    defer result.deinit(allocator);

    var i: usize = 0;
    while (i < content.len) {
        if (i + 2 < content.len and content[i] == '[' and content[i + 1] == '^') {
            var j = i + 2;
            while (j < content.len and content[j] != ']' and content[j] != '\n') : (j += 1) {}

            if (j < content.len and content[j] == ']') {
                const id = content[i + 2 .. j];

                // Definition - skip (processed separately)
                if (j + 1 < content.len and content[j + 1] == ':') {
                    try result.appendSlice(allocator, content[i .. j + 1]);
                    i = j + 1;
                    continue;
                }

                // Reference - convert to HTML
                try result.appendSlice(allocator, "<sup class=\"footnote-ref\"><a href=\"#fn-");
                try result.appendSlice(allocator, id);
                try result.appendSlice(allocator, "\" id=\"fnref-");
                try result.appendSlice(allocator, id);
                try result.appendSlice(allocator, "\">[");
                try result.appendSlice(allocator, id);
                try result.appendSlice(allocator, "]</a></sup>");
                i = j + 1;
                continue;
            }
        }

        try result.append(allocator, content[i]);
        i += 1;
    }

    return result.toOwnedSlice(allocator);
}

fn collectDefinitions(allocator: std.mem.Allocator, content: []const u8, footnotes: *std.ArrayList(Footnote)) ![]const u8 {
    var result: std.ArrayList(u8) = .{};
    defer result.deinit(allocator);

    var lines = std.mem.splitSequence(u8, content, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        if (std.mem.startsWith(u8, trimmed, "[^")) {
            if (std.mem.indexOf(u8, trimmed, "]:")) |colon_pos| {
                const id_end = std.mem.indexOf(u8, trimmed[2..], "]") orelse continue;
                const id = trimmed[2 .. 2 + id_end];
                const def_content = std.mem.trim(u8, trimmed[colon_pos + 2 ..], " \t");

                try footnotes.append(allocator, .{
                    .id = try allocator.dupe(u8, id),
                    .content = try allocator.dupe(u8, def_content),
                });
                continue;
            }
        }

        try result.appendSlice(allocator, line);
        try result.append(allocator, '\n');
    }

    return result.toOwnedSlice(allocator);
}

pub fn generateFootnotesSection(allocator: std.mem.Allocator, footnotes_list: []const Footnote) ![]const u8 {
    if (footnotes_list.len == 0) return try allocator.dupe(u8, "");

    var result: std.ArrayList(u8) = .{};
    defer result.deinit(allocator);

    try result.appendSlice(allocator, "<section class=\"footnotes-section\">\n");
    try result.appendSlice(allocator, "<hr>\n");
    try result.appendSlice(allocator, "<h4>Footnotes</h4>\n");
    try result.appendSlice(allocator, "<ol class=\"footnotes-list\">\n");

    for (footnotes_list) |note| {
        try result.appendSlice(allocator, "<li id=\"fn-");
        try result.appendSlice(allocator, note.id);
        try result.appendSlice(allocator, "\" class=\"footnote-item\">\n");
        try result.appendSlice(allocator, "<span class=\"footnote-number\">");
        try result.appendSlice(allocator, note.id);
        try result.appendSlice(allocator, ".</span> ");
        try result.appendSlice(allocator, note.content);
        try result.appendSlice(allocator, " <a href=\"#fnref-");
        try result.appendSlice(allocator, note.id);
        try result.appendSlice(allocator, "\" class=\"footnote-backref\">&hookleftarrow;</a>\n");
        try result.appendSlice(allocator, "</li>\n");
    }

    try result.appendSlice(allocator, "</ol>\n");
    try result.appendSlice(allocator, "</section>\n");

    return result.toOwnedSlice(allocator);
}

test "process footnote references" {
    const allocator = std.testing.allocator;

    const content = "Hello[^1] world[^2].\n[^1]: First note\n[^2]: Second note";
    var result = try process(allocator, content);
    defer result.deinit();

    try std.testing.expect(std.mem.indexOf(u8, result.html, "fnref-1") != null);
    try std.testing.expectEqual(@as(usize, 2), result.footnotes.len);
}
