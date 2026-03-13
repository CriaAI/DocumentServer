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
echo "=== Patch 3: Remove Google Analytics telemetry ==="

# The pre-built image ships both individual JS files and minified bundles.
# We need to neutralize GA in all forms:
#   1. The Analytics.js file itself (source or minified)
#   2. Minified bundles that inline the GA code
#   3. Embed HTML files that load Analytics.js via <script> tags
#   4. Any trackEvent / initialize calls referencing the GA tracking ID

GA_PATCHED=0

# --- 3a. Neutralize Analytics.js (replace with no-op stub) ---
ANALYTICS_FILE="$ROOT/web-apps/apps/common/Analytics.js"
if [ -f "$ANALYTICS_FILE" ]; then
    cat > "$ANALYTICS_FILE" << 'STUB'
if(window.Common===undefined)window.Common={};Common.component=Common.component||{};
Common.Analytics=Common.component.Analytics=new function(){return{initialize:function(){},trackEvent:function(){}}}();
STUB
    echo "  -> Analytics.js replaced with no-op stub"
    GA_PATCHED=$((GA_PATCHED + 1))
else
    echo "  -> Analytics.js not found at expected path (may be bundled)"
fi

# --- 3b. Remove GA script tags from embed HTML files ---
for html in $(find "$ROOT/web-apps" -name '*.html' -type f 2>/dev/null); do
    if grep -q 'Analytics\.js' "$html"; then
        sed -i '/Analytics\.js/d' "$html"
        echo "  -> Removed Analytics.js script tag from: $html"
        GA_PATCHED=$((GA_PATCHED + 1))
    fi
done

# --- 3c. Neutralize GA in minified bundles ---
# In minified code, the GA loader appears as a string containing "google-analytics.com/ga.js"
# We replace the URL with an empty string so the script loader becomes a no-op.
for file in $(grep -rl 'google-analytics\.com' "$ROOT" --include='*.js' 2>/dev/null); do
    sed -i 's|google-analytics\.com/ga\.js||g' "$file"
    sed -i 's|google-analytics\.com||g' "$file"
    echo "  -> Removed google-analytics.com references from: $file"
    GA_PATCHED=$((GA_PATCHED + 1))
done

# --- 3d. Neutralize the GA tracking ID across all JS files ---
# The tracking ID UA-12442749-13 is the fingerprint that identifies OnlyOffice.
# Removing it ensures even if some GA code path survives, it won't register.
for file in $(grep -rl 'UA-12442749' "$ROOT" --include='*.js' 2>/dev/null); do
    sed -i 's/UA-12442749-[0-9]*/REMOVED/g' "$file"
    echo "  -> Removed GA tracking ID from: $file"
    GA_PATCHED=$((GA_PATCHED + 1))
done

# --- 3e. Neutralize _gaq references in minified bundles ---
# The legacy GA protocol uses window._gaq.push(). We replace _gaq.push calls
# with no-ops to prevent any data from being sent even if the GA script somehow loads.
for file in $(grep -rl '_gaq\.push\|_gaq\[' "$ROOT" --include='*.js' 2>/dev/null | grep -v 'Analytics\.js'); do
    # Replace _gaq.push([...]) with void(0) — safe in minified code
    sed -i 's/_gaq\.push(/void(/g' "$file"
    echo "  -> Neutralized _gaq.push calls in: $file"
    GA_PATCHED=$((GA_PATCHED + 1))
done

# --- Verification ---
REMAINING=$(grep -rl 'google-analytics\.com' "$ROOT" --include='*.js' --include='*.html' 2>/dev/null || true)
if [ -n "$REMAINING" ]; then
    echo "  WARNING: Residual google-analytics.com references found in:"
    echo "$REMAINING" | sed 's/^/    /'
else
    echo "  -> Verified: No google-analytics.com references remain"
fi

REMAINING_ID=$(grep -rl 'UA-12442749' "$ROOT" --include='*.js' 2>/dev/null || true)
if [ -n "$REMAINING_ID" ]; then
    echo "  WARNING: Residual GA tracking ID found in:"
    echo "$REMAINING_ID" | sed 's/^/    /'
else
    echo "  -> Verified: No GA tracking ID (UA-12442749) remains"
fi

echo "Google Analytics patch applied to $GA_PATCHED file(s)"

echo ""
echo "=== Patch 4: Remove connection limit (server-side) ==="

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
echo "=== Patch 5: Replace CORS allowed origins ==="

CONFIG_FILE="$ROOT/../server/Common/config/default.json"
if [ -f "$CONFIG_FILE" ]; then
    sed -i 's|\("allowedCorsOrigins"\s*:\s*\)\[.*\]|\1["https://copiloto.criaai.com", "https://copiloto-dev.criaai.com", "https://copiloto-staging.criaai.com", "https://2ezzay1go1.execute-api.sa-east-1.amazonaws.com"]|' "$CONFIG_FILE"
    # Also remove sales@onlyoffice.com from notification templates
    sed -i 's|Please contact sales@onlyoffice.com to discuss license renewal.|Please contact support to discuss license renewal.|' "$CONFIG_FILE"
    echo "  -> CORS origins and email references updated in default.json"
else
    echo "  WARNING: Config file not found at $CONFIG_FILE"
    # Try alternate path
    ALT_CONFIG="/etc/onlyoffice/documentserver/default.json"
    if [ -f "$ALT_CONFIG" ]; then
        sed -i 's|\("allowedCorsOrigins"\s*:\s*\)\[.*\]|\1["https://copiloto.criaai.com", "https://copiloto-dev.criaai.com", "https://copiloto-staging.criaai.com", "https://2ezzay1go1.execute-api.sa-east-1.amazonaws.com"]|' "$ALT_CONFIG"
        sed -i 's|Please contact sales@onlyoffice.com to discuss license renewal.|Please contact support to discuss license renewal.|' "$ALT_CONFIG"
        echo "  -> CORS origins and email references updated in $ALT_CONFIG"
    else
        echo "  ERROR: No config file found!"
    fi
fi

echo ""
echo "=== Patch 6: Remove OnlyOffice references from AdminPanel ==="

AP_PATCHED=0

# LoginPage.js — replace title and remove helpcenter link
for file in $(find /var/www /etc -path '*/AdminPanel/*/LoginPage.js' -type f 2>/dev/null); do
    # Replace "ONLYOFFICE Admin Panel" with "CriaAI Admin Panel"
    sed -i "s|ONLYOFFICE Admin Panel|CriaAI Admin Panel|g" "$file"
    # Remove the helpcenter.onlyoffice.com link block (minified or source)
    sed -i 's|https://helpcenter\.onlyoffice\.com[^"'"'"']*||g' "$file"
    echo "  -> Patched LoginPage.js: $file"
    AP_PATCHED=$((AP_PATCHED + 1))
done

# package.json — replace homepage URL
for file in $(find /var/www /etc -path '*/AdminPanel/*/package.json' -type f 2>/dev/null); do
    if grep -qF 'onlyoffice.com' "$file"; then
        sed -i 's|https://www\.onlyoffice\.com|https://copiloto.criaai.com|g' "$file"
        echo "  -> Patched package.json: $file"
        AP_PATCHED=$((AP_PATCHED + 1))
    fi
done

# engine.js — blank out OnlyOffice proxy URL
for file in $(find /var/www /etc -path '*/AdminPanel/*/engine.js' -type f 2>/dev/null); do
    if grep -qF 'plugins-services.onlyoffice.com' "$file"; then
        sed -i 's|https://plugins-services\.onlyoffice\.com/proxy||g' "$file"
        echo "  -> Patched engine.js: $file"
        AP_PATCHED=$((AP_PATCHED + 1))
    fi
done

# Catch-all: any remaining onlyoffice.com references in AdminPanel JS/HTML files
for file in $(find /var/www /etc -path '*/AdminPanel/*' \( -name '*.js' -o -name '*.html' -o -name '*.json' \) -type f 2>/dev/null); do
    if grep -qF 'onlyoffice.com' "$file"; then
        echo "  -> WARNING: Residual onlyoffice.com reference in: $file"
    fi
done

if [ "$AP_PATCHED" -eq 0 ]; then
    echo "  -> No AdminPanel files found (may not be present in this image variant)"
else
    echo "  AdminPanel patch applied to $AP_PATCHED file(s)"
fi

echo ""
echo "=== Patch 7: Remove OnlyOffice external URL references ==="

# Replaces OnlyOffice default URLs baked into the compiled web-apps with
# values provided via environment variables (set from Dockerfile ARGs).
# Empty values (the default) effectively blank out the URL, preventing
# domain exposure during source inspection or traffic interception.

URL_PATCHED=0

replace_url() {
    local search="$1"
    local replace="$2"
    local label="$3"
    local count=0

    # Escape & in replacement string (special in sed substitution)
    local safe_replace="${replace//&/\\&}"

    for file in $(grep -rFl "$search" "$ROOT/web-apps" --include='*.js' --include='*.html' 2>/dev/null); do
        sed -i "s|${search}|${safe_replace}|g" "$file"
        count=$((count + 1))
    done

    URL_PATCHED=$((URL_PATCHED + count))
    if [ "$count" -gt 0 ]; then
        echo "  -> $label: replaced in $count file(s)"
    else
        echo "  -> $label: no matches found"
    fi
}

# Order: most specific paths first to avoid partial matches on broader domains

# api.onlyoffice.com (specific paths before any broader match)
replace_url 'https://api.onlyoffice.com/editors/callback' "${BRAND_API_CALLBACK_URL:-}" "API callback URL"
replace_url 'https://api.onlyoffice.com/plugin/basic'     "${BRAND_PLUGIN_URL:-}"         "Plugin docs URL"
replace_url 'https://api.onlyoffice.com/plugin/macros'    "${BRAND_PLUGIN_MACROS_URL:-}"   "Plugin macros URL"

# helpcenter.onlyoffice.com (base URL — also covers /userguides/* sub-paths)
replace_url 'https://helpcenter.onlyoffice.com' "${BRAND_HELP_URL:-}" "Help center URL"

# feedback.onlyoffice.com
replace_url 'https://feedback.onlyoffice.com' "${BRAND_FEEDBACK_URL:-}" "Feedback URL"

# support.onlyoffice.com
replace_url 'https://support.onlyoffice.com' "${BRAND_SUPPORT_URL:-}" "Support URL"

# www.onlyoffice.com (publisher)
replace_url 'https://www.onlyoffice.com' "${BRAND_PUBLISHER_URL:-}" "Publisher URL"

# Email addresses
replace_url 'support@onlyoffice.com' "${BRAND_SUPPORT_EMAIL:-}" "Support email"
replace_url 'sales@onlyoffice.com'   "${BRAND_SALES_EMAIL:-}"   "Sales email"

# Company info (About dialog)
replace_url 'Ascensio System SIA' "${BRAND_PUBLISHER_NAME:-CriaAI}" "Publisher name"
replace_url '20A-12 Ernesta Birznieka-Upisha street, Riga, Latvia, EU, LV-1050' "${BRAND_PUBLISHER_ADDRESS:-}" "Publisher address"
replace_url '+371 633-99867' "${BRAND_PUBLISHER_PHONE:-}" "Publisher phone"

# --- Verification ---
REMAINING_URLS=$(grep -rFl 'onlyoffice.com' "$ROOT/web-apps" --include='*.js' --include='*.html' 2>/dev/null || true)
if [ -n "$REMAINING_URLS" ]; then
    echo "  WARNING: Residual onlyoffice.com references found in:"
    echo "$REMAINING_URLS" | sed 's/^/    /'
    echo "  (May be in comments, copyright notices, or non-URL contexts)"
else
    echo "  -> Verified: No onlyoffice.com references remain in web-apps"
fi

echo "URL rebranding patch applied to $URL_PATCHED file(s)"

echo ""
echo "=== Patch 8: Harden HTTP headers (nginx + Express) ==="

# --- 8a. Nginx: disable server_tokens and strip revealing headers ---
NGINX_PATCHED=0

for conf in $(find /etc/nginx /etc/onlyoffice -name '*.conf' -type f 2>/dev/null); do
    # Add server_tokens off if not already present
    if grep -q 'server_tokens' "$conf"; then
        sed -i 's/server_tokens\s*on/server_tokens off/g' "$conf"
        echo "  -> Set server_tokens off in: $conf"
        NGINX_PATCHED=$((NGINX_PATCHED + 1))
    elif grep -q 'http\s*{' "$conf"; then
        sed -i '/http\s*{/a\    server_tokens off;' "$conf"
        echo "  -> Added server_tokens off to http block in: $conf"
        NGINX_PATCHED=$((NGINX_PATCHED + 1))
    fi

    # Hide upstream headers that reveal technology
    if grep -q 'proxy_pass' "$conf" && ! grep -q 'proxy_hide_header X-Powered-By' "$conf"; then
        sed -i '/proxy_pass/a\        proxy_hide_header X-Powered-By;' "$conf"
        echo "  -> Added proxy_hide_header X-Powered-By in: $conf"
        NGINX_PATCHED=$((NGINX_PATCHED + 1))
    fi
done

# --- 8b. SpellChecker: disable x-powered-by (compiled server in base image) ---
for file in $(find /var/www /etc -path '*/SpellChecker/*/server.js' -type f 2>/dev/null); do
    if ! grep -q "disable.*x-powered-by" "$file"; then
        # Insert app.disable('x-powered-by') after app = express()
        sed -i "/app\s*=\s*express()/a\\	app.disable('x-powered-by');" "$file"
        echo "  -> Disabled x-powered-by in SpellChecker: $file"
        NGINX_PATCHED=$((NGINX_PATCHED + 1))
    else
        echo "  -> SpellChecker x-powered-by already disabled: $file"
    fi
done

if [ "$NGINX_PATCHED" -eq 0 ]; then
    echo "  -> No nginx configs or SpellChecker files found to patch"
else
    echo "  HTTP header hardening applied to $NGINX_PATCHED file(s)"
fi

echo ""
echo "=== Patch 9: Remove OnlyOffice UI branding ==="

BRAND_PATCHED=0

# --- 9a. Hide Help and Suggest a Feature menu items ---
# Force canHelp=false and canSuggest=false in all editor app.js bundles
# by replacing the appOptions assignment. Also blank the residual suggest URL path.
for file in $(find "$ROOT/web-apps" -path "*/main/app.js" -type f 2>/dev/null); do
    sed -i 's|this\.appOptions\.canHelp=!|this.appOptions.canHelp=!!0\&\&!|g' "$file"
    sed -i 's|this\.appOptions\.canSuggest=!|this.appOptions.canSuggest=!!0\&\&!|g' "$file"
    sed -i 's|/forums/966080-your-voice-matters?category_id=519084||g' "$file"
    echo "  -> Disabled Help & Suggest menus in: $file"
    BRAND_PATCHED=$((BRAND_PATCHED + 1))
done
for file in $(find "$ROOT/web-apps" -path "*/mobile/dist/js/app.js" -type f 2>/dev/null); do
    sed -i 's|/forums/966080-your-voice-matters?category_id=519084||g' "$file"
done

# --- 9b. api.js.tpl: replace customer=ONLYOFFICE ---
TPL_API="$ROOT/web-apps/apps/api/documents/api.js.tpl"
if [ -f "$TPL_API" ]; then
    sed -i 's|customer=ONLYOFFICE|customer=CriaAI|g' "$TPL_API"
    sed -i 's|http://www\.onlyoffice\.com|https://copiloto.criaai.com|g' "$TPL_API"
    echo "  -> Patched api.js.tpl branding"
    BRAND_PATCHED=$((BRAND_PATCHED + 1))
fi

# --- 9b. Welcome page: replace ONLYOFFICE branding and links ---
WELCOME="$ROOT/server/welcome/index.html"
if [ -f "$WELCOME" ]; then
    sed -i 's|ONLYOFFICE™|CriaAI Docs|g' "$WELCOME"
    sed -i 's|ONLYOFFICE|CriaAI|g' "$WELCOME"
    sed -i 's|https://api\.onlyoffice\.com[^"]*||g' "$WELCOME"
    sed -i 's|http://dev\.onlyoffice\.org[^"]*||g' "$WELCOME"
    sed -i 's|http://helpcenter\.onlyoffice\.com[^"]*||g' "$WELCOME"
    echo "  -> Patched welcome page"
    BRAND_PATCHED=$((BRAND_PATCHED + 1))
fi

# --- 9c. Replace logo SVGs with CriaAI logo (embedded PNG) ---
# DISABLED: Keep the original OnlyOffice logo in the editor UI.
# To re-enable, uncomment the block below.
#
# LOGO_PNG="/tmp/logo.png"
# if [ -f "$LOGO_PNG" ]; then
#     LOGO_B64=$(base64 -w0 "$LOGO_PNG" 2>/dev/null || base64 "$LOGO_PNG" | tr -d '\n')
#     LOGO_DATA_URI="data:image/png;base64,${LOGO_B64}"
# else
#     echo "  WARNING: /tmp/logo.png not found, using text fallback"
#     LOGO_DATA_URI=""
# fi
#
# if [ -n "$LOGO_DATA_URI" ]; then
#     CRIAAI_HEADER_LOGO="<svg width=\"100\" height=\"14\" viewBox=\"0 0 100 14\" xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\"><image href=\"${LOGO_DATA_URI}\" x=\"0\" y=\"0\" width=\"100\" height=\"14\" preserveAspectRatio=\"xMinYMid meet\"/></svg>"
#     CRIAAI_HEADER_LOGO_DARK="$CRIAAI_HEADER_LOGO"
#     CRIAAI_ABOUT_LOGO="<svg width=\"187\" height=\"80\" viewBox=\"0 0 187 80\" xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\"><image href=\"${LOGO_DATA_URI}\" x=\"0\" y=\"0\" width=\"187\" height=\"80\" preserveAspectRatio=\"xMidYMid meet\"/></svg>"
#     CRIAAI_ABOUT_LOGO_WHITE="$CRIAAI_ABOUT_LOGO"
# else
#     CRIAAI_HEADER_LOGO='<svg width="100" height="14" viewBox="0 0 100 14" xmlns="http://www.w3.org/2000/svg"><text x="0" y="12" font-family="Arial, Helvetica, sans-serif" font-size="14" font-weight="bold" fill="white">CriaAI</text></svg>'
#     CRIAAI_HEADER_LOGO_DARK='<svg width="100" height="14" viewBox="0 0 100 14" xmlns="http://www.w3.org/2000/svg"><text x="0" y="12" font-family="Arial, Helvetica, sans-serif" font-size="14" font-weight="bold" fill="#444">CriaAI</text></svg>'
#     CRIAAI_ABOUT_LOGO='<svg width="187" height="80" viewBox="0 0 187 80" xmlns="http://www.w3.org/2000/svg"><text x="93" y="45" font-family="Arial, Helvetica, sans-serif" font-size="24" font-weight="bold" fill="#333" text-anchor="middle">CriaAI</text><text x="93" y="70" font-family="Arial, Helvetica, sans-serif" font-size="12" fill="#666" text-anchor="middle">Document Server</text></svg>'
#     CRIAAI_ABOUT_LOGO_WHITE='<svg width="187" height="80" viewBox="0 0 187 80" xmlns="http://www.w3.org/2000/svg"><text x="93" y="45" font-family="Arial, Helvetica, sans-serif" font-size="24" font-weight="bold" fill="white" text-anchor="middle">CriaAI</text><text x="93" y="70" font-family="Arial, Helvetica, sans-serif" font-size="12" fill="#ccc" text-anchor="middle">Document Server</text></svg>'
# fi
#
# for file in $(find "$ROOT/web-apps" -type f -name "header-logo*.svg" ! -name "*.gz" 2>/dev/null); do
#     if echo "$file" | grep -qi "dark\|light"; then
#         echo "$CRIAAI_HEADER_LOGO_DARK" > "$file"
#     else
#         echo "$CRIAAI_HEADER_LOGO" > "$file"
#     fi
#     BRAND_PATCHED=$((BRAND_PATCHED + 1))
# done
#
# for file in $(find "$ROOT/web-apps" -type f \( -name "logo_s.svg" -o -name "header-logo_s.svg" \) ! -name "*.gz" 2>/dev/null); do
#     echo "$CRIAAI_HEADER_LOGO" > "$file"
#     BRAND_PATCHED=$((BRAND_PATCHED + 1))
# done
# for file in $(find "$ROOT/web-apps" -type f -name "dark-logo_s.svg" ! -name "*.gz" 2>/dev/null); do
#     echo "$CRIAAI_HEADER_LOGO_DARK" > "$file"
#     BRAND_PATCHED=$((BRAND_PATCHED + 1))
# done
# for file in $(find "$ROOT/web-apps" -type f -name "white-logo_s.svg" ! -name "*.gz" 2>/dev/null); do
#     echo "$CRIAAI_HEADER_LOGO" > "$file"
#     BRAND_PATCHED=$((BRAND_PATCHED + 1))
# done
#
# for file in $(find "$ROOT/web-apps" -type f -name "logo-new.svg" ! -name "*.gz" 2>/dev/null); do
#     echo "$CRIAAI_ABOUT_LOGO" > "$file"
#     BRAND_PATCHED=$((BRAND_PATCHED + 1))
# done
# for file in $(find "$ROOT/web-apps" -type f -name "logo-new-white.svg" ! -name "*.gz" 2>/dev/null); do
#     echo "$CRIAAI_ABOUT_LOGO_WHITE" > "$file"
#     BRAND_PATCHED=$((BRAND_PATCHED + 1))
# done
# for file in $(find "$ROOT/web-apps" -type f -name "logo-white_s.svg" ! -name "*.gz" 2>/dev/null); do
#     echo "$CRIAAI_ABOUT_LOGO_WHITE" > "$file"
#     BRAND_PATCHED=$((BRAND_PATCHED + 1))
# done
# for file in $(find "$ROOT/web-apps" -type f -name "logo.svg" ! -name "*.gz" 2>/dev/null); do
#     echo "$CRIAAI_ABOUT_LOGO" > "$file"
#     BRAND_PATCHED=$((BRAND_PATCHED + 1))
# done
#
# for file in $(find "$ROOT/web-apps" -type f -name "logo-android.svg" ! -name "*.gz" 2>/dev/null); do
#     echo "$CRIAAI_HEADER_LOGO" > "$file"
#     BRAND_PATCHED=$((BRAND_PATCHED + 1))
# done
# for file in $(find "$ROOT/web-apps" -type f -name "logo-ios.svg" ! -name "*.gz" 2>/dev/null); do
#     echo "$CRIAAI_HEADER_LOGO" > "$file"
#     BRAND_PATCHED=$((BRAND_PATCHED + 1))
# done

# --- 9d. Replace PNG header logos and favicons with CriaAI logo ---
# DISABLED: Keep the original OnlyOffice logo.
# if [ -f "$LOGO_PNG" ]; then
#     for file in $(find "$ROOT/web-apps" -type f -name "header-logo*.png" ! -name "*.gz" 2>/dev/null); do
#         cp "$LOGO_PNG" "$file"
#         BRAND_PATCHED=$((BRAND_PATCHED + 1))
#     done
#     echo "  -> Replaced PNG header logos"
# fi

# --- 9e. Regenerate .gz copies for all patched SVGs ---
# DISABLED: No SVG logos were patched, so no .gz regeneration needed.
# GZ_REGEN=0
# for svgfile in $(find "$ROOT/web-apps" -type f -name "*.svg" ! -name "*.gz" 2>/dev/null); do
#     gzfile="${svgfile}.gz"
#     if [ -f "$gzfile" ]; then
#         gzip -c -9 "$svgfile" > "$gzfile"
#         GZ_REGEN=$((GZ_REGEN + 1))
#     fi
# done
# echo "  -> Regenerated $GZ_REGEN .gz copies"
echo "  -> Logo replacement SKIPPED (keeping original OnlyOffice logos)"

echo "  UI branding patch applied to $BRAND_PATCHED file(s)"

echo ""
echo "=== Patch 10: Harden editor iframe with sandbox attribute ==="

# Add sandbox="allow-scripts allow-same-origin allow-forms allow-popups allow-downloads allow-modals"
# to the iframe created by createIframe() in api.js.tpl.
# This restricts the iframe to only the capabilities the editor needs while blocking
# things like top-navigation and pointer-lock.
# We anchor on the unique "allow" setAttribute line and append our sandbox line after it.

SANDBOX_ATTR='iframe.setAttribute("sandbox", "allow-scripts allow-same-origin allow-forms allow-popups allow-downloads allow-modals");'

SANDBOX_PATCHED=0

for file in "$ROOT/web-apps/apps/api/documents/api.js.tpl" "$ROOT/web-apps/apps/api/documents/api.js"; do
    if [ ! -f "$file" ]; then
        continue
    fi

    if grep -q 'sandbox' "$file"; then
        echo "  -> Already has sandbox attribute: $file"
    else
        sed -i '/iframe\.setAttribute("allow",.*clipboard-write/a\        '"$SANDBOX_ATTR" "$file"
        if grep -q 'sandbox' "$file"; then
            echo "  -> Added sandbox attribute to iframe in: $file"
            SANDBOX_PATCHED=$((SANDBOX_PATCHED + 1))
        else
            echo "  WARNING: Failed to inject sandbox attribute in: $file"
        fi
    fi
done

if [ "$SANDBOX_PATCHED" -eq 0 ]; then
    echo "  -> No files needed patching (already patched or not found)"
else
    echo "  Iframe sandbox patch applied to $SANDBOX_PATCHED file(s)"
fi

echo ""
echo "=== All patches applied successfully ==="
