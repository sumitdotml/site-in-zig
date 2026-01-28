# Zig Static Site Generator

A custom static site generator written in Zig for the sumit.ml personal site.

## Features

- Markdown to HTML conversion with support for:
  - Headers, paragraphs, lists
  - Code blocks with syntax highlighting (via highlight.js)
  - Math equations (via KaTeX)
  - Footnotes with back-references
  - Images and links
- TOML-like frontmatter parsing
- Mustache-style templating with partials
- Dark/light theme toggle
- Mobile-responsive design
- GitHub Pages deployment

## Project Structure

```
zig-ssg/
├── build.zig              # Zig build configuration
├── src/
│   ├── main.zig           # Entry point, CLI
│   ├── scanner.zig        # Directory traversal
│   ├── frontmatter.zig    # Frontmatter parser
│   ├── markdown.zig       # Markdown to HTML
│   ├── footnotes.zig      # Footnote processing
│   ├── template.zig       # Template engine
│   ├── assets.zig         # Static file handling
│   └── site.zig           # Build orchestration
├── templates/
│   ├── base.html
│   ├── post.html
│   ├── page.html
│   ├── blog_list.html
│   ├── index.html
│   └── partials/
├── static/
│   ├── css/
│   ├── js/
│   └── assets/
├── content/
│   ├── blog/
│   └── pages/
└── dist/                  # Generated output
```

## Building

Requires Zig 0.13.0 or later.

```bash
cd zig-ssg
zig build
```

## Usage

Generate the site:

```bash
zig build run
```

Options:
- `--content <dir>` - Content directory (default: content)
- `--output <dir>` - Output directory (default: dist)
- `--templates <dir>` - Template directory (default: templates)
- `--static <dir>` - Static files directory (default: static)

## Content Format

### Frontmatter

Use TOML-like syntax:

```markdown
---
title = "My Post Title"
description = "A description"
pubDate = 2025-10-30
dateLabels.published = "Last updated: "
---

Content here...
```

### Math

- Inline: `$x^2$`
- Display: `$$\sum_{i=1}^n i$$`

### Footnotes

```markdown
This is text with a footnote[^1].

[^1]: This is the footnote content.
```

## Local Development

After building, serve the site locally:

```bash
cd dist
python3 -m http.server 8000
```

Then visit http://localhost:8000

## Deployment

Push to main branch to trigger GitHub Pages deployment via the workflow at `.github/workflows/deploy.yml`.
