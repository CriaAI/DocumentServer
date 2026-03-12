#!/bin/bash
#
# Test script for Document Server conversion API
#
# Usage:
#   ./test-conversion.sh [DS_URL] [JWT_SECRET]
#
# Examples:
#   ./test-conversion.sh                                    # defaults: localhost:80, reads from .env
#   ./test-conversion.sh http://localhost:8080 mysecret
#

set -euo pipefail

# ── Config ──
DS_URL="${1:-http://localhost}"
JWT_SECRET="${2:-}"

# Try to read JWT_SECRET from .env if not provided
if [ -z "$JWT_SECRET" ]; then
    if [ -f .env ]; then
        JWT_SECRET=$(grep -E '^JWT_SECRET=' .env 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'")
    fi
    if [ -z "$JWT_SECRET" ]; then
        echo "ERROR: JWT_SECRET not provided and not found in .env"
        echo "Usage: $0 [DS_URL] [JWT_SECRET]"
        exit 1
    fi
fi

CONVERT_URL="${DS_URL}/ConvertService.ashx"

# ── Dependency check ──
for cmd in curl node; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: '$cmd' is required but not installed."
        exit 1
    fi
done

echo "=== Document Server Conversion API Test ==="
echo "URL:    $CONVERT_URL"
echo ""

# ── Step 1: Healthcheck ──
echo "1. Healthcheck..."
HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" "${DS_URL}/healthcheck" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    echo "   OK (HTTP $HTTP_CODE)"
else
    echo "   FAILED (HTTP $HTTP_CODE) - Is the Document Server running at ${DS_URL}?"
    exit 1
fi

# ── Step 2: Create a sample file and serve it ──
echo "2. Creating test file..."
TEMP_DIR=$(mktemp -d)
trap 'kill $FILE_SERVER_PID 2>/dev/null; rm -rf "$TEMP_DIR"' EXIT

# Copy the test docx file
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cp "$SCRIPT_DIR/7JmlOQV7ch1GxYj89vzl.docx" "$TEMP_DIR/"

# Start a simple HTTP file server
FILE_SERVER_PORT=9876
node -e "
const http = require('http');
const fs = require('fs');
const path = require('path');
const dir = '${TEMP_DIR}';
http.createServer((req, res) => {
  const file = path.join(dir, path.basename(req.url));
  if (fs.existsSync(file)) {
    res.writeHead(200, {'Content-Type': 'application/octet-stream'});
    fs.createReadStream(file).pipe(res);
  } else {
    res.writeHead(404); res.end('Not found');
  }
}).listen(${FILE_SERVER_PORT}, () => {});
" &
FILE_SERVER_PID=$!
sleep 1

# Docker Desktop: container reaches host via host.docker.internal
FILE_HOST="host.docker.internal"
FILE_URL="http://${FILE_HOST}:${FILE_SERVER_PORT}/7JmlOQV7ch1GxYj89vzl.docx"

echo "   File URL: $FILE_URL"

# ── Step 3: Build payload, sign JWT, and call conversion API ──
echo "3. Calling conversion API (docx -> html)..."

# Generate the full request body with a properly signed JWT token.
# The token must sign the entire payload (including all conversion params).
# OnlyOffice expects the token in BOTH the Authorization header AND the body.
REQUEST_BODY=$(node -e "
const crypto = require('crypto');

function base64url(data) {
  return Buffer.from(data)
    .toString('base64')
    .replace(/=/g, '')
    .replace(/\+/g, '-')
    .replace(/\//g, '_');
}

function signJwt(payload, secret) {
  const header = base64url(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
  const body = base64url(JSON.stringify(payload));
  const unsigned = header + '.' + body;
  const signature = crypto
    .createHmac('sha256', secret)
    .update(unsigned)
    .digest('base64')
    .replace(/=/g, '')
    .replace(/\+/g, '-')
    .replace(/\//g, '_');
  return unsigned + '.' + signature;
}

const secret = '${JWT_SECRET}';
const now = Math.floor(Date.now() / 1000);

// The conversion parameters
const params = {
  async: false,
  filetype: 'docx',
  outputtype: 'html',
  key: 'test-' + Date.now(),
  url: '${FILE_URL}'
};

// Sign the full payload
const token = signJwt({ ...params, iat: now, exp: now + 300 }, secret);

// Include token in body (JWT_IN_BODY=true)
const requestBody = { ...params, token: token };
console.log(JSON.stringify(requestBody));
")

echo "   Request body: $REQUEST_BODY"
echo ""

# Extract the token from the body for the Authorization header too
AUTH_TOKEN=$(echo "$REQUEST_BODY" | node -e "
const d = JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
console.log(d.token);
")

RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${AUTH_TOKEN}" \
    "${CONVERT_URL}" \
    -d "$REQUEST_BODY")

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | sed '$d')

echo "4. Response (HTTP $HTTP_CODE):"
echo "   $BODY"
echo ""

# ── Step 4: Parse XML response and download result ──
# Response format: <?xml ...><FileResult><FileUrl>...</FileUrl><EndConvert>True</EndConvert></FileResult>
# Or on error:    <?xml ...><FileResult><Error>-N</Error></FileResult>

# Check for error
ERROR_CODE=$(echo "$BODY" | sed -n 's/.*<Error>\(.*\)<\/Error>.*/\1/p')
if [ -n "$ERROR_CODE" ]; then
    echo "   CONVERSION FAILED (error code: $ERROR_CODE)"
    case "$ERROR_CODE" in
        -1) echo "   Meaning: Unknown error" ;;
        -2) echo "   Meaning: Conversion timeout" ;;
        -3) echo "   Meaning: Conversion error" ;;
        -4) echo "   Meaning: Error downloading source file (check URL accessibility from container)" ;;
        -5) echo "   Meaning: Incorrect password" ;;
        -6) echo "   Meaning: Error accessing conversion result database" ;;
        -7) echo "   Meaning: Input error" ;;
        -8) echo "   Meaning: Invalid JWT token" ;;
        *)  echo "   Meaning: Unknown" ;;
    esac
    echo ""
    echo "=== Test complete - FAILED ==="
    exit 1
fi

# Extract file URL from successful response
DOWNLOAD_URL=$(echo "$BODY" | sed -n 's/.*<FileUrl>\(.*\)<\/FileUrl>.*/\1/p')

# Unescape XML entities (e.g., &amp; -> &)
DOWNLOAD_URL=$(echo "$DOWNLOAD_URL" | sed 's/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g')

if [ -z "$DOWNLOAD_URL" ]; then
    echo "   No file URL in response"
    echo ""
    echo "=== Test complete - no output ==="
    exit 1
fi

echo "5. Downloading converted file..."

# The fileUrl may use the container's internal hostname — replace with our DS_URL
DOWNLOAD_URL=$(echo "$DOWNLOAD_URL" | sed "s|http://localhost[^/]*|${DS_URL}|g")
echo "   URL: $DOWNLOAD_URL"

OUTPUT_FILE="converted_output.html"
if curl -sf -o "$OUTPUT_FILE" "$DOWNLOAD_URL"; then
    FILE_SIZE=$(wc -c < "$OUTPUT_FILE" | tr -d ' ')
    echo "   Saved to: $(pwd)/$OUTPUT_FILE ($FILE_SIZE bytes)"
    echo ""
    echo "=== Test complete - SUCCESS ==="
else
    echo "   ERROR: Failed to download converted file"
    echo ""
    echo "=== Test complete - conversion OK but download failed ==="
    exit 1
fi
