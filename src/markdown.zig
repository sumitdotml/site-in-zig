const std = @import("std");
const footnotes = @import("footnotes.zig");

const MathBlock = struct {
    placeholder: []const u8,
    content: []const u8,
    is_display: bool,
};

pub const ProcessResult = struct {
    html: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ProcessResult) void {
        self.allocator.free(self.html);
    }
};

pub fn processSimple(allocator: std.mem.Allocator, content: []const u8) !ProcessResult {
    var math_list: std.ArrayList(MathBlock) = .{};
    defer {
        for (math_list.items) |block| {
            allocator.free(block.placeholder);
            allocator.free(block.content);
        }
        math_list.deinit(allocator);
    }

    const preprocessed = try extractMathBlocks(allocator, content, &math_list);
    defer allocator.free(preprocessed);

    const with_footnotes = try footnotes.processReferences(allocator, preprocessed);
    defer allocator.free(with_footnotes);

    var html = try simpleMarkdownToHtml(allocator, with_footnotes);
    errdefer allocator.free(html);

    html = try restoreMathBlocks(allocator, html, math_list.items);

    return .{ .html = html, .allocator = allocator };
}

fn extractMathBlocks(allocator: std.mem.Allocator, content: []const u8, math_list: *std.ArrayList(MathBlock)) ![]const u8 {
    var result: std.ArrayList(u8) = .{};
    defer result.deinit(allocator);

    var display_count: usize = 0;
    var inline_count: usize = 0;
    var i: usize = 0;

    while (i < content.len) {
        // Display math $$...$$
        if (i + 1 < content.len and content[i] == '$' and content[i + 1] == '$') {
            const start = i + 2;
            var end = start;

            while (end + 1 < content.len) {
                if (content[end] == '$' and content[end + 1] == '$') break;
                end += 1;
            }

            if (end + 1 < content.len) {
                const math_content = content[start..end];
                const placeholder = try std.fmt.allocPrint(allocator, "{{{{MATH_DISPLAY_{d}}}}}", .{display_count});

                try math_list.append(allocator, .{
                    .placeholder = placeholder,
                    .content = try allocator.dupe(u8, math_content),
                    .is_display = true,
                });

                try result.appendSlice(allocator, placeholder);
                display_count += 1;
                i = end + 2;
                continue;
            }
        }

        // Inline math $...$
        if (content[i] == '$' and (i == 0 or content[i - 1] != '$')) {
            if (i + 1 < content.len and content[i + 1] != '$') {
                const start = i + 1;
                var end = start;

                while (end < content.len) {
                    if (content[end] == '$') {
                        if (end + 1 >= content.len or content[end + 1] != '$') break;
                    }
                    end += 1;
                }

                if (end < content.len and content[end] == '$') {
                    const math_content = content[start..end];
                    if (math_content.len > 0 and std.mem.indexOf(u8, math_content, "\n") == null) {
                        const placeholder = try std.fmt.allocPrint(allocator, "{{{{MATH_INLINE_{d}}}}}", .{inline_count});

                        try math_list.append(allocator, .{
                            .placeholder = placeholder,
                            .content = try allocator.dupe(u8, math_content),
                            .is_display = false,
                        });

                        try result.appendSlice(allocator, placeholder);
                        inline_count += 1;
                        i = end + 1;
                        continue;
                    }
                }
            }
        }

        try result.append(allocator, content[i]);
        i += 1;
    }

    return result.toOwnedSlice(allocator);
}

fn restoreMathBlocks(allocator: std.mem.Allocator, html: []const u8, math_blocks: []const MathBlock) ![]const u8 {
    var result = try allocator.dupe(u8, html);

    for (math_blocks) |block| {
        const wrapper = if (block.is_display)
            try std.fmt.allocPrint(allocator, "<div class=\"katex-display\">$${s}$$</div>", .{block.content})
        else
            try std.fmt.allocPrint(allocator, "<span class=\"math-inline\">${s}$</span>", .{block.content});
        defer allocator.free(wrapper);

        if (std.mem.indexOf(u8, result, block.placeholder)) |pos| {
            const new_len = result.len - block.placeholder.len + wrapper.len;
            const new_result = try allocator.alloc(u8, new_len);

            @memcpy(new_result[0..pos], result[0..pos]);
            @memcpy(new_result[pos .. pos + wrapper.len], wrapper);
            @memcpy(new_result[pos + wrapper.len ..], result[pos + block.placeholder.len ..]);

            allocator.free(result);
            result = new_result;
        }
    }

    return result;
}

fn simpleMarkdownToHtml(allocator: std.mem.Allocator, content: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .{};
    defer result.deinit(allocator);

    var lines = std.mem.splitSequence(u8, content, "\n");
    var in_code_block = false;
    var code_lang: []const u8 = "";
    var in_paragraph = false;
    var in_list = false;
    var in_blockquote = false;

    while (lines.next()) |line| {
        const trimmed = std.mem.trimRight(u8, line, " \t\r");

        if (std.mem.startsWith(u8, trimmed, "```")) {
            if (in_code_block) {
                try result.appendSlice(allocator, "</code></pre></div>\n");
                in_code_block = false;
                code_lang = "";
            } else {
                if (in_paragraph) {
                    try result.appendSlice(allocator, "</p>\n");
                    in_paragraph = false;
                }
                code_lang = if (trimmed.len > 3) trimmed[3..] else "";
                try result.appendSlice(allocator, "<div class=\"code-block-wrapper\"><div class=\"code-block-header\"><span class=\"code-language\">");
                try result.appendSlice(allocator, if (code_lang.len > 0) code_lang else "text");
                try result.appendSlice(allocator, "</span></div><pre><code>");
                in_code_block = true;
            }
            continue;
        }

        if (in_code_block) {
            const escaped = try escapeHtml(allocator, trimmed);
            defer allocator.free(escaped);
            try result.appendSlice(allocator, escaped);
            try result.append(allocator, '\n');
            continue;
        }

        if (trimmed.len == 0) {
            if (in_paragraph) {
                try result.appendSlice(allocator, "</p>\n");
                in_paragraph = false;
            }
            if (in_list) {
                try result.appendSlice(allocator, "</ul>\n");
                in_list = false;
            }
            if (in_blockquote) {
                try result.appendSlice(allocator, "</blockquote>\n");
                in_blockquote = false;
            }
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "######")) {
            const processed = try processInline(allocator, std.mem.trimLeft(u8, trimmed[6..], " "));
            defer allocator.free(processed);
            try result.appendSlice(allocator, "<h6>");
            try result.appendSlice(allocator, processed);
            try result.appendSlice(allocator, "</h6>\n");
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "#####")) {
            const processed = try processInline(allocator, std.mem.trimLeft(u8, trimmed[5..], " "));
            defer allocator.free(processed);
            try result.appendSlice(allocator, "<h5>");
            try result.appendSlice(allocator, processed);
            try result.appendSlice(allocator, "</h5>\n");
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "####")) {
            const processed = try processInline(allocator, std.mem.trimLeft(u8, trimmed[4..], " "));
            defer allocator.free(processed);
            try result.appendSlice(allocator, "<h4>");
            try result.appendSlice(allocator, processed);
            try result.appendSlice(allocator, "</h4>\n");
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "###")) {
            const processed = try processInline(allocator, std.mem.trimLeft(u8, trimmed[3..], " "));
            defer allocator.free(processed);
            try result.appendSlice(allocator, "<h3>");
            try result.appendSlice(allocator, processed);
            try result.appendSlice(allocator, "</h3>\n");
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "##")) {
            const processed = try processInline(allocator, std.mem.trimLeft(u8, trimmed[2..], " "));
            defer allocator.free(processed);
            try result.appendSlice(allocator, "<h2>");
            try result.appendSlice(allocator, processed);
            try result.appendSlice(allocator, "</h2>\n");
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "#")) {
            const processed = try processInline(allocator, std.mem.trimLeft(u8, trimmed[1..], " "));
            defer allocator.free(processed);
            try result.appendSlice(allocator, "<h1>");
            try result.appendSlice(allocator, processed);
            try result.appendSlice(allocator, "</h1>\n");
            continue;
        }

        if (std.mem.eql(u8, trimmed, "---") or std.mem.eql(u8, trimmed, "***") or std.mem.eql(u8, trimmed, "___")) {
            try result.appendSlice(allocator, "<hr>\n");
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "> ")) {
            if (!in_blockquote) {
                try result.appendSlice(allocator, "<blockquote>\n");
                in_blockquote = true;
            }
            const processed = try processInline(allocator, trimmed[2..]);
            defer allocator.free(processed);
            try result.appendSlice(allocator, "<p>");
            try result.appendSlice(allocator, processed);
            try result.appendSlice(allocator, "</p>\n");
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "- ") or std.mem.startsWith(u8, trimmed, "* ")) {
            if (!in_list) {
                try result.appendSlice(allocator, "<ul>\n");
                in_list = true;
            }
            const processed = try processInline(allocator, trimmed[2..]);
            defer allocator.free(processed);
            try result.appendSlice(allocator, "<li>");
            try result.appendSlice(allocator, processed);
            try result.appendSlice(allocator, "</li>\n");
            continue;
        }

        if (trimmed.len > 2 and trimmed[0] >= '0' and trimmed[0] <= '9') {
            if (std.mem.indexOf(u8, trimmed, ". ")) |dot_pos| {
                if (dot_pos > 0 and dot_pos < 4) {
                    if (!in_list) {
                        try result.appendSlice(allocator, "<ol>\n");
                        in_list = true;
                    }
                    const processed = try processInline(allocator, trimmed[dot_pos + 2 ..]);
                    defer allocator.free(processed);
                    try result.appendSlice(allocator, "<li>");
                    try result.appendSlice(allocator, processed);
                    try result.appendSlice(allocator, "</li>\n");
                    continue;
                }
            }
        }

        if (!in_paragraph) {
            try result.appendSlice(allocator, "<p>");
            in_paragraph = true;
        } else {
            try result.append(allocator, '\n');
        }
        const processed = try processInline(allocator, trimmed);
        defer allocator.free(processed);
        try result.appendSlice(allocator, processed);
    }

    if (in_paragraph) try result.appendSlice(allocator, "</p>\n");
    if (in_list) try result.appendSlice(allocator, "</ul>\n");
    if (in_blockquote) try result.appendSlice(allocator, "</blockquote>\n");
    if (in_code_block) try result.appendSlice(allocator, "</code></pre></div>\n");

    return result.toOwnedSlice(allocator);
}

fn processInline(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .{};
    defer result.deinit(allocator);

    var i: usize = 0;
    while (i < text.len) {
        if (i + 1 < text.len and text[i] == '*' and text[i + 1] == '*') {
            if (std.mem.indexOf(u8, text[i + 2 ..], "**")) |end| {
                try result.appendSlice(allocator, "<strong>");
                try result.appendSlice(allocator, text[i + 2 .. i + 2 + end]);
                try result.appendSlice(allocator, "</strong>");
                i += 4 + end;
                continue;
            }
        }

        if (text[i] == '*' or text[i] == '_') {
            const marker = text[i];
            var end: usize = i + 1;
            while (end < text.len and text[end] != marker) : (end += 1) {}
            if (end < text.len and end > i + 1) {
                try result.appendSlice(allocator, "<em>");
                try result.appendSlice(allocator, text[i + 1 .. end]);
                try result.appendSlice(allocator, "</em>");
                i = end + 1;
                continue;
            }
        }

        if (text[i] == '`') {
            if (std.mem.indexOf(u8, text[i + 1 ..], "`")) |end| {
                try result.appendSlice(allocator, "<code>");
                try result.appendSlice(allocator, text[i + 1 .. i + 1 + end]);
                try result.appendSlice(allocator, "</code>");
                i += 2 + end;
                continue;
            }
        }

        if (text[i] == '[') {
            if (std.mem.indexOf(u8, text[i..], "](")) |bracket_end| {
                if (std.mem.indexOf(u8, text[i + bracket_end + 2 ..], ")")) |paren_end| {
                    const link_text = text[i + 1 .. i + bracket_end];
                    const url = text[i + bracket_end + 2 .. i + bracket_end + 2 + paren_end];
                    try result.appendSlice(allocator, "<a href=\"");
                    try result.appendSlice(allocator, url);
                    try result.appendSlice(allocator, "\">");
                    try result.appendSlice(allocator, link_text);
                    try result.appendSlice(allocator, "</a>");
                    i += bracket_end + 3 + paren_end;
                    continue;
                }
            }
        }

        if (i + 1 < text.len and text[i] == '!' and text[i + 1] == '[') {
            if (std.mem.indexOf(u8, text[i + 1 ..], "](")) |bracket_end| {
                if (std.mem.indexOf(u8, text[i + 2 + bracket_end ..], ")")) |paren_end| {
                    const alt_text = text[i + 2 .. i + 1 + bracket_end];
                    const src = text[i + 2 + bracket_end + 1 .. i + 2 + bracket_end + paren_end];
                    try result.appendSlice(allocator, "<img src=\"");
                    try result.appendSlice(allocator, src);
                    try result.appendSlice(allocator, "\" alt=\"");
                    try result.appendSlice(allocator, alt_text);
                    try result.appendSlice(allocator, "\">");
                    i += bracket_end + 3 + paren_end;
                    continue;
                }
            }
        }

        try result.append(allocator, text[i]);
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
            else => try result.append(allocator, c),
        }
    }

    return result.toOwnedSlice(allocator);
}

test "process markdown with math" {
    const allocator = std.testing.allocator;

    const content = "Hello $$x^2$$ world";
    var result = try processSimple(allocator, content);
    defer result.deinit();

    try std.testing.expect(std.mem.indexOf(u8, result.html, "katex-display") != null);
}
