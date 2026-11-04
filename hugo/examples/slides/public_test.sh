#!/usr/bin/env bash
# Checks the rendered deck (the directory in $1) has its three slides, with
# both diagrams and reveal.js.
set -euo pipefail
p="$1"
test -f "$p/reveal/reveal.js"
test -f "$p/reveal/theme/white.css"
test -f "$p/diagrams/architecture.svg"
test -f "$p/diagrams/build.svg"
test "$(grep -o '<section>' "$p/talks/intro/index.html" | wc -l)" -eq 3
grep -q 'src="/diagrams/architecture.svg"' "$p/talks/intro/index.html"
grep -q 'src="/diagrams/build.svg"' "$p/talks/intro/index.html"
