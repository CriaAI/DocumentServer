FROM onlyoffice/documentserver:latest

# --- Patch 1: Remove advancedApi license gate ---
# Uses perl for multi-line regex (available in Ubuntu base image).
# Removes the if(advancedApi)return; check from ALL JS files under sdkjs/.
COPY patch.sh /tmp/patch.sh
COPY createConnector.js /tmp/createConnector.js
RUN chmod +x /tmp/patch.sh && /tmp/patch.sh && rm /tmp/patch.sh /tmp/createConnector.js
