#!/usr/bin/env bash
# One-shot pipeline: download from Wayback with retries/SSL fallback, then process for WP (rewrite links, export WXR, docs).
# Required env vars:
#   BASE_URL   (e.g., https://example.com/)
#   TO_TS      (e.g., 20250810061055)
#   OUT_DIR    (output directory)
# Optional:
#   FROM_TS    (lower bound)
#   SITE_URL   (for README/link rewrites; defaults to BASE_URL)
#   CONCURRENCY (default 14, auto-fallback to 10 on failure)
#   MAX_SNAPSHOT (default 300)
#   RETRY_FLAG  (default "--retry 3")
#   WAIT_SECS   (default 120)
#   AUTO_PROCESS (default YES; set to NO to prompt for rewrite/processing)

set -euo pipefail

# Minimal status line helper (prints to bottom of terminal without losing scrollback)
if [[ -t 1 ]] && tput cols >/dev/null 2>&1; then
  STATUS_ENABLED=1
else
  STATUS_ENABLED=0
fi

status_line() {
  local msg="$1"
  if [[ "$STATUS_ENABLED" -eq 0 ]]; then
    return 0
  fi
  local cols rows
  cols=$(tput cols)
  rows=$(tput lines)
  tput sc
  tput cup $((rows-1)) 0
  printf "\r%-${cols}s" "== ${msg} =="
  tput rc
}

BASE_URL="${BASE_URL:-}"
TO_TS="${TO_TS:-}"
FROM_TS="${FROM_TS:-}"
OUT_DIR="${OUT_DIR:-}"
SITE_URL="${SITE_URL:-$BASE_URL}"
CONCURRENCY="${CONCURRENCY:-14}"
MAX_SNAPSHOT="${MAX_SNAPSHOT:-300}"
RETRY_FLAG="${RETRY_FLAG:---retry 3}"
WAIT_SECS="${WAIT_SECS:-120}"

if [[ -z "$BASE_URL" || -z "$TO_TS" || -z "$OUT_DIR" ]]; then
  echo "Usage: set BASE_URL, TO_TS, OUT_DIR (FROM_TS optional). Current: BASE_URL=${BASE_URL}, TO_TS=${TO_TS}, OUT_DIR=${OUT_DIR}" >&2
  exit 1
fi

run_downloader() {
  local use_ssl_fix="${1:-0}"
  LOG_PATH=$(mktemp)
  if [[ "$use_ssl_fix" == "1" ]]; then
    export RUBYOPT="-r./fix_ssl_store.rb"
  else
    unset RUBYOPT
  fi
  wayback_machine_downloader "${BASE_URL}" \
    ${FROM_TS:+--from "${FROM_TS}"} \
    --to "${TO_TS}" \
    --directory "${OUT_DIR}" \
    --concurrency "${CONCURRENCY}" \
    --maximum-snapshot "${MAX_SNAPSHOT}" \
    ${RETRY_FLAG} > >(tee "$LOG_PATH") 2> >(tee -a "$LOG_PATH" >&2)
  return $?
}

attempt=0
fell_back=0
while true; do
  attempt=$((attempt + 1))
  echo ""
  echo "== Attempt ${attempt}: checking web.archive.org..."
  status_line "Attempt ${attempt}: checking web.archive.org"
  if ! curl -Is https://web.archive.org >/dev/null 2>&1; then
    echo "   Wayback not reachable. Sleeping ${WAIT_SECS}s..."
    sleep "${WAIT_SECS}"
    continue
  fi

  echo "   Running wayback_machine_downloader (to=${TO_TS}, dir=${OUT_DIR}, concurrency=${CONCURRENCY})"
  if run_downloader 0; then
    status=0
  else
    status=$?
  fi
  log_file="$LOG_PATH"
  if [[ $status -ne 0 ]]; then
    if grep -qi 'SSL_connect' "$log_file"; then
      echo "   SSL error detected; retrying with fix_ssl_store.rb ..."
      status_line "SSL error detected; retrying with SSL fix"
      rm -f "$log_file"
      if run_downloader 1; then
        status=0
      else
        status=$?
      fi
      log_file="$LOG_PATH"
    fi
  fi

  if [[ $status -eq 0 ]]; then
    echo "== Download completed."
    status_line "Download completed"
    rm -f "$log_file"
    break
  else
    echo "   Downloader exited with status ${status}. See log: ${log_file}"
    if [[ $fell_back -eq 0 && "$CONCURRENCY" -eq 14 ]]; then
      CONCURRENCY=10
      fell_back=1
      echo "   High concurrency (14) may have failed. Falling back to concurrency=10 and retrying..."
    else
      echo "   Sleeping ${WAIT_SECS}s and retrying..."
      sleep "${WAIT_SECS}"
    fi
  fi
done

echo ""
echo "== Post-processing for WordPress..."
status_line "Post-processing for WordPress"
python3 - "$OUT_DIR" "$SITE_URL" <<'PY'
import html
import html.parser
import os
import re
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path
from urllib.parse import urlparse

root = Path(sys.argv[1]).resolve()
site_url = sys.argv[2].rstrip("/")
auto_process = os.environ.get("AUTO_PROCESS", "YES").strip().lower() != "no"

def prompt_yes(msg):
    if auto_process:
        print(f"{msg} [y/N]: y (AUTO_PROCESS)")
        return True
    try:
        ans = input(f"{msg} [y/N]: ").strip().lower()
        return ans in ("y", "yes")
    except EOFError:
        return False

def is_wp_site(root: Path):
    if (root / "wp-content").exists() or (root / "wp-includes").exists():
        return True
    generator_re = re.compile(r"content=[\"']WordPress", re.I)
    for p in root.rglob("index.html"):
        try:
            txt = p.read_text(encoding="utf-8", errors="ignore")
        except Exception:
            continue
        if generator_re.search(txt):
            return True
    return False

def rewrite_links(root: Path, site_url: str):
    parsed = urlparse(site_url)
    host = re.escape(parsed.netloc)
    patterns = [
        (re.compile(rf"https?://web\.archive\.org/web/\d+/(?:https?:)?//?{host}/?", re.I), "/"),
        (re.compile(rf"https?://{host}/?", re.I), "/"),
        (re.compile(rf"//{host}/?", re.I), "/"),
        (re.compile(rf"https:\\\\/\\\\/{host}\\\\/", re.I), "/"),
        (re.compile(rf"http:\\\\/\\\\/{host}\\\\/", re.I), "/"),
        (re.compile(rf"https%3A%2F%2F{host}%2F", re.I), "/"),
        (re.compile(rf"http%3A%2F%2F{host}%2F", re.I), "/"),
    ]
    exts = {".html", ".htm", ".css", ".js", ".xml", ".txt", ".json", ".php", ".rss", ".atom"}
    rewritten = 0
    for dirpath, _, filenames in os.walk(root):
        for name in filenames:
            ext = os.path.splitext(name)[1].lower()
            if ext not in exts:
                continue
            path = Path(dirpath) / name
            try:
                data = path.read_bytes()
            except Exception:
                continue
            try:
                text = data.decode("utf-8")
            except UnicodeDecodeError:
                try:
                    text = data.decode("latin-1")
                except Exception:
                    continue
            orig = text
            for pat, repl in patterns:
                text = pat.sub(repl, text)
            if text != orig:
                path.write_text(text, encoding="utf-8")
                rewritten += 1
    return rewritten

def find_theme(root: Path):
    themes_dir = root / "wp-content" / "themes"
    if not themes_dir.exists():
        return None, None
    for theme in themes_dir.iterdir():
        if not theme.is_dir():
            continue
        style = theme / "style.css"
        if not style.exists():
            css_candidates = sorted(theme.glob("style*.css"))
            if css_candidates:
                style = css_candidates[0]
        header = style.read_text(errors="ignore") if style.exists() else ""
        name = None
        m = re.search(r"Theme Name:\s*(.+)", header)
        if m:
            name = m.group(1).strip()
        return theme.name, name
    return None, None

def collect_posts(root: Path):
    posts = []
    title_re = re.compile(r"<title>(.*?)</title>", re.I | re.S)
    pub_re = re.compile(r'property="article:published_time"\s+content="([^"]+)"', re.I)
    author_res = [
        re.compile(r'meta[^>]+name=["\']author["\'][^>]+content=["\']([^"\']+)', re.I),
        re.compile(r'meta[^>]+name=["\']twitter:data1["\'][^>]+content=["\']([^"\']+)', re.I),
    ]

    class EntryContentParser(html.parser.HTMLParser):
        def __init__(self):
            super().__init__()
            self.in_entry = False
            self.depth = 0
            self.parts = []
        def handle_starttag(self, tag, attrs):
            attrs_str = "".join(f' {k}="{html.escape(v or "", quote=True)}"' for k, v in attrs)
            if not self.in_entry:
                classes = " ".join(v or "" for k, v in attrs if k == "class")
                if "entry-content" in classes or "blog-content" in classes:
                    self.in_entry = True
                    self.depth = 1
                    self.parts.append(f"<{tag}{attrs_str}>")
            else:
                self.depth += 1
                self.parts.append(f"<{tag}{attrs_str}>")
        def handle_endtag(self, tag):
            if self.in_entry:
                self.parts.append(f"</{tag}>")
                self.depth -= 1
                if self.depth == 0:
                    self.in_entry = False
        def handle_data(self, data):
            if self.in_entry:
                self.parts.append(html.escape(data))
        def handle_entityref(self, name):
            if self.in_entry:
                self.parts.append(f"&{name};")
        def handle_charref(self, name):
            if self.in_entry:
                self.parts.append(f"&#{name};")

    for p in root.rglob("index.html"):
        try:
            text = p.read_text(encoding="utf-8", errors="ignore")
        except Exception:
            continue
        mtitle = title_re.search(text)
        title = html.unescape(mtitle.group(1).strip()) if mtitle else p.parent.name
        pub = None
        m = pub_re.search(text)
        if m:
            pub = m.group(1)
        author = "Unknown"
        for ar in author_res:
            ma = ar.search(text)
            if ma:
                author = html.unescape(ma.group(1).strip())
                break
        parser = EntryContentParser()
        try:
            parser.feed(text)
        except Exception:
            content = ""
        else:
            content = "".join(parser.parts).strip()
        if not content:
            m_article = re.search(r"<article[^>]*>(.*?)</article>", text, re.I | re.S)
            if m_article:
                content = m_article.group(1).strip()
        if not content:
            m_body = re.search(r"<body[^>]*>(.*?)</body>", text, re.I | re.S)
            if m_body:
                content = m_body.group(1).strip()
        if not content:
            continue
        slug = str(p.parent.relative_to(root))
        posts.append({"title": title, "pub": pub, "author": author, "slug": slug, "content": content})
    return posts

def write_authors_posts(root: Path, posts):
    by_author = defaultdict(list)
    for post in posts:
        by_author[post["author"]].append(post)
    lines = []
    for author in sorted(by_author):
        lines.append(f"## {author}")
        for post in sorted(by_author[author], key=lambda x: (x["pub"] or "", x["slug"])):
            pub_str = f" ({post['pub']})" if post["pub"] else ""
            lines.append(f"- {post['title']} — /{post['slug']}/{pub_str}")
        lines.append("")
    (root / "authors_posts.md").write_text("\n".join(lines), encoding="utf-8")
    return len(by_author)

def write_widgets(root: Path):
    widgets = set()
    widget_id_re = re.compile(r'id=["\'](widget-[^"\']+)["\']', re.I)
    widget_class_re = re.compile(r'class=["\']([^"\']*\\bwidget[^"\']*)["\']', re.I)
    for p in root.rglob("index.html"):
        try:
            text = p.read_text(encoding="utf-8", errors="ignore")
        except Exception:
            continue
        for m in widget_id_re.finditer(text):
            widgets.add(m.group(1))
        for m in widget_class_re.finditer(text):
            classes = m.group(1).split()
            for c in classes:
                if c.startswith("widget"):
                    widgets.add(c)
    (root / "widgets.txt").write_text("\n".join(sorted(widgets)), encoding="utf-8")
    return widgets

def write_wxr(root: Path, posts):
    now = datetime.utcnow().strftime("%a, %d %b %Y %H:%M:%S +0000")
    items = []
    for post in posts:
        link = f"{site_url}/{post['slug']}/"
        slug = post["slug"].split("/")[-1]
        title = html.escape(post["title"])
        content = post["content"]
        pub_date = post["pub"] or now
        items.append(
            f"""
  <item>
    <title>{title}</title>
    <link>{link}</link>
    <pubDate>{pub_date}</pubDate>
    <wp:post_date>{pub_date}</wp:post_date>
    <wp:post_name>{html.escape(slug)}</wp:post_name>
    <wp:status>publish</wp:status>
    <wp:post_type>post</wp:post_type>
    <content:encoded><![CDATA[{content}]]></content:encoded>
  </item>"""
        )
    wxr = f"""<?xml version="1.0" encoding="UTF-8" ?>
<rss version="2.0"
    xmlns:excerpt="http://wordpress.org/export/1.2/excerpt/"
    xmlns:content="http://purl.org/rss/1.0/modules/content/"
    xmlns:wp="http://wordpress.org/export/1.2/">
  <channel>
    <title>{root.name} (Recovered)</title>
    <link>{site_url}</link>
    <description>Recovered posts</description>
    <pubDate>{now}</pubDate>
    {''.join(items)}
  </channel>
</rss>
"""
    (root / "export.xml").write_text(wxr, encoding="utf-8")
    return len(items)

def write_readme(root: Path, posts, theme_dir, theme_name, authors_count, widgets):
    latest = None
    for post in posts:
        if not post["pub"]:
            continue
        if latest is None or post["pub"] > latest["pub"]:
            latest = post
    readme = []
    readme.append("## What this directory is")
    readme.append(f"- `{root.name}/` is a rebuilt static mirror of {site_url}.")
    readme.append(f"- Theme in use: `{theme_dir or 'unknown'}` (theme folder `wp-content/themes/{theme_dir}`, header `{theme_name or 'n/a'}`).")
    readme.append("- Plugins and media are under `wp-content/plugins/` and `wp-content/uploads/`.")
    readme.append(f"- `export.xml` is a WXR file ({len(posts)} items exported).")
    readme.append(f"- Author/post mapping is in `authors_posts.md` ({authors_count} authors). Widget types seen are in `widgets.txt` ({', '.join(sorted(widgets)) if widgets else 'none found'}).")
    readme.append("- Note: the crawl also includes non-post pages such as category archives (`category/*`), tag archives (`tag/*`), event listings (`event/*`), sitemaps (`sitemap*.xml`, `sitemap-root.xml`, `sitemap-posttype-*.xml`, `sitemap-news.xml`), feeds (`feed/`, `feed/podcast/`), and a few index-style pages without post content. These are present in the static mirror but not necessarily in `export.xml`.")
    readme.append("")
    readme.append("## Latest dated post")
    if latest:
        readme.append(f"- “{latest['title']}”")
        readme.append(f"- Date: {latest['pub']}")
        readme.append(f"- Path: `{latest['slug']}/`")
    else:
        readme.append("- Not detected (no published_time meta found).")
    readme.append("")
    readme.append("## Static hosting (quick)")
    readme.append(f"- Serve this folder as-is; links are root-relative, so it will work when deployed at `{site_url}/`.")
    readme.append("")
    readme.append("## WordPress import (dynamic)")
    readme.append("1. In WP admin: Tools → Import → WordPress → upload `export.xml`.")
    readme.append("2. Copy/overlay `wp-content/` from this folder into the WP instance so media, theme, and plugin assets resolve. Activate the appropriate theme.")
    readme.append(f"3. Set Site URL to `{site_url}` (or target) and resave permalinks.")
    readme.append("")
    readme.append("## Known leftovers / clean-up")
    readme.append("- Analytics/third-party scripts remain as captured; disable in WP if undesired.")
    readme.append("- If you see any archived system/debug banners, they were present in the crawl and can be removed safely.")
    (root / "IMPORT_NOTES.md").write_text("\n".join(readme), encoding="utf-8")

if not is_wp_site(root):
    if auto_process:
        print("Site does not appear to be WordPress based on quick checks. Proceeding due to AUTO_PROCESS.")
    else:
        print("Site does not appear to be WordPress based on quick checks. Aborting.")
        sys.exit(1)

if not prompt_yes("WordPress site detected. Proceed with processing?"):
    print("Aborted by user.")
    sys.exit(0)

if prompt_yes("Rewrite absolute and Wayback links to root-relative?"):
    rewritten = rewrite_links(root, site_url)
    print(f"Rewrote {rewritten} files with link replacements.")
else:
    print("Skipped link rewriting.")

posts = collect_posts(root)
print(f"Collected {len(posts)} posts with content blocks.")
authors_count = write_authors_posts(root, posts)
widgets = write_widgets(root)
wxr_count = write_wxr(root, posts)
theme_dir, theme_name = find_theme(root)
write_readme(root, posts, theme_dir, theme_name, authors_count, widgets)
print(f"Wrote authors_posts.md, widgets.txt, export.xml ({wxr_count} items), and IMPORT_NOTES.md")
PY
