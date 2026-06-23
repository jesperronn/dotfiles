#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
BUILDER="$DIR/presentation-builder"
PASS=0; FAIL=0

ok()   { echo "[PASS] $1"; ((PASS++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

# Setup
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── Test: no args prints usage and exits non-zero ────────────────
USAGE_OUT="$("$BUILDER" 2>&1 || true)"
if echo "$USAGE_OUT" | grep -qi "usage"; then
  ok "no args prints usage"
else
  fail "no args should print usage"
fi

# ── Test: missing file exits non-zero ───────────────────────────
if ! "$BUILDER" "$TMP/nonexistent.md" 2>/dev/null; then
  ok "missing file exits non-zero"
else
  fail "missing file should exit non-zero"
fi

# ── Test: basic build produces .html with same basename ─────────
cat > "$TMP/my-slides.md" <<'MD'
# Hello World

Subtitle here

---

## Slide Two

- Bullet one
- Bullet two
MD

"$BUILDER" "$TMP/my-slides.md" > /dev/null
OUTPUT="$TMP/my-slides.html"

if [[ -f "$OUTPUT" ]]; then
  ok "output file created with .html extension"
else
  fail "output file not found: $OUTPUT"
fi

# ── Test: output is valid HTML (has doctype and closing tag) ─────
if grep -q "<!DOCTYPE html>" "$OUTPUT" && grep -q "</html>" "$OUTPUT"; then
  ok "output contains DOCTYPE and closing html tag"
else
  fail "output missing DOCTYPE or </html>"
fi

# ── Test: markdown content is embedded in source block ──────────
if grep -q "Hello World" "$OUTPUT" && grep -q "Bullet one" "$OUTPUT"; then
  ok "markdown content embedded in output"
else
  fail "markdown content missing from output"
fi

# ── Test: slide separator (---) is preserved in source block ────
if grep -q "text/markdown" "$OUTPUT"; then
  ok "markdown script tag present"
else
  fail "markdown script tag missing"
fi

# ── Test: [slide:hidden] slides supported (content still in source) ─
cat > "$TMP/hidden.md" <<'MD'
# Visible Slide

Content here

---

[slide:hidden]
## Hidden Slide

Secret content
MD

"$BUILDER" "$TMP/hidden.md" > /dev/null
if grep -q "Secret content" "$TMP/hidden.html"; then
  ok "[slide:hidden] content present in source (filtered by JS)"
else
  fail "[slide:hidden] content missing from source block"
fi

# ── Summary ──────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
