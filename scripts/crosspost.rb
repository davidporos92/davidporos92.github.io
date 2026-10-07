# frozen_string_literal: true

# Cross-posts blog posts to dev.to (as drafts, via the Forem API) and prepares
# ready-to-paste markdown for Hashnode (whose API needs a paid Pro plan).
#
# Usage:
#   ruby scripts/crosspost.rb [--dry-run] [--out DIR] _posts/series/YYYY-MM-DD-slug.md ...
#
# Environment:
#   DEVTO_API_KEY  dev.to API key (Settings > Extensions). Without it, dev.to is skipped.
#
# Idempotent: a dev.to article is matched by its canonical URL, so re-running
# updates the existing article instead of creating a duplicate. Updates never
# change whether the dev.to article is published.

require "date"
require "fileutils"
require "json"
require "net/http"
require "optparse"
require "uri"
require "yaml"

SITE_URL = YAML.safe_load_file(File.expand_path("../_config.yml", __dir__))["url"].chomp("/")
DEVTO_API = "https://dev.to/api"
DEVTO_MAX_TAGS = 4

Post = Struct.new(:path, :slug, :date, :front_matter, :body, keyword_init: true) do
  def url = "#{SITE_URL}/posts/#{slug}/"
  def title = front_matter.fetch("title")
  def description = front_matter["description"]
  def series = front_matter["series"]
  def source_url = front_matter["source_url"]
  def tags = Array(front_matter["tags"]).map(&:to_s)
end

def parse_post(path)
  name = File.basename(path, ".md")
  match = name.match(/\A(\d{4}-\d{2}-\d{2})-(.+)\z/) or abort "#{path}: file name must be YYYY-MM-DD-slug.md"
  raw = File.read(path)
  parts = raw.match(/\A---\s*\n(.*?)\n---\s*\n(.*)\z/m) or abort "#{path}: missing front matter"
  fm, body = parts.captures
  front_matter = YAML.safe_load(fm, permitted_classes: [Date, Time])
  date = front_matter["date"] ? Date.parse(front_matter["date"].to_s) : Date.parse(match[1])
  Post.new(path:, slug: match[2], date:, front_matter:, body:)
end

# Turns the Jekyll source into plain markdown with absolute links.
def render(post)
  body = post.body.dup

  body.gsub!(/\{%-?\s*post_url\s+(\S+)\s*-?%\}/) do
    target = Dir.glob(File.join("_posts", "**", "#{File.basename(Regexp.last_match(1))}.md")).first
    abort "#{post.path}: post_url target #{Regexp.last_match(1)} not found" unless target
    parse_post(target).url
  end
  body.gsub!(/\{\{-?\s*["']([^"']+)["']\s*\|\s*(?:relative_url|absolute_url)\s*-?\}\}/) { "#{SITE_URL}#{Regexp.last_match(1)}" }
  body.gsub!(/\{%-?\s*(?:raw|endraw)\s*-?%\}/, "")
  # Root-relative markdown links and images: [text](/path) and ![alt](/path)
  body.gsub!(%r{\]\(/(?!/)}, "](#{SITE_URL}/")

  if (leftover = body[/\{%.*?%\}|\{\{.*?\}\}/])
    abort "#{post.path}: unsupported Liquid left after rendering: #{leftover}"
  end

  footer = +"\n\n---\n\n*Originally published on [my blog](#{post.url}), where the comments live."
  footer << " The code for this post is [on GitHub](#{post.source_url})." if post.source_url
  footer << "*\n"
  body.rstrip + footer
end

# dev.to tags: lowercase alphanumerics only, at most four.
def devto_tags(tags)
  cleaned = tags.map { |t| t.downcase.gsub(/[^a-z0-9]/, "") }.reject(&:empty?).uniq
  warn "  dev.to allows #{DEVTO_MAX_TAGS} tags, dropping: #{cleaned.drop(DEVTO_MAX_TAGS).join(', ')}" if cleaned.size > DEVTO_MAX_TAGS
  cleaned.first(DEVTO_MAX_TAGS)
end

def devto_request(method, path, api_key, body = nil)
  uri = URI("#{DEVTO_API}#{path}")
  request = Net::HTTP.const_get(method.capitalize).new(uri)
  request["api-key"] = api_key
  request["accept"] = "application/vnd.forem.api-v1+json"
  request["content-type"] = "application/json"
  request.body = JSON.generate(body) if body
  response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(request) }
  abort "dev.to #{method} #{path} failed: #{response.code} #{response.body}" unless response.is_a?(Net::HTTPSuccess)
  JSON.parse(response.body)
end

def devto_find_by_canonical(api_key, canonical_url)
  page = 1
  loop do
    articles = devto_request("get", "/articles/me/all?per_page=1000&page=#{page}", api_key)
    return nil if articles.empty?

    found = articles.find { |a| a["canonical_url"]&.chomp("/") == canonical_url.chomp("/") }
    return found if found

    page += 1
  end
end

def crosspost_devto(post, markdown, api_key:, dry_run:)
  article = {
    title: post.title,
    body_markdown: markdown,
    canonical_url: post.url,
    description: post.description,
    tags: devto_tags(post.tags),
    series: post.series
  }.compact

  if dry_run
    puts "  dev.to (dry run): would create or update a draft with #{JSON.generate(article.except(:body_markdown))}"
    return nil
  end

  existing = devto_find_by_canonical(api_key, post.url)
  if existing
    result = devto_request("put", "/articles/#{existing['id']}", api_key, { article: })
    puts "  dev.to: updated #{existing['published'] ? 'published article' : 'draft'} #{result['url']}"
  else
    result = devto_request("post", "/articles", api_key, { article: article.merge(published: false) })
    puts "  dev.to: created draft #{result['url']}"
  end
  result["url"]
end

def write_hashnode(post, markdown, out_dir)
  dir = File.join(out_dir, "hashnode")
  FileUtils.mkdir_p(dir)
  file = File.join(dir, "#{post.slug}.md")
  File.write(file, markdown)
  puts "  Hashnode: wrote #{file}"
  file
end

def summary(post, devto_url, hashnode_file)
  <<~MD
    ### #{post.title}

    | Field | Value |
    | --- | --- |
    | dev.to | #{devto_url ? "[draft](#{devto_url}): review, then publish" : 'skipped'} |
    | Hashnode content | `hashnode/#{File.basename(hashnode_file)}` in the `crosspost` artifact |
    | Hashnode title | #{post.title} |
    | Hashnode subtitle | #{post.description} |
    | Hashnode slug | `#{post.slug}` |
    | Hashnode tags | #{post.tags.join(', ')} |
    | Hashnode series | #{post.series || '-'} |
    | Canonical URL | #{post.url} |

  MD
end

options = { dry_run: false, out: "crosspost" }
OptionParser.new do |o|
  o.banner = "Usage: ruby scripts/crosspost.rb [--dry-run] [--out DIR] POST..."
  o.on("--dry-run", "Render and print, don't call dev.to") { options[:dry_run] = true }
  o.on("--out DIR", "Where to write the Hashnode files (default: crosspost)") { |d| options[:out] = d }
end.parse!

abort "No posts given." if ARGV.empty?

api_key = ENV["DEVTO_API_KEY"].to_s
warn "DEVTO_API_KEY is not set, skipping dev.to." if api_key.empty? && !options[:dry_run]

summaries = ARGV.filter_map do |path|
  post = parse_post(path)
  puts "#{post.title} (#{path})"

  if post.front_matter["published"] == false || post.date > Date.today
    puts "  skipped: unpublished or dated in the future"
    next
  end

  markdown = render(post)
  devto_url = unless api_key.empty? && !options[:dry_run]
                crosspost_devto(post, markdown, api_key:, dry_run: options[:dry_run])
              end
  hashnode_file = write_hashnode(post, markdown, options[:out])
  summary(post, devto_url, hashnode_file)
end

if (summary_file = ENV["GITHUB_STEP_SUMMARY"]) && !summaries.empty?
  File.write(summary_file, "## Cross-posting\n\n#{summaries.join}", mode: "a")
end
