#!/bin/bash
set -e

ROOT="/var/www/onlyoffice/documentserver"

echo "=== Patch 1: Remove advancedApi license gate ==="

PATCHED=0
for file in $(grep -rl 'advancedApi' "$ROOT" --include='*.js' 2>/dev/null); do
    echo "Found advancedApi in: $file"
    # The minified code has: <obfuscated>.advancedApi&&("connector"===...
    # Replace .advancedApi&& with && to bypass the license check.
    # This turns X.Y.advancedApi&&(...) into X.Y&&(...), which just
    # checks that licenseResult exists without requiring advancedApi flag.
    sed -i 's/\.advancedApi&&/\&\&/g' "$file"
    # Verify
    if grep -q '\.advancedApi' "$file"; then
        echo "  -> WARNING: .advancedApi still present after sed!"
    else
        echo "  -> Verified: advancedApi gate removed!"
    fi
    PATCHED=$((PATCHED + 1))
done

if [ "$PATCHED" -eq 0 ]; then
    echo "WARNING: No files with advancedApi pattern found!"
else
    echo "Patched $PATCHED file(s)"
fi

echo ""
echo "=== Patch 2: Add createConnector() to api.js.tpl ==="

# The actual api.js is generated at container startup from api.js.tpl
TPL_FILE="$ROOT/web-apps/apps/api/documents/api.js.tpl"

if [ ! -f "$TPL_FILE" ]; then
    echo "ERROR: Template not found at $TPL_FILE"
    echo "Searching for api.js.tpl..."
    find /var/www -name 'api.js.tpl' -type f 2>/dev/null
    exit 1
fi

echo "Found template: $TPL_FILE"
echo "File size: $(wc -c < "$TPL_FILE") bytes"

if grep -q 'createConnector' "$TPL_FILE"; then
    echo "Already patched, skipping."
else
    # Append the createConnector monkey-patch to the template
    cat /tmp/createConnector.js >> "$TPL_FILE"
    echo "Appended createConnector to api.js.tpl"
fi

if grep -q 'createConnector' "$TPL_FILE"; then
    echo "SUCCESS: createConnector is present in $TPL_FILE"
else
    echo "ERROR: createConnector not found after patching!"
    exit 1
fi

echo ""
echo "=== Patch 3: Remove connection limit (server-side) ==="

# The docservice binary is compiled with `pkg` and uses /snapshot/server/...
# as its virtual filesystem. Files placed on the real filesystem at the same
# path take precedence over the bundled versions.

SNAPSHOT_DIR="/snapshot/server/Common/sources"
mkdir -p "$SNAPSHOT_DIR"

# Copy the original source files from our repo as the base
cp /tmp/license-patch/constants.js "$SNAPSHOT_DIR/constants.js"
cp /tmp/license-patch/license.js "$SNAPSHOT_DIR/license.js"

echo "Placed patched license.js and constants.js at $SNAPSHOT_DIR"
ls -la "$SNAPSHOT_DIR"

echo ""
echo "=== All patches applied successfully ==="
