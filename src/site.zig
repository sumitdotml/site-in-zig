const std = @import("std");
const scanner = @import("scanner.zig");
const frontmatter = @import("frontmatter.zig");
const markdown = @import("markdown.zig");
const footnotes_mod = @import("footnotes.zig");
const template = @import("template.zig");
const assets = @import("assets.zig");

pub const BuildConfig = struct {
    content_dir: []const u8,
    output_dir: []const u8,
    template_dir: []const u8,
    static_dir: []const u8,
};

pub const SiteConfig = struct {
    title: []const u8 = "sumit.ml",
    description: []const u8 = "a site for my ml r&d worklogs and nonsensical thoughts",
    base_url: []const u8 = "",
};

pub fn build(allocator: std.mem.Allocator, config: BuildConfig) !void {
    const site_config = SiteConfig{};

    // Step 1: Prepare output directory
    std.debug.print("Preparing output directory...\n", .{});
    try assets.prepareOutputDir(config.output_dir);

    // Step 2: Scan content files
    std.debug.print("Scanning content files...\n", .{});
    var content_scanner = scanner.Scanner.init(allocator, config.content_dir);
    defer content_scanner.deinit();
    try content_scanner.scan();

    std.debug.print("Found {} content files\n", .{content_scanner.files.items.len});

    // Step 3: Load templates
    std.debug.print("Loading templates...\n", .{});
    var templates = try template.loadTemplates(allocator, config.template_dir);
    defer {
        var iter = templates.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        templates.deinit();
    }

    // Step 4: Copy static files
    std.debug.print("Copying static files...\n", .{});
    try assets.copyDirectory(allocator, config.static_dir, config.output_dir);

    // Step 5: Generate blog listing page
    std.debug.print("Generating blog listing...\n", .{});
    try generateBlogListing(allocator, &content_scanner, &templates, config.output_dir, site_config);

    // Step 6: Generate individual pages
    std.debug.print("Generating pages...\n", .{});
    for (content_scanner.files.items) |*file| {
        try generatePage(allocator, file, &templates, config, site_config);
    }

    // Step 7: Generate homepage
    std.debug.print("Generating homepage...\n", .{});
    try generateHomepage(allocator, &content_scanner, &templates, config.output_dir, site_config);
}

fn generateBlogListing(
    allocator: std.mem.Allocator,
    content_scanner: *scanner.Scanner,
    templates: *std.StringHashMap([]const u8),
    output_dir: []const u8,
    site_config: SiteConfig,
) !void {
    var ctx = template.Context.init(allocator);
    defer ctx.deinit();

    // Site config
    try ctx.setString("site_title", site_config.title);
    try ctx.setString("site_description", site_config.description);
    try ctx.setString("title", "Blog");
    try ctx.setString("description", "my ml worklogs and blog dumps");

    // Build posts list
    var posts_list: std.ArrayList(template.Context) = .{};
    defer {
        for (posts_list.items) |*p| p.deinit();
        posts_list.deinit(allocator);
    }

    for (content_scanner.files.items) |file| {
        if (file.content_type != .blog) continue;

        var post_ctx = template.Context.init(allocator);
        try post_ctx.setString("title", file.frontmatter.title orelse "Untitled");
        try post_ctx.setString("description", file.frontmatter.description orelse "");
        try post_ctx.setString("date", file.frontmatter.pub_date orelse "");
        try post_ctx.setString("url", try std.fmt.allocPrint(allocator, "/blog/{s}/", .{file.slug}));
        try posts_list.append(allocator, post_ctx);
    }

    try ctx.setList("posts", posts_list.items);

    // Load partials into context
    if (templates.get("head")) |head| try ctx.setPartial("head", head);
    if (templates.get("header")) |header| try ctx.setPartial("header", header);
    if (templates.get("footer")) |footer| try ctx.setPartial("footer", footer);

    // Render template
    const blog_list_template = templates.get("blog_list") orelse templates.get("base") orelse return error.TemplateNotFound;
    const html = try template.renderTemplate(allocator, blog_list_template, &ctx);
    defer allocator.free(html);

    // Write output
    const blog_dir = try std.fs.path.join(allocator, &.{ output_dir, "blog" });
    defer allocator.free(blog_dir);
    std.fs.cwd().makePath(blog_dir) catch {};

    try assets.writeOutput(allocator, output_dir, "blog/index.html", html);
}

fn generatePage(
    allocator: std.mem.Allocator,
    file: *const scanner.ContentFile,
    templates: *std.StringHashMap([]const u8),
    config: BuildConfig,
    site_config: SiteConfig,
) !void {
    std.debug.print("  Generating: {s}\n", .{file.slug});

    // Get markdown body (frontmatter was already parsed by scanner)
    var parse_result = frontmatter.parse(allocator, file.raw_content) catch |err| {
        std.debug.print("    Error parsing frontmatter: {}\n", .{err});
        return;
    };
    defer parse_result.frontmatter.deinit(allocator);

    const body = frontmatter.getBody(file.raw_content, parse_result.body_start);

    // Process footnotes
    var footnote_result = try footnotes_mod.process(allocator, body);
    defer footnote_result.deinit();

    // Process markdown
    var md_result = markdown.processSimple(allocator, footnote_result.html) catch |err| {
        std.debug.print("    Error processing markdown: {}\n", .{err});
        return;
    };
    defer md_result.deinit();

    // Generate footnotes section
    const footnotes_html = try footnotes_mod.generateFootnotesSection(allocator, footnote_result.footnotes);
    defer allocator.free(footnotes_html);

    // Combine content with footnotes
    const full_content = try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ md_result.html, footnotes_html });
    defer allocator.free(full_content);

    // Build template context
    var ctx = template.Context.init(allocator);
    defer ctx.deinit();

    try ctx.setString("site_title", site_config.title);
    try ctx.setString("site_description", site_config.description);
    try ctx.setString("title", file.frontmatter.title orelse "Untitled");
    try ctx.setString("description", file.frontmatter.description orelse "");
    try ctx.setString("date", file.frontmatter.pub_date orelse "");
    try ctx.setString("date_label", file.frontmatter.date_label orelse "Published: ");
    try ctx.setString("content", full_content);
    try ctx.setBool("has_date", file.frontmatter.pub_date != null);

    // Load partials
    if (templates.get("head")) |head| try ctx.setPartial("head", head);
    if (templates.get("header")) |header| try ctx.setPartial("header", header);
    if (templates.get("footer")) |footer| try ctx.setPartial("footer", footer);

    // Choose template based on content type
    const template_name = if (file.content_type == .blog) "post" else "page";
    const page_template = templates.get(template_name) orelse templates.get("base") orelse return error.TemplateNotFound;
    const html = try template.renderTemplate(allocator, page_template, &ctx);
    defer allocator.free(html);

    // Determine output path
    const output_path = switch (file.content_type) {
        .blog => try std.fmt.allocPrint(allocator, "blog/{s}/index.html", .{file.slug}),
        .page => try std.fmt.allocPrint(allocator, "{s}/index.html", .{file.slug}),
    };
    defer allocator.free(output_path);

    try assets.writeOutput(allocator, config.output_dir, output_path, html);
}

fn generateHomepage(
    allocator: std.mem.Allocator,
    content_scanner: *scanner.Scanner,
    templates: *std.StringHashMap([]const u8),
    output_dir: []const u8,
    site_config: SiteConfig,
) !void {
    var ctx = template.Context.init(allocator);
    defer ctx.deinit();

    try ctx.setString("site_title", site_config.title);
    try ctx.setString("site_description", site_config.description);
    try ctx.setString("title", site_config.title);
    try ctx.setString("description", site_config.description);

    // Recent posts (top 5)
    var posts_list: std.ArrayList(template.Context) = .{};
    defer {
        for (posts_list.items) |*p| p.deinit();
        posts_list.deinit(allocator);
    }

    var count: usize = 0;
    for (content_scanner.files.items) |file| {
        if (file.content_type != .blog) continue;
        if (count >= 5) break;

        var post_ctx = template.Context.init(allocator);
        try post_ctx.setString("title", file.frontmatter.title orelse "Untitled");
        try post_ctx.setString("description", file.frontmatter.description orelse "");
        try post_ctx.setString("date", file.frontmatter.pub_date orelse "");
        try post_ctx.setString("url", try std.fmt.allocPrint(allocator, "/blog/{s}/", .{file.slug}));
        try posts_list.append(allocator, post_ctx);
        count += 1;
    }

    try ctx.setList("recent_posts", posts_list.items);
    try ctx.setBool("has_posts", posts_list.items.len > 0);

    // Load partials
    if (templates.get("head")) |head| try ctx.setPartial("head", head);
    if (templates.get("header")) |header| try ctx.setPartial("header", header);
    if (templates.get("footer")) |footer| try ctx.setPartial("footer", footer);

    // Render
    const home_template = templates.get("index") orelse templates.get("base") orelse return error.TemplateNotFound;
    const html = try template.renderTemplate(allocator, home_template, &ctx);
    defer allocator.free(html);

    try assets.writeOutput(allocator, output_dir, "index.html", html);
}
