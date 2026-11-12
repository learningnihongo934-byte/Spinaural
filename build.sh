#!/usr/bin/env bash
# Builds dist/ (the page plus vendored libraries) from src/ and vendor/.
#   ./build.sh          build
#   ./build.sh serve    build, then serve it at http://localhost:8830
#   ./build.sh deploy   build, then publish to https://spinaural.rennko.tech (Cloudflare Workers)
set -euo pipefail
cd "$(dirname "$0")"

rm -rf dist && mkdir -p dist/vendor
cp src/index.html dist/index.html
cp vendor/mediabunny.min.mjs vendor/lamejs.js dist/vendor/
echo "Built dist/"

case "${1:-}" in
  serve)
    echo "Serving at http://localhost:8830"
    python3 -m http.server 8830 --directory dist ;;
  deploy) npx -y wrangler@4 deploy ;;
esac
