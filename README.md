# Wayback Machine Downloader + WP recovery pipeline

[![version](https://badge.fury.io/rb/wayback_machine_downloader_straw.svg)](https://rubygems.org/gems/wayback_machine_downloader_straw)

This fork extends the original [Wayback Machine Downloader](https://github.com/hartator/wayback-machine-downloader) with resiliency fixes and a WordPress-ready recovery pipeline.

Included here is partial content from other forks, namely those @ [ShiftaDeband](https://github.com/ShiftaDeband/wayback-machine-downloader) and [matthid](https://github.com/matthid/wayback-machine-downloader) — attributions are in the code.

---

## ▶️ Quick start (downloader)
Download a website's latest snapshot:
```bash
wayback_machine_downloader https://example.com
```
Files save to `./websites/example.com/` with original structure preserved.

## 📥 Installation
**Requirements**
- Ruby 2.3+ ([download Ruby](https://www.ruby-lang.org/en/downloads/))
- Bundler gem (`gem install bundler`)

**Gem install**
```bash
gem install wayback_machine_downloader_straw
```
Then run as usual:
```bash
wayback_machine_downloader https://example.com
```
If you see version 2.3.1 or earlier, uninstall the old hartator gem so this fork (2.4.x) is used.

**Manual run**
```bash
bundle install
cd path/to/wayback-machine-downloader/bin
ruby wayback_machine_downloader https://example.com
```
Windows tip: In File Explorer, Shift + Right Click your `bin` folder → "Open Terminal here".

---

## Wayback → WordPress recovery pipeline (added in this fork)
**Why this exists**
- Speed and reliability of full-site recoveries from Wayback, with immediate WordPress readiness. Collapses SSL handling, retries, link cleanup, and WXR creation into one run.
- Helps ops/infra, content teams, and devs who need WP-ready imports without deep Wayback/Ruby expertise.

**Pipeline quick start**
```bash
BASE_URL="https://example.com/" \
TO_TS="20250810061055" \
OUT_DIR="example" \
./wayback_wp_pipeline.sh
```
Defaults: 
- CONCURRENCY=14 (auto-fallback to 10) 
- MAX_SNAPSHOT=300
- RETRY_FLAG="--retry 3"
- AUTO_PROCESS=YES. 
- Optional: FROM_TS, SITE_URL, WAIT_SECS, AUTO_PROCESS=NO for prompts.

**What it does**
- Download from Wayback with retry/backoff and SSL fallback (`fix_ssl_store.rb` on SSL errors).
- Rewrite Wayback/absolute links to root-relative for the target domain.
- Detect WordPress, extract posts, and build `export.xml` (WXR), `authors_posts.md`, `widgets.txt`, `IMPORT_NOTES.md` (theme, authors, latest post, leftovers).
- Show a live status line at the bottom of the terminal while preserving scrollback.

**Outputs**
- `OUT_DIR/` static mirror.
- `export.xml`, `authors_posts.md`, `widgets.txt`, `IMPORT_NOTES.md` inside `OUT_DIR/`.
- Root-relative links for easier hosting/Playground import.

**Notes**
- AUTO_PROCESS=YES proceeds even if WP heuristics are weak; set AUTO_PROCESS=NO to require confirmation.
- If concurrency 14 fails, it retries automatically with concurrency 10.
- Status line only appears when stdout is a TTY (tput available); logging still goes to stdout/stderr.

---

## 🐳 Docker users
```bash
docker build -t wayback_machine_downloader .
docker run -it --rm wayback_machine_downloader [options] URL
```
Example without cloning:
```bash
docker run -v .:/build/websites \
  ghcr.io/strawberrymaster/wayback-machine-downloader:master \
  wayback_machine_downloader --to 20130101 smallrockets.com
```
Docker Compose (excerpt):
```yaml
services:
  wayback_machine_downloader:
    build:
      context: .
    tty: true
    image: wayback_machine_downloader:latest
    container_name: wayback_machine_downloader
    volumes:
      - .:/build:rw
      - ./websites:/build/websites:rw
```

---

## ⚙️ Configuration
Defaults (edit in `wayback_machine_downloader.rb` if needed):
```ruby
DEFAULT_TIMEOUT = 30        # HTTP timeout (s)
MAX_RETRIES = 3             # Retries per request
RETRY_DELAY = 2             # Wait between retries (s)
RATE_LIMIT = 0.25           # Throttle between requests (s)
CONNECTION_POOL_SIZE = 10   # Simultaneous connections
MEMORY_BUFFER_SIZE = 16384  # Download buffer (bytes)
STATE_CDX_FILENAME = '.cdx.json'       # Snapshot listing
STATE_DB_FILENAME = '.downloaded.txt'  # Completed downloads
```

---

## 🛠️ Advanced usage (downloader)
- `-d DIR`, `--directory DIR`: Custom output directory
- `-s`, `--all-timestamps`: Download all versions
- `-f TS`, `--from TS`: Start from timestamp (YYYYMMDDhhmmss)
- `-t TS`, `--to TS`: Stop at timestamp
- `-e`, `--exact-url`: Only the exact URL
- `-r`, `--rewritten`: Download rewritten Wayback files only
- `-rt`, `--retry NUM`: Retry count (default 1)
- Filtering: `-o FILTER` (only), `-x FILTER` (exclude), supports regex `/.../`
- Performance: `-c NUM` concurrency, `-p NUM` maximum snapshot pages
- Diagnostics: `-a` include errors, `-l` list-only
- Job control: `--reset` (wipe state files), `--keep` (preserve state files)

Examples:
```bash
ruby wayback_machine_downloader https://example.com --directory downloaded-backup/
ruby wayback_machine_downloader https://example.com --all-timestamps
ruby wayback_machine_downloader https://example.com --from 20060716231334 --to 20100916231334
ruby wayback_machine_downloader https://example.com --only "/\.(gif|jpg|jpeg)$/i"
ruby wayback_machine_downloader https://example.com --exclude "/\.(gif|jpg|jpeg)$/i"
ruby wayback_machine_downloader https://example.com --concurrency 20
```

---

## Troubleshooting
### SSL certificate errors
If you see:
```
SSL_connect returned=1 errno=0 state=error: certificate verify failed (unable to get certificate CRL)
```
Create `fix_ssl_store.rb`:
```ruby
require "openssl"
store = OpenSSL::X509::Store.new.tap(&:set_default_paths)
OpenSSL::SSL::SSLContext::DEFAULT_PARAMS[:cert_store] = store
```
Run with:
```bash
RUBYOPT="-r./fix_ssl_store.rb" wayback_machine_downloader "http://example.com"
```

Verify your Ruby/OpenSSL:
```ruby
require "net/http"
require "uri"
uri = URI("https://web.archive.org/")
Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
  resp = http.get("/")
  puts "GET / => #{resp.code}"
end
```

---

## 🤝 Contributing
1. Fork
2. Create a feature branch
3. Submit a PR

Run tests (known flaky):
```bash
bundle exec rake test
```
