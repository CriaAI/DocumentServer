FROM onlyoffice/documentserver:9.3.1

# --- Patch 1: Remove advancedApi license gate ---
# Uses perl for multi-line regex (available in Ubuntu base image).
# Removes the if(advancedApi)return; check from ALL JS files under sdkjs/.
COPY patch.sh /tmp/patch.sh
COPY createConnector.js /tmp/createConnector.js
COPY license-patch/ /tmp/license-patch/
COPY logo.png /tmp/logo.png
RUN chmod +x /tmp/patch.sh && /tmp/patch.sh && rm -rf /tmp/patch.sh /tmp/createConnector.js /tmp/license-patch /tmp/logo.png
