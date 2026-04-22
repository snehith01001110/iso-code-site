#!/usr/bin/env bash
# Pre-deploy check for isocode.dev.
# Verifies canonicals, OG tags, sitemap consistency, JSON-LD parsability,
# and flags stale references to deleted pages.
# Usage: ./validate.sh

HOST="https://isocode.dev"
FAIL=0
COUNT=0

cd "$(dirname "$0")" || exit 2

echo "== iso-code site validation =="

# Collect all HTML files under the site (excluding .git, node_modules)
PAGES=$(find . -name "*.html" -not -path "*/.git/*" -not -path "*/node_modules/*" | sort)

for f in $PAGES; do
  COUNT=$((COUNT + 1))
  path="${f#./}"

  # Expected canonical URL for this file
  if [ "$path" = "index.html" ]; then
    expected="$HOST/"
  elif [[ "$path" == */index.html ]]; then
    expected="$HOST/${path%index.html}"
  else
    expected="$HOST/$path"
  fi

  # 1. Has a canonical link
  actual=$(grep -o 'rel="canonical" href="[^"]*"' "$f" | head -1 | sed 's/.*href="\([^"]*\)".*/\1/')
  if [ -z "$actual" ]; then
    echo "  [FAIL] $f missing <link rel=\"canonical\">"
    FAIL=1
    continue
  fi

  # 2. Canonical matches expected URL for this file's location
  if [ "$actual" != "$expected" ]; then
    echo "  [FAIL] $f canonical=$actual but should be $expected"
    FAIL=1
  fi

  # 3. og:url matches canonical (when present)
  og_url=$(grep -o 'property="og:url" content="[^"]*"' "$f" | head -1 | sed 's/.*content="\([^"]*\)".*/\1/')
  if [ -n "$og_url" ] && [ "$og_url" != "$expected" ]; then
    echo "  [FAIL] $f og:url=$og_url but canonical=$expected"
    FAIL=1
  fi

  # 4. Has og:image and twitter:card (soft)
  if ! grep -q 'property="og:image"' "$f"; then
    echo "  [WARN] $f missing og:image"
  fi
  if ! grep -q 'name="twitter:card"' "$f"; then
    echo "  [WARN] $f missing twitter:card"
  fi

  # 5. Canonical URL present in sitemap.xml
  if ! grep -q "<loc>$expected</loc>" sitemap.xml; then
    echo "  [FAIL] $expected not listed in sitemap.xml ($f)"
    FAIL=1
  fi
done

# 6. Every sitemap <loc> points to an extant file on disk
while IFS= read -r loc; do
  rel="${loc#$HOST/}"
  if [ -z "$rel" ]; then
    target="./index.html"
  elif [[ "$rel" == */ ]]; then
    target="./${rel}index.html"
  else
    target="./$rel"
  fi
  if [ ! -f "$target" ]; then
    echo "  [FAIL] sitemap references missing file: $loc (expected $target)"
    FAIL=1
  fi
done < <(grep -o '<loc>[^<]*</loc>' sitemap.xml | sed 's|<loc>\(.*\)</loc>|\1|')

# 7. Common internal-link rot check: flag references to known-deleted pages.
# Add new entries here whenever a public URL is deleted.
STALE_REFS=(
  "2026-04-22-getting-started.html"
)
for ref in "${STALE_REFS[@]}"; do
  hits=$(grep -rl "$ref" --include="*.html" . 2>/dev/null)
  if [ -n "$hits" ]; then
    echo "  [FAIL] stale reference to deleted '$ref' in:"
    echo "$hits" | sed 's/^/           /'
    FAIL=1
  fi
done

# 8. JSON-LD blocks must parse as valid JSON
if command -v python3 >/dev/null 2>&1; then
  python3 - $PAGES <<'PY'
import sys, re, json
bad = False
for fn in sys.argv[1:]:
    try:
        src = open(fn).read()
    except Exception:
        continue
    for i, m in enumerate(re.findall(r'<script type="application/ld\+json">(.*?)</script>', src, re.S)):
        try:
            json.loads(m)
        except Exception as e:
            print(f"  [FAIL] invalid JSON-LD block #{i+1} in {fn}: {e}")
            bad = True
sys.exit(1 if bad else 0)
PY
  if [ $? -ne 0 ]; then FAIL=1; fi
else
  echo "  [WARN] python3 not found; skipping JSON-LD parse check"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "OK — $COUNT HTML files validated."
  exit 0
else
  echo "FAILED — fix issues above, then re-run."
  exit 1
fi
