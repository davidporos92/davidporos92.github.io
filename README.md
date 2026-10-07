# davidporos92.github.io

Source of my personal blog, live at **https://davidporos92.github.io**.

It's where I write up my pet projects: what I built, what broke, and what I learned along the way. Every post links to the code, so you can clone it, run it, and prove me wrong. It's mostly for myself, but you're welcome to read along.

This repo isn't a template or a community project, so I don't take pull requests for posts. If you spot a typo, a broken link or something that's just wrong, open an issue or leave a comment under the post.

## Comments

Comments under each post are powered by [giscus](https://giscus.app) and stored in this repo's [Discussions](https://github.com/davidporos92/davidporos92.github.io/discussions), so you need a GitHub account to join in.

## How it's built

- [Jekyll](https://jekyllrb.com) with the [minima](https://github.com/jekyll/minima) 2.5 theme, plus a few overridden layouts and includes
- Built and deployed to GitHub Pages by [a GitHub Actions workflow](.github/workflows/pages.yml) on every push to `main`
- Posts are plain markdown files in [`_posts/`](_posts)
- Anonymous, cookieless page analytics with [PostHog](https://posthog.com) (production only)

| Path | What it is |
| --- | --- |
| `_posts/` | Blog posts, `YYYY-MM-DD-slug.md` |
| `_layouts/`, `_includes/` | Theme overrides: post page, home page, head, footer, comments, tags |
| `assets/main.scss`, `_sass/site/` | Stylesheet entry point; design settings and component styles on top of minima |
| `about.md`, `tags.md`, `index.md` | The About, Tags and home pages |

## Running it locally

Requires Ruby 3.3 and Bundler. Ruby 4.0 doesn't work yet, because the `github-pages` gem depends on `commonmarker` 0.x, which needs Ruby < 4.0. On macOS:

```sh
brew install ruby@3.3
export PATH="/opt/homebrew/opt/ruby@3.3/bin:$PATH"

bundle config set --local path vendor/bundle
bundle install
bundle exec jekyll serve --livereload
```

Then open http://127.0.0.1:4000. Changes to `_config.yml` need a server restart. Add `--drafts` to show `_drafts/` and `--future` to show posts dated in the future.

## Writing a post

Create `_posts/YYYY-MM-DD-slug.md`. The URL becomes `/posts/slug/`, and comment threads are tied to it, so pick the slug before publishing and don't change it afterwards.

```markdown
---
title: "Post title"
description: "One or two sentences for search results, link previews and RSS."
tags: [go, postgres]
series: "Series name"                                     # optional
source_url: "https://github.com/davidporos92/repo/tree/tag" # optional: "source and code on GitHub" link
previous_post: other-post-slug                             # optional: override the "Previous" link, or `false` to hide it
next_post: false                                          # optional: same for "Next"
---

The first paragraph becomes the excerpt on the home page.
```

Previous/Next links at the bottom of a post default to the neighboring posts in the same series, or by date if the post isn't in a series. A misspelled slug in `previous_post`/`next_post` fails the build.

Don't start the body with `# Title`; the layout prints it. Link to other posts with `{% post_url YYYY-MM-DD-slug %}`, which fails the build if the target ever disappears.

Fonts, colors and spacing are set in `_sass/site/_variables.scss`.

## License

The posts and pages are my own writing; please don't republish them without asking. The code behind each post lives in its own repository, under that repository's license.
